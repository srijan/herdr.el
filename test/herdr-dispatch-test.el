;;; herdr-dispatch-test.el --- Tests for the dispatcher buffer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-tree)

;; magit-section is a hard dependency of herdr-dispatch and is not on the
;; load path under `emacs -Q -L .', which is what `make test' uses.  The
;; tree model is covered hermetically in herdr-tree-test; these tests
;; cover the renderer and only run where the dependency exists.
(when (require 'magit-section nil t)
  (require 'herdr-dispatch))

(defmacro herdr-dispatch-test-with-buffer (nodes &rest body)
  "Render NODES into a temporary dispatcher buffer and run BODY there."
  (declare (indent 1) (debug t))
  `(progn
     (skip-unless (featurep 'magit-section))
     (with-temp-buffer
       (herdr-dispatch-mode)
       (let ((inhibit-read-only t))
         (magit-insert-section (herdr-root)
           (herdr-dispatch--insert-nodes ,nodes)))
       (goto-char (point-min))
       ,@body)))

(defconst herdr-dispatch-test--nodes
  '((herdr-workspace "w1" "herdr.el  /tmp/herdr.el  2 panes"
     ((herdr-pane "w1:p1" "> claude working w1:p1" nil)
      (herdr-pane "w1:p2" "| codex blocked w1:p2" nil)
      (herdr-worktrees "w1" "worktrees 1"
       ((herdr-worktree "/tmp/herdr.el-fix" "fix  open as w2" nil)))))
    (herdr-workspace "w2" "api  /tmp/api  2 panes"
     ((herdr-tab "w2:t1" "main  1 panes"
       ((herdr-pane "w2:p1" "> claude working w2:p1" nil)))
      (herdr-tab "w2:t2" "spike  1 panes"
       ((herdr-pane "w2:p2" "· gemini idle w2:p2" nil))))))
  "One workspace of each shape `herdr-tree-build' emits.
`w1' is the flattened single-tab case, carrying a worktrees section;
`w2' keeps its tab level because it has more than one tab.  Between them
every node type the renderer must handle appears.")

(defun herdr-dispatch-test--type-at (text)
  "Return the type of the section whose line contains TEXT."
  (goto-char (point-min))
  (search-forward text)
  (oref (magit-current-section) type))

(ert-deftest herdr-dispatch-renders-every-line ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (string-match-p "herdr.el" (buffer-string)))
    (should (string-match-p "w1:p1" (buffer-string)))
    (should (string-match-p "w1:p2" (buffer-string)))))

(ert-deftest herdr-dispatch-tags-sections-with-type-and-value ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1:p1")
    (let ((section (magit-current-section)))
      (should (eq 'herdr-pane (oref section type)))
      (should (equal "w1:p1" (oref section value))))))

(ert-deftest herdr-dispatch-nests-panes-under-their-workspace ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1:p1")
    (should (eq 'herdr-workspace
                (oref (oref (magit-current-section) parent) type)))))

(ert-deftest herdr-dispatch-renders-every-node-type ()
  "Every node type must reach a branch of its own.

The `pcase' in `herdr-dispatch--insert-nodes' has no fallback clause, so
a mistyped branch head — `herdr-worktree' where `herdr-worktrees' was
meant — drops that node and everything under it without signalling.
herdr-tree-test covers the model emitting these types; this covers the
renderer consuming them, which is the seam such a typo would hide in."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (eq 'herdr-workspace (herdr-dispatch-test--type-at "herdr.el")))
    (should (eq 'herdr-pane      (herdr-dispatch-test--type-at "w1:p1")))
    (should (eq 'herdr-tab       (herdr-dispatch-test--type-at "main")))
    (should (eq 'herdr-worktrees (herdr-dispatch-test--type-at "worktrees 1")))
    (should (eq 'herdr-worktree  (herdr-dispatch-test--type-at "open as w2")))))

(ert-deftest herdr-dispatch-nests-children-under-a-tab ()
  "A dropped child list is invisible unless something looks under a tab."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p1")
    (should (eq 'herdr-tab (oref (oref (magit-current-section) parent) type)))))

;;; Refresh

(defconst herdr-dispatch-test--snapshot
  '((workspaces . (((workspace_id . "w1") (label . "web") (pane_count . 2))))
    (tabs . (((tab_id . "w1:t1") (workspace_id . "w1") (label . "main"))))
    (panes . (((pane_id . "w1:p1") (agent . "claude")
               (agent_status . "blocked")
               (workspace_id . "w1") (tab_id . "w1:t1"))
              ((pane_id . "w1:p2") (agent . "codex")
               (agent_status . "working")
               (workspace_id . "w1") (tab_id . "w1:t1")))))
  "A session for the refresh tests to drive `herdr-state-current' from.")

(defmacro herdr-dispatch-test-with-dispatcher (&rest body)
  "Run BODY in a real dispatcher buffer built from the test snapshot.
`herdr-dispatch-refresh' finds its buffer by name, so this has to be the
real one rather than a temporary."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (featurep 'magit-section))
     (let ((herdr-state--current
            (herdr-state-from-snapshot herdr-dispatch-test--snapshot))
           (herdr-dispatch--worktrees nil)
           (buffer (get-buffer-create herdr-dispatch-buffer-name)))
       (unwind-protect
           (with-current-buffer buffer
             (herdr-dispatch-mode)
             ,@body)
         (kill-buffer buffer)))))

(ert-deftest herdr-dispatch-refresh-draws-the-session ()
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh)
    (should (string-match-p "1 workspaces  2 panes  2 agents" (buffer-string)))
    (should (string-match-p "web" (buffer-string)))
    (should (string-match-p "w1:p1" (buffer-string)))
    (should (string-match-p "w1:p2" (buffer-string)))))

(ert-deftest herdr-dispatch-refresh-keeps-folds-and-point ()
  "Redrawing must not unfold the tree or move you to a different agent.

Neither was covered while `herdr-dispatch-refresh' still called
`magit-section-cache-visibility' with no argument — which signals
`wrong-type-argument' on every invocation, because outside an insert
there is no current section to cache.  The three renderer tests passed
throughout, so a completely broken refresh looked green."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh)
    (goto-char (point-min))
    (search-forward "web")
    (magit-section-hide (magit-current-section))
    (should (oref (magit-current-section) hidden))
    (goto-char (point-min))
    (search-forward "w1:p2")
    (let ((ident (magit-section-ident (magit-current-section))))
      (should (equal '((herdr-pane . "w1:p2") (herdr-workspace . "w1")
                       (herdr-root))
                     ident))
      (herdr-dispatch-refresh)
      (should (equal ident (magit-section-ident (magit-current-section))))
      (goto-char (point-min))
      (search-forward "web")
      (should (oref (magit-current-section) hidden)))))

(provide 'herdr-dispatch-test)
;;; herdr-dispatch-test.el ends here
