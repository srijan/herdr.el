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
;; Two event connections, for a measured reason.  Connection A carries
;; the global subscriptions, which need no pane id and are never rebuilt.
;; Connection B carries per-pane `pane.agent_status_changed'
;; subscriptions for the agent panes and is rebuilt whenever that
;; set changes.
;;
;; Connection B is the status channel, and it is prompt by
;; construction: the server backs each per-pane subscription with a
;; matching-event scan plus a 100ms snapshot compare of the pane's
;; status and reported metadata (herdr 0.8.2, api/subscriptions.rs), so
;; a transition reaches B within a tick even when its event was lost.
;; The compare reads the hook-reported metadata title, not the terminal
;; title, so B stays quiet while an agent merely animates its spinner.
;;
;; Connection A deliberately does not subscribe to `pane.updated'.
;; That event fires on every stripped-terminal-title change — a busy
;; agent animates its title about 7.5 times a second — and carries a
;; full PaneInfo each time.  The server delivers at most one event per
;; subscribed type per 100ms poll tick (herdr 0.8.2, api/server.rs), so
;; one busy agent nearly saturates the type's channel and two put it
;; permanently behind; the 6.18s and 31.79s status lags once measured
;; on A against B are that backlog.  Everything `pane.updated' carries
;; arrives elsewhere: status and agent identity through B, lifecycle
;; through `pane.created'/`pane.closed'/`pane.agent_detected', and the
;; volatile fields — terminal title, cwd — through
;; `herdr-state-reconcile-panes' at poll cadence.
;;
;; Events missed during a disconnect cannot be replayed, so every
;; reconnect is followed by a full resync rather than an attempt to
;; resume.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr-rpc)

