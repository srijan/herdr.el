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
;; subscriptions and is rebuilt whenever the set of panes changes.
;;
;; Connection B exists because the global `pane_updated' event coalesces:
;; driving a pane through working, blocked and idle produced three
;; per-pane events but only one `pane_updated'.  Relying on the global
;; stream alone would silently drop status transitions, which is exactly
;; what the agents buffer is for.
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

(defvar herdr-state-change-hook nil
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
    "pane.created" "pane.closed" "pane.updated" "pane.focused"
    "pane.moved" "pane.exited" "pane.agent_detected"
    "layout.updated")
  "Subscriptions that carry no pane id and so never need rebuilding.

Order matters, so do not sort this.  `events.subscribe\\=' answers with
the last retained event of each type before it starts streaming, and it
emits them in the order the types are listed here rather than in the
order they happened.  A retained `pane.created\\=' for a closed pane
therefore folds away only because `pane.closed\\=' is listed after it.
`herdr-state-reconcile-panes\\=' is what makes that safe rather than
lucky, but the ordering is still the first line of defence.")

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

(defcustom herdr-shell-agent-name "shell"
  "Agent name reported for shell panes adopted by `herdr-adopt-shell'.

herdr will only attach to a pane that has a reported agent, so adopting
a plain shell means reporting one.  Panes carrying this name are treated
as terminals rather than agents: they get a buffer, but they are kept
out of the modeline count, the agent picker, and notifications, because
a shell has no lifecycle worth reporting on."
  :type 'string
  :group 'herdr)

(defun herdr-state-shell-pane-p (pane)
  "Return non-nil when PANE is a shell adopted via `herdr-shell-agent-name'."
  (equal (alist-get 'agent pane) herdr-shell-agent-name))

(defun herdr-state-attachable (state)
  "Return the panes in STATE that herdr will let a client attach to.
That is every pane with a reported agent, adopted shells included."
  (seq-filter (lambda (pane) (alist-get 'agent pane))
              (herdr-state-panes state)))

(defun herdr-state-agents (state)
  "Return the panes in STATE running a real agent.
Adopted shells are excluded; see `herdr-state-attachable' for the set
that gets terminal buffers."
  (seq-remove #'herdr-state-shell-pane-p (herdr-state-attachable state)))

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
clamped.  Like `herdr-state--upsert\\=', ITEMS is not mutated."
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
       ;; `agent' is written even when it is nil, because a release is
       ;; exactly the event that has to clear the label.
       (herdr-state--merge-pane
        state (alist-get 'pane_id data)
        (cons (cons 'agent (alist-get 'agent data))
              (when-let* ((status (alist-get 'final_status data)))
                (list (cons 'agent_status status))))))

      ("pane.agent_status_changed"
       (herdr-state--merge-pane
        state (alist-get 'pane_id data)
        (seq-filter #'cdr
                    (list (cons 'agent_status (alist-get 'agent_status data))
                          (cons 'agent (alist-get 'agent data))))))

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
       ;; current across the move.  Both a vector, as JSON arrays decode.
       ;;
       ;; Placement follows `insert_index' rather than the order of the
       ;; `workspaces' array: the index is the number the caller passed
       ;; and so cannot be misread, whereas whether that array is the
       ;; whole new ordering or only the workspaces it touched is not
       ;; something the schema says.
       (dolist (workspace (append (alist-get 'workspaces data) nil))
         (setf (herdr-state-workspaces next)
               (herdr-state--upsert (herdr-state-workspaces next)
                                    'workspace_id
                                    (alist-get 'workspace_id workspace)
                                    workspace)))
       (setf (herdr-state-workspaces next)
             (herdr-state--move-within (herdr-state-workspaces next)
                                       'workspace_id
                                       (alist-get 'workspace_id data)
                                       (alist-get 'insert_index data)
                                       (lambda (_workspace) t)))
       next)

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
       ;; labels and counts stay current across the move.  Both arrive as
       ;; vectors, so coerce to lists.
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
       ;; `tab_id', `workspace_id', `insert_index' and a `tabs' vector of
       ;; TabInfo, folded in first for freshness.  `insert_index' counts
       ;; among the tabs of `workspace_id' alone, since that is what
       ;; `tab.move' means by it, while the cache holds every
       ;; workspace's tabs in one list.
       (dolist (tab (append (alist-get 'tabs data) nil))
         (setf (herdr-state-tabs next)
               (herdr-state--upsert (herdr-state-tabs next) 'tab_id
                                    (alist-get 'tab_id tab) tab)))
       (let ((workspace-id (alist-get 'workspace_id data)))
         (setf (herdr-state-tabs next)
               (herdr-state--move-within
                (herdr-state-tabs next) 'tab_id (alist-get 'tab_id data)
                (alist-get 'insert_index data)
                (lambda (tab)
                  (equal workspace-id (alist-get 'workspace_id tab))))))
       next)

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

`events.subscribe' replays, but it replays at most ONE RETAINED EVENT
PER SUBSCRIBED TYPE — last-value retention, not history.  Measured
against 0.8.0: subscribing to all 24 global types replayed 8 events in
about 4 ms, and subscribing to `pane.updated' alone in a window that
carried 662 of them replayed exactly one.  The bound is structural, so
the replay is over long before this delay expires whatever the session
is doing.

Long enough, then, to let the retained events land before one
`pane.list' checks the result; see `herdr-state--settle'."
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

(defun herdr-state-current ()
  "Return the live cache."
  herdr-state--current)

(defun herdr-state--dispatch (kind data)
  "Fold event KIND with DATA into the cache and notify listeners.

Every event notifies, including the handful replayed on subscribe.
This used to hold the hook back until the stream had been silent for
0.4s, on the belief that subscribing replayed a hundred and fifty
events of history.  It does not — the replay is
bounded at one retained event per subscribed type — while the live
stream's median gap between events is 0.105s, so a quiet-based window
never closed: simulated against a real 200-second timeline it held the
hook for 54.3 seconds and swallowed 533 events to absorb a replay of 8.
That is a minute of frozen modeline and dashboard after every connect,
which is precisely when an agent is most likely to be working."
  (setq herdr-state--current (herdr-state-reduce herdr-state--current kind data))
  (run-hook-with-args 'herdr-state-change-hook kind data))

(defun herdr-state--schedule-settle ()
  "Arrange the one post-connect reconcile, replacing any pending one."
  (when herdr-state--settle-timer
    (cancel-timer herdr-state--settle-timer))
  (setq herdr-state--settle-timer
        (run-at-time herdr-state-settle-delay nil #'herdr-state--settle)))

(defun herdr-state--settle ()
  "Reconcile the pane set once the retained events have landed, then realign B.

Both halves earn their place even though the replay is small.

Reconciling: one of the retained events is a `pane.created' for whatever
pane was created last, and for a long-closed pane that is a ghost.  The
observed replay folds correctly only because `pane.created' precedes
`pane.closed' in `herdr-state-global-subscriptions' — retained events
arrive in subscription-list order, not chronological order — so a ghost
is one list edit away at any time, and it is a ghost that shows up in
every picker and cannot be navigated to.  `pane.list' is authoritative
and settles it either way.

Realigning connection B afterwards, not before: reconciling is what
makes the pane set final, and B carries one subscription per pane."
  (setq herdr-state--settle-timer nil)
  (when herdr-state--running
    ;; The replayed pane events have already queued a debounced rebuild
    ;; of B through `herdr-state--note-pane-set-change'; drop it, since
    ;; the rebuild below is the same work against a better pane set.
    (when herdr-state--resubscribe-timer
      (cancel-timer herdr-state--resubscribe-timer)
      (setq herdr-state--resubscribe-timer nil))
    (herdr-state-reconcile-panes)
    (herdr-state--open-pane-stream)))

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

(defun herdr-state--pane-subscriptions ()
  "Return per-pane status subscriptions for every pane in the cache.
A vector, because `subscriptions' is a JSON array."
  (herdr-rpc-array
   (mapcar (lambda (id) `((type . "pane.agent_status_changed") (pane_id . ,id)))
           (herdr-state-pane-ids herdr-state--current))))

(defun herdr-state--open-pane-stream ()
  "Rebuild connection B against the current pane set."
  (herdr-state--close herdr-state--pane-process)
  (setq herdr-state--pane-process nil)
  (let ((subscriptions (herdr-state--pane-subscriptions)))
    (when (> (length subscriptions) 0)
      (setq herdr-state--pane-process
            (herdr-state--subscribe "herdr-events-panes" subscriptions)))))

(defun herdr-state--resubscribe-panes ()
  "Rebuild connection B, then refresh statuses the rebuild may have missed."
  (setq herdr-state--resubscribe-timer nil)
  (when herdr-state--running
    (herdr-state--open-pane-stream)
    ;; A rebuild has a gap.  The snapshot carries agent_status for every
    ;; pane, so refreshing from it closes the gap without replaying.
    (herdr-state--refresh-statuses)))

(defun herdr-state--refresh-statuses ()
  "Merge current agent statuses from a fresh snapshot into the cache."
  (when-let* ((snapshot (ignore-errors
                          (alist-get 'snapshot
                                     (herdr-rpc-call "session.snapshot")))))
    (dolist (pane (alist-get 'panes snapshot))
      (setq herdr-state--current
            (herdr-state--merge-pane
             herdr-state--current (alist-get 'pane_id pane)
             (seq-filter #'cdr
                         (list (cons 'agent_status
                                     (alist-get 'agent_status pane))
                               (cons 'agent (alist-get 'agent pane)))))))
    (run-hook-with-args 'herdr-state-change-hook "resync" nil)))

(defun herdr-state--note-pane-set-change (kind _data)
  "Rebuild connection B, debounced, when KIND changed the pane set."
  (when (member kind '("pane_created" "pane_closed" "pane_exited"
                       "pane_agent_detected"))
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
          ;; replayed, so the settle after reconnecting is a resync as
          ;; much as a ghost sweep.
          (herdr-state--schedule-settle)
          (setq herdr-state--reconnect-delay nil))
      (herdr-error (herdr-state--schedule-reconnect)))))

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
  '(agent agent_status cwd foreground_cwd workspace_id tab_id
          terminal_title_stripped)
  "Pane fields worth reacting to.
Deliberately excludes volatile ones such as revision and scroll, which
change constantly and would make every poll look like a change.")

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

Worse, panes can linger.  `events.subscribe\\=' retains the last event of
each subscribed type and replays it, so a `pane_created\\=' for a pane
closed long ago is delivered as though it were news — verified against
0.8.0, where a pane created and closed minutes earlier came back on
every fresh subscription.  The matching `pane_closed\\=' is retained too
and happens to arrive after it, but only because retained events come in
subscription-list order and `pane.created\\=' precedes `pane.closed\\=' in
`herdr-state-global-subscriptions\\='.  Nothing enforces that, and the
ghosts it would otherwise leave show up in every picker and cannot be
navigated to.

One `pane.list\\=' answers both: it is the authoritative set, so panes
missing from it are dropped, panes new to us are added, and directories
are refreshed in the same pass.  Returns non-nil when anything changed."
  (when-let* ((panes (ignore-errors
                       (alist-get 'panes (herdr-rpc-call "pane.list")))))
    (let* ((live-ids (mapcar (lambda (pane) (alist-get 'pane_id pane)) panes))
           (cached-ids (herdr-state-pane-ids herdr-state--current))
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
            ;; agent label can change under us and a cache that only ever
            ;; refreshed directories kept reporting the old one.  The
            ;; common case is an adopted shell that someone then starts
            ;; Claude in: herdr 0.8.0 relabels it `claude' of its own
            ;; accord a few seconds later, because reporting an agent
            ;; does not suppress detection — the two run independently,
            ;; and detection wins.
            (setq changed t)
            (setq herdr-state--current
                  (herdr-state-reduce herdr-state--current "pane_updated"
                                      `((pane . ,pane))))))))
      (when changed
        (run-hook-with-args 'herdr-state-change-hook "reconcile" nil))
      changed)))

(define-obsolete-function-alias 'herdr-state-refresh-directories
  'herdr-state-reconcile-panes "0.1.0")

(defun herdr-state-refresh ()
  "Replace the cache from a fresh snapshot, leaving subscriptions alone.

Lighter than `herdr-state-resync\=', which also rebuilds the per-pane
event connection and so triggers another replay.  This is what the
pickers use: the cache can drift, and a picker offering panes that no
longer exist is worse than one extra round trip."
  (when-let* ((snapshot (ignore-errors
                          (alist-get 'snapshot
                                     (herdr-rpc-call "session.snapshot")))))
    (setq herdr-state--current (herdr-state-from-snapshot snapshot))
    (run-hook-with-args 'herdr-state-change-hook "refresh" nil)
    herdr-state--current))

(defun herdr-state-resync ()
  "Refetch the snapshot and rebuild per-pane subscriptions."
  (interactive)
  (setq herdr-state--current
        (herdr-state-from-snapshot
         (alist-get 'snapshot (herdr-rpc-call "session.snapshot"))))
  (herdr-state--open-pane-stream)
  (run-hook-with-args 'herdr-state-change-hook "resync" nil)
  herdr-state--current)

(defun herdr-state-start ()
  "Hydrate the cache and begin following the event stream."
  (unless herdr-state--running
    (setq herdr-state--running t)
    (add-hook 'herdr-state-change-hook #'herdr-state--note-pane-set-change)
    (condition-case err
        (progn
          (setq herdr-state--current
                (herdr-state-from-snapshot
                 (alist-get 'snapshot (herdr-rpc-call "session.snapshot"))))
          ;; Announce the snapshot immediately so consumers paint
          ;; something true before any event arrives.
          (run-hook-with-args 'herdr-state-change-hook "resync" nil)
          (herdr-state--open-streams)
          (herdr-state--schedule-settle))
      (herdr-error
       (setq herdr-state--running nil)
       (remove-hook 'herdr-state-change-hook #'herdr-state--note-pane-set-change)
       (signal (car err) (cdr err))))))

(defun herdr-state-stop ()
  "Stop following the event stream and drop the cache."
  (setq herdr-state--running nil)
  (remove-hook 'herdr-state-change-hook #'herdr-state--note-pane-set-change)
  (dolist (proc (list herdr-state--global-process herdr-state--pane-process))
    (herdr-state--close proc))
  (dolist (timer (list herdr-state--reconnect-timer
                       herdr-state--resubscribe-timer
                       herdr-state--settle-timer))
    (when timer (cancel-timer timer)))
  (setq herdr-state--global-process nil
        herdr-state--pane-process nil
        herdr-state--reconnect-timer nil
        herdr-state--resubscribe-timer nil
        herdr-state--settle-timer nil
        herdr-state--reconnect-delay nil
        herdr-state--current (herdr-state-empty)))

(defun herdr-state-running-p ()
  "Return non-nil when the event stream is being followed."
  (and herdr-state--running t))

(provide 'herdr-state)
;;; herdr-state.el ends here
