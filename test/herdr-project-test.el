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
  (let ((found (herdr-state-workspace-for-directory
                (herdr-project-test--state) "/tmp/project")))
    (should (equal "w1" (alist-get 'workspace_id found)))))

(ert-deftest herdr-project-matches-with-or-without-a-trailing-slash ()
  (let ((state (herdr-project-test--state)))
    (should (equal "w1" (alist-get 'workspace_id
                                   (herdr-state-workspace-for-directory
                                    state "/tmp/project/"))))))

(ert-deftest herdr-project-returns-nil-for-an-unknown-root ()
  (should-not (herdr-state-workspace-for-directory
               (herdr-project-test--state) "/tmp/nowhere")))

(ert-deftest herdr-project-focuses-an-existing-workspace-rather-than-creating-one ()
  "`herdr-state-workspace-for-directory' exists to stop a second workspace being
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
              ;; The two that replaced it: `herdr-cmd-open-workspace-for'
              ;; goes to the new pane rather than showing a primary
              ;; buffer, and unstubbed they would add `pane.current' to
              ;; the wire these tests assert on.
              ((symbol-function 'herdr-term-select-focused) #'ignore)
              ((symbol-function 'herdr-term-select-pane) #'ignore)
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
              ;; The two that replaced it: `herdr-cmd-open-workspace-for'
              ;; goes to the new pane rather than showing a primary
              ;; buffer, and unstubbed they would add `pane.current' to
              ;; the wire these tests assert on.
              ((symbol-function 'herdr-term-select-focused) #'ignore)
              ((symbol-function 'herdr-term-select-pane) #'ignore)
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
              ;; The two that replaced it: `herdr-cmd-open-workspace-for'
              ;; goes to the new pane rather than showing a primary
              ;; buffer, and unstubbed they would add `pane.current' to
              ;; the wire these tests assert on.
              ((symbol-function 'herdr-term-select-focused) #'ignore)
              ((symbol-function 'herdr-term-select-pane) #'ignore)
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

(ert-deftest herdr-opens-the-dashboard-after-running-the-start-sequence ()
  "`herdr\\=' runs the start sequence; `herdr-agents\\=' does not."
  (should (commandp 'herdr))
  (let (opened started)
    (cl-letf (((symbol-function 'herdr-start) (lambda () (setq started t)))
              ((symbol-function 'herdr-term-display) #'ignore)
              ((symbol-function 'herdr-agents)
               (lambda () (push 'dashboard opened))))
      (herdr)
      (should started)
      (should (equal '(dashboard) opened)))))

;;; The prefix keymap

(ert-deftest herdr-command-map-binds-the-verbs-the-dashboard-uses ()
  "The letters are the dashboard\\='s letters, so there is one set to learn."
  (should (keymapp herdr-command-map))
  (dolist (entry '(("s" . herdr)
                   ("f" . herdr-pane-focus)
                   ("n" . herdr-new-terminal)
                   ("k" . herdr-pane-close)
                   ("w" . herdr-workspace-focus)
                   ("p" . herdr-project)
                   ("%" . herdr-worktree-create)
                   ("g" . herdr-state-resync)))
    (should (eq (cdr entry) (lookup-key herdr-command-map (car entry))))
    (should (commandp (cdr entry)))))

(ert-deftest herdr-dispatch-takes-the-frame-rather-than-splitting-it ()
  "Asserted on the action passed to `pop-to-buffer\\=', not on the window
count: batch has one window, where `display-buffer-full-frame\\=' is a
no-op."
  (let (action)
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (_buffer &optional given &rest _) (setq action given)))
              ((symbol-function 'herdr-dispatch-refresh) #'ignore))
      (herdr-agents)
      (should (equal '(display-buffer-full-frame) action))
      (should (equal herdr-dispatch-display-action action)))
    ;; And it is a knob, so the old splitting behaviour is one setq away.
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (_buffer &optional given &rest _) (setq action given)))
              ((symbol-function 'herdr-dispatch-refresh) #'ignore))
      (let ((herdr-dispatch-display-action nil))
        (herdr-agents)
        (should-not action)))))

(ert-deftest herdr-requires-the-escape-hatch-rather-than-autoloading-it ()
  "`herdr-call\\=' used to arrive with `herdr-transient\\=' and answered
`void-function\\=' once that went.  Asserted on the `require\\=', because
`fboundp\\=' is true here whichever way the symbol arrived."
  (should (memq 'herdr-call features))
  (should (commandp 'herdr-call)))

(ert-deftest herdr-command-map-is-the-only-menu ()
  "`herdr-menu\\=' and `herdr-transient\\=' were surfaces over commands this
map and the dashboard already reach."
  (should-not (fboundp 'herdr-menu))
  (should-not (fboundp 'herdr-transient))
  (should-not (lookup-key herdr-command-map "?")))

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
      (herdr-start)
      (should-not starts)
      (should (= 2 (length ensures))))))

(ert-deftest herdr-start-starts-the-stream-when-there-is-none ()
  "Twice: which buffers to attach cannot be decided until the cache has
been primed."
  (let (starts ensures)
    (cl-letf (((symbol-function 'herdr-term-ensure)
               (lambda () (push t ensures)))
              ((symbol-function 'herdr--check-protocol) #'ignore)
              ((symbol-function 'herdr-state-running-p) (lambda () nil))
              ((symbol-function 'herdr-state-start) (lambda () (push t starts))))
      (herdr-start)
      (should (= 1 (length starts)))
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