(defcustom herdr-state-reconnect-min 1.0
  "Initial delay, in seconds, before retrying a dropped event stream."
  :type 'number
  :group 'herdr)

(defcustom herdr-state-reconnect-max 30.0
  "Longest delay, in seconds, between event stream reconnect attempts."
  :type 'number
  :group 'herdr)

;; Renamed from `herdr-state-change-hook': the manual reserves `-hook'
;; for a hook whose functions take no arguments, and this one always
;; ran through `run-hook-with-args' — the docstring below has called it
;; abnormal since it was written.  Ahead of the `defvar', as with the
;; mode-line string alias in herdr-modeline.el: a variable alias
;; declared after its referent does not carry a value already set
;; under the old name, and the byte compiler rejects it outright.
(define-obsolete-variable-alias 'herdr-state-change-hook
  'herdr-state-change-functions "0.1.0")

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
    "tab.created" "tab.closed" "tab.renamed" "tab.moved" "tab.focused"
    "pane.created" "pane.closed" "pane.focused"
    "pane.moved" "pane.exited" "pane.agent_detected"
    "layout.updated")
  "Subscriptions that carry no pane id and so never need rebuilding.

`pane.updated\\=' is deliberately absent; the commentary at the top of
this file says why, and `herdr-state-reconcile-panes\\=' covers what it
alone carried.

Order matters, so do not sort this.  A fresh subscription replays
whatever matching events remain in the server's shared ring buffer
\(512 events in herdr 0.8.2), delivered one per subscribed type per
100ms tick, with the types drained in the order they are listed here
rather than in the order the events happened.  A replayed
`pane.created\\=' for a closed pane therefore folds away only because
`pane.closed\\=' is listed after it.  `herdr-state-reconcile-panes\\=' is
what makes that safe rather than lucky, but the ordering is still the
first line of defence.")

;;; The state object

(cl-defstruct (herdr-state (:constructor herdr-state--make)
                           (:copier herdr-state-copy))
  (panes nil)
  (tabs nil)
  (workspaces nil)
  ;; Named `agent-info' rather than `agents': a slot called `agents'
  ;; would generate `herdr-state-agents', clobbering the function of that
  ;; name below.  This holds the raw AgentInfo array from
  ;; `session.snapshot', which carries `name' — the one field no
  ;; PaneInfo has.
  (agent-info nil)
  (focused-pane-id nil)
  (focused-tab-id nil)
  (focused-workspace-id nil))

(defun herdr-state-empty ()
  "Return an empty state."
  (herdr-state--make))

(defun herdr-state-from-snapshot (snapshot)
  "Build a state from SNAPSHOT, the payload of `session.snapshot'."
  (herdr-state--make
   :panes (alist-get 'panes snapshot)
   :tabs (alist-get 'tabs snapshot)
   :workspaces (alist-get 'workspaces snapshot)
   :agent-info (alist-get 'agents snapshot)
   :focused-pane-id (alist-get 'focused_pane_id snapshot)
   :focused-tab-id (alist-get 'focused_tab_id snapshot)
   :focused-workspace-id (alist-get 'focused_workspace_id snapshot)))

(defun herdr-state-pane (state id)
  "Return the pane in STATE whose id is ID, or nil."
  (seq-find (lambda (pane) (equal id (alist-get 'pane_id pane)))
            (herdr-state-panes state)))

(defun herdr-state-workspace (state id)
  "Return the workspace in STATE whose id is ID, or nil.
The workspace counterpart of `herdr-state-pane\\=', and the way a caller
holding one string tells a workspace id from a directory: only one of
the two is in the cache under that name."
  (seq-find (lambda (workspace) (equal id (alist-get 'workspace_id workspace)))
            (herdr-state-workspaces state)))

(defcustom herdr-shell-agent-name "shell"
  "Agent name `herdr-adopt-shell' used to report for plain shells.
Obsolete: since herdr 0.8.2, `herdr terminal attach' takes any pane, so
nothing needs to be reported to make a pane attachable."
  :type 'string
  :group 'herdr)
(make-obsolete-variable 'herdr-shell-agent-name nil "0.2.0")

(defun herdr-state-shell-pane-p (pane)
  "Return non-nil when PANE was adopted via `herdr-adopt-shell'."
  (equal (alist-get 'agent pane) (bound-and-true-p herdr-shell-agent-name)))
(make-obsolete 'herdr-state-shell-pane-p
               "test (alist-get 'agent pane) instead; every pane is attachable now."
               "0.2.0")

(defun herdr-state-attachable (state)
  "Return the panes in STATE a terminal client can attach to.
`herdr terminal attach' takes any pane's raw terminal stream, so that
is every pane; the function survives as the single place that says so."
  (herdr-state-panes state))

(defun herdr-state-agents (state)
  "Return the panes in STATE with a detected or reported agent."
  (seq-filter (lambda (pane) (alist-get 'agent pane))
              (herdr-state-panes state)))

(defun herdr-state-pane-directory (pane)
  "Return PANE's working directory as a directory name, or nil.

herdr tracks cwd itself and republishes it as panes change directory,
which is what makes this possible: it consumes OSC 7 rather than
forwarding it, so a terminal buffer fronting a herdr pane has no other
way to know where it is."
  (when-let* ((dir (or (alist-get 'cwd pane)
                       (alist-get 'foreground_cwd pane))))
    (when (file-directory-p dir)
      (file-name-as-directory dir))))

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
                                           (alist-get 'workspace_id pane))
                                    (alist-get 'cwd pane)))
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
                        state (alist-get 'workspace_id workspace))))
              (herdr-state-workspaces state))))

(defun herdr-state-pane-ids (state)
  "Return every pane id in STATE."
  (mapcar (lambda (pane) (alist-get 'pane_id pane))
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

(defun herdr-state--move-within (items key id index predicate)
  "Return ITEMS with the entry whose KEY is ID placed at INDEX.

Only the entries PREDICATE accepts take part: they are lifted out in
order, the one named by ID is put back among them at INDEX, and the
result is written into the slots they came from.  Entries PREDICATE
rejects never move, which is what lets a tab be positioned among its own
workspace\\='s tabs while the cache holds every workspace\\='s tabs in one
flat list.

An ID no entry carries leaves ITEMS alone; an INDEX past the end is
clamped.  Like `herdr-state--upsert\\=', ITEMS is not mutated.

INDEX counts against the group with the moved entry ALREADY REMOVED,
which is the usual convention but is NOT VERIFIED against herdr.  It
only matters for a forward move — moving an entry to a position after
its own — where the other reading, counting against the list including
the entry, lands it one slot earlier.  Backward moves are identical
under both.  One real `tab.move\\=' watched on the event stream would
settle it; until then the tests say plainly which of the two they pin."
  (let* ((group (seq-filter predicate items))
         (moved (seq-find (lambda (item) (equal id (alist-get key item))) group)))
    (if (not moved)
        items
      (let* ((rest (delq moved (copy-sequence group)))
             (at (max 0 (min (length rest) (or index 0))))
             (ordered (append (seq-take rest at) (list moved) (seq-drop rest at)))
             (result nil))
        (dolist (item items (nreverse result))
          (push (if (funcall predicate item) (pop ordered) item) result))))))

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
                                      (alist-get 'pane_id pane) pane))
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
       ;; Flat, unlike the three pane events above that this used to
       ;; share a branch with: `pane_id', `workspace_id', the detected
       ;; `agent', and — when herdr is announcing a release rather than a
       ;; detection — `released' with the `final_status' the agent ended
       ;; on.  There is no PaneInfo here, so reading one found nil and
       ;; the branch did nothing at all.
       ;;
       ;; `released' decides the label, not `agent'.  The schema allows
       ;; `agent' to be present alongside `released', and it would be a
       ;; reasonable thing to send — naming which agent went away.  A
       ;; release is also the one case that must clear the label, or the
       ;; pane is counted in the modeline, offered by the agent picker
       ;; and notified about for the rest of the session.  Keying off
       ;; `released' is right under either reading; keying off `agent'
       ;; alone is right under only one of them.
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
                                      (alist-get 'workspace_id workspace)
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
       ;; `workspace_id' and `insert_index' — `workspace.move's own two
       ;; parameters, echoed back — plus `workspaces', which carries
       ;; WorkspaceInfo and is folded in first so labels and counts stay
       ;; current across the move.  Both decode as lists, since events
       ;; are parsed with `:array-type \\='list'; the `append' below is
       ;; then a defensive copy rather than a vector-to-list coercion.
       ;;
       ;; Placement follows `insert_index' rather than the order of the
       ;; `workspaces' array: the index is the number the caller passed
       ;; and so cannot be misread, whereas whether that array is the
       ;; whole new ordering or only the workspaces it touched is not
       ;; something the schema says.
       (let ((workspaces (herdr-state-workspaces state)))
         (dolist (workspace (append (alist-get 'workspaces data) nil))
           (setq workspaces
                 (herdr-state--upsert workspaces 'workspace_id
                                      (alist-get 'workspace_id workspace)
                                      workspace)))
         (setq workspaces
               (herdr-state--move-within workspaces 'workspace_id
                                         (alist-get 'workspace_id data)
                                         (alist-get 'insert_index data)
                                         (lambda (_workspace) t)))
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
                                    (alist-get 'workspace_id workspace)
                                    workspace)))
       (setf (herdr-state-workspaces next)
             (herdr-state--reorder-block
              (herdr-state-workspaces next) 'workspace_id
              (append (alist-get 'workspace_ids data) nil)
              (alist-get 'before_workspace_id data)))
       next)

      ("tab_created"
       (let ((tab (alist-get 'tab data)))
         (if (not tab)
             state
           (setf (herdr-state-tabs next)
                 (herdr-state--upsert (herdr-state-tabs state) 'tab_id
                                      (alist-get 'tab_id tab) tab))
           next)))

      ("tab_renamed"
       ;; `tab_id', `workspace_id' and the new `label'.  No TabInfo, so
       ;; the old shared branch read nil and dropped every rename.
       (let ((tabs (herdr-state--merge-item
                    (herdr-state-tabs state) 'tab_id
                    (alist-get 'tab_id data)
                    (list (cons 'label (alist-get 'label data))))))
         (if (eq tabs (herdr-state-tabs state))
             state
           (setf (herdr-state-tabs next) tabs)
           next)))

      ("tab_moved"
       ;; `tab_id', `workspace_id', `insert_index' and a `tabs' list of
       ;; TabInfo, folded in first for freshness.  `insert_index' counts
       ;; among the tabs of `workspace_id' alone, since that is what
       ;; `tab.move' means by it, while the cache holds every
       ;; workspace's tabs in one list.
       (let ((tabs (herdr-state-tabs state))
             (workspace-id (alist-get 'workspace_id data)))
         (dolist (tab (append (alist-get 'tabs data) nil))
           (setq tabs (herdr-state--upsert tabs 'tab_id
                                           (alist-get 'tab_id tab) tab)))
         (setq tabs
               (herdr-state--move-within
                tabs 'tab_id (alist-get 'tab_id data)
                (alist-get 'insert_index data)
                (lambda (tab)
                  (equal workspace-id (alist-get 'workspace_id tab)))))
         (if (eq tabs (herdr-state-tabs state))
             state
           (setf (herdr-state-tabs next) tabs)
           next)))

      ("tab_closed"
       (setf (herdr-state-tabs next)
             (herdr-state--remove (herdr-state-tabs state)
                                  'tab_id (alist-get 'tab_id data)))
       next)

      ("tab_focused"
       (setf (herdr-state-focused-tab-id next) (alist-get 'tab_id data))
       next)

      ;; layout_updated and anything herdr adds later: no cache impact.
      (_ state))))

;;; Live connections

(defcustom herdr-state-settle-delay 0.4
  "Seconds after connecting before the cache is reconciled with the server.

`events.subscribe\\=' replays whatever matching events remain in the
server's 512-event ring buffer, drip-fed at one event per subscribed
type per 100ms tick (herdr 0.8.2, api/server.rs).  An earlier comment
here read a short measurement window — 8 events in 4ms, one
`pane.updated\\=' — as last-value retention; the drip simply had not
continued yet.  For the types subscribed now the ring rarely holds more
than a few of each, so the bulk of the replay lands within this delay,
and `herdr-state--settle\\='s reconcile makes the result right even when
a long drip is still arriving: replayed events are folded like live
ones, and `pane.list\\=' is authoritative over all of them."
  :type 'number
  :group 'herdr)

(defvar herdr-state--current (herdr-state-empty)
  "The live cache.")

(defvar herdr-state--settle-timer nil)

(defvar herdr-state--global-process nil)
(defvar herdr-state--pane-process nil)
(defvar herdr-state--reconnect-delay nil)
(defvar herdr-state--reconnect-timer nil)
(defvar herdr-state--resubscribe-timer nil)
(defvar herdr-state--running nil)

(defvar herdr-state--generation 0
  "Bumped by `herdr-state-start' and `herdr-state-stop'.

Distinguishes the session an in-flight async request or a pending
timer chain was begun for from whatever session happens to be running
by the time it acts.  `herdr-state--running' cannot do this alone: a
stop followed by a quick restart makes it true again before a request
issued under the old session gets a reply, so a callback gated only on
it merges a stale result into the new session's cache — see
`herdr-state--refresh-statuses' and, outside this file,
`herdr-cmd--select-pane-when-ready'.")

(defun herdr-state-generation ()
  "Return the current session generation.
See `herdr-state--generation'."
  herdr-state--generation)

(defun herdr-state-current ()
  "Return the live cache."
  herdr-state--current)

(defun herdr-state--dispatch (kind data)
  "Fold event KIND with DATA into the cache and notify listeners.

Every event notifies, replayed ones included.  This used to hold the
hook back until the stream had been silent for 0.4s, to absorb the
replay a fresh subscription starts with.  But the replay is drip-fed
from the server's ring at one event per type per 100ms tick, so it has
no silent edge to detect — while the live stream's median gap between
events is 0.105s, so a quiet-based window never closed: simulated
against a real 200-second timeline it held the hook for 54.3 seconds
and swallowed 533 events to absorb a replay of 8.  That is a minute of
frozen modeline and dashboard after every connect, which is precisely
when an agent is most likely to be working."
  (setq herdr-state--current (herdr-state-reduce herdr-state--current kind data))
  (run-hook-with-args 'herdr-state-change-functions kind data))

(defun herdr-state--schedule-settle (&optional resync)
  "Arrange the one post-connect settle, replacing any pending one.
RESYNC is passed through to `herdr-state--settle\\='."
  (when herdr-state--settle-timer
    (cancel-timer herdr-state--settle-timer))
  (setq herdr-state--settle-timer
        (run-at-time herdr-state-settle-delay nil
                     #'herdr-state--settle resync)))

(defun herdr-state--settle (&optional resync)
  "Settle the cache once the retained events have landed, then realign B.

Non-nil RESYNC replaces the whole cache from `session.snapshot\\=' first,
and is what the reconnect path passes.  It is not optional there.  A
disconnect drops events that cannot be replayed, and they are not only
pane events: a workspace renamed or a tab closed during the gap is
announced once and never again.  `pane.list\\=' repairs panes and nothing
else, so without the snapshot a reconnect left the workspace and tab
halves of the cache wrong for the rest of the session — the dashboard
showing a stale label and a closed tab lingering as a ghost nothing
could reach.  `herdr-state-start\\=' needs no RESYNC because it snapshots
immediately before subscribing.

Reconciling: the replay can carry a `pane.created\\=' for a pane closed
long ago — a ghost.  It folds correctly only because `pane.created\\='
precedes `pane.closed\\=' in `herdr-state-global-subscriptions\\=' —
replayed types are drained in subscription-list order, not
chronological order — so a ghost is one list edit away at any time,
and it is a ghost that shows up in every picker and cannot be
navigated to.  `pane.list\\=' is authoritative and settles it either
way.

Realigning connection B afterwards, not before: reconciling is what
makes the pane set final, and B subscribes the agent slice of it."
  (setq herdr-state--settle-timer nil)
  (when herdr-state--running
    ;; The replayed pane events have already queued a debounced rebuild
    ;; of B through `herdr-state--note-pane-set-change'; drop it, since
    ;; the rebuild below is the same work against a better pane set.
    (when herdr-state--resubscribe-timer
      (cancel-timer herdr-state--resubscribe-timer)
      (setq herdr-state--resubscribe-timer nil))
    ;; The settle runs on a timer, so its synchronous calls are bound to
    ;; the background timeout: a wedged server costs the refresh, not
    ;; ten seconds of frozen editor that nobody asked for.  Plain
    ;; `error' rather than `herdr-error' below, because
    ;; `process-send-string' inside the RPC signals a plain error when
    ;; the peer closes between connect and send — narrower handling let
    ;; that escape the timer as a backtrace and lose the attempt.
    (let ((herdr-rpc-timeout (min herdr-rpc-timeout
                                  herdr-rpc-background-timeout)))
      (when resync
        (condition-case nil
            (setq herdr-state--current
                  (herdr-state-from-snapshot
                   (alist-get 'snapshot (herdr-rpc-call "session.snapshot"))))
          (error nil)))
      (herdr-state-reconcile-panes))
    (condition-case nil
        (herdr-state--open-pane-stream)
      (error (herdr-state--schedule-reconnect)))
    ;; Announce after the pane set is final, so a listener that redraws
    ;; from the whole cache does it once and sees everything.
    (when resync
      (run-hook-with-args 'herdr-state-change-functions "resync" nil))))

(defun herdr-state--handle-line (line)
  "Handle one NDJSON LINE from an event connection."
  (let ((payload (ignore-errors (herdr-rpc-decode line))))
    (when payload
      (let ((kind (alist-get 'event payload)))
        (cond
         ;; The subscription ack is not an event; dispatching it would
         ;; reduce against a kind nothing understands.
         ((and (null kind) (alist-get 'result payload)) nil)
         ((null kind) nil)
         (t (herdr-state--dispatch kind (alist-get 'data payload))))))))

(defun herdr-state--filter (proc chunk)
  "Accumulate CHUNK on PROC and handle each complete line."
  (let ((buffered (concat (or (process-get proc 'herdr-pending) "") chunk)))
    (while (string-match "\n" buffered)
      (let ((line (substring buffered 0 (match-beginning 0))))
        (setq buffered (substring buffered (match-end 0)))
        (unless (string-blank-p line)
          (herdr-state--handle-line line))))
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

(defun herdr-state--sentinel (proc _event)
  "Schedule a reconnect when PROC's event stream ends unexpectedly."
  (when (and herdr-state--running
             (not (process-get proc 'herdr-intentional))
             (memq (process-status proc) '(closed failed exit signal)))
    (herdr-state--schedule-reconnect)))

(defun herdr-state--subscribe (name subscriptions)
  "Open an event connection called NAME carrying SUBSCRIPTIONS."
  (let ((proc (herdr-rpc-connect name #'herdr-state--filter
                                 #'herdr-state--sentinel)))
    (process-put proc 'herdr-pending "")
    (process-send-string
     proc (herdr-rpc-encode (herdr-rpc--next-id) "events.subscribe"
                            `((subscriptions . ,subscriptions))))
    proc))

(defvar herdr-state--pane-stream-ids nil
  "Pane ids connection B was last built against.
What `herdr-state--note-pane-set-change\\=' compares the cache with to
decide that B needs rebuilding.  Assigned only after a successful
subscribe, so a failed rebuild keeps looking stale and is retried.")

(defun herdr-state--watched-pane-ids ()
  "Return ids of the panes connection B should subscribe to.

The agent panes, not every pane — `herdr-state-attachable' widened to
every pane once `herdr terminal attach' stopped requiring a reported
agent, but `pane.agent_status_changed' still only has something to say
about a pane running an agent.  Each per-pane subscription makes the
herdr server dispatch a `pane.get\\=' into its main loop every 100ms for
as long as the subscription lives (herdr 0.8.2, api/subscriptions.rs) —
subscribing every pane meant a session with a dozen plain shells paid
~120 server-side requests a second to watch statuses nothing here
displays."
  (mapcar (lambda (pane) (alist-get 'pane_id pane))
          (herdr-state-agents herdr-state--current)))

(defun herdr-state--pane-subscriptions ()
  "Return per-pane status subscriptions for the watched panes.
A vector, because `subscriptions' is a JSON array."
  (herdr-rpc-array
   (mapcar (lambda (id) `((type . "pane.agent_status_changed") (pane_id . ,id)))
           (herdr-state--watched-pane-ids))))

(defun herdr-state--open-pane-stream ()
  "Rebuild connection B against the watched pane set."
  (herdr-state--close herdr-state--pane-process)
  (setq herdr-state--pane-process nil)
  (let ((ids (herdr-state--watched-pane-ids))
        (subscriptions (herdr-state--pane-subscriptions)))
    (when (> (length subscriptions) 0)
      (setq herdr-state--pane-process
            (herdr-state--subscribe "herdr-events-panes" subscriptions)))
    ;; After the subscribe, which can signal: a B that failed to open
    ;; must keep comparing as stale so the next event retries it.
    (setq herdr-state--pane-stream-ids ids)))

(defun herdr-state--resubscribe-panes ()
  "Rebuild connection B, then refresh statuses the rebuild may have missed.

The set is re-checked at fire time because a rebuild has a gap in it
and the debounce window is exactly when someone else may have closed
that gap already: the connect sequence announces the snapshot before
the streams open, so the first events schedule a rebuild that the
settle then performs itself, against a better pane set, moments later.
Re-checking turns that duplicate into a no-op instead of a second
teardown."
  (setq herdr-state--resubscribe-timer nil)
  (when (and herdr-state--running
             (not (seq-set-equal-p (herdr-state--watched-pane-ids)
                                   herdr-state--pane-stream-ids)))
    ;; Plain `error': see the matching handler in `herdr-state--settle'.
    (condition-case nil
        (herdr-state--open-pane-stream)
      (error (herdr-state--schedule-reconnect)))
    ;; A rebuild has a gap.  The snapshot carries agent_status for every
    ;; pane, so refreshing from it closes the gap without replaying.
    (herdr-state--refresh-statuses)))

(defun herdr-state--refresh-statuses ()
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
new one: `herdr-state--running' alone would already be true again by
then."
  (let ((generation herdr-state--generation))
    (ignore-errors
      (herdr-rpc-call-async
       "session.snapshot" nil
       (lambda (result _error)
         (when-let* (((= generation herdr-state--generation))
                     (herdr-state--running)
                     (snapshot (alist-get 'snapshot result)))
           (dolist (pane (alist-get 'panes snapshot))
             (setq herdr-state--current
                   (herdr-state--merge-pane
                    herdr-state--current (alist-get 'pane_id pane)
                    (seq-filter #'cdr
                                (list (cons 'agent_status
                                            (alist-get 'agent_status pane))
                                      (cons 'agent (alist-get 'agent pane)))))))
           (run-hook-with-args 'herdr-state-change-functions "resync" nil)))
       herdr-rpc-background-timeout))))

(defun herdr-state--note-pane-set-change (_kind _data)
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
  (when (and herdr-state--running
             (not (seq-set-equal-p (herdr-state--watched-pane-ids)
                                   herdr-state--pane-stream-ids)))
    (when herdr-state--resubscribe-timer
      (cancel-timer herdr-state--resubscribe-timer))
    (setq herdr-state--resubscribe-timer
          (run-at-time 0.3 nil #'herdr-state--resubscribe-panes))))

(defun herdr-state--schedule-reconnect ()
  "Arrange to reopen the event streams after a backoff."
  (unless herdr-state--reconnect-timer
    (setq herdr-state--reconnect-delay
          (min herdr-state-reconnect-max
               (* 2 (or herdr-state--reconnect-delay
                        (/ herdr-state-reconnect-min 2)))))
    (setq herdr-state--reconnect-timer
          (run-at-time herdr-state--reconnect-delay nil
                       #'herdr-state--reconnect))))

(defun herdr-state--reconnect ()
  "Reopen the event streams and resync, since missed events cannot replay."
  (setq herdr-state--reconnect-timer nil)
  (when herdr-state--running
    (condition-case nil
        (progn
          (herdr-state--open-streams)
          ;; A disconnect of any length loses events that cannot be
          ;; replayed, and they are not only pane events — so this
          ;; settle takes a full snapshot rather than reconciling panes
          ;; alone.  Reconnecting without one left every workspace and
          ;; tab change made during the gap missing for good.
          (herdr-state--schedule-settle t)
          (setq herdr-state--reconnect-delay nil))
      ;; Plain `error', not `herdr-error': `process-send-string' signals
      ;; a plain error when the peer closes between connect and send
      ;; (the case herdr-dispatch.el documents), and the timer variable
      ;; was already cleared above — an escaping signal here lost the
      ;; attempt with no reconnect scheduled, only a timer backtrace.
      (error (herdr-state--schedule-reconnect)))))

(defun herdr-state--open-streams ()
  "Open connection A, and connection B if there are panes to watch."
  (herdr-state--close herdr-state--global-process)
  (setq herdr-state--global-process
        (herdr-state--subscribe
         "herdr-events-global"
         (herdr-rpc-array
          (mapcar (lambda (type) `((type . ,type)))
                  herdr-state-global-subscriptions))))
  (herdr-state--open-pane-stream))

(defconst herdr-state-pane-significant-fields
  '(agent agent_status cwd foreground_cwd workspace_id tab_id label)
  "Pane fields worth reacting to when reconciling against `pane.list\\='.

`label\\=' is on the list because it is the one pane field a person or a
plugin sets deliberately — `pane.rename\\=' writes it, and a plugin pane
is seated carrying its `[[panes]].title\\=' as one.  It moves only when
somebody moves it, so it costs nothing to watch, and leaving it off
meant a rename reached the cache silently and did not appear on any
surface until an unrelated change happened to redraw them.

Deliberately excludes the volatile ones — revision, scroll and the
terminal title — which change constantly and would make every poll look
like a change.

The title belongs on that list however much it looks like a stable
label.  Claude animates a spinner glyph and an elapsed-second counter
inside it, so it changes several times a second while an agent works:
of 662 `pane_updated\\=' events measured in one window, 662 differed in
the title and 11 differed in `agent_status\\='.  Including it here meant
every reconcile poll declared a change, replaced every pane record and
re-ran the directory sync, which is the whole cost the list exists to
avoid.

With `pane.updated\\=' no longer subscribed, the reconcile is also how
volatile fields reach the cache at all: a record that differs only in
them is refreshed silently — written without running the change hook —
so titles are at most one poll interval stale while the hook keeps its
significant-change cadence.  See `herdr-state-reconcile-panes\\='.

`revision\\=' could look like a cheap staleness guard for all of this,
but upstream bumps it only for presentation metadata — the stripped
terminal title and metadata tokens — never for `agent_status\\=' (herdr
0.8.2, terminal/state.rs).  It cannot order status updates and must not
be used to.")

(defun herdr-state--pane-differs-p (known fresh)
  "Return non-nil when FRESH differs from KNOWN in a field worth noticing."
  (seq-some (lambda (field)
              (not (equal (alist-get field known) (alist-get field fresh))))
            herdr-state-pane-significant-fields))

(defun herdr-state-reconcile-panes ()
  "Make the cached pane set match the server, and refresh directories.

Two problems this solves, both of which leave the cache wrong in ways
the event stream cannot correct on its own.

Directory changes are never announced: herdr tracks cwd accurately, but
a `cd\\=' produces no `pane_updated\\=', only unrelated `layout_updated\\='
traffic.

Worse, panes can linger.  A fresh `events.subscribe\\=' replays what
remains of the server's event ring, so a `pane_created\\=' for a pane
closed long ago is delivered as though it were news — verified against
0.8.0, where a pane created and closed minutes earlier came back on
every fresh subscription.  The matching `pane_closed\\=' replays too and
happens to arrive after it, but only because replayed types drain in
subscription-list order and `pane.created\\=' precedes `pane.closed\\=' in
`herdr-state-global-subscriptions\\='.  Nothing enforces that, and the
ghosts it would otherwise leave show up in every picker and cannot be
navigated to.

One `pane.list\\=' answers both: it is the authoritative set, so panes
missing from it are dropped, panes new to us are added, and directories
are refreshed in the same pass.  Returns non-nil when anything
significant changed.  A record that drifted only in volatile fields —
the terminal title, scroll, revision — is refreshed without running the
change hook or counting as a change: with `pane.updated\\=' unsubscribed
this pass is what keeps titles current, and announcing every animated
title made each poll a full redraw, which is the churn dropping the
subscription bought back.

This is also the liveness watchdog for the event streams.  The server
sends nothing on a quiet subscription, so a wedged server leaves both
connections open and silent forever — indistinguishable from a calm
session.  The poll that calls this is the one periodic RPC, and its
failure is the one signal that the socket stopped answering while the
streams still look alive; scheduling a reconnect on it closes the gap,
and the backoff in `herdr-state--schedule-reconnect\\=' keeps a
struggling server from being hammered.

The cached ids are captured BEFORE the call: `herdr-rpc-call\\='s wait
services the event-stream filters, so the cache can gain a pane while
the reply is in flight — and a reply built before that pane existed
cannot pronounce it stale.  Judging staleness against the pre-call set
means a pane that arrived mid-wait is never evicted (nor its buffer
killed by the agent-windows reap listening on the change hook)."
  (let ((known-ids (herdr-state-pane-ids herdr-state--current)))
    (when-let* ((panes (condition-case nil
                           (alist-get 'panes (herdr-rpc-call "pane.list"))
                         (error (when herdr-state--running
                                  (herdr-state--schedule-reconnect))
                                nil))))
      (let* ((live-ids (mapcar (lambda (pane) (alist-get 'pane_id pane)) panes))
             (cached-ids (seq-filter (lambda (id) (member id known-ids))
                                     (herdr-state-pane-ids herdr-state--current)))
             (stale (seq-remove (lambda (id) (member id live-ids)) cached-ids))
             (changed nil))
        (dolist (id stale)
          (setq changed t)
          (setq herdr-state--current
                (herdr-state-reduce herdr-state--current "pane_closed"
                                    `((pane_id . ,id)))))
        (dolist (pane panes)
          (let* ((id (alist-get 'pane_id pane))
                 (known (herdr-state-pane herdr-state--current id)))
            (cond
             ((null known)
              (setq changed t)
              (setq herdr-state--current
                    (herdr-state-reduce herdr-state--current "pane_created"
                                        `((pane . ,pane)))))
             ((herdr-state--pane-differs-p known pane)
              ;; Replace the record rather than patching cwd alone: an
              ;; agent label can change under us and a cache that only
              ;; ever refreshed directories kept reporting the old one.
              ;; The common case is an adopted shell that someone then
              ;; starts Claude in: herdr 0.8.0 relabels it `claude' of
              ;; its own accord a few seconds later, because reporting an
              ;; agent does not suppress detection — the two run
              ;; independently, and detection wins.
              (setq changed t)
              (setq herdr-state--current
                    (herdr-state-reduce herdr-state--current "pane_updated"
                                        `((pane . ,pane)))))
             ((not (equal known pane))
              ;; Volatile-only drift: refresh the record but stay
              ;; silent, so titles track the server at poll cadence
              ;; without the hook redrawing everything per poll.  See
              ;; `herdr-state-pane-significant-fields'.
              (setq herdr-state--current
                    (herdr-state-reduce herdr-state--current "pane_updated"
                                        `((pane . ,pane))))))))
        (when changed
          (run-hook-with-args 'herdr-state-change-functions "reconcile" nil))
        changed))))

(define-obsolete-function-alias 'herdr-state-refresh-directories
  'herdr-state-reconcile-panes "0.1.0")

(defun herdr-state-reconcile-workspaces ()
  "Make the cached workspace set match the server.

Panes get this from `herdr-state-reconcile-panes' every poll; workspaces
and tabs never did, because nothing periodic called `workspace.list' or
`tab.list' the way the pane poll calls `pane.list'.  A missed
`workspace.closed' — the same disconnect-window and ring-replay gaps
`herdr-state-reconcile-panes' defends panes against — then leaves a
ghost workspace in the cache indefinitely: not just until the next
poll, since there is no next poll for it, but until the next full
resync, which only fires on reconnect.  A session that never
disconnects never reconnects, so the ghost is permanent — it shows up
in the dispatcher, the modeline, and every picker for the rest of the
session.  `herdr-state-reconcile-tabs' is the tab-scoped sibling of
this function, called alongside it from the same periodic poll; see
`herdr-term--poll-directories'.

`workspace.list', like `pane.list', takes no required parameters and
answers with every live workspace, so one call resolves both closures
and updates in a single pass.  Returns non-nil when anything changed."
  (when-let* ((workspaces (ignore-errors
                            (alist-get 'workspaces
                                       (herdr-rpc-call "workspace.list")))))
    (let* ((live-ids (mapcar (lambda (w) (alist-get 'workspace_id w))
                             workspaces))
           (stale (seq-remove (lambda (w) (member (alist-get 'workspace_id w)
                                                  live-ids))
                              (herdr-state-workspaces herdr-state--current)))
           (changed nil))
      (dolist (workspace stale)
        (setq changed t)
        (setq herdr-state--current
              (herdr-state-reduce herdr-state--current "workspace_closed"
                                  `((workspace_id
                                     . ,(alist-get 'workspace_id workspace))))))
      (dolist (workspace workspaces)
        (let* ((id (alist-get 'workspace_id workspace))
               (known (seq-find (lambda (w) (equal id (alist-get 'workspace_id w)))
                                (herdr-state-workspaces herdr-state--current))))
          (unless (equal known workspace)
            (setq changed t)
            (setq herdr-state--current
                  (herdr-state-reduce herdr-state--current "workspace_updated"
                                      `((workspace . ,workspace)))))))
      (when changed
        (run-hook-with-args 'herdr-state-change-functions "reconcile" nil))
      changed)))

(defun herdr-state-reconcile-tabs ()
  "Make the cached tab set match the server.
The tab-scoped sibling of `herdr-state-reconcile-workspaces'; see its
docstring for why this exists.  A tab whose workspace closed is
orphaned the same way a pane is when its own owner disappears without
a `pane.closed' — this sweep catches it without `workspace_closed'
needing to know to cascade into the tabs it owned.

`tab.list' with no `workspace_id' filter, like `pane.list', answers
with every live tab across every workspace.  Returns non-nil when
anything changed."
  (when-let* ((tabs (ignore-errors (alist-get 'tabs (herdr-rpc-call "tab.list")))))
    (let* ((live-ids (mapcar (lambda (tab) (alist-get 'tab_id tab)) tabs))
           (stale (seq-remove (lambda (tab) (member (alist-get 'tab_id tab)
                                                     live-ids))
                              (herdr-state-tabs herdr-state--current)))
           (changed nil))
      (dolist (tab stale)
        (setq changed t)
        (setq herdr-state--current
              (herdr-state-reduce herdr-state--current "tab_closed"
                                  `((tab_id . ,(alist-get 'tab_id tab))))))
      (dolist (tab tabs)
        (let* ((id (alist-get 'tab_id tab))
               (known (seq-find (lambda (c) (equal id (alist-get 'tab_id c)))
                                (herdr-state-tabs herdr-state--current))))
          (unless (equal known tab)
            (setq changed t)
            (setq herdr-state--current
                  (herdr-state-reduce herdr-state--current "tab_created"
                                      `((tab . ,tab)))))))
      (when changed
        (run-hook-with-args 'herdr-state-change-functions "reconcile" nil))
      changed)))

(defun herdr-state-refresh ()
  "Replace the cache from a fresh snapshot, leaving subscriptions alone.

Lighter than `herdr-state-resync\\=', which also rebuilds the per-pane
event connection and so triggers another replay.  This is what the
pickers use: the cache can drift, and a picker offering panes that no
longer exist is worse than one extra round trip."
  (when-let* ((snapshot (ignore-errors
                          (alist-get 'snapshot
                                     (herdr-rpc-call "session.snapshot")))))
    (setq herdr-state--current (herdr-state-from-snapshot snapshot))
    (run-hook-with-args 'herdr-state-change-functions "refresh" nil)
    herdr-state--current))

(defun herdr-state-resync ()
  "Refetch the snapshot and rebuild per-pane subscriptions."
  (interactive)
  (setq herdr-state--current
        (herdr-state-from-snapshot
         (alist-get 'snapshot (herdr-rpc-call "session.snapshot"))))
  (herdr-state--open-pane-stream)
  (run-hook-with-args 'herdr-state-change-functions "resync" nil)
  herdr-state--current)

(defun herdr-state-start ()
  "Hydrate the cache and begin following the event stream."
  (unless herdr-state--running
    (setq herdr-state--running t)
    (setq herdr-state--generation (1+ herdr-state--generation))
    (add-hook 'herdr-state-change-functions #'herdr-state--note-pane-set-change)
    (condition-case err
        (progn
          (setq herdr-state--current
                (herdr-state-from-snapshot
                 (alist-get 'snapshot (herdr-rpc-call "session.snapshot"))))
          ;; Announce the snapshot immediately so consumers paint
          ;; something true before any event arrives.
          (run-hook-with-args 'herdr-state-change-functions "resync" nil)
          (herdr-state--open-streams)
          (herdr-state--schedule-settle))
      ;; Plain `error', not `herdr-error': `herdr-state--open-streams'
      ;; reaches `process-send-string' through the same subscribe path
      ;; `herdr-state--settle' and `herdr-state--reconnect' widened their
      ;; handlers for — the peer can close between connect and send and
      ;; signal a plain error.  Catching only `herdr-error' here let that
      ;; escape the rollback, leaving `herdr-state--running' stuck at t
      ;; with no stream open and `herdr-start''s own `unless' skipping
      ;; every later retry.
      (error
       (setq herdr-state--running nil)
       (remove-hook 'herdr-state-change-functions #'herdr-state--note-pane-set-change)
       (signal (car err) (cdr err))))))

(defun herdr-state-stop ()
  "Stop following the event stream and drop the cache."
  (setq herdr-state--running nil)
  (setq herdr-state--generation (1+ herdr-state--generation))
  (remove-hook 'herdr-state-change-functions #'herdr-state--note-pane-set-change)
  (dolist (proc (list herdr-state--global-process herdr-state--pane-process))
    (herdr-state--close proc))
  (dolist (timer (list herdr-state--reconnect-timer
                       herdr-state--resubscribe-timer
                       herdr-state--settle-timer))
    (when timer (cancel-timer timer)))
  (setq herdr-state--global-process nil
        herdr-state--pane-process nil
        herdr-state--pane-stream-ids nil
        herdr-state--reconnect-timer nil
        herdr-state--resubscribe-timer nil
        herdr-state--settle-timer nil
        herdr-state--reconnect-delay nil
        herdr-state--current (herdr-state-empty))
  ;; Listeners hold their own view of the cache just dropped.  Without
  ;; this the modeline advertised the dead session's agent counts until
  ;; the mode was toggled — stale, and actionable-looking, for agents
  ;; Emacs is no longer following.
  (run-hook-with-args 'herdr-state-change-functions "resync" nil))

(defun herdr-state-running-p ()
  "Return non-nil when the event stream is being followed."
  (and herdr-state--running t))

(provide 'herdr-state)
;;; herdr-state.el ends here
