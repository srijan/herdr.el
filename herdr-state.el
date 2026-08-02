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
    "workspace.renamed" "workspace.moved" "workspace.closed"
    "workspace.focused"
    "worktree.created" "worktree.opened" "worktree.removed"
    "tab.created" "tab.closed" "tab.renamed" "tab.moved" "tab.focused"
    "pane.created" "pane.closed" "pane.updated" "pane.focused"
    "pane.moved" "pane.exited" "pane.agent_detected"
    "layout.updated")
  "Subscriptions that carry no pane id and so never need rebuilding.")

;;; The state object

(cl-defstruct (herdr-state (:constructor herdr-state--make)
                           (:copier herdr-state-copy))
  (panes nil)
  (tabs nil)
  (workspaces nil)
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

(defun herdr-state--merge-pane (state pane-id changes)
  "Return STATE with CHANGES merged into the pane named PANE-ID.
Absent panes are ignored.  Keys not present in CHANGES are left alone,
which matters because per-pane status events carry only a few fields."
  (let ((pane (herdr-state-pane state pane-id)))
    (if (not pane)
        state
      (let ((merged (copy-alist pane))
            (next (herdr-state-copy state)))
        (dolist (cell changes)
          (setf (alist-get (car cell) merged) (cdr cell)))
        (setf (herdr-state-panes next)
              (herdr-state--upsert (herdr-state-panes state)
                                   'pane_id pane-id merged))
        next))))

(defun herdr-state-reduce (state kind data)
  "Return a new state produced by applying event KIND with DATA to STATE.

Pure: STATE is never mutated.  KIND is herdr's event name.  Note that
global events use underscores while the three per-pane subscription
events use dots, so both spellings appear here deliberately."
  (let ((next (herdr-state-copy state)))
    (pcase kind
      ((or "pane_created" "pane_updated" "pane_moved" "pane_agent_detected")
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

      ("pane.agent_status_changed"
       (herdr-state--merge-pane
        state (alist-get 'pane_id data)
        (seq-filter #'cdr
                    (list (cons 'agent_status (alist-get 'agent_status data))
                          (cons 'agent (alist-get 'agent data))))))

      ("pane.scroll_changed"
       (herdr-state--merge-pane state (alist-get 'pane_id data)
                                (list (cons 'scroll (alist-get 'scroll data)))))

      ((or "workspace_created" "workspace_updated" "workspace_renamed"
           "workspace_moved" "workspace_metadata_updated")
       (let ((workspace (alist-get 'workspace data)))
         (if (not workspace)
             state
           (setf (herdr-state-workspaces next)
                 (herdr-state--upsert (herdr-state-workspaces state)
                                      'workspace_id
                                      (alist-get 'workspace_id workspace)
                                      workspace))
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

      ((or "tab_created" "tab_renamed" "tab_moved")
       (let ((tab (alist-get 'tab data)))
         (if (not tab)
             state
           (setf (herdr-state-tabs next)
                 (herdr-state--upsert (herdr-state-tabs state) 'tab_id
                                      (alist-get 'tab_id tab) tab))
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

(defcustom herdr-state-prime-quiet 0.4
  "Seconds of event-stream silence that end the priming window.

`events.subscribe' replays history: subscribing to an idle server
returned 54 past events here, and a real startup produced roughly 150.
The cache converges correctly because the replay is ordered, but firing
`herdr-state-change-hook' for every replayed event would make each
consumer redraw a hundred times before showing anything true.  So the
hook is suppressed until the stream goes quiet, then a snapshot settles
the cache authoritatively and listeners are notified once."
  :type 'number
  :group 'herdr)

(defvar herdr-state--current (herdr-state-empty)
  "The live cache.")

(defvar herdr-state--priming nil
  "Non-nil while the subscription replay is still draining.")

(defvar herdr-state--prime-timer nil)

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
While priming, the fold still happens but listeners are not notified;
see `herdr-state-prime-quiet'."
  (setq herdr-state--current (herdr-state-reduce herdr-state--current kind data))
  (if herdr-state--priming
      (herdr-state--defer-prime-end)
    (run-hook-with-args 'herdr-state-change-hook kind data)))

(defun herdr-state--defer-prime-end ()
  "Push the end of the current priming phase out by `herdr-state-prime-quiet'.

Priming runs in two phases because rebuilding connection B replays as
well.  Phase `settle' drains the initial replay and then rebuilds B
against an authoritative snapshot; phase `quiet' drains B's own replay
and finally announces."
  (when herdr-state--prime-timer
    (cancel-timer herdr-state--prime-timer))
  (setq herdr-state--prime-timer
        (run-at-time herdr-state-prime-quiet nil
                     (if (eq herdr-state--priming 'settle)
                         #'herdr-state--settle-priming
                       #'herdr-state--finish-priming))))

(defun herdr-state--settle-priming ()
  "Snapshot authoritatively, realign connection B, then wait out its replay."
  (setq herdr-state--prime-timer nil)
  (when herdr-state--running
    (condition-case nil
        (setq herdr-state--current
              (herdr-state-from-snapshot
               (alist-get 'snapshot (herdr-rpc-call "session.snapshot"))))
      (herdr-error nil))
    (setq herdr-state--priming 'quiet)
    (herdr-state--open-pane-stream)
    (herdr-state--defer-prime-end)))

(defun herdr-state--finish-priming ()
  "Leave the priming window and notify listeners once.

Reconciles first: the replay this window exists to absorb is exactly
what leaves ghost panes behind, so waiting for the next poll would mean
the first pickers of the session show panes that no longer exist."
  (setq herdr-state--prime-timer nil
        herdr-state--priming nil)
  (when herdr-state--running
    (herdr-state-reconcile-panes)
    (run-hook-with-args 'herdr-state-change-hook "resync" nil)))

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
          ;; Reconnecting replays too, so re-enter the priming window.
          (setq herdr-state--priming 'settle)
          (herdr-state--open-streams)
          (herdr-state--defer-prime-end)
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

(defun herdr-state-detected-agent (pane-id)
  "Return the agent herdr's detector recognises in PANE-ID, or nil.

This is not the same as the pane's reported agent.  `agent.explain'
exposes what detection concluded, which stays visible even while another
source holds the label."
  (let ((explain (ignore-errors
                   (alist-get 'explain
                              (herdr-rpc-call "agent.explain"
                                              `((target . ,pane-id)))))))
    (alist-get 'agent explain)))

(defun herdr-state-promote-shell-panes ()
  "Relabel adopted shells in which a real agent has since started.

Adopting a pane means reporting an agent for it, and reporting takes
lifecycle authority — which suppresses herdr's own detection for that
pane.  So starting Claude in an adopted shell leaves it labelled
`herdr-shell-agent-name' forever, and it never appears as an agent.

Releasing authority does not help: detection binds when an agent starts
and does not re-run, so a released pane goes to no agent at all rather
than to the one that is plainly running.

What does work is reading the detector's own conclusion through
`agent.explain', which remains available while we hold the label, and
re-reporting under that name.  Returns non-nil if anything was promoted."
  (let ((promoted nil))
    (dolist (pane (herdr-state-panes herdr-state--current))
      (when (herdr-state-shell-pane-p pane)
        (let* ((id (alist-get 'pane_id pane))
               (detected (herdr-state-detected-agent id)))
          (when (and detected
                     (not (equal detected herdr-shell-agent-name)))
            (ignore-errors
              (herdr-rpc-call "pane.report_agent"
                              `((pane_id . ,id)
                                (source . "herdr.el")
                                (agent . ,detected)
                                (state . "idle")))
              (setq promoted t)
              (message "herdr: %s is running %s; promoted from %s"
                       id detected herdr-shell-agent-name))))))
    promoted))

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
a `cd\=' produces no `pane_updated\=', only unrelated `layout_updated\='
traffic.

Worse, panes can linger.  `events.subscribe\=' replays history, and
priming ends after a fixed quiet period — so a bursty replay can end
priming early, and `pane_created\=' events for long-closed panes then
fold in after the settling snapshot, resurrecting them.  Those ghosts
show up in every picker and cannot be navigated to.

One `pane.list\=' answers both: it is the authoritative set, so panes
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
            ;; agent label can change under us — a shell promoted to a
            ;; real agent is the common case — and a cache that only ever
            ;; refreshed directories kept reporting the old label.
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
          ;; Announce the snapshot immediately so consumers paint something
          ;; true, then swallow the subscription replay that follows.
          (run-hook-with-args 'herdr-state-change-hook "resync" nil)
          (setq herdr-state--priming 'settle)
          (herdr-state--open-streams)
          (herdr-state--defer-prime-end))
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
                       herdr-state--prime-timer))
    (when timer (cancel-timer timer)))
  (setq herdr-state--global-process nil
        herdr-state--pane-process nil
        herdr-state--reconnect-timer nil
        herdr-state--resubscribe-timer nil
        herdr-state--prime-timer nil
        herdr-state--priming nil
        herdr-state--reconnect-delay nil
        herdr-state--current (herdr-state-empty)))

(defun herdr-state-running-p ()
  "Return non-nil when the event stream is being followed."
  (and herdr-state--running t))

(provide 'herdr-state)
;;; herdr-state.el ends here
