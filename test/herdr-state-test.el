;;; herdr-state-test.el --- Tests for the herdr state reducer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-state)
(require 'herdr-test-helper)

(defun herdr-state-test--pane (id &optional agent status)
  `((pane_id . ,id)
    (workspace_id . "w1")
    (tab_id . "w1:t1")
    (cwd . "/tmp")
    (agent . ,agent)
    (agent_status . ,(or status "unknown"))))

(defun herdr-state-test--seed ()
  (herdr-state-from-snapshot
   `((focused_pane_id . "w1:p1")
     (focused_tab_id . "w1:t1")
     (focused_workspace_id . "w1")
     (panes . (,(herdr-state-test--pane "w1:p1" "claude" "idle")
               ,(herdr-state-test--pane "w1:p2")))
     (workspaces . (((workspace_id . "w1") (label . "web")))))))

;;; Snapshot hydration

(ert-deftest herdr-state-workspace-finds-one-by-id ()
  "The workspace counterpart of `herdr-state-pane\\=', and the way a
caller holding one string tells a workspace id from a directory: only
one of the two is in the cache under that name."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1") (label . "ws"))
                                 ((workspace_id . "w2") (label . "api"))))))))
    (should (equal "api" (herdr-workspace-label
                          (herdr-state-workspace state "w2"))))
    (should-not (herdr-state-workspace state "/tmp/not-a-workspace/"))
    (should-not (herdr-state-workspace state "w9"))))

(ert-deftest herdr-state-from-snapshot-populates-everything ()
  (let ((state (herdr-state-test--seed)))
    (should (= 2 (length (herdr-state-panes state))))
    (should (= 1 (length (herdr-state-workspaces state))))
    (should (equal "w1:p1" (herdr-state-focused-pane-id state)))))

