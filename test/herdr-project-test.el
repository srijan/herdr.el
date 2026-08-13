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

;;; Startup, shutdown and the protocol check

(ert-deftest herdr-check-protocol-warns-once-when-the-server-is-ahead ()
  "A mismatch warns rather than refusing to run — declining to work
because herdr bumped a minor is worse than one command misbehaving — and
it warns once.  This runs at the front of `herdr-start', which runs at
the front of every entry point, so warning per call is warning per
command."
  (let ((herdr--protocol-warned nil)
        said)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
      (herdr-test-with-server
          (lambda (req)
            (cons (herdr-test-ok
                   req `((protocol . ,(1+ herdr-protocol-version))))
                  nil))
        (herdr--check-protocol)
        (herdr--check-protocol)))
    (should (= 1 (length said)))
    (should (string-match-p (number-to-string (1+ herdr-protocol-version))
                            (car said)))
    (should (string-match-p (number-to-string herdr-protocol-version)
                            (car said)))))

(ert-deftest herdr-check-protocol-is-silent-when-the-versions-agree ()
  "The common case has to cost nothing and say nothing."
  (let ((herdr--protocol-warned nil)
        said)
    (cl-letf (((symbol-function 'message) (lambda (&rest _) (push t said))))
      (herdr-test-with-server
          (lambda (req)
            (cons (herdr-test-ok req `((protocol . ,herdr-protocol-version)))
                  nil))
        (herdr--check-protocol)))
    (should-not said)
    (should-not herdr--protocol-warned)))

(ert-deftest herdr-start-does-not-restart-a-stream-already-running ()
  "`herdr-start' fronts every entry point, so it has to be safe to call
again: a second event stream would double every event the cache folds."
  (let (starts ensures)
    (cl-letf (((symbol-function 'herdr-term-ensure)
               (lambda () (push t ensures)))
              ((symbol-function 'herdr--check-protocol) #'ignore)
              ((symbol-function 'herdr-state-running-p) (lambda () t))
              ((symbol-function 'herdr-state-start) (lambda () (push t starts))))
      (let ((herdr-terminal-backend 'session))
        (herdr-start))
      (should-not starts)
      (should (= 1 (length ensures))))))

(ert-deftest herdr-start-starts-the-stream-when-there-is-none ()
  "And under `agent-windows' reconciles a second time, because which
buffers to attach cannot be decided until the cache has been primed."
  (let (starts ensures)
    (cl-letf (((symbol-function 'herdr-term-ensure)
               (lambda () (push t ensures)))
              ((symbol-function 'herdr--check-protocol) #'ignore)
              ((symbol-function 'herdr-state-running-p) (lambda () nil))
              ((symbol-function 'herdr-state-start) (lambda () (push t starts))))
      (let ((herdr-terminal-backend 'session))
        (herdr-start))
      (should (= 1 (length starts)))
      (should (= 1 (length ensures)))
      (setq starts nil ensures nil)
      (let ((herdr-terminal-backend 'agent-windows))
        (herdr-start))
      (should (= 2 (length ensures))))))

(ert-deftest herdr-stop-tears-down-both-halves ()
  "Stopping one half leaves either an event stream feeding buffers that
are gone, or buffers attached to a stream that has stopped."
  (let (torn stopped)
    (cl-letf (((symbol-function 'herdr-term-teardown) (lambda () (push t torn)))
              ((symbol-function 'herdr-state-stop) (lambda () (push t stopped))))
      (herdr-stop))
    (should torn)
    (should stopped)))

(provide 'herdr-project-test)
;;; herdr-project-test.el ends here
