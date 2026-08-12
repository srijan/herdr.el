;;; herdr-tree-test.el --- Tests for the pure dispatcher tree -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-tree)

(defun herdr-tree-test--state (&rest overrides)
  "Return a state: one workspace, two tabs, three panes.
OVERRIDES is spliced into the snapshot alist ahead of the defaults."
  (herdr-state-from-snapshot
   (append
    overrides
    '((workspaces . (((workspace_id . "w1") (label . "herdr.el")
                      (pane_count . 3) (tab_count . 2)
                      (agent_status . "blocked"))))
      (tabs . (((tab_id . "w1:t1") (workspace_id . "w1") (label . "agents")
                (pane_count . 2) (agent_status . "blocked"))
               ((tab_id . "w1:t2") (workspace_id . "w1") (label . "checks")
                (pane_count . 1) (agent_status . "idle"))))
      (panes . (((pane_id . "w1:p1") (workspace_id . "w1") (tab_id . "w1:t1")
                 (agent . "claude") (agent_status . "working")
                 (cwd . "/tmp/herdr.el")
                 (terminal_title_stripped . "fixing tests"))
                ((pane_id . "w1:p2") (workspace_id . "w1") (tab_id . "w1:t1")
                 (agent . "codex") (agent_status . "blocked")
                 (cwd . "/tmp/herdr.el"))
                ((pane_id . "w1:p3") (workspace_id . "w1") (tab_id . "w1:t2")
                 (agent . "shell") (agent_status . "idle")
                 (cwd . "/tmp/herdr.el"))))))))

(defun herdr-tree-test--types (nodes)
  "Return the nested (TYPE . CHILD-TYPES) shape of NODES."
  (mapcar (lambda (node)
            (cons (nth 0 node) (herdr-tree-test--types (nth 3 node))))
          nodes))

(ert-deftest herdr-tree-nests-workspace-tab-pane ()
  (should (equal '((herdr-workspace
                    (herdr-tab (herdr-pane) (herdr-pane))
                    (herdr-tab (herdr-pane))))
                 (herdr-tree-test--types
                  (herdr-tree-build (herdr-tree-test--state) nil)))))

(ert-deftest herdr-tree-flattens-a-single-tab-workspace ()
  "Unnamed tabs get numeric labels, so one tab is noise, not structure."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1") (label . "solo")
                                  (pane_count . 1) (tab_count . 1))))
                  (tabs . (((tab_id . "w1:t1") (workspace_id . "w1")
                            (label . "1") (pane_count . 1))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude"))))))))
    (should (equal '((herdr-workspace (herdr-pane)))
                   (herdr-tree-test--types (herdr-tree-build state nil))))))

(ert-deftest herdr-tree-workspace-line-carries-directory-and-rollup ()
  (let ((line (nth 2 (car (herdr-tree-build (herdr-tree-test--state) nil)))))
    (should (string-match-p "herdr.el" line))
    (should (string-match-p "/tmp/herdr.el" line))
    (should (string-match-p (herdr-tree-glyph "blocked") line))))

(ert-deftest herdr-tree-collapsed-idle-section-shows-no-glyph ()
  "Same omit-idle rule as the modeline, so the two never disagree."
  (let* ((tabs (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (checks (nth 2 (nth 1 tabs))))
    (should-not (string-match-p (herdr-tree-glyph "blocked") checks))
    (should-not (string-match-p (herdr-tree-glyph "idle") checks))))

(ert-deftest herdr-tree-pane-line-shows-agent-status-and-title ()
  (let* ((tabs (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (pane (nth 2 (car (nth 3 (car tabs))))))
    (should (string-match-p "claude" pane))
    (should (string-match-p "working" pane))
    (should (string-match-p "w1:p1" pane))
    (should (string-match-p "fixing tests" pane))))

(ert-deftest herdr-tree-marks-adopted-shells ()
  (let* ((tabs (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (pane (nth 2 (car (nth 3 (nth 1 tabs))))))
    (should (string-match-p "shell\\*" pane))))

(ert-deftest herdr-tree-appends-an-agent-name-when-set ()
  (let* ((state (herdr-tree-test--state
                 '(agents . (((pane_id . "w1:p1") (agent . "claude")
                              (name . "reviewer"))))))
         (tabs (nth 3 (car (herdr-tree-build state nil))))
         (pane (nth 2 (car (nth 3 (car tabs))))))
    (should (string-match-p "claude/reviewer" pane))))

(ert-deftest herdr-tree-omits-worktrees-when-not-fetched ()
  "A workspace absent from WORKTREES gets no worktrees section."
  (should-not
   (seq-find (lambda (node) (eq 'herdr-worktrees (car node)))
             (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))))

(ert-deftest herdr-tree-includes-worktrees-when-fetched ()
  "A workspace present in WORKTREES gets a worktrees section, last."
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-feat")
                                (branch . "feat/dispatch")
                                (label . "feat/dispatch")
                                (open_workspace_id . nil))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (section (car (last children))))
    (should (eq 'herdr-worktrees (car section)))
    (should (equal 1 (length (nth 3 section))))))

(ert-deftest herdr-tree-dims-a-worktree-already-open-as-a-workspace ()
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-feat")
                                (branch . "feat/dispatch")
                                (label . "feat/dispatch")
                                (open_workspace_id . "w2"))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (worktree (car (nth 3 (car (last children))))))
    (should (equal 'herdr-worktree (nth 0 worktree)))
    (should (string-match-p "open" (nth 2 worktree)))))

(provide 'herdr-tree-test)
;;; herdr-tree-test.el ends here
