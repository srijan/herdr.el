;;; herdr-project-test.el --- Tests for project workspace matching -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-test-helper)
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

(ert-deftest herdr-project-focuses-an-existing-workspace-rather-than-creating-one ()
  "`herdr--workspace-for-directory' exists to stop a second workspace being
made for a directory that already has one, and the branch that acts on
its answer was never tested.  Measured: inverting it — create when there
is one to focus, focus when there is not — passed the whole suite, so
the duplicate-workspace bug could come back unseen.

Both directions are asserted on the wire, because either alone leaves
the other looking right, and the payload is checked too: focusing the
wrong workspace and creating one in the wrong directory are the two ways
this goes wrong while still sending the right method."
  (dolist (case '(("/tmp/project/" "workspace.focus" workspace_id "w1")
                  ("/tmp/nowhere/" "workspace.create" cwd "/tmp/nowhere/")))
    (let ((herdr-state--current (herdr-project-test--state))
          (default-directory (nth 0 case))
          wire params)
      (cl-letf (((symbol-function 'herdr-start) #'ignore)
                ((symbol-function 'herdr-term-display) #'ignore)
                ((symbol-function 'project-current) (lambda (&rest _) nil)))
        (herdr-test-with-server
            (lambda (req)
              (push (alist-get 'method req) wire)
              (setq params (alist-get 'params req))
              (cons (herdr-test-ok req '((type . "ok"))) nil))
          (herdr-project)))
      (should (equal (list (nth 1 case)) wire))
      (should (equal (nth 3 case) (alist-get (nth 2 case) params)))))
  ;; A created workspace is named for the directory it is rooted in.
  (let ((herdr-state--current (herdr-project-test--state))
        (default-directory "/tmp/nowhere/")
        params)
    (cl-letf (((symbol-function 'herdr-start) #'ignore)
              ((symbol-function 'herdr-term-display) #'ignore)
              ((symbol-function 'project-current) (lambda (&rest _) nil)))
      (herdr-test-with-server
          (lambda (req)
            (setq params (alist-get 'params req))
            (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-project)))
    (should (equal "nowhere" (alist-get 'label params)))))

(ert-deftest herdr-project-prefers-the-project-root-over-the-default-directory ()
  "A command run from a file deep in a tree should reach the tree's
workspace, not make one for the subdirectory it happened to be in."
  (let ((herdr-state--current (herdr-project-test--state))
        (default-directory "/tmp/project/src/deep/")
        wire params)
    (cl-letf (((symbol-function 'herdr-start) #'ignore)
              ((symbol-function 'herdr-term-display) #'ignore)
              ((symbol-function 'project-current) (lambda (&rest _) 'fake))
              ((symbol-function 'project-root) (lambda (_) "/tmp/project/")))
      (herdr-test-with-server
          (lambda (req)
            (push (alist-get 'method req) wire)
            (setq params (alist-get 'params req))
            (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-project)))
    (should (equal '("workspace.focus") wire))
    (should (equal "w1" (alist-get 'workspace_id params)))))

(ert-deftest herdr-menu-ends-on-the-transient-and-herdr-on-the-dashboard ()
  "Which surface each command opens is the whole difference between them.

This used to compare their function cells with `eq'.  Two separately
defined `defun's are never `eq' whatever they contain, so that assertion
could not fail — confirmed by making the two bodies byte-for-byte
identical, which the suite passed."
  (should (commandp 'herdr-menu))
  (should (commandp 'herdr))
  (let (opened)
    (cl-letf (((symbol-function 'herdr-start) #'ignore)
              ((symbol-function 'herdr-term-display) #'ignore)
              ((symbol-function 'herdr-agents)
               (lambda () (push 'dashboard opened)))
              ((symbol-function 'herdr-transient)
               (lambda () (interactive) (push 'transient opened))))
      (herdr)
      (should (equal '(dashboard) opened))
      (setq opened nil)
      (herdr-menu)
      (should (equal '(transient) opened)))))

(provide 'herdr-project-test)
;;; herdr-project-test.el ends here