(ert-deftest herdr-state-agents-are-panes-with-an-agent ()
  (let ((state (herdr-state-test--seed)))
    (should (= 1 (length (herdr-state-agents state))))
    (should (equal "w1:p1"
                   (alist-get 'pane_id (car (herdr-state-agents state)))))))

;;; Reduction

(ert-deftest herdr-state-reduce-pane-created-adds-a-pane ()
  (let* ((state (herdr-state-test--seed))
         (next (herdr-state-reduce
                state "pane_created"
                `((pane . ,(herdr-state-test--pane "w1:p3"))))))
    (should (= 3 (length (herdr-state-panes next))))
    (should (herdr-state-pane next "w1:p3"))))

(ert-deftest herdr-state-reduce-is-pure ()
  "Reducing must not mutate the state it was handed."
  (let* ((state (herdr-state-test--seed))
         (_ (herdr-state-reduce state "pane_created"
                                `((pane . ,(herdr-state-test--pane "w1:p3"))))))
    (should (= 2 (length (herdr-state-panes state))))
    (should-not (herdr-state-pane state "w1:p3"))))

(ert-deftest herdr-state-reduce-pane-closed-removes-a-pane ()
  (let ((next (herdr-state-reduce (herdr-state-test--seed)
                                  "pane_closed" '((pane_id . "w1:p2")))))
    (should (= 1 (length (herdr-state-panes next))))
    (should-not (herdr-state-pane next "w1:p2"))))

(ert-deftest herdr-state-reduce-pane-exited-removes-a-pane ()
  (let ((next (herdr-state-reduce (herdr-state-test--seed)
                                  "pane_exited" '((pane_id . "w1:p1")))))
    (should-not (herdr-state-pane next "w1:p1"))))

(ert-deftest herdr-state-reduce-pane-updated-replaces-in-place ()
  "An updated pane must keep its position so pickers do not reshuffle."
  (let* ((next (herdr-state-reduce
                (herdr-state-test--seed) "pane_updated"
                `((pane . ,(herdr-state-test--pane "w1:p1" "claude" "working"))))))
    (should (= 2 (length (herdr-state-panes next))))
    (should (equal "w1:p1" (alist-get 'pane_id (car (herdr-state-panes next)))))
    (should (equal "working"
                   (alist-get 'agent_status (herdr-state-pane next "w1:p1"))))))

(ert-deftest herdr-state-reduce-dotted-agent-status-event-updates-status ()
  "Per-pane subscription events use dotted kinds and a flat payload."
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane.agent_status_changed"
               '((pane_id . "w1:p1") (workspace_id . "w1")
                 (agent_status . "blocked")))))
    (should (equal "blocked"
                   (alist-get 'agent_status (herdr-state-pane next "w1:p1"))))
    ;; Fields the event does not carry must survive untouched.
    (should (equal "claude" (alist-get 'agent (herdr-state-pane next "w1:p1"))))
    (should (equal "/tmp" (alist-get 'cwd (herdr-state-pane next "w1:p1"))))))

(ert-deftest herdr-state-reduce-agent-status-for-unknown-pane-is-a-noop ()
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane.agent_status_changed"
               '((pane_id . "w9:p9") (agent_status . "blocked")))))
    (should (= 2 (length (herdr-state-panes next))))))

(ert-deftest herdr-state-reduce-agent-detected-sets-the-agent ()
  "The event is flat — pane_id, workspace_id, agent — with no PaneInfo.
Reading a `pane' out of it, as this branch used to, finds nothing and
leaves a detected agent invisible to the modeline and the pickers."
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane_agent_detected"
               '((type . "pane_agent_detected") (pane_id . "w1:p2")
                 (workspace_id . "w1") (agent . "codex")))))
    (should (= 2 (length (herdr-state-agents next))))
    (should (equal "codex" (alist-get 'agent (herdr-state-pane next "w1:p2"))))
    ;; Only the label moves: the event carries no other pane field.
    (should (equal "/tmp" (alist-get 'cwd (herdr-state-pane next "w1:p2"))))))

(ert-deftest herdr-state-reduce-agent-detected-release-clears-the-agent ()
  "A release comes through the same event, so the label must be written
rather than merged over."
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane_agent_detected"
               '((type . "pane_agent_detected") (pane_id . "w1:p1")
                 (workspace_id . "w1") (agent . nil) (released . t)
                 (final_status . "idle")))))
    (should-not (alist-get 'agent (herdr-state-pane next "w1:p1")))
    (should (equal "idle"
                   (alist-get 'agent_status (herdr-state-pane next "w1:p1"))))
    (should (null (herdr-state-agents next)))))

(ert-deftest herdr-state-reduce-agent-detected-release-wins-over-a-named-agent ()
  "`released' decides, not `agent'.

The schema allows a release to name the agent that went away, and
nothing observed rules that out — the one release-shaped event captured
from the wire was a detection.  Trusting `agent' there would leave the
pane counted in the modeline, offered by the agent picker and notified
about for the rest of the session.  Keying off `released' is correct
whichever way herdr fills the field in."
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane_agent_detected"
               '((type . "pane_agent_detected") (pane_id . "w1:p1")
                 (workspace_id . "w1") (agent . "claude") (released . t)
                 (final_status . "idle")))))
    (should-not (alist-get 'agent (herdr-state-pane next "w1:p1")))
    (should (null (herdr-state-agents next)))))

(ert-deftest herdr-state-reduce-agent-detected-for-an-unknown-pane-is-a-noop ()
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane_agent_detected"
               '((pane_id . "w9:p9") (agent . "codex")))))
    (should (= 2 (length (herdr-state-panes next))))
    (should (= 1 (length (herdr-state-agents next))))))

(ert-deftest herdr-state-reduce-pane-focused-moves-focus ()
  (let ((next (herdr-state-reduce (herdr-state-test--seed)
                                  "pane_focused" '((pane_id . "w1:p2")))))
    (should (equal "w1:p2" (herdr-state-focused-pane-id next)))))

(ert-deftest herdr-state-reduce-workspace-events ()
  (let* ((s (herdr-state-test--seed))
         (s (herdr-state-reduce s "workspace_created"
                                '((workspace . ((workspace_id . "w2")
                                                (label . "other"))))))
         (s (herdr-state-reduce s "workspace_focused" '((workspace_id . "w2")))))
    (should (= 2 (length (herdr-state-workspaces s))))
    (should (equal "w2" (herdr-state-focused-workspace-id s)))
    (let ((s (herdr-state-reduce s "workspace_closed" '((workspace_id . "w2")))))
      (should (= 1 (length (herdr-state-workspaces s)))))))

(ert-deftest herdr-state-ignores-tab-events-entirely ()
  "Nothing outside this file ever read a tab record, so the cache stopped
keeping them.  A tab event must therefore leave the state untouched
rather than signal."
  (let* ((s (herdr-state-test--seed))
         (next (herdr-state-reduce s "tab_created"
                                   '((tab . ((tab_id . "w2:t1")))))))
    (should (eq s next))
    (should-not (fboundp 'herdr-state-tabs))
    (should-not (fboundp 'herdr-state-reconcile-tabs))))

;;; Renames and moves, whose events carry no nested record

(ert-deftest herdr-state-reduce-workspace-renamed-updates-the-label ()
  "The event is `workspace_id' plus `label', with no WorkspaceInfo.
Looking for one dropped every rename on the floor, so the dashboard
went on showing the old name."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w1") (label . "web")
                                   (pane_count . 3)))))))
         (next (herdr-state-reduce state "workspace_renamed"
                                   '((type . "workspace_renamed")
                                     (workspace_id . "w1")
                                     (label . "api")))))
    (let ((workspace (car (herdr-state-workspaces next))))
      (should (equal "api" (herdr-workspace-label workspace)))
      ;; A rename carries nothing else, so nothing else may be lost.
      (should (equal 3 (herdr-workspace-pane-count workspace))))
    ;; Pure, as ever.
    (should (equal "web" (herdr-workspace-label
                          (car (herdr-state-workspaces state)))))))

(ert-deftest herdr-state-reduce-workspace-renamed-for-an-unknown-id-is-a-noop ()
  (let* ((state (herdr-state-test--seed))
         (next (herdr-state-reduce state "workspace_renamed"
                                   '((workspace_id . "w9") (label . "api")))))
    ;; The very state object, not a copy of it: an event that changes
    ;; nothing must be indistinguishable from one that never arrived.
    (should (eq state next))
    (should (= 1 (length (herdr-state-workspaces next))))
    (should (equal "web" (herdr-workspace-label
                          (car (herdr-state-workspaces next)))))))

(defun herdr-state-test--ws-seed ()
  "State with four workspaces w1..w4 in order, for reorder tests."
  (herdr-state-from-snapshot
   `((focused_workspace_id . "w1")
     (panes . ())
     (workspaces . (((workspace_id . "w1") (label . "one"))
                    ((workspace_id . "w2") (label . "two"))
                    ((workspace_id . "w3") (label . "three"))
                    ((workspace_id . "w4") (label . "four")))))))

(defun herdr-state-test--ws-order (state)
  "Return STATE's workspace ids in list order."
  (mapcar (lambda (w) (herdr-workspace-id w))
          (herdr-state-workspaces state)))

(ert-deftest herdr-state-reduce-workspace-moved-places-it-by-insert-index ()
  "`workspace.move' takes an id and an index and the event echoes both,
so the index is what decides where the workspace lands.

A backward move — w4 from the end to index 1 — which both readings of
`insert_index' agree on; see
`herdr-state-reduce-workspace-moved-forward-pins-an-unverified-reading'."
  (let ((next (herdr-state-reduce
               (herdr-state-test--ws-seed) "workspace_moved"
               `((type . "workspace_moved") (workspace_id . "w4")
                 (insert_index . 1)
                 (workspaces . [((workspace_id . "w4") (label . "four"))])))))
    (should (equal '("w1" "w4" "w2" "w3") (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-moved-folds-in-fresh-info ()
  "The WorkspaceInfo the event carries refreshes labels across the move.
Backward move, so the fold is asserted without the placement reading
riding along on it."
  (let* ((next (herdr-state-reduce
                (herdr-state-test--ws-seed) "workspace_moved"
                `((workspace_id . "w2") (insert_index . 0)
                  (workspaces . [((workspace_id . "w2") (label . "renamed"))]))))
         (w2 (seq-find (lambda (w) (equal "w2" (herdr-workspace-id w)))
                       (herdr-state-workspaces next))))
    (should (equal "renamed" (herdr-workspace-label w2)))
    (should (equal '("w2" "w1" "w3" "w4") (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-moved-forward-pins-an-unverified-reading ()
  "UNVERIFIED: this fixes one of two possible readings of `insert_index'.

`herdr-state--move-within' counts the index against the list with the
moved workspace already taken out, so w2 to index 3 of (w1 w2 w3 w4)
gives (w1 w3 w4 w2).  Counting against the list with w2 still in it
gives (w1 w3 w2 w4) instead.  Only a forward move can tell them apart.

Nothing has been measured: provoking one means calling
`workspace.move' on a live session, which was out of bounds here.  A
single real `workspace_moved' watched read-only on the event stream
settles it.  This test is here to be found and corrected if the other
reading is right — correct it, do not delete it."
  (let ((next (herdr-state-reduce
               (herdr-state-test--ws-seed) "workspace_moved"
               `((workspace_id . "w2") (insert_index . 3)
                 (workspaces . [])))))
    (should (equal '("w1" "w3" "w4" "w2") (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-moved-is-pure ()
  (let* ((state (herdr-state-test--ws-seed))
         (_ (herdr-state-reduce state "workspace_moved"
                                `((workspace_id . "w4") (insert_index . 0)
                                  (workspaces . [])))))
    (should (equal '("w1" "w2" "w3" "w4") (herdr-state-test--ws-order state)))))

(ert-deftest herdr-state-reduce-workspace-moved-for-an-unknown-id-is-a-noop ()
  (let* ((state (herdr-state-test--ws-seed))
         (next (herdr-state-reduce state "workspace_moved"
                                   `((workspace_id . "w9") (insert_index . 0)
                                     (workspaces . [])))))
    (should (eq state next))
    (should (equal '("w1" "w2" "w3" "w4") (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-moved-clamps-a-past-the-end-index ()
  "Clamping puts it at the end under either reading of the index."
  (let ((next (herdr-state-reduce
               (herdr-state-test--ws-seed) "workspace_moved"
               `((workspace_id . "w1") (insert_index . 99) (workspaces . [])))))
    (should (equal '("w2" "w3" "w4" "w1") (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-reordered-splices-a-block ()
  "A worktree-group move relocates its block ahead of the anchor.
The payload arrives with vector fields, as `json-parse-string' decodes
arrays."
  (let ((next (herdr-state-reduce
               (herdr-state-test--ws-seed) "workspace_reordered"
               `((workspace_ids . ["w3" "w4"])
                 (before_workspace_id . "w2")
                 (workspaces . [((workspace_id . "w3") (label . "three"))
                                ((workspace_id . "w4") (label . "four"))])))))
    (should (equal '("w1" "w3" "w4" "w2")
                   (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-reordered-appends-without-an-anchor ()
  "A nil `before_workspace_id' drops the block at the end."
  (let ((next (herdr-state-reduce
               (herdr-state-test--ws-seed) "workspace_reordered"
               `((workspace_ids . ["w1" "w2"])
                 (before_workspace_id . nil)
                 (workspaces . [((workspace_id . "w1") (label . "one"))
                                ((workspace_id . "w2") (label . "two"))])))))
    (should (equal '("w3" "w4" "w1" "w2")
                   (herdr-state-test--ws-order next)))))

(ert-deftest herdr-state-reduce-workspace-reordered-folds-updated-info ()
  "The WorkspaceInfo the event carries refreshes fields across the move."
  (let* ((next (herdr-state-reduce
                (herdr-state-test--ws-seed) "workspace_reordered"
                `((workspace_ids . ["w3"])
                  (before_workspace_id . "w1")
                  (workspaces . [((workspace_id . "w3") (label . "renamed"))]))))
         (w3 (seq-find (lambda (w) (equal "w3" (herdr-workspace-id w)))
                       (herdr-state-workspaces next))))
    (should (equal '("w3" "w1" "w2" "w4") (herdr-state-test--ws-order next)))
    (should (equal "renamed" (herdr-workspace-label w3)))))

(ert-deftest herdr-state-reduce-workspace-reordered-is-pure ()
  "Reordering must not mutate the state it was handed."
  (let* ((state (herdr-state-test--ws-seed))
         (_ (herdr-state-reduce
             state "workspace_reordered"
             `((workspace_ids . ["w4"])
               (before_workspace_id . "w1")
               (workspaces . [((workspace_id . "w4") (label . "four"))])))))
    (should (equal '("w1" "w2" "w3" "w4") (herdr-state-test--ws-order state)))))

(ert-deftest herdr-state-reduce-ignores-layout-and-unknown-kinds ()
  (let* ((state (herdr-state-test--seed))
         (a (herdr-state-reduce state "layout_updated" '((layout . ()))))
         (b (herdr-state-reduce state "something_new" '((x . 1)))))
    (should (= 2 (length (herdr-state-panes a))))
    (should (= 2 (length (herdr-state-panes b))))
    (should (equal (herdr-state-focused-pane-id state)
                   (herdr-state-focused-pane-id b)))))

;;; Attachability

(ert-deftest herdr-state-agents-is-every-pane-with-an-agent ()
  "An agent is a process herdr recognizes inside a pane — nothing more."
  (let ((state (herdr-state-from-snapshot
                `((panes . (((pane_id . "w1:p1") (agent . "claude"))
                            ((pane_id . "w1:p2") (agent . nil))))))))
    (should (equal '("w1:p1")
                   (mapcar (lambda (p) (alist-get 'pane_id p))
                           (herdr-state-agents state))))))

(ert-deftest herdr-state-keeps-the-agents-array ()
  "session.snapshot carries agent names that no pane record has."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (agent . "claude"))))
                  (agents . (((pane_id . "w1:p1") (agent . "claude")
                              (name . "reviewer"))))))))
    (should (equal "reviewer" (herdr-state-agent-name state "w1:p1")))))

(ert-deftest herdr-state-agent-name-is-nil-until-renamed ()
  "AgentInfo.name is null until someone calls agent.rename."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (agent . "claude"))))
                  (agents . (((pane_id . "w1:p1") (agent . "claude")
                              (name . nil))))))))
    (should-not (herdr-state-agent-name state "w1:p1"))
    (should-not (herdr-state-agent-name state "w1:p9"))))

(ert-deftest herdr-state-workspace-directory-comes-from-panes ()
  "Protocol 19 WorkspaceInfo has no cwd, so it is derived."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1"))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (cwd . "/tmp/project"))
                            ((pane_id . "w1:p2") (workspace_id . "w1")
                             (cwd . "/tmp/project/sub"))))))))
    (should (equal "/tmp/project/"
                   (herdr-state-workspace-directory state "w1")))))

(ert-deftest herdr-state-workspace-directory-skips-panes-without-cwd ()
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1"))
                            ((pane_id . "w1:p2") (workspace_id . "w1")
                             (cwd . "/tmp/project"))))))))
    (should (equal "/tmp/project/"
                   (herdr-state-workspace-directory state "w1")))))

(ert-deftest herdr-state-workspace-directory-is-nil-when-unknown ()
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1"))))))))
    (should-not (herdr-state-workspace-directory state "w1"))
    (should-not (herdr-state-workspace-directory state "w9"))))

(ert-deftest herdr-state-workspace-for-directory-matches-with-or-without-a-trailing-slash ()
  "Shared with `herdr-tree.el' now, so this pins the contract at its new
home rather than only through `herdr-project' in test/herdr-project-test.el."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1"))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (cwd . "/tmp/project"))))))))
    (should (equal "w1" (herdr-workspace-id
                         (herdr-state-workspace-for-directory
                          state "/tmp/project"))))
    (should (equal "w1" (herdr-workspace-id
                         (herdr-state-workspace-for-directory
                          state "/tmp/project/"))))))

(ert-deftest herdr-state-workspace-for-directory-is-nil-for-an-unknown-root ()
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1"))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (cwd . "/tmp/project"))))))))
    (should-not (herdr-state-workspace-for-directory state "/tmp/elsewhere"))))

;;; Failure paths around the live connections

(ert-deftest herdr-state-stop-announces-the-emptied-cache ()
  "Listeners hold their own view; dropping the cache silently is the
same bug as the unannounced resync one connection earlier.  Without
this the modeline advertised the dead session's agent counts until the
minor mode was toggled."
  (herdr-test-with-state (:running t :global-process nil :pane-process nil :reconnect-timer nil :resubscribe-timer nil :settle-timer nil :reconnect-delay nil :cache (herdr-state-from-snapshot
          '((panes . (((pane_id . "w1:p1") (agent . "claude")))))))(let* ((kinds nil))
    (let ((herdr-state-change-functions
           (list (lambda (kind _data) (push kind kinds)))))
      (herdr-state-stop (herdr-current-connection))
      (should (equal '("resync") kinds))
      (should-not (herdr-state-pane-ids (herdr-connection-cache (herdr-current-connection))))))))

(ert-deftest herdr-state-start-rolls-back-on-a-plain-error ()
  "`herdr-state--open-streams' reaches `process-send-string' through the
subscribe path, which signals a plain `error' — not `herdr-error' —
when the peer closes between connect and send.  A handler that caught
only `herdr-error' let that escape the rollback, leaving
`(herdr-connection-running (herdr-current-connection))' stuck at t with no stream open and no hook
removed, and `herdr-start''s own `unless' skipping every later retry."
  (herdr-test-with-state (:running nil :generation 0)
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (&rest _) '((snapshot . ((panes . ()))))))
              ((symbol-function 'herdr-state--open-streams)
               (lambda (_connection) (error "peer closed before send"))))
      (should-error (herdr-state-start (herdr-current-connection)))
      (should-not (herdr-connection-running (herdr-current-connection)))
      (should-not (memq #'herdr-state--note-pane-set-change
                        herdr-state-change-functions)))))

(ert-deftest herdr-state-reconnect-survives-a-plain-error ()
  "`process-send-string' signals a plain `error' when the peer closes
between connect and send — not a `herdr-error' — and the reconnect
timer variable is already cleared when the attempt runs.  A handler
that caught only `herdr-error' let that signal escape the timer as a
backtrace, with no reconnect scheduled and recovery left to luck."
  (herdr-test-with-state (:running t :reconnect-timer nil :reconnect-delay nil)
    (cl-letf (((symbol-function 'herdr-state--open-streams)
               (lambda (_connection) (error "peer closed before send"))))
      (unwind-protect
          (progn
            (herdr-state--reconnect (herdr-current-connection))
            (should (herdr-connection-reconnect-timer (herdr-current-connection))))
        (when (herdr-connection-reconnect-timer (herdr-current-connection))
          (cancel-timer (herdr-connection-reconnect-timer (herdr-current-connection))))))))

;;; The repair cadence belongs to the cache

(defmacro herdr-state-test--with-quiet-session (&rest body)
  "Run BODY with every session global bound to a fresh, empty value."
  (declare (indent 0))
  `(herdr-test-with-state (:running nil :generation 0 :repairing nil :global-process nil :pane-process nil :pane-stream-ids nil :reconnect-timer nil :reconnect-delay nil :resubscribe-timer nil :settle-timer nil :repair-timer nil)(let* ((herdr-state-change-functions nil))
     (unwind-protect (progn ,@body)
       (dolist (timer (list (herdr-connection-reconnect-timer (herdr-current-connection))
                            (herdr-connection-resubscribe-timer (herdr-current-connection))
                            (herdr-connection-settle-timer (herdr-current-connection))
                            (herdr-connection-repair-timer (herdr-current-connection))))
         (when (timerp timer) (cancel-timer timer)))))))

(ert-deftest herdr-state-start-arms-the-repair-timer ()
  "The cadence is the cache's own, armed by the thing that starts it."
  (herdr-state-test--with-quiet-session
    (let ((herdr-state-repair-interval 5.0))
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (&rest _) '((snapshot . ((panes . ()))))))
                ((symbol-function 'herdr-state--open-streams) #'ignore))
        (herdr-state-start (herdr-current-connection))
        (should (timerp (herdr-connection-repair-timer (herdr-current-connection))))))))

(ert-deftest herdr-state-start-twice-arms-one-timer ()
  "`herdr-state-start' is idempotent, and a second timer would double
the repair rate for the rest of the session with nothing to cancel it."
  (herdr-state-test--with-quiet-session
    (let ((herdr-state-repair-interval 5.0)
          (armed 0))
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (&rest _) '((snapshot . ((panes . ()))))))
                ((symbol-function 'herdr-state--open-streams) #'ignore))
        (herdr-state-start (herdr-current-connection))
        (let ((first (herdr-connection-repair-timer (herdr-current-connection))))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (&rest _) (cl-incf armed) 'extra)))
            (herdr-state-start (herdr-current-connection)))
          (should (eq first (herdr-connection-repair-timer (herdr-current-connection))))
          (should (zerop armed)))))))

(ert-deftest herdr-state-repair-interval-nil-arms-no-timer ()
  "Nil means no periodic repair, and the cache still starts."
  (herdr-state-test--with-quiet-session
    (let ((herdr-state-repair-interval nil))
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (&rest _) '((snapshot . ((panes . ()))))))
                ((symbol-function 'herdr-state--open-streams) #'ignore))
        (herdr-state-start (herdr-current-connection))
        (should (herdr-connection-running (herdr-current-connection)))
        (should-not (herdr-connection-repair-timer (herdr-current-connection)))))))

(ert-deftest herdr-state-stop-cancels-the-repair-timer ()
  "Nilling the handle is not cancelling the timer, and no test that
watches the repair can tell the difference: the repair is guarded, so a
spurious later fire is swallowed."
  (let ((repair (run-at-time 3600 nil #'ignore))
        (cancelled nil))
    (unwind-protect
        (herdr-test-with-state (:running t :global-process nil :pane-process nil :reconnect-timer nil :resubscribe-timer nil :settle-timer nil :repair-timer repair)(let* ((herdr-state-change-functions nil))
          (cl-letf (((symbol-function 'cancel-timer)
                     (lambda (timer) (push timer cancelled))))
            (herdr-state-stop (herdr-current-connection)))
          (should (equal (list repair) cancelled))
          (should-not (herdr-connection-repair-timer (herdr-current-connection)))))
      (cancel-timer repair))))

(ert-deftest herdr-state-stop-has-no-repair-timer-to-cancel ()
  "A stop before any start must not hand nil to `cancel-timer'."
  (let ((cancelled nil))
    (herdr-test-with-state (:running nil :global-process nil :pane-process nil :reconnect-timer nil :resubscribe-timer nil :settle-timer nil :repair-timer nil)(let* ((herdr-state-change-functions nil))
      (cl-letf (((symbol-function 'cancel-timer)
                 (lambda (timer) (push timer cancelled))))
        (herdr-state-stop (herdr-current-connection)))
      (should-not cancelled)))))

(ert-deftest herdr-state-repair-reconciles-panes-then-workspaces ()
  "Panes first: a workspace reconcile reads a pane set the pane
reconcile has just made authoritative."
  (herdr-state-test--with-quiet-session
    (let ((order nil))
      (setf (herdr-connection-running (herdr-current-connection)) t)
      (cl-letf (((symbol-function 'herdr-state-reconcile-panes)
                 (lambda (_connection) (push 'panes order) nil))
                ((symbol-function 'herdr-state-reconcile-workspaces)
                 (lambda (_connection) (push 'workspaces order) nil)))
        (herdr-state-repair (herdr-current-connection))
        (should (equal '(workspaces panes) order))))))

(ert-deftest herdr-state-calls-the-connection-it-was-given ()
  "Every RPC a state function makes goes to the connection it was handed.

Threading the argument and then resolving the current connection at the
call site anyway reads the same at one connection and sends every
request to the wrong server at two, which is the failure this unit
exists to prevent.  The connection under test is deliberately not the
sole one."
  (herdr-state-test--with-quiet-session
    (let ((mine (herdr-test-connection))
          (asked nil))
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (connection &rest _)
                   (push connection asked)
                   '((snapshot . ((panes . ()))) (panes . ()) (workspaces . ()))))
                ((symbol-function 'herdr-rpc-call-async)
                 (lambda (connection &rest _) (push connection asked) nil))
                ((symbol-function 'herdr-state--open-streams) #'ignore)
                ((symbol-function 'herdr-state--open-pane-stream) #'ignore))
        (herdr-state-refresh mine)
        (herdr-state-resync mine)
        (herdr-state-reconcile-panes mine)
        (herdr-state-reconcile-workspaces mine)
        (herdr-state--refresh-statuses mine)
        (herdr-state-start mine)
        (should asked)
        (should (equal (list mine) (delete-dups asked)))))))

(ert-deftest herdr-state-two-connections-do-not-share-a-session ()
  "Each connection owns its cache, so folding an event into one leaves
the other exactly as it was.  Two of them in one test is the cheapest
proof that nothing behind the struct is still a package global."
  (let ((one (herdr-connection-local))
        (two (herdr-connection-local)))
    (setf (herdr-connection-cache one)
          (herdr-state-from-snapshot '((panes . (((pane_id . "w1:p1")))))))
    (setf (herdr-connection-cache two) (herdr-state-empty))
    (let ((herdr-state-change-functions nil))
      (herdr-state--dispatch one "pane_created"
                             '((pane . ((pane_id . "w1:p9") (agent . "codex"))))))
    (should (equal '("w1:p1" "w1:p9")
                   (sort (herdr-state-pane-ids (herdr-state-current one)) #'string<)))
    (should-not (herdr-state-pane-ids (herdr-state-current two)))))

(ert-deftest herdr-state-two-connections-do-not-share-a-generation ()
  "The generation gates every deferred reply, so sharing one would let a
stop on one server drop an answer meant for another."
  (let ((one (herdr-connection-local))
        (two (herdr-connection-local)))
    (setf (herdr-connection-running one) t)
    (herdr-state-stop one)
    (should (= 1 (herdr-state-generation one)))
    (should (= 0 (herdr-state-generation two)))))

(ert-deftest herdr-state-reconcile-drops-a-reply-from-a-stopped-session ()
  "`herdr-rpc-call\\=' services due timers while it waits, so the session can
stop underneath a reconcile.  A reply that lands afterwards must not
repopulate the cache the stop just emptied, or the modeline advertises
the dead session's agents until the mode is toggled."
  (herdr-state-test--with-quiet-session
    (setf (herdr-connection-running (herdr-current-connection)) t
          (herdr-connection-cache (herdr-current-connection))
          (herdr-state-from-snapshot
           '((panes . (((pane_id . "w1:p1") (agent . "claude")))))))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (&rest _)
                 ;; The stop fires inside the wait.
                 (setf (herdr-connection-running (herdr-current-connection)) nil
                       (herdr-connection-generation (herdr-current-connection)) (1+ (herdr-connection-generation (herdr-current-connection)))
                       (herdr-connection-cache (herdr-current-connection)) (herdr-state-empty))
                 '((panes . (((pane_id . "w1:p1") (agent . "claude"))))))))
      (should-not (herdr-state-reconcile-panes (herdr-current-connection)))
      (should-not (herdr-state-pane-ids (herdr-connection-cache (herdr-current-connection)))))))

(ert-deftest herdr-state-reconcile-workspaces-drops-a-reply-from-a-stopped-session ()
  "The workspace half of the same window."
  (herdr-state-test--with-quiet-session
    (setf (herdr-connection-running (herdr-current-connection)) t
          (herdr-connection-cache (herdr-current-connection))
          (herdr-state-from-snapshot '((workspaces . nil))))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (&rest _)
                 (setf (herdr-connection-running (herdr-current-connection)) nil
                       (herdr-connection-generation (herdr-current-connection)) (1+ (herdr-connection-generation (herdr-current-connection)))
                       (herdr-connection-cache (herdr-current-connection)) (herdr-state-empty))
                 '((workspaces . (((workspace_id . "w1") (label . "web"))))))))
      (should-not (herdr-state-reconcile-workspaces (herdr-current-connection)))
      (should-not (herdr-state-workspaces (herdr-connection-cache (herdr-current-connection)))))))

(ert-deftest herdr-state-repair-skips-workspaces-when-panes-just-failed ()
  "A `pane.list\\=' that failed has scheduled a reconnect.  Asking
`workspace.list\\=' over the same wedged socket spends a second background
timeout on an answer that is not coming, doubling the freeze this
function binds the timeout to avoid."
  (herdr-state-test--with-quiet-session
    (let ((workspaces-called nil))
      (setf (herdr-connection-running (herdr-current-connection)) t)
      (cl-letf (((symbol-function 'herdr-state-reconcile-panes)
                 (lambda (_connection) (herdr-state--schedule-reconnect (herdr-current-connection)) nil))
                ((symbol-function 'herdr-state-reconcile-workspaces)
                 (lambda (_connection) (setq workspaces-called t) nil)))
        (should (herdr-state-repair (herdr-current-connection)))
        (should (herdr-connection-reconnect-timer (herdr-current-connection)))
        (should-not workspaces-called)))))

(ert-deftest herdr-state-repair-reconciles-workspaces-during-a-pending-reconnect ()
  "Only the tick that schedules the reconnect skips.  A backoff already
pending says nothing about whether this tick's `pane.list\\=' answered, and
suppressing the workspace half through the whole backoff would stop
repairing workspaces exactly when the cache is most likely wrong."
  (herdr-state-test--with-quiet-session
    (let ((workspaces-called nil))
      (setf (herdr-connection-running (herdr-current-connection)) t
            (herdr-connection-reconnect-timer (herdr-current-connection)) (run-at-time 3600 nil #'ignore))
      (cl-letf (((symbol-function 'herdr-state-reconcile-panes) (lambda (_connection) nil))
                ((symbol-function 'herdr-state-reconcile-workspaces)
                 (lambda (_connection) (setq workspaces-called t) nil)))
        (should (herdr-state-repair (herdr-current-connection)))
        (should workspaces-called)))))

(ert-deftest herdr-state-subscribe-closes-its-process-when-the-send-fails ()
  "`process-send-string\\=' signals when the peer closes between connect and
send.  Until the subscribe returns, the process is in no variable, so
nothing downstream could close it and a failed start leaked one."
  (let ((closed nil))
    (cl-letf (((symbol-function 'herdr-rpc-connect)
               (lambda (&rest _) 'a-process))
              ((symbol-function 'process-put) #'ignore)
              ((symbol-function 'process-send-string)
               (lambda (&rest _) (error "peer closed before send")))
              ((symbol-function 'herdr-state--close)
               (lambda (proc) (push proc closed))))
      (should-error (herdr-state--subscribe (herdr-current-connection) "herdr-events-global" []))
      (should (equal '(a-process) closed)))))

(ert-deftest herdr-state-repair-returns-non-nil-when-it-ran ()
  "The return is the contract callers branch on."
  (herdr-state-test--with-quiet-session
    (setf (herdr-connection-running (herdr-current-connection)) t)
    (cl-letf (((symbol-function 'herdr-state-reconcile-panes) #'ignore)
              ((symbol-function 'herdr-state-reconcile-workspaces) #'ignore))
      (should (herdr-state-repair (herdr-current-connection))))))

(ert-deftest herdr-state-repair-after-a-stop-does-nothing ()
  "A debounce armed before the stop must not spend a background timeout
on a socket the session no longer holds."
  (herdr-state-test--with-quiet-session
    (let ((called nil))
      (cl-letf (((symbol-function 'herdr-state-reconcile-panes)
                 (lambda (_connection) (setq called t) nil))
                ((symbol-function 'herdr-state-reconcile-workspaces) #'ignore))
        (should-not (herdr-state-repair (herdr-current-connection)))
        (should-not called)))))

(ert-deftest herdr-state-repair-binds-the-background-timeout ()
  "The repair fires on its interval whether or not the server is well;
at the full `herdr-rpc-timeout' (10s) a wedged server made it a
near-continuous main-thread freeze — Emacs re-froze faster than it
thawed."
  (herdr-state-test--with-quiet-session
    (let ((herdr-rpc-timeout 10.0)
          (herdr-rpc-background-timeout 2.0)
          (seen nil))
      (setf (herdr-connection-running (herdr-current-connection)) t)
      (cl-letf (((symbol-function 'herdr-state-reconcile-panes)
                 (lambda (_connection) (setq seen herdr-rpc-timeout) nil))
                ((symbol-function 'herdr-state-reconcile-workspaces) #'ignore))
        (herdr-state-repair (herdr-current-connection))
        (should (equal 2.0 seen))))))

(ert-deftest herdr-state-repair-does-not-nest-across-callers ()
  "`herdr-rpc-call' services due timers while it waits, so a repair can
fire inside another caller's wait and stack blocking calls.  Entered
through the settle and re-entered through the published entry point,
because one caller calling itself is the case that already worked."
  (herdr-state-test--with-quiet-session
    (let ((calls 0))
      (setf (herdr-connection-running (herdr-current-connection)) t)
      (cl-letf (((symbol-function 'herdr-state--open-pane-stream) #'ignore)
                ((symbol-function 'herdr-state-reconcile-panes)
                 (lambda (_connection)
                   (cl-incf calls)
                   (herdr-state-repair (herdr-current-connection))
                   nil))
                ((symbol-function 'herdr-state-reconcile-workspaces) #'ignore))
        (herdr-state--settle (herdr-current-connection))
        (should (= 1 calls))))))

(ert-deftest herdr-state-repair-runs-with-no-terminal-in-existence ()
  "The invariant a green suite could otherwise hide: if the repair only
runs because something opened a terminal, the coupling this unit
removes has merely moved."
  (herdr-state-test--with-quiet-session
    (let ((herdr-state-repair-interval 5.0)
          (reconciled nil))
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (&rest _) '((snapshot . ((panes . ()))))))
                ((symbol-function 'herdr-state--open-streams) #'ignore)
                ((symbol-function 'herdr-state-reconcile-panes)
                 (lambda (_connection) (push 'panes reconciled) nil))
                ((symbol-function 'herdr-state-reconcile-workspaces)
                 (lambda (_connection) (push 'workspaces reconciled) nil)))
        (herdr-state-start (herdr-current-connection))
        (herdr-state-repair (herdr-current-connection))
        (herdr-state-stop (herdr-current-connection))
        (should (equal '(workspaces panes) reconciled))
        (should-not (herdr-connection-repair-timer (herdr-current-connection)))))))

(ert-deftest herdr-state-settle-defers-when-a-repair-is-in-flight ()
  "The timer may skip a tick; the settle may not.  Realigning
connection B depends on the repair having happened, so a settle that
fires inside another repair's wait tries again rather than subscribing
against a pane set nothing settled."
  (herdr-state-test--with-quiet-session
    (let ((opened nil)
          (rescheduled nil))
      (setf (herdr-connection-running (herdr-current-connection)) t
            (herdr-connection-repairing (herdr-current-connection)) t)
      (cl-letf (((symbol-function 'herdr-state--open-pane-stream)
                 (lambda (_connection) (setq opened t)))
                ((symbol-function 'herdr-state--schedule-settle)
                 (lambda (_connection &optional resync) (setq rescheduled (list t resync)))))
        (herdr-state--settle (herdr-current-connection) t)
        (should (equal '(t t) rescheduled))
        (should-not opened)))))

(ert-deftest herdr-state-settle-defers-without-a-resync-too ()
  "The startup settle carries no RESYNC, and it depends on the repair
just as much as the reconnect path does."
  (herdr-state-test--with-quiet-session
    (let ((opened nil)
          (rescheduled 'unset))
      (setf (herdr-connection-running (herdr-current-connection)) t
            (herdr-connection-repairing (herdr-current-connection)) t)
      (cl-letf (((symbol-function 'herdr-state--open-pane-stream)
                 (lambda (_connection) (setq opened t)))
                ((symbol-function 'herdr-state--schedule-settle)
                 (lambda (_connection &optional resync) (setq rescheduled resync))))
        (herdr-state--settle (herdr-current-connection))
        (should-not rescheduled)
        (should-not (eq 'unset rescheduled))
        (should-not opened)))))

(ert-deftest herdr-state-start-rollback-releases-a-half-open-session ()
  "The rollback must release everything the attempt acquired, not just
the newest timer.  `herdr-state--open-streams' opens connection A
before attempting B, and the repair timer is armed before either, so a
failure past that point left an open stream and an armed timer behind a
`(herdr-connection-running (herdr-current-connection))' of nil."
  (herdr-state-test--with-quiet-session
    (let ((herdr-state-repair-interval 5.0)
          (closed nil))
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (&rest _) '((snapshot . ((panes . ()))))))
                ((symbol-function 'herdr-state--close)
                 (lambda (proc) (when proc (push proc closed))))
                ((symbol-function 'herdr-state--open-streams)
                 (lambda (_connection)
                   (setf (herdr-connection-global-process (herdr-current-connection)) 'stream-a)
                   (error "peer closed before send"))))
        (should-error (herdr-state-start (herdr-current-connection)))
        (should-not (herdr-connection-running (herdr-current-connection)))
        (should-not (herdr-connection-repair-timer (herdr-current-connection)))
        (should-not (herdr-connection-global-process (herdr-current-connection)))
        (should (equal '(stream-a) closed))
        (should (= 1 (herdr-connection-generation (herdr-current-connection))))))))

(ert-deftest herdr-state-start-rollback-arms-nothing-when-the-snapshot-fails ()
  "The other injection point: a failure before the repair timer is
armed is a different leak, and only one of the two is new."
  (herdr-state-test--with-quiet-session
    (let ((herdr-state-repair-interval 5.0))
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (&rest _) (error "no server")))
                ((symbol-function 'herdr-state--open-streams) #'ignore))
        (should-error (herdr-state-start (herdr-current-connection)))
        (should-not (herdr-connection-running (herdr-current-connection)))
        (should-not (herdr-connection-repair-timer (herdr-current-connection)))
        (should-not (memq #'herdr-state--note-pane-set-change
                          herdr-state-change-functions))))))

(ert-deftest herdr-state-reconcile-keeps-a-pane-that-arrived-mid-wait ()
  "The RPC wait services the event filters, so the cache can gain a
pane while `pane.list' is in flight.  Staleness judged against the
post-call cache evicted exactly that pane: it was in the cache but not
in a reply built before it existed, and the reap on the change hook
then killed its buffer.  Judged against the pre-call ids, a mid-wait
arrival is not the reply's to condemn."
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
          '((panes . (((pane_id . "w1:p1") (agent . "claude")))))))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_connection method &optional _params)
                 (should (equal "pane.list" method))
                 ;; The event filter runs inside the wait and folds in a
                 ;; pane the server created after building this reply.
                 (setf (herdr-connection-cache (herdr-current-connection))
                       (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "pane_created"
                                           '((pane . ((pane_id . "w1:new")
                                                      (agent . "codex"))))))
                 '((panes . (((pane_id . "w1:p1") (agent . "claude"))))))))
      (herdr-state-reconcile-panes (herdr-current-connection))
      (should (member "w1:new" (herdr-state-pane-ids (herdr-connection-cache (herdr-current-connection)))))
      (should (member "w1:p1" (herdr-state-pane-ids (herdr-connection-cache (herdr-current-connection))))))))

(ert-deftest herdr-state-refresh-statuses-is-asynchronous-and-bounded ()
  "The status refresh runs from the resubscribe timer, which fires on
every pane-set change: synchronous, it held the whole editor for up to
`herdr-rpc-timeout' against a slow server, for a refresh nobody was
waiting on.  So it must go through `herdr-rpc-call-async' with the
background bound, and fold the reply in when it lands."
  (herdr-test-with-state (:running t :cache (herdr-state-from-snapshot
          '((panes . (((pane_id . "w1:p1") (agent . "claude")
                       (agent_status . "working")))))))(let* ((kinds nil) (captured nil) (callback nil))
    (cl-letf (((symbol-function 'herdr-rpc-call-async)
               (lambda (_connection method params cb &optional timeout)
                 (setq captured (list method params timeout)
                       callback cb)
                 'proc)))
      (let ((herdr-state-change-functions
             (list (lambda (kind _data) (push kind kinds)))))
        (herdr-state--refresh-statuses (herdr-current-connection))
        ;; Nothing folded yet: the call returned without blocking.
        (should (equal (list "session.snapshot" nil
                             herdr-rpc-background-timeout)
                       captured))
        (should-not kinds)
        (funcall callback
                 '((snapshot . ((panes . (((pane_id . "w1:p1")
                                           (agent . "claude")
                                           (agent_status . "blocked")))))))
                 nil)
        (should (equal '("resync") kinds))
        (should (equal "blocked"
                       (alist-get 'agent_status
                                  (herdr-state-pane (herdr-connection-cache (herdr-current-connection))
                                                    "w1:p1")))))))))

(ert-deftest herdr-state-refresh-statuses-drops-a-reply-from-a-stale-generation ()
  "A stop followed by a quick restart makes `(herdr-connection-running (herdr-current-connection))' true
again before an old refresh's reply lands.  Gating only on that flag
would merge the stale reply into the new session's cache; gating on
the generation captured when the request went out must not."
  (herdr-test-with-state (:running t :generation 1 :cache (herdr-state-from-snapshot
          '((panes . (((pane_id . "w1:p1") (agent . "claude")
                       (agent_status . "working")))))))(let* ((kinds nil) (callback nil))
    (cl-letf (((symbol-function 'herdr-rpc-call-async)
               (lambda (_connection _method _params cb &optional _timeout)
                 (setq callback cb) 'proc)))
      (let ((herdr-state-change-functions
             (list (lambda (kind _data) (push kind kinds)))))
        (herdr-state--refresh-statuses (herdr-current-connection))
        ;; The session was stopped and restarted while the request was
        ;; in flight: still running, but a new generation.
        (setf (herdr-connection-generation (herdr-current-connection)) 2)
        (funcall callback
                 '((snapshot . ((panes . (((pane_id . "w1:p1")
                                           (agent . "claude")
                                           (agent_status . "blocked")))))))
                 nil)
        (should-not kinds)
        (should (equal "working"
                       (alist-get 'agent_status
                                  (herdr-state-pane (herdr-connection-cache (herdr-current-connection))
                                                    "w1:p1")))))))))

(ert-deftest herdr-state-global-subscriptions-exclude-pane-updated ()
  "`pane.updated' fires on every animated-title frame with a full
PaneInfo, and the server delivers at most one event per subscribed type
per 100ms — one busy agent nearly saturates the channel and two put it
permanently behind, which was measured here as multi-second status lag.
Everything it carries arrives through connection B, the lifecycle
events, or the reconcile poll; resubscribing it reopens the firehose
and the lag."
  (should-not (member "pane.updated" herdr-state-global-subscriptions))
  ;; The ghost-folding order the reconcile docstring leans on.
  (should (< (seq-position herdr-state-global-subscriptions "pane.created")
             (seq-position herdr-state-global-subscriptions "pane.closed"))))

(ert-deftest herdr-state-reduce-status-event-merges-display-agent ()
  "With `pane.updated' gone, the B event is the only prompt carrier of
`display_agent', which buffer naming and the dashboard rows prefer."
  (let ((next (herdr-state-reduce
               (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (agent . "claude"))))))
               "pane.agent_status_changed"
               '((pane_id . "w1:p1") (agent_status . "working")
                 (agent . "claude") (display_agent . "Claude Code")))))
    (let ((pane (herdr-state-pane next "w1:p1")))
      (should (equal "working" (alist-get 'agent_status pane)))
      (should (equal "Claude Code" (alist-get 'display_agent pane))))))

(ert-deftest herdr-state-reconcile-failure-schedules-a-reconnect ()
  "The reconcile poll doubles as the liveness watchdog.  The server
sends nothing on a quiet subscription, so a wedged server leaves both
event streams open and silent — indistinguishable from a calm session —
and only this periodic RPC can notice.  Its failure while the state is
running must schedule a reconnect; when nothing is running there is
nothing to reconnect, and a failed poll stays a failed poll."
  (cl-letf (((symbol-function 'herdr-rpc-call)
             (lambda (&rest _) (error "socket stopped answering"))))
    (herdr-test-with-state (:running t :reconnect-timer nil :reconnect-delay nil :cache (herdr-state-from-snapshot
            '((panes . (((pane_id . "w1:p1")))))))
      (unwind-protect
          (progn
            (should-not (herdr-state-reconcile-panes (herdr-current-connection)))
            (should (herdr-connection-reconnect-timer (herdr-current-connection)))
            ;; The failed poll must not touch the cache either.
            (should (equal '("w1:p1")
                           (herdr-state-pane-ids (herdr-connection-cache (herdr-current-connection))))))
        (when (herdr-connection-reconnect-timer (herdr-current-connection))
          (cancel-timer (herdr-connection-reconnect-timer (herdr-current-connection))))))
    (herdr-test-with-state (:running nil :reconnect-timer nil :reconnect-delay nil)(let* ((herdr-connection--sole (herdr-test-connection (herdr-state-empty))))
      (should-not (herdr-state-reconcile-panes (herdr-current-connection)))
      (should-not (herdr-connection-reconnect-timer (herdr-current-connection)))))))

(provide 'herdr-state-test)
;;; herdr-state-test.el ends here
