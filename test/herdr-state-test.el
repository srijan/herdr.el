;;; herdr-state-test.el --- Tests for the herdr state reducer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-state)

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
     (tabs . (((tab_id . "w1:t1") (label . "1") (workspace_id . "w1"))))
     (workspaces . (((workspace_id . "w1") (label . "web")))))))

;;; Snapshot hydration

(ert-deftest herdr-state-from-snapshot-populates-everything ()
  (let ((state (herdr-state-test--seed)))
    (should (= 2 (length (herdr-state-panes state))))
    (should (= 1 (length (herdr-state-tabs state))))
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
  (let ((next (herdr-state-reduce
               (herdr-state-test--seed) "pane_agent_detected"
               `((pane . ,(herdr-state-test--pane "w1:p2" "codex" "idle"))))))
    (should (= 2 (length (herdr-state-agents next))))))

(ert-deftest herdr-state-reduce-pane-focused-moves-focus ()
  (let ((next (herdr-state-reduce (herdr-state-test--seed)
                                  "pane_focused" '((pane_id . "w1:p2")))))
    (should (equal "w1:p2" (herdr-state-focused-pane-id next)))))

(ert-deftest herdr-state-reduce-workspace-and-tab-events ()
  (let* ((s (herdr-state-test--seed))
         (s (herdr-state-reduce s "workspace_created"
                                '((workspace . ((workspace_id . "w2")
                                                (label . "other"))))))
         (s (herdr-state-reduce s "tab_created"
                                '((tab . ((tab_id . "w2:t1") (label . "1")
                                          (workspace_id . "w2"))))))
         (s (herdr-state-reduce s "workspace_focused" '((workspace_id . "w2"))))
         (s (herdr-state-reduce s "tab_focused" '((tab_id . "w2:t1")))))
    (should (= 2 (length (herdr-state-workspaces s))))
    (should (= 2 (length (herdr-state-tabs s))))
    (should (equal "w2" (herdr-state-focused-workspace-id s)))
    (should (equal "w2:t1" (herdr-state-focused-tab-id s)))
    (let ((s (herdr-state-reduce s "workspace_closed" '((workspace_id . "w2")))))
      (should (= 1 (length (herdr-state-workspaces s)))))))

(ert-deftest herdr-state-reduce-ignores-layout-and-unknown-kinds ()
  (let* ((state (herdr-state-test--seed))
         (a (herdr-state-reduce state "layout_updated" '((layout . ()))))
         (b (herdr-state-reduce state "something_new" '((x . 1)))))
    (should (= 2 (length (herdr-state-panes a))))
    (should (= 2 (length (herdr-state-panes b))))
    (should (equal (herdr-state-focused-pane-id state)
                   (herdr-state-focused-pane-id b)))))

(provide 'herdr-state-test)
;;; herdr-state-test.el ends here
