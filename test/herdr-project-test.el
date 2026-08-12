;;; herdr-project-test.el --- Tests for project workspace matching -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr)

(defun herdr-project-test--state ()
  "Return a state with two workspaces rooted at known directories."
  (herdr-state-from-snapshot
   '((workspaces . (((workspace_id . "w1") (label . "project"))
                    ((workspace_id . "w2") (label . "other"))))
     (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                (cwd . "/tmp/project"))
               ((pane_id . "w2:p1") (workspace_id . "w2")
                (cwd . "/tmp/other")))))))

(ert-deftest herdr-project-finds-the-workspace-for-a-root ()
  "The bug this covers: matching on identity_cwd never matched anything,
so every invocation created a duplicate workspace."
  (let ((found (herdr--workspace-for-directory
                (herdr-project-test--state) "/tmp/project")))
    (should (equal "w1" (alist-get 'workspace_id found)))))

(ert-deftest herdr-project-matches-with-or-without-a-trailing-slash ()
  (let ((state (herdr-project-test--state)))
    (should (equal "w1" (alist-get 'workspace_id
                                   (herdr--workspace-for-directory
                                    state "/tmp/project/"))))))

(ert-deftest herdr-project-returns-nil-for-an-unknown-root ()
  (should-not (herdr--workspace-for-directory
               (herdr-project-test--state) "/tmp/nowhere")))

(provide 'herdr-project-test)
;;; herdr-project-test.el ends here
