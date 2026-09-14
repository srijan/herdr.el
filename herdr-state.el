;;; herdr-state.el --- Session state cache for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; One cache of herdr's session, hydrated by `session.snapshot' and kept
;; current by the event stream.  Everything else in this package reads
;; the cache instead of issuing its own RPC, so the modeline, the agents
;; buffer and the pickers all cost nothing to refresh.
;;
;; Two event connections.  A carries the global subscriptions, needs no
;; pane id, and is never rebuilt.  B carries per-pane
;; `pane.agent_status_changed' for the agent panes and is rebuilt when
;; that set changes.
;;
;; B is the status channel and is prompt by construction: the server
;; backs each per-pane subscription with a 100ms snapshot compare, so a
;; transition arrives within a tick even if its event was lost.
;;
;; A must not subscribe to `pane.updated'.  It fires on every terminal
;; title change, roughly 7.5 times a second per busy agent, and the
;; server delivers at most one event per type per 100ms tick: one agent
;; nearly saturates the channel and two put it permanently behind.
;; Everything it carries arrives elsewhere anyway — status through B,
;; lifecycle through the `pane.*' events, volatile fields through
;; `herdr-state-reconcile-panes'.
;;
;; Events missed during a disconnect cannot be replayed, so every
;; reconnect is followed by a full resync rather than an attempt to
;; resume.
;;
;; The cadence — the periodic repair, the post-connect settle and the
;; hydration a reconnect does — is asynchronous throughout.  A server
;; that is unreachable fails at once, but one that accepts the
;; connection and never answers costs its whole deadline, and paying
;; that on the main thread is paying it for every connection in turn.
;; Each of those paths therefore carries its continuation and its
;; generation: what depended on the ordering a blocking call gave for
;; free now says so, and a reply belonging to a session that has since
;; stopped is dropped rather than folded.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr-rpc)
(require 'herdr-connection)
(require 'herdr-pane)
(require 'herdr-workspace)

(defcustom herdr-state-reconnect-min 1.0
  "Initial delay, in seconds, before retrying a dropped event stream."
  :type 'number
  :group 'herdr)

(defcustom herdr-state-reconnect-max 30.0
  "Longest delay, in seconds, between event stream reconnect attempts."
  :type 'number
  :group 'herdr)

(defvar herdr-state-change-functions nil
  "Abnormal hook run after the cache changes.
Each function is called with (EVENT-KIND DATA).  EVENT-KIND is the
string herdr used; DATA is its payload alist.  On a resync, EVENT-KIND
is \"resync\" and DATA is nil.")

(defconst herdr-state-global-subscriptions
  '("workspace.created" "workspace.updated" "workspace.metadata_updated"
    "workspace.renamed" "workspace.moved" "workspace.reordered"
    "workspace.closed" "workspace.focused"
    "worktree.created" "worktree.opened" "worktree.removed"
    "pane.created" "pane.closed" "pane.focused"
    "pane.moved" "pane.exited" "pane.agent_detected"
    "layout.updated")
  "Subscriptions that carry no pane id and so never need rebuilding.

`pane.updated\\=' is deliberately absent; the commentary at the top of
this file says why, and `herdr-state-reconcile-panes\\=' covers what it
alone carried.

Order matters, so do not sort this.  The server polls each subscription
in the order listed here and emits at most one matching event for each
pass, so a burst delivered across one pass arrives in list order rather
than in the order the events happened.  A `pane.created\\=' for a pane
that has already closed therefore folds away only because
`pane.closed\\=' is listed after it.

Through herdr 0.8.2 this governed the whole 512-event replay a fresh
subscription began with, and getting it wrong left ghosts from hours
earlier.  0.9.0 starts a subscription at the sequence its request
arrived on, so the window is now milliseconds wide.  The ordering stays:
it costs nothing, and `herdr-state-reconcile-panes\\=' is what makes the
result right rather than lucky either way.")

;;; The state object

(cl-defstruct (herdr-state (:constructor herdr-state--make)
                           (:copier herdr-state-copy))
  (panes nil)
  (workspaces nil)
  ;; Named `agent-info' rather than `agents': a slot called `agents'
  ;; would generate `herdr-state-agents', clobbering the function of that
  ;; name below.  This holds the raw AgentInfo array from
  ;; `session.snapshot', which carries `name' — the one field no
  ;; PaneInfo has.
  (agent-info nil)
  (focused-pane-id nil)
  (focused-workspace-id nil))

(defun herdr-state-empty ()
  "Return an empty state."
  (herdr-state--make))

(defun herdr-state-from-snapshot (snapshot)
  "Build a state from SNAPSHOT, the payload of `session.snapshot'."
  (herdr-state--make
   :panes (alist-get 'panes snapshot)
   :workspaces (alist-get 'workspaces snapshot)
   :agent-info (alist-get 'agents snapshot)
   :focused-pane-id (alist-get 'focused_pane_id snapshot)
   :focused-workspace-id (alist-get 'focused_workspace_id snapshot)))

(defun herdr-state-pane (state id)
  "Return the pane in STATE whose id is ID, or nil."
  (seq-find (lambda (pane) (equal id (herdr-pane-id pane)))
            (herdr-state-panes state)))

(defun herdr-state-workspace (state id)
  "Return the workspace in STATE whose id is ID, or nil."
  (seq-find (lambda (workspace) (equal id (herdr-workspace-id workspace)))
            (herdr-state-workspaces state)))

(defun herdr-state-workspace-label (state id)
  "Return the label of the workspace ID in STATE, or nil.
Nil for a workspace the cache has no record of, and for one the server
labelled with an empty string: both mean the same thing to a caller, and
each has its own fallback - a buffer name wants the workspace id, a
confirmation wants the workspace id in parentheses."
  (herdr-workspace-label (herdr-state-workspace state id)))

(defun herdr-state-agents (state)
  "Return the panes in STATE with a detected or reported agent."
  (seq-filter (lambda (pane) (herdr-pane-agent pane))
              (herdr-state-panes state)))

(defun herdr-state-agent-name (state pane-id)
  "Return the name reported for the agent in PANE-ID, or nil.
STATE is the cache to look it up in.

Names live only in `session.snapshot\\='s `agents\\=' array; neither
`pane.list\\=' nor the pane events carry one, so this is refreshed on the
snapshot cadence rather than off the event stream.  Nil until someone
calls `agent.rename\\='."
  (when-let* ((agent (seq-find (lambda (candidate)
                                 (equal pane-id (alist-get 'pane_id candidate)))
                               (herdr-state-agent-info state))))
    (alist-get 'name agent)))

(defun herdr-state-workspace-directory (state workspace-id)
  "Return WORKSPACE-ID\\='s directory in STATE, or nil.

Protocol 19\\='s WorkspaceInfo carries no cwd of any kind, so it is derived
from the workspace\\='s panes: the first one that reports a `cwd\\='.  Panes
are held in cache order — snapshot order with later arrivals appended —
so that is the oldest pane herdr told us about, which is the one the
workspace was created in."
  (when-let* ((dir (seq-some (lambda (pane)
                               (and (equal workspace-id
                                           (herdr-pane-workspace-id pane))
                                    (herdr-pane-cwd pane)))
                             (herdr-state-panes state))))
    (file-name-as-directory dir)))

(defun herdr-state-workspace-for-directory (state root)
  "Return the workspace in STATE rooted at ROOT, or nil.

Compared through `herdr-state-workspace-directory\\=' because protocol 19
workspaces carry no cwd of their own — this used to compare against an
`identity_cwd\\=' field that does not exist, so it never matched and
`herdr-project\\=' made a fresh workspace every time it was called.  ROOT
is normalized first — with or without a trailing slash must match the
same workspace — so callers never have to agree on a convention
`herdr-state-workspace-directory\\=' already settles one way.

Shared rather than private to `herdr.el', which used to be its only
caller: `herdr-tree.el' needs the identical answer to decide whether a
known project root already has an open workspace, or is one the
dispatcher has never seen a pane in."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (seq-find (lambda (workspace)
                (equal root
                       (herdr-state-workspace-directory
                        state (herdr-workspace-id workspace))))
              (herdr-state-workspaces state))))

(defun herdr-state-pane-ids (state)
  "Return every pane id in STATE."
  (mapcar (lambda (pane) (herdr-pane-id pane))
          (herdr-state-panes state)))

;;; Pure reduction

(defun herdr-state--upsert (items key id new)
  "Return ITEMS with the entry whose KEY is ID replaced by NEW.
Position is preserved on replacement so that pickers and the agents
buffer do not reorder themselves as panes update.  When no entry
matches, NEW is appended."
  (if (seq-find (lambda (item) (equal id (alist-get key item))) items)
      (mapcar (lambda (item)
                (if (equal id (alist-get key item)) new item))
              items)
    (append items (list new))))

(defun herdr-state--remove (items key id)
  "Return ITEMS without the entry whose KEY is ID."
  (seq-remove (lambda (item) (equal id (alist-get key item))) items))

(defun herdr-state--reorder-block (items key ids before)
  "Return ITEMS with the entries named in IDS moved as one block.
KEY is the alist key holding each item's id.  IDS lists the moved
entries in their new relative order; they are spliced in ahead of the
entry whose id is BEFORE, or appended when BEFORE is nil or unknown.
Entries not in IDS keep their relative order, and ids with no matching
entry are skipped.  Like `herdr-state--upsert', ITEMS is not mutated."
  (let ((moved (delq nil
                     (mapcar (lambda (id)
                               (seq-find (lambda (item)
                                           (equal id (alist-get key item)))
                                         items))
                             ids)))
        (rest (seq-remove (lambda (item) (member (alist-get key item) ids))
                          items))
        (result nil)
        (spliced nil))
    (dolist (item rest)
      (when (and before (not spliced) (equal before (alist-get key item)))
        (setq result (append result moved) spliced t))
      (setq result (append result (list item))))
    (if spliced result (append result moved))))

(defun herdr-state--merge-item (items key id changes)
  "Return ITEMS with CHANGES merged into the entry whose KEY is ID.

CHANGES is an alist; keys it does not mention are left alone, which is
what most of herdr\\='s events need — a rename carries a label and nothing
else, and the rest of the record must survive it.  A key CHANGES maps to
nil is still written, since that is how an agent release clears a label.

When no entry matches, ITEMS comes back `eq\\=' to what went in, which is
how callers tell a miss from a merge.  ITEMS is never mutated."
  (let ((item (seq-find (lambda (candidate) (equal id (alist-get key candidate)))
                        items)))
    (if (not item)
        items
      (let ((merged (copy-alist item)))
        (dolist (cell changes)
          (setf (alist-get (car cell) merged) (cdr cell)))
        (herdr-state--upsert items key id merged)))))

(defun herdr-state--move-within (items key id index)
  "Return ITEMS with the entry whose KEY is ID placed at INDEX.

An ID no entry carries leaves ITEMS alone.  An INDEX past the end is
clamped.  Like `herdr-state--upsert\\=', ITEMS is not mutated.

INDEX counts against the list with the moved entry ALREADY REMOVED.
That is the usual convention, but it is NOT VERIFIED against herdr, and
only a forward move can tell the two readings apart.  The other reading
counts against the list including the entry and lands it one slot
earlier.  One real `workspace.move\\=' watched on the event stream would
settle it; until then the tests say which of the two they pin."
  (let ((moved (seq-find (lambda (item) (equal id (alist-get key item))) items)))
    (if (not moved)
        items
      (let* ((rest (delq moved (copy-sequence items)))
             (at (max 0 (min (length rest) (or index 0)))))
        (append (seq-take rest at) (list moved) (seq-drop rest at))))))

(defun herdr-state--merge-pane (state pane-id changes)
  "Return STATE with CHANGES merged into the pane named PANE-ID.
Absent panes are ignored.  Keys not present in CHANGES are left alone,
which matters because per-pane status events carry only a few fields."
  (let ((panes (herdr-state--merge-item (herdr-state-panes state)
                                        'pane_id pane-id changes)))
    (if (eq panes (herdr-state-panes state))
        state
      (let ((next (herdr-state-copy state)))
        (setf (herdr-state-panes next) panes)
        next))))

(defun herdr-state-reduce (state kind data)
  "Return a new state produced by applying event KIND with DATA to STATE.

Pure: STATE is never mutated.  KIND is herdr's event name.  Note that
global events use underscores while the three per-pane subscription
events use dots, so both spellings appear here deliberately."
  (let ((next (herdr-state-copy state)))
    (pcase kind
      ((or "pane_created" "pane_updated" "pane_moved")
       (let ((pane (alist-get 'pane data)))
         (if (not pane)
             state
           (setf (herdr-state-panes next)
                 (herdr-state--upsert (herdr-state-panes state) 'pane_id
                                      (herdr-pane-id pane) pane))
           next)))

      ((or "pane_closed" "pane_exited")
       (setf (herdr-state-panes next)
             (herdr-state--remove (herdr-state-panes state)
                                  'pane_id (alist-get 'pane_id data)))
       next)

      ("pane_focused"
       (setf (herdr-state-focused-pane-id next) (alist-get 'pane_id data))
       next)

      ("pane_agent_detected"
       ;; Flat: `pane_id', `workspace_id', `agent', and on a release
       ;; `released' with `final_status'.  No PaneInfo, so reading one
       ;; finds nil and the branch does nothing.
       ;;
       ;; Key off `released', not `agent'.  The schema allows `agent'
       ;; alongside `released' to name which agent went away, and a
       ;; release must clear the label or the pane is counted in the
       ;; modeline for the rest of the session.
       (let ((released (alist-get 'released data)))
         (herdr-state--merge-pane
          state (alist-get 'pane_id data)
          (cons (cons 'agent (unless released (alist-get 'agent data)))
                (when-let* ((status (alist-get 'final_status data)))
                  (list (cons 'agent_status status)))))))

      ("pane.agent_status_changed"
       ;; `display_agent' rides along because with `pane.updated' gone
       ;; this event is the only prompt carrier of it, and it is read —
       ;; buffer naming and the dashboard rows both prefer it over
       ;; `agent'.  The event also carries `title' and `state_labels',
       ;; which nothing here displays, so they are left unmerged.
       (herdr-state--merge-pane
        state (alist-get 'pane_id data)
        (seq-filter #'cdr
                    (list (cons 'agent_status (alist-get 'agent_status data))
                          (cons 'agent (alist-get 'agent data))
                          (cons 'display_agent
                                (alist-get 'display_agent data))))))

      ("pane.scroll_changed"
       (herdr-state--merge-pane state (alist-get 'pane_id data)
                                (list (cons 'scroll (alist-get 'scroll data)))))

      ((or "workspace_created" "workspace_updated"
           "workspace_metadata_updated")
       (let ((workspace (alist-get 'workspace data)))
         (if (not workspace)
             state
           (setf (herdr-state-workspaces next)
                 (herdr-state--upsert (herdr-state-workspaces state)
                                      'workspace_id
                                      (herdr-workspace-id workspace)
                                      workspace))
           next)))

      ("workspace_renamed"
       ;; Flat: `workspace_id' and the new `label', nothing more.  The
       ;; branch used to look for a whole WorkspaceInfo under
       ;; `workspace', found nothing and returned the state untouched —
       ;; so ten renames in one session never reached the cache and the
       ;; dashboard showed the old name until something forced a resync.
       (let ((workspaces (herdr-state--merge-item
                          (herdr-state-workspaces state) 'workspace_id
                          (alist-get 'workspace_id data)
                          (list (cons 'label (alist-get 'label data))))))
         (if (eq workspaces (herdr-state-workspaces state))
             state
           (setf (herdr-state-workspaces next) workspaces)
           next)))

      ("workspace_moved"
       ;; `workspace.move's own parameters echoed back, plus
       ;; `workspaces', folded in first so labels stay current.
       ;;
       ;; Place by `insert_index', not by the order of the `workspaces'
       ;; array: the index cannot be misread, whereas the schema does
       ;; not say whether that array is the whole new ordering or only
       ;; the workspaces it touched.
       (let ((workspaces (herdr-state-workspaces state)))
         (dolist (workspace (append (alist-get 'workspaces data) nil))
           (setq workspaces
                 (herdr-state--upsert workspaces 'workspace_id
                                      (herdr-workspace-id workspace)
                                      workspace)))
         (setq workspaces
               (herdr-state--move-within workspaces 'workspace_id
                                         (alist-get 'workspace_id data)
                                         (alist-get 'insert_index data)))
         (if (eq workspaces (herdr-state-workspaces state))
             state
           (setf (herdr-state-workspaces next) workspaces)
           next)))

      ("workspace_closed"
       (setf (herdr-state-workspaces next)
             (herdr-state--remove (herdr-state-workspaces state)
                                  'workspace_id
                                  (alist-get 'workspace_id data)))
       next)

      ("workspace_focused"
       (setf (herdr-state-focused-workspace-id next)
             (alist-get 'workspace_id data))
       next)

      ("workspace_reordered"
       ;; A worktree-group move (herdr 0.8.0).  `workspace_ids' is the
       ;; moved block in its new order, spliced before
       ;; `before_workspace_id' (or the end when nil).  `workspaces'
       ;; carries fresh WorkspaceInfo for the block, folded in first so
       ;; labels and counts stay current across the move.  Both decode
       ;; as lists already; `append' below is a defensive copy.
       (dolist (workspace (append (alist-get 'workspaces data) nil))
         (setf (herdr-state-workspaces next)
               (herdr-state--upsert (herdr-state-workspaces next)
                                    'workspace_id
                                    (herdr-workspace-id workspace)
                                    workspace)))
       (setf (herdr-state-workspaces next)
             (herdr-state--reorder-block
              (herdr-state-workspaces next) 'workspace_id
              (append (alist-get 'workspace_ids data) nil)
              (alist-get 'before_workspace_id data)))
       next)

      ;; layout_updated and anything herdr adds later: no cache impact.
      (_ state))))

;;; Live connections

(defcustom herdr-state-settle-delay 0.4
  "Seconds after connecting before the cache is reconciled with the server.

The delay is what the startup gap costs.  A subscription starts at the
sequence its request arrived on, so whatever the server announced
between `session.snapshot\\=' and the subscribe is lost, and
`herdr-state--settle\\=' is what repairs it: `pane.list\\=' and
`workspace.list\\=' are both authoritative and both take no parameters.
Until this fires, a workspace renamed in that window reads stale.

Through herdr 0.8.2 this delay had a second job.  A fresh subscription
replayed the server's 512-event ring, drip-fed at one event per
subscribed type per 100ms tick, and the value was chosen so the bulk of
that replay landed inside it.  0.9.0 removed the replay; the value is
kept because the reconcile it schedules is now the only thing closing
the gap, and delaying that further buys nothing."
  :type 'number
  :group 'herdr)

(defcustom herdr-state-repair-interval 5.0
  "Seconds between periodic cache repairs, or nil for none.
A repair reconciles the cached pane and workspace sets against the
server, and its failure is the only signal that the socket stopped
answering.  A tick arriving while the last one is still in flight
declines, so a server slower than this interval is polled no faster
than it answers."
  :type '(choice number (const :tag "Never repair" nil))
  :group 'herdr)

(defun herdr-state-generation (connection)
  "Return the current session generation.
See the generation slot."
  (herdr-connection-generation connection))

(defun herdr-state-current (&optional connection)
  "Return CONNECTION\='s cache, or the current connection\='s.
The optional argument is what lets a renderer ask for one server while
a command asks for whichever it is acting on."
  (let ((connection (or connection (herdr-current-connection))))
    ;; A connection that has never hydrated reads as an empty session
    ;; rather than as nil, which is what the global it replaced did.
    (or (herdr-connection-cache connection)
        (setf (herdr-connection-cache connection) (herdr-state-empty)))))

(defun herdr-state--dispatch (connection kind data)
  "Fold event KIND with DATA into the cache and notify listeners.

Every event notifies, with no quiet window in front of it.  This used
to hold the hook back until the stream had been silent for 0.4s, to
absorb the ring replay a fresh subscription began with through herdr
0.8.2.  It did not work even then: the replay was drip-fed at one event
per type per 100ms tick and so had no silent edge to detect, while the
live stream's median gap between events is 0.105s, so a quiet-based
window never closed.  Simulated against a real 200-second timeline it
held the hook for 54.3 seconds and swallowed 533 events to absorb a
replay of 8 — a minute of frozen modeline and dashboard after every
connect, precisely when an agent is most likely to be working.  0.9.0
removed the replay, so there is nothing left to absorb either."
  (setf (herdr-connection-cache connection) (herdr-state-reduce (herdr-state-current connection) kind data))
  (run-hook-with-args 'herdr-state-change-functions kind data))

(defun herdr-state--reconcile-panes-async (connection done)
  "Ask CONNECTION for the pane set and fold the reply when it lands.

DONE is called exactly once, with the RPC error or nil.  Exactly once
including the paths that never reach a reply: `herdr-rpc-connect\=' can
signal before the request goes out, and the caller\='s in-flight guard
would stay set for the session if that escaped.

Also the liveness watchdog, as the synchronous reconcile is: a failure
here is the one signal the socket stopped answering, so it schedules a
reconnect.  A timeout reaches this as an ordinary error.

The cached ids and the generation are captured before the request, not
read when the reply lands: a pane that appeared in between cannot be
pronounced stale by an answer built before it existed, and a reply from
a session that has since stopped must not repopulate the cache the stop
emptied."
  (let ((known-ids (herdr-state-pane-ids (herdr-state-current connection)))
        (generation (herdr-connection-generation connection))
        (fail (lambda (error)
                (when (herdr-connection-running connection)
                  (herdr-state--schedule-reconnect connection))
                (funcall done error))))
    (condition-case err
        (herdr-rpc-call-async
         connection "pane.list" nil
         (lambda (result error)
           (cond
            (error (funcall fail error))
            ((not (equal generation
                         (herdr-connection-generation connection)))
             (funcall done nil))
            (t
             ;; Only when the reply actually carries a list.  A reply
             ;; with no `panes' in it is an answer to a different
             ;; question, not an empty server, and folding it would
             ;; close every pane in the cache.
             (when-let* ((panes (alist-get 'panes result)))
               (herdr-state--fold-panes connection panes known-ids))
             (funcall done nil))))
         herdr-rpc-background-timeout)
      ;; Plain `error' as well as `herdr-error': the peer can close
      ;; between connect and send, which `process-send-string' reports
      ;; as a plain one.
      (error (funcall fail `((code . "call_failed")
                             (message . ,(error-message-string err))))))))

(defun herdr-state--reconcile-workspaces-async (connection done)
  "Ask CONNECTION for the workspace set and fold the reply when it lands.
DONE is called exactly once, with the RPC error or nil.  Unlike the pane
half this is not a watchdog: `herdr-state--reconcile-panes-async\=' has
already spoken for the socket by the time this runs."
  (let ((generation (herdr-connection-generation connection)))
    (condition-case err
        (herdr-rpc-call-async
         connection "workspace.list" nil
         (lambda (result error)
           (when (and (null error)
                      (equal generation
                             (herdr-connection-generation connection)))
             ;; See `herdr-state--reconcile-panes-async\=': a reply with
             ;; no `workspaces' in it must not read as an empty server.
             (when-let* ((workspaces (alist-get 'workspaces result)))
               (herdr-state--fold-workspaces connection workspaces)))
           (funcall done error))
         herdr-rpc-background-timeout)
      (error (funcall done `((code . "call_failed")
                             (message . ,(error-message-string err))))))))

(defun herdr-state-repair (connection &optional done)
  "Reconcile CONNECTION\='s cached pane set, then its workspace set.

Asynchronous, which is the whole point of it.  A server that is
unreachable fails immediately, but one that accepts the connection and
never answers costs the full timeout — and synchronously that is the
editor, for every connection in turn, every tick of the cadence.  The
requests go out and the replies fold in whenever they land; a server
too slow forfeits that round of freshness and nothing else.

Returns non-nil when it started.  DONE, when given, runs after the pair
has finished and is not run at all when the repair declines to start or
when the session moved on underneath it: a caller with work that
depends on the reconciled pane set — `herdr-state--settle\=' is the one —
must not do it against a set nothing settled.

The in-flight guard is a slot rather than a binding, so every path out
has to clear it, the ones that never reach a reply included.  Only the
generation it was set under clears it: a reply belonging to a stopped
session must not release the guard a restarted one is holding."
  (when (and (herdr-connection-running connection)
             (not (herdr-connection-repairing connection)))
    (let* ((reconnecting (herdr-connection-reconnect-timer connection))
           (generation (herdr-connection-generation connection))
           (current-p (lambda ()
                        (equal generation
                               (herdr-connection-generation connection))))
           (finish (lambda ()
                     (when (funcall current-p)
                       (setf (herdr-connection-repairing connection) nil)
                       (when done (funcall done))))))
      (setf (herdr-connection-repairing connection) t)
      (herdr-state--reconcile-panes-async
       connection
       (lambda (_error)
         ;; A `pane.list\=' that just failed has scheduled a reconnect, so
         ;; `workspace.list\=' would spend a second timeout on the same
         ;; wedged socket for an answer that is not coming either.
         (if (or (not (funcall current-p))
                 (and (null reconnecting)
                      (herdr-connection-reconnect-timer connection)))
             (funcall finish)
           (herdr-state--reconcile-workspaces-async
            connection (lambda (_error) (funcall finish))))))
      t)))

(defun herdr-state--arm-repair-timer (connection)
  "Begin the periodic repair, unless it is already running or disabled.
A repeating timer rather than an idle one: idle timers never fire while
something keeps Emacs busy, which is when a wedged server most needs
noticing."
  (when (and herdr-state-repair-interval
             (not (herdr-connection-repair-timer connection)))
    (setf (herdr-connection-repair-timer connection)
          ;; The connection travels with the timer.  A callback fires in
          ;; an empty extent, so anything it resolves there is whatever
          ;; the user last looked at rather than what armed it.
          (run-at-time herdr-state-repair-interval
                       herdr-state-repair-interval
                       #'herdr-state-repair connection))))

(defun herdr-state--release (connection)
  "Close the event streams and cancel every timer the session armed."
  (dolist (proc (list (herdr-connection-global-process connection) (herdr-connection-pane-process connection)))
    (herdr-state--close proc))
  (dolist (timer (list (herdr-connection-reconnect-timer connection)
                       (herdr-connection-resubscribe-timer connection)
                       (herdr-connection-settle-timer connection)
                       (herdr-connection-repair-timer connection)))
    (when timer (cancel-timer timer)))
  (setf (herdr-connection-global-process connection) nil
        (herdr-connection-pane-process connection) nil
        (herdr-connection-pane-stream-ids connection) nil
        (herdr-connection-reconnect-timer connection) nil
        (herdr-connection-resubscribe-timer connection) nil
        (herdr-connection-settle-timer connection) nil
        (herdr-connection-repair-timer connection) nil
        (herdr-connection-reconnect-delay connection) nil
        ;; A repair may still be on the wire.  Its reply is dropped by
        ;; the generation, which also stops it releasing this guard, so
        ;; the release has to happen here or the next session declines
        ;; every repair until something else clears it.
        (herdr-connection-repairing connection) nil))

(defun herdr-state--schedule-settle (connection &optional resync)
  "Arrange the one post-connect settle, replacing any pending one.
RESYNC is passed through to `herdr-state--settle\\='."
  (when (herdr-connection-settle-timer connection)
    (cancel-timer (herdr-connection-settle-timer connection)))
  (setf (herdr-connection-settle-timer connection)
        (run-at-time herdr-state-settle-delay nil
                     #'herdr-state--settle connection resync)))

(defun herdr-state--settle (connection &optional resync)
  "Reconcile the cache against the server after connecting, then realign B.

Both halves are reconciled, panes and workspaces, because both have a
gap and neither closes the other's.  A subscription starts at the
sequence its request arrived on, so whatever the server announced
between the snapshot and the subscribe is gone; before herdr 0.9.0 a
retained-event replay happened to cover that window, and now nothing
does.  `pane.list\\=' and `workspace.list\\=' both take no parameters and
both answer with everything live, so the pair is authoritative over
whatever was missed.

What the pair does not restore is order and focus.  Reconciling
updates and removes workspaces; it does not reorder them, and neither
list call carries `focused_pane_id\\='.  A `workspace.reordered\\=' or a
focus change lost in the window therefore survives until the next one
of its kind.  Both are cosmetic and both need an ordering fact the
protocol does not give a client.

Non-nil RESYNC replaces the whole cache from `session.snapshot\\=' first,
and is what the reconnect path passes.  It is not optional there: a
disconnect can span minutes, and reconciling repairs membership while
the snapshot is what restores focus with it.  `herdr-state-start\\='
needs no RESYNC because it has just snapshotted.

Realigning connection B afterwards, not before: reconciling is what
makes the pane set final, and B subscribes the agent slice of it.  That
ordering came free while the calls were synchronous; now it is a
continuation, which is the whole reason the repair takes one."
  (setf (herdr-connection-settle-timer connection) nil)
  (when (herdr-connection-running connection)
    (if (herdr-connection-repairing connection)
        ;; Fired inside another repair's wait.  Try again rather than
        ;; subscribing B against a pane set nothing has settled.
        (herdr-state--schedule-settle connection resync)
      ;; Events arriving since the subscribe have already queued a
      ;; debounced rebuild of B through `herdr-state--note-pane-set-change';
      ;; drop it, since the rebuild below is the same work against a
      ;; better pane set.
      (when (herdr-connection-resubscribe-timer connection)
        (cancel-timer (herdr-connection-resubscribe-timer connection))
        (setf (herdr-connection-resubscribe-timer connection) nil))
      (herdr-state--settle-hydrate
       connection resync
       (lambda ()
         (unless
             (herdr-state-repair
              connection
              (lambda ()
                (condition-case nil
                    (herdr-state--open-pane-stream connection)
                  (error (herdr-state--schedule-reconnect connection)))
                ;; Announce after the pane set is final, so a listener
                ;; that redraws from the whole cache does it once and
                ;; sees everything.
                (when resync
                  (run-hook-with-args
                   'herdr-state-change-functions "resync" nil))))
           ;; The repair declined, so nothing has settled the pane set.
           ;; Rebuilding B against an unsettled set is the thing this
           ;; ordering exists to prevent, so the whole settle goes round
           ;; again rather than the tail of it running anyway.
           (herdr-state--schedule-settle connection resync)))))))

(defun herdr-state--settle-hydrate (connection resync done)
  "Replace CONNECTION\='s cache from a fresh snapshot, then call DONE.

Does nothing but call DONE when RESYNC is nil, which is the start path:
`herdr-state-start\=' has just snapshotted.

Asynchronous for the reason the repair is.  This runs on a timer after
a disconnect, which is exactly when the server is most likely to be
gone or silent, and a synchronous snapshot there held the editor for
the whole background timeout on a refresh nobody asked for.

A snapshot that fails is not fatal to the settle: the reconcile that
follows repairs membership on its own, and the focus the snapshot
carries is restored by the next one.  So DONE runs either way, and the
generation is what stops a reply from a session that has since stopped
being installed over a newer cache."
  (if (not resync)
      (funcall done)
    (let ((generation (herdr-connection-generation connection)))
      (condition-case nil
          (herdr-rpc-call-async
           connection "session.snapshot" nil
           (lambda (result _error)
             (when (equal generation
                          (herdr-connection-generation connection))
               (when-let* ((snapshot (alist-get 'snapshot result)))
                 (setf (herdr-connection-cache connection)
                       (herdr-state-from-snapshot snapshot)))
               (funcall done)))
           herdr-rpc-background-timeout)
        ;; Plain `error' as well as `herdr-error': the peer can close
        ;; between connect and send.
        (error (funcall done))))))

(defun herdr-state--handle-line (connection line)
  "Handle one NDJSON LINE from an event connection."
  (let ((payload (ignore-errors (herdr-rpc-decode line))))
    (when payload
      (let ((kind (alist-get 'event payload)))
        (cond
         ;; The subscription ack is not an event; dispatching it would
         ;; reduce against a kind nothing understands.
         ((and (null kind) (alist-get 'result payload)) nil)
         ((null kind) nil)
         (t (herdr-state--dispatch connection kind (alist-get 'data payload))))))))

(defun herdr-state--filter (connection proc chunk)
  "Accumulate CHUNK on PROC and handle each complete line."
  (let ((buffered (concat (or (process-get proc 'herdr-pending) "") chunk)))
    (while (string-match "\n" buffered)
      (let ((line (substring buffered 0 (match-beginning 0))))
        (setq buffered (substring buffered (match-end 0)))
        (unless (string-blank-p line)
          (herdr-state--handle-line connection line))))
    ;; Whatever is left is a partial line; hold it until its newline lands.
    (process-put proc 'herdr-pending buffered)))

(defun herdr-state--close (proc)
  "Delete PROC without its sentinel mistaking this for a dropped stream.
Connection B is torn down and rebuilt on purpose whenever the pane set
changes, and an unmarked teardown is indistinguishable from a real
disconnect — which sends the reconnect logic into a loop that suppresses
every subsequent event."
  (when (process-live-p proc)
    (process-put proc 'herdr-intentional t)
    (delete-process proc)))

(defun herdr-state--sentinel (connection proc _event)
  "Schedule a reconnect when PROC's event stream ends unexpectedly."
  (when (and (herdr-connection-running connection)
             (not (process-get proc 'herdr-intentional))
             (memq (process-status proc) '(closed failed exit signal)))
    (herdr-state--schedule-reconnect connection)))

(defun herdr-state--subscribe (connection name subscriptions)
  "Open an event connection called NAME carrying SUBSCRIPTIONS.
Closes its own process if the subscribe signals: until this returns the
process is in no variable, so nothing else could close it."
  (let ((proc (herdr-rpc-connect
               connection name
               ;; Captured, not resolved: a filter and a sentinel fire
               ;; long after this returns, and by then whichever server
               ;; the user last looked at is not this one.
               (lambda (proc chunk)
                 (herdr-state--filter connection proc chunk))
               (lambda (proc event)
                 (herdr-state--sentinel connection proc event)))))
    (condition-case err
        (progn
          (process-put proc 'herdr-pending "")
          (process-send-string
           proc (herdr-rpc-encode (herdr-rpc--next-id) "events.subscribe"
                                  `((subscriptions . ,subscriptions))))
          proc)
      (error (herdr-state--close proc)
             (signal (car err) (cdr err))))))

(defun herdr-state--watched-pane-ids (connection)
  "Return ids of the panes connection B should subscribe to.

The agent panes, not every pane — attachment widened to
every pane once `herdr terminal attach' stopped requiring a reported
agent, but `pane.agent_status_changed' still only has something to say
about a pane running an agent.  Each per-pane subscription makes the
herdr server dispatch a `pane.get\\=' into its main loop every 100ms for
as long as the subscription lives (herdr 0.8.2, api/subscriptions.rs) —
subscribing every pane meant a session with a dozen plain shells paid
~120 server-side requests a second to watch statuses nothing here
displays."
  (mapcar (lambda (pane) (herdr-pane-id pane))
          (herdr-state-agents (herdr-state-current connection))))

(defun herdr-state--pane-subscriptions (connection)
  "Return per-pane status subscriptions for the watched panes.
A vector, because `subscriptions' is a JSON array."
  (herdr-rpc-array
   (mapcar (lambda (id) `((type . "pane.agent_status_changed") (pane_id . ,id)))
           (herdr-state--watched-pane-ids connection))))

(defun herdr-state--open-pane-stream (connection)
  "Rebuild connection B against the watched pane set."
  (herdr-state--close (herdr-connection-pane-process connection))
  (setf (herdr-connection-pane-process connection) nil)
  (let ((ids (herdr-state--watched-pane-ids connection))
        (subscriptions (herdr-state--pane-subscriptions connection)))
    (when (> (length subscriptions) 0)
      (setf (herdr-connection-pane-process connection)
            (herdr-state--subscribe connection
 "herdr-events-panes" subscriptions)))
    ;; After the subscribe, which can signal: a B that failed to open
    ;; must keep comparing as stale so the next event retries it.
    (setf (herdr-connection-pane-stream-ids connection) ids)))

(defun herdr-state--resubscribe-panes (connection)
  "Rebuild connection B, then refresh statuses the rebuild may have missed.

The set is re-checked at fire time because a rebuild has a gap in it
and the debounce window is exactly when someone else may have closed
that gap already: the connect sequence announces the snapshot before
the streams open, so the first events schedule a rebuild that the
settle then performs itself, against a better pane set, moments later.
Re-checking turns that duplicate into a no-op instead of a second
teardown."
  (setf (herdr-connection-resubscribe-timer connection) nil)
  (when (and (herdr-connection-running connection)
             (not (seq-set-equal-p (herdr-state--watched-pane-ids connection)
                                   (herdr-connection-pane-stream-ids connection))))
    ;; Plain `error': see the matching handler in `herdr-state--settle'.
    (condition-case nil
        (herdr-state--open-pane-stream connection)
      (error (herdr-state--schedule-reconnect connection)))
    ;; A rebuild has a gap.  The snapshot carries agent_status for every
    ;; pane, so refreshing from it closes the gap without replaying.
    (herdr-state--refresh-statuses connection)))

(defun herdr-state--refresh-statuses (connection)
  "Merge agent statuses from a fresh snapshot into the cache, async.

Asynchronous because this runs from the resubscribe timer, which fires
on every pane-set change: a synchronous snapshot here held the whole
editor for up to `herdr-rpc-timeout' against a slow server, for a
refresh nobody was waiting on.  The reply folds in whenever it lands;
a server slower than `herdr-rpc-background-timeout' forfeits the
refresh, and the next reconcile or event repairs the same state.

The request carries no handle for `herdr-state-stop' to cancel, so the
generation captured here is what keeps a reply arriving after a
stop-then-restart from merging the old session's statuses into the
new one: the running flag alone would already be true again by
then."
  (let ((generation (herdr-connection-generation connection)))
    (ignore-errors
      (herdr-rpc-call-async
       connection
       "session.snapshot" nil
       (lambda (result _error)
         (when-let* (((= generation (herdr-connection-generation connection)))
                     ((herdr-connection-running connection))
                     (snapshot (alist-get 'snapshot result)))
           (dolist (pane (alist-get 'panes snapshot))
             (setf (herdr-connection-cache connection)
                   (herdr-state--merge-pane
                    (herdr-state-current connection) (herdr-pane-id pane)
                    (seq-filter #'cdr
                                (list (cons 'agent_status
                                            (herdr-pane-status pane))
                                      (cons 'agent (herdr-pane-agent pane)))))))
           (run-hook-with-args 'herdr-state-change-functions "resync" nil)))
       herdr-rpc-background-timeout))))

(defun herdr-state--note-pane-set-change (connection _kind _data)
  "Rebuild connection B, debounced, when the watched pane set drifted.

A set comparison rather than a dispatch on event kind, because B now
subscribes the agent panes only, and what changes that set is not
just pane lifecycle: `pane_agent_detected\\=' gives a pane an agent or
takes one away, and a reconcile can relabel a pane wholesale.  When
this dispatched on kind, `pane_agent_detected\\=' was deliberately
excluded — correct while B named every pane, a missed rebuild once it
stopped.  Comparing the sets is immune to the enumeration going stale
again.  Order-insensitive, since a reconcile may reorder the cache
without changing what B should watch."
  (when (and (herdr-connection-running connection)
             (not (seq-set-equal-p (herdr-state--watched-pane-ids connection)
                                   (herdr-connection-pane-stream-ids connection))))
    (when (herdr-connection-resubscribe-timer connection)
      (cancel-timer (herdr-connection-resubscribe-timer connection)))
    (setf (herdr-connection-resubscribe-timer connection)
          (run-at-time 0.3 nil #'herdr-state--resubscribe-panes connection))))

(defun herdr-state--schedule-reconnect (connection)
  "Arrange to reopen the event streams after a backoff."
  (unless (herdr-connection-reconnect-timer connection)
    (setf (herdr-connection-reconnect-delay connection)
          (min herdr-state-reconnect-max
               (* 2 (or (herdr-connection-reconnect-delay connection)
                        (/ herdr-state-reconnect-min 2)))))
    (setf (herdr-connection-reconnect-timer connection)
          (run-at-time (herdr-connection-reconnect-delay connection) nil
                       #'herdr-state--reconnect connection))))

(defun herdr-state--reconnect (connection)
  "Reopen the event streams and resync, since missed events cannot replay."
  (setf (herdr-connection-reconnect-timer connection) nil)
  (when (herdr-connection-running connection)
    (condition-case nil
        (progn
          (herdr-state--open-streams connection)
          ;; A disconnect of any length loses events that are never
          ;; sent again — so this settle takes a full snapshot rather
          ;; than reconciling alone.  The reconcile repairs membership
          ;; for panes and workspaces; the snapshot is what restores
          ;; focus, which neither list call carries.  Reconnecting
          ;; without one left every workspace and tab change made
          ;; during the gap missing for good.
          (herdr-state--schedule-settle connection t)
          (setf (herdr-connection-reconnect-delay connection) nil))
      ;; Plain `error', not `herdr-error': `process-send-string' signals
      ;; a plain error when the peer closes between connect and send
      ;; (the case herdr-dispatch.el documents), and the timer variable
      ;; was already cleared above — an escaping signal here lost the
      ;; attempt with no reconnect scheduled, only a timer backtrace.
      (error (herdr-state--schedule-reconnect connection)))))

(defun herdr-state--open-streams (connection)
  "Open connection A, and connection B if there are panes to watch."
  (herdr-state--close (herdr-connection-global-process connection))
  (setf (herdr-connection-global-process connection)
        (herdr-state--subscribe connection
         "herdr-events-global"
         (herdr-rpc-array
          (mapcar (lambda (type) `((type . ,type)))
                  herdr-state-global-subscriptions))))
  (herdr-state--open-pane-stream connection))

(defun herdr-state-reconcile-panes (connection)
  "Make the cached pane set match the server, and refresh directories.

The event stream cannot keep the cache right on its own.  A `cd\\=' is
never announced, and a subscription starts at the sequence its request
arrived on, so whatever happened between the snapshot and the subscribe
is never sent.  One `pane.list\\=' is authoritative and answers both.
Through herdr 0.8.2 there was a third reason: a fresh subscription
replayed the server's event ring, so a `pane_created\\=' for a
long-closed pane arrived as news.

Returns non-nil when anything significant changed.  A record drifting
only in volatile fields is refreshed without running the change hook, so
titles stay current without every poll becoming a redraw.

Also the liveness watchdog.  A quiet subscription and a wedged server
look identical, and this is the only periodic RPC, so its failure is the
one signal the socket stopped answering; it schedules a reconnect.

Capture the cached ids BEFORE the call.  `herdr-rpc-call\\='s wait
services the event-stream filters, so the cache can gain a pane while
the reply is in flight, and a reply built before that pane existed
cannot pronounce it stale."
  (let ((known-ids (herdr-state-pane-ids (herdr-state-current connection)))
        (generation (herdr-connection-generation connection)))
    (when-let* ((panes (condition-case nil
                           (alist-get 'panes (herdr-rpc-call connection "pane.list"))
                         (error (when (herdr-connection-running connection)
                                  (herdr-state--schedule-reconnect connection))
                                nil)))
                ;; The wait services due timers, so the session can stop
                ;; underneath this call.  A reply from a session that is
                ;; gone must not repopulate the cache `herdr-state-stop\='
                ;; just emptied.
                ((equal generation (herdr-connection-generation connection))))
      (herdr-state--fold-panes connection panes known-ids))))

(defun herdr-state--fold-panes (connection panes known-ids)
  "Fold the authoritative PANES into CONNECTION\='s cache.

KNOWN-IDS is the cached pane set as it stood when the request went out.
A pane that has appeared since cannot be pronounced stale by a reply
built before it existed, which is why the comparison is against that
set rather than against the cache as it is now.

Returns non-nil when anything significant changed.  Shared by the
synchronous reconcile and the asynchronous one, which differ only in
how the list is obtained."
  (let* ((live-ids (mapcar (lambda (pane) (herdr-pane-id pane)) panes))
         (cached-ids (seq-filter
                      (lambda (id) (member id known-ids))
                      (herdr-state-pane-ids (herdr-state-current connection))))
         (stale (seq-remove (lambda (id) (member id live-ids)) cached-ids))
         (changed nil))
    (dolist (id stale)
      (setq changed t)
      (setf (herdr-connection-cache connection)
            (herdr-state-reduce (herdr-state-current connection) "pane_closed"
                                `((pane_id . ,id)))))
    (dolist (pane panes)
      (let* ((id (herdr-pane-id pane))
             (known (herdr-state-pane (herdr-state-current connection) id)))
        (cond
         ((null known)
          (setq changed t)
          (setf (herdr-connection-cache connection)
                (herdr-state-reduce (herdr-state-current connection)
                                    "pane_created" `((pane . ,pane)))))
         ((herdr-pane-differs-p known pane)
          ;; Replace the record rather than patching cwd alone: an
          ;; agent label can change under us and a cache that only
          ;; ever refreshed directories kept reporting the old one.
          ;; The common case is a plain shell that someone starts
          ;; Claude in: herdr relabels it `claude' of its own accord
          ;; a few seconds later.
          (setq changed t)
          (setf (herdr-connection-cache connection)
                (herdr-state-reduce (herdr-state-current connection)
                                    "pane_updated" `((pane . ,pane)))))
         ((not (equal known pane))
          ;; Volatile-only drift: refresh the record but stay silent, so
          ;; titles track the server at poll cadence without the hook
          ;; redrawing everything per poll.  See
          ;; `herdr-pane-significant-fields'.
          (setf (herdr-connection-cache connection)
                (herdr-state-reduce (herdr-state-current connection)
                                    "pane_updated" `((pane . ,pane))))))))
    (when changed
      (run-hook-with-args 'herdr-state-change-functions "reconcile" nil))
    changed))

(defun herdr-state-reconcile-workspaces (connection)
  "Make the cached workspace set match the server.

Panes get this from `herdr-state-reconcile-panes' every poll; workspaces
never did, because nothing periodic called `workspace.list' the way the
pane poll calls `pane.list'.  A missed
`workspace.closed' — the same disconnect and startup-window gaps
`herdr-state-reconcile-panes' defends panes against — then leaves a
ghost workspace in the cache indefinitely: not just until the next
poll, since there is no next poll for it, but until the next full
resync, which only fires on reconnect.  A session that never
disconnects never reconnects, so the ghost is permanent — it shows up
in the dispatcher, the modeline, and every picker for the rest of the
`workspace.list', like `pane.list', takes no required parameters and
answers with every live workspace, so one call resolves both closures
and updates in a single pass.  Returns non-nil when anything changed."
  (when-let* ((generation (herdr-connection-generation connection))
              (workspaces (ignore-errors
                            (alist-get 'workspaces
                                       (herdr-rpc-call connection "workspace.list"))))
              ;; See `herdr-state-reconcile-panes\=': same stop-mid-wait.
              ((equal generation (herdr-connection-generation connection))))
    (herdr-state--fold-workspaces connection workspaces)))

(defun herdr-state--fold-workspaces (connection workspaces)
  "Fold the authoritative WORKSPACES into CONNECTION\='s cache.
Returns non-nil when anything changed.  Shared by the synchronous
reconcile and the asynchronous one."
  (let* ((live-ids (mapcar #'herdr-workspace-id workspaces))
         (stale (seq-remove
                 (lambda (w) (member (herdr-workspace-id w) live-ids))
                 (herdr-state-workspaces (herdr-state-current connection))))
         (changed nil))
    (dolist (workspace stale)
      (setq changed t)
      (setf (herdr-connection-cache connection)
            (herdr-state-reduce (herdr-state-current connection)
                                "workspace_closed"
                                `((workspace_id
                                   . ,(herdr-workspace-id workspace))))))
    (dolist (workspace workspaces)
      (let* ((id (herdr-workspace-id workspace))
             (known (seq-find
                     (lambda (w) (equal id (herdr-workspace-id w)))
                     (herdr-state-workspaces
                      (herdr-state-current connection)))))
        (unless (equal known workspace)
          (setq changed t)
          (setf (herdr-connection-cache connection)
                (herdr-state-reduce (herdr-state-current connection)
                                    "workspace_updated"
                                    `((workspace . ,workspace)))))))
    (when changed
      (run-hook-with-args 'herdr-state-change-functions "reconcile" nil))
    changed))

(defun herdr-state-refresh (connection)
  "Replace the cache from a fresh snapshot, leaving subscriptions alone.

Lighter than `herdr-state-resync\\=', which also tears down and rebuilds
the per-pane event connection.  This is what the pickers use: the cache
can drift, and a picker offering panes that no longer exist is worse
than one extra round trip."
  (when-let* ((snapshot (ignore-errors
                          (alist-get 'snapshot
                                     (herdr-rpc-call connection "session.snapshot")))))
    (setf (herdr-connection-cache connection) (herdr-state-from-snapshot snapshot))
    (run-hook-with-args 'herdr-state-change-functions "refresh" nil)
    (herdr-state-current connection)))

(defun herdr-state-resync (connection)
  "Refetch the snapshot and rebuild per-pane subscriptions."
  (interactive)
  (setf (herdr-connection-cache connection)
        (herdr-state-from-snapshot
         (alist-get 'snapshot (herdr-rpc-call connection "session.snapshot"))))
  (herdr-state--open-pane-stream connection)
  (run-hook-with-args 'herdr-state-change-functions "resync" nil)
  (herdr-state-current connection))

(defun herdr-state-start (connection)
  "Hydrate the cache and begin following the event stream."
  (unless (herdr-connection-running connection)
    (setf (herdr-connection-running connection) t)
    (setf (herdr-connection-generation connection) (1+ (herdr-connection-generation connection)))
    ;; A closure, kept in the connection, because the hook is called
    ;; with the event and not with the connection whose cache moved.
    (setf (herdr-connection-notify connection)
          (lambda (kind data)
            (herdr-state--note-pane-set-change connection kind data)))
    (add-hook 'herdr-state-change-functions
              (herdr-connection-notify connection))
    (condition-case err
        (progn
          (setf (herdr-connection-cache connection)
                (herdr-state-from-snapshot
                 (alist-get 'snapshot (herdr-rpc-call connection "session.snapshot"))))
          ;; Announce the snapshot immediately so consumers paint
          ;; something true before any event arrives.
          (run-hook-with-args 'herdr-state-change-functions "resync" nil)
          (herdr-state--arm-repair-timer connection)
          (herdr-state--open-streams connection)
          (herdr-state--schedule-settle connection))
      ;; Plain `error', not `herdr-error': `herdr-state--open-streams'
      ;; reaches `process-send-string' through the same subscribe path
      ;; `herdr-state--settle' and `herdr-state--reconnect' widened their
      ;; handlers for — the peer can close between connect and send and
      ;; signal a plain error.  Catching only `herdr-error' here let that
      ;; escape the rollback, leaving the running slot stuck at t
      ;; with no stream open and `herdr-start''s own `unless' skipping
      ;; every later retry.
      ;; The rollback releases everything the attempt acquired: the
      ;; repair timer is armed and connection A opened before the point
      ;; a failure is most likely.  The generation stays bumped.
      (error
       (setf (herdr-connection-running connection) nil)
       (remove-hook 'herdr-state-change-functions
                    (herdr-connection-notify connection))
       (herdr-state--release connection)
       (signal (car err) (cdr err))))))

(defun herdr-state-stop (connection)
  "Stop following the event stream and drop the cache."
  (setf (herdr-connection-running connection) nil)
  (setf (herdr-connection-generation connection) (1+ (herdr-connection-generation connection)))
  (remove-hook 'herdr-state-change-functions
               (herdr-connection-notify connection))
  (herdr-state--release connection)
  (setf (herdr-connection-cache connection) (herdr-state-empty))
  ;; Listeners hold their own view of the cache just dropped.  Without
  ;; this the modeline advertised the dead session's agent counts until
  ;; the mode was toggled — stale, and actionable-looking, for agents
  ;; Emacs is no longer following.
  (run-hook-with-args 'herdr-state-change-functions "resync" nil))

(defun herdr-state-running-p (connection)
  "Return non-nil when the event stream is being followed."
  (and (herdr-connection-running connection) t))

(provide 'herdr-state)
;;; herdr-state.el ends here
