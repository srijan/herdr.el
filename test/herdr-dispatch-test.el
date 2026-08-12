;;; herdr-dispatch-test.el --- Tests for the dispatcher buffer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
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

(defun herdr-dispatch-test--indent-at (text)
  "Return the leading whitespace width of the line containing TEXT."
  (goto-char (point-min))
  (search-forward text)
  (goto-char (line-beginning-position))
  (skip-chars-forward " ")
  (current-column))

(ert-deftest herdr-dispatch-indents-a-pane-under-a-tab-deeper-than-one-under-a-workspace ()
  "The hierarchy has to be visible, not just navigable.

`w1:p1\\=' hangs directly off its workspace (the single-tab flattened
case); `w2:p1\\=' hangs off a tab which hangs off its workspace.  The
second must read one level deeper than the first, with no
special-casing for the flattened shape."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((workspace-indent (herdr-dispatch-test--indent-at "herdr.el"))
          (flattened-pane-indent (herdr-dispatch-test--indent-at "w1:p1"))
          (tab-indent (herdr-dispatch-test--indent-at "main"))
          (nested-pane-indent (herdr-dispatch-test--indent-at "w2:p1")))
      (should (< workspace-indent flattened-pane-indent))
      (should (= tab-indent flattened-pane-indent))
      (should (< tab-indent nested-pane-indent))
      (should (< flattened-pane-indent nested-pane-indent)))))

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

(defvar herdr-dispatch-test--rebuilds 0
  "Whole-buffer rebuilds counted by `herdr-dispatch-test-counting-rebuilds'.")

(defun herdr-dispatch-test--count-rebuild (&rest args)
  "Count one rebuild unless ARGS say this is a recursive insert.
`herdr-dispatch--insert-nodes' recurses with an explicit DEPTH, so only
the top-level call a redraw makes arrives with a single argument."
  (unless (cdr args)
    (setq herdr-dispatch-test--rebuilds (1+ herdr-dispatch-test--rebuilds))))

(defmacro herdr-dispatch-test-counting-rebuilds (&rest body)
  "Run BODY, evaluating to the number of buffer rebuilds it caused.
Counting the insert is what tells a suppressed redraw apart from a
redraw that happened to lay down the same characters — comparing buffer
strings cannot, and that is the whole distinction under test."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn
         (setq herdr-dispatch-test--rebuilds 0)
         (advice-add 'herdr-dispatch--insert-nodes :before
                     #'herdr-dispatch-test--count-rebuild)
         ,@body
         herdr-dispatch-test--rebuilds)
     (advice-remove 'herdr-dispatch--insert-nodes
                    #'herdr-dispatch-test--count-rebuild)))

(defun herdr-dispatch-test--pane-event (id status revision)
  "Fold a `pane_updated' for pane ID with STATUS and REVISION into the cache.
REVISION and scroll are the fields the live stream mostly carries and the
dashboard never renders; STATUS is one it does."
  (setq herdr-state--current
        (herdr-state-reduce herdr-state--current "pane_updated"
                            `((pane . ((pane_id . ,id)
                                       (agent . "claude")
                                       (agent_status . ,status)
                                       (workspace_id . "w1")
                                       (tab_id . "w1:t1")
                                       (revision . ,revision)
                                       (scroll . ,revision)))))))

(ert-deftest herdr-dispatch-refresh-draws-the-session ()
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh)
    (should (string-match-p
             (regexp-quote
              (format "1 workspaces  2 panes  1%s1%s"
                      (herdr-tree-glyph "blocked")
                      (herdr-tree-glyph "working")))
             (buffer-string)))
    (should (string-match-p "web" (buffer-string)))
    (should (string-match-p "w1:p1" (buffer-string)))
    (should (string-match-p "w1:p2" (buffer-string)))))

(ert-deftest herdr-dispatch-refresh-keeps-folds-and-point ()
  "Redrawing must not unfold the tree or move you to a different agent.

Neither was covered while `herdr-dispatch-refresh' still called
`magit-section-cache-visibility' with no argument — which signals
`wrong-type-argument' on every invocation, because outside an insert
there is no current section to cache.  The three renderer tests passed
throughout, so a completely broken refresh looked green.

A rendered change is driven before the second refresh deliberately.
`herdr-dispatch-refresh' now returns without erasing anything when the
tree and header are what is already on screen, so a second call against
an unchanged cache asserts nothing at all — it would pass against a
refresh that had no restore path whatsoever.  The change is what makes
this a test of a redraw again rather than a test of the skip."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
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
      (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
      (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                         (herdr-dispatch-refresh))))
      (should (equal ident (magit-section-ident (magit-current-section))))
      (goto-char (point-min))
      (search-forward "web")
      (should (oref (magit-current-section) hidden)))))

;;; Redraw suppression, debouncing and point

(ert-deftest herdr-dispatch-refresh-skips-a-redraw-of-an-unchanged-tree ()
  "Revision churn must not cost an `erase-buffer'.

A 20-second capture against a live server produced 201 events, 192 of
them `pane_updated' carrying only revision and scroll.  Redrawing on each
is what reset the cursor and left folds acting on erased sections, so a
redraw that would produce the identical tree must not happen at all."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (let ((tick (buffer-chars-modified-tick)))
      (should (equal 0 (herdr-dispatch-test-counting-rebuilds
                         (dotimes (i 10)
                           (herdr-dispatch-test--pane-event "w1:p1" "blocked" i)
                           (herdr-dispatch-refresh)))))
      (should (equal tick (buffer-chars-modified-tick)))
      ;; A field the dashboard does render still gets through.
      (herdr-dispatch-test--pane-event "w1:p1" "idle" 11)
      (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                         (herdr-dispatch-refresh))))
      (should-not (equal tick (buffer-chars-modified-tick)))
      (should (string-match-p (regexp-quote (herdr-tree-glyph "idle"))
                              (buffer-string))))))

(ert-deftest herdr-dispatch-refresh-redraws-when-only-the-header-changed ()
  "The header is not derived from the tree, so it needs its own comparison.

`herdr-dispatch--header' counts every pane in the cache, while
`herdr-tree-build' walks workspaces — so a pane whose workspace herdr
does not know about moves the header and leaves the tree alone.  A skip
keyed on the tree by itself would freeze the header at a stale count."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (let ((tree (herdr-tree-build (herdr-state-current) nil)))
      (setq herdr-state--current
            (herdr-state-reduce herdr-state--current "pane_created"
                                '((pane . ((pane_id . "ghost:p9")
                                           (agent . "shell")
                                           (agent_status . "idle")
                                           (workspace_id . "ghost")
                                           (tab_id . "ghost:t1"))))))
      (should (equal tree (herdr-tree-build (herdr-state-current) nil)))
      (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                         (herdr-dispatch-refresh))))
      (should (string-match-p "3 panes" (buffer-string))))))

(ert-deftest herdr-dispatch-refresh-called-interactively-always-redraws ()
  "`g' is what you press when you doubt the screen, so it must not be skipped."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (should (equal 0 (herdr-dispatch-test-counting-rebuilds
                       (herdr-dispatch-refresh))))
    (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                       (call-interactively #'herdr-dispatch-refresh))))))

(ert-deftest herdr-dispatch-refresh-hook-defers-rather-than-redrawing ()
  "The hook schedules; it does not draw.

Asserting only that a redraw eventually happened would pass against the
undebounced hook, so the point immediately after the event — nothing
drawn, a timer pending — is what is pinned here."
  (herdr-dispatch-test-with-dispatcher
    (let ((herdr-dispatch-refresh-debounce 0.05))
      (herdr-dispatch-refresh t)
      (unwind-protect
          (progn
            (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
            (should (equal 0 (herdr-dispatch-test-counting-rebuilds
                               (herdr-dispatch--refresh-hook "pane_updated" nil))))
            (should herdr-dispatch--refresh-timer)
            (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                               (sit-for 0.2))))
            (should-not herdr-dispatch--refresh-timer))
        (herdr-dispatch--cancel-refresh)))))

(ert-deftest herdr-dispatch-refresh-hook-coalesces-a-burst-of-events ()
  "Ten events inside one window must cost one redraw rather than ten.

Every event here flips `agent_status', which the dashboard does render,
so the tree-equality skip cannot account for the saving on its own —
only coalescing can, which is what makes this a test of the debounce
rather than a second test of the skip."
  (herdr-dispatch-test-with-dispatcher
    (let ((herdr-dispatch-refresh-debounce 0.05))
      (herdr-dispatch-refresh t)
      (unwind-protect
          (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                             (dotimes (i 10)
                               (herdr-dispatch-test--pane-event
                                "w1:p1" (if (cl-evenp i) "idle" "working") i)
                               (herdr-dispatch--refresh-hook "pane_updated" nil))
                             (sit-for 0.2))))
        (herdr-dispatch--cancel-refresh)))))

(ert-deftest herdr-dispatch-refresh-hook-cancels-its-timer-with-the-buffer ()
  "A pending redraw must not outlive the buffer it would draw into."
  (skip-unless (featurep 'magit-section))
  (let ((herdr-state-change-hook (list #'herdr-dispatch--refresh-hook))
        (buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (unwind-protect
        (progn
          (with-current-buffer buffer (herdr-dispatch-mode))
          (herdr-dispatch--refresh-hook "pane_updated" nil)
          (should herdr-dispatch--refresh-timer)
          (kill-buffer buffer)
          (herdr-dispatch--refresh-hook "pane_updated" nil)
          (should-not herdr-dispatch--refresh-timer)
          (should-not (memq #'herdr-dispatch--refresh-hook
                            herdr-state-change-hook)))
      (herdr-dispatch--cancel-refresh)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest herdr-dispatch-refresh-restores-point-in-an-unselected-window ()
  "The cursor reset happens in a window that is not the selected one.

When the hook fires from the event-stream process filter the dashboard
is typically not selected, and for such a window `window-point' is what
governs — `erase-buffer' collapses it to 1 and a buffer-point restore
never touches it.  Buffer point is parked at `point-min' here so a
restore that only puts back `point' cannot pass by accident."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (let ((window (split-window)))
      (unwind-protect
          (progn
            (set-window-buffer window (current-buffer))
            (should-not (eq (current-buffer) (window-buffer (selected-window))))
            (goto-char (point-min))
            (search-forward "w1:p2")
            (set-window-point window (+ 3 (line-beginning-position)))
            (goto-char (point-min))
            (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
            (herdr-dispatch-refresh)
            (let ((position (window-point window)))
              (should (equal "w1:p2"
                             (save-excursion
                               (goto-char position)
                               (herdr-dispatch--value-at-point 'herdr-pane))))
              (should (equal 3 (save-excursion
                                 (goto-char position)
                                 (current-column))))))
        (delete-window window)))))

(ert-deftest herdr-dispatch-refresh-keeps-the-column-not-only-the-line ()
  "Restoring to the section start alone throws you back to column 0.
Vertical position was already covered; horizontal was not, and both move
under the same `erase-buffer'."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (goto-char (point-min))
    (search-forward "w1:p2")
    (goto-char (+ 4 (line-beginning-position)))
    (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
    (herdr-dispatch-refresh)
    (should (equal "w1:p2" (herdr-dispatch--value-at-point 'herdr-pane)))
    (should (equal 4 (current-column)))))

;;; Resolution

(ert-deftest herdr-dispatch-resolves-the-nearest-enclosing-section ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1:p2")
    (should (equal "w1:p2" (herdr-dispatch--value-at-point 'herdr-pane)))
    (should (equal "w1" (herdr-dispatch--value-at-point 'herdr-workspace)))))

(ert-deftest herdr-dispatch-resolution-is-nil-when-absent ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "herdr.el")
    (should-not (herdr-dispatch--value-at-point 'herdr-pane))))

(ert-deftest herdr-dispatch-resolves-every-ancestor-type ()
  "One pane line has to answer for its tab and its workspace as well."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p2")
    (should (equal "w2:p2" (herdr-dispatch--value-at-point 'herdr-pane)))
    (should (equal "w2:t2" (herdr-dispatch--value-at-point 'herdr-tab)))
    (should (equal "w2" (herdr-dispatch--value-at-point 'herdr-workspace)))))

(ert-deftest herdr-dispatch-resolution-prefers-the-innermost-match ()
  "\"Nearest enclosing\" means the walk stops at the first match.

`herdr-tree-build' never nests a type inside itself today, so no fixture
drawn from a real session can tell a resolver that stops from one that
keeps climbing.  The guarantee belongs to the resolver rather than to
the current tree shape, so it is pinned here with a nested fixture of
its own."
  (herdr-dispatch-test-with-buffer
      '((herdr-workspace "outer" "outer workspace"
                         ((herdr-workspace "inner" "inner workspace"
                                           ((herdr-pane "p" "a pane" nil))))))
    (search-forward "a pane")
    (should (equal "inner" (herdr-dispatch--value-at-point 'herdr-workspace)))))

(ert-deftest herdr-dispatch-require-errors-with-a-specific-message ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "herdr.el")
    (should-error (herdr-dispatch--require 'herdr-pane "a pane")
                  :type 'user-error)
    (should (equal "herdr: point is not on a pane"
                   (condition-case err
                       (herdr-dispatch--require 'herdr-pane "a pane")
                     (user-error (error-message-string err)))))
    (should (equal "w1" (herdr-dispatch--require 'herdr-workspace "a workspace")))))

;;; Error reporting

(defvar herdr-dispatch-test--calls nil
  "Calls recorded by `herdr-dispatch-test--recorder', newest first.")

(defun herdr-dispatch-test--recorder (name)
  "Return a function recording each call to it as (NAME . ARGS)."
  (lambda (&rest args)
    (push (cons name args) herdr-dispatch-test--calls)
    nil))

(defmacro herdr-dispatch-test-with-recorders (names &rest body)
  "Run BODY with each function in NAMES replaced by a recorder.
Evaluates to the list of calls made, oldest first, so a test can assert
on which command ran, with which arguments, and in which order."
  (declare (indent 1) (debug t))
  `(let ((herdr-dispatch-test--calls nil))
     (cl-letf ,(mapcar (lambda (name)
                         `((symbol-function ',name)
                           (herdr-dispatch-test--recorder ',name)))
                       names)
       ,@body)
     (nreverse herdr-dispatch-test--calls)))

(defvar herdr-dispatch-test--messages nil
  "Messages captured by `herdr-dispatch-test-with-messages', newest first.")

(defmacro herdr-dispatch-test-with-messages (&rest body)
  "Run BODY with `message' captured, evaluating to the messages, oldest first."
  (declare (indent 0) (debug t))
  `(let ((herdr-dispatch-test--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (apply #'format fmt args)
                        herdr-dispatch-test--messages))))
       ,@body)
     (nreverse herdr-dispatch-test--messages)))

(ert-deftest herdr-dispatch-protect-reports-a-server-error ()
  (skip-unless (featurep 'magit-section))
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (herdr-dispatch--protect
       (lambda () (signal 'herdr-error (list "busy" "pane is busy")))))
    (should (string-match-p "busy" (car messages)))
    (should (equal '("herdr: pane is busy [busy]") messages))))

(ert-deftest herdr-dispatch-protect-passes-a-result-through ()
  "Protection must not cost the return value of the command it wraps."
  (skip-unless (featurep 'magit-section))
  (should (equal 42 (herdr-dispatch--protect (lambda () 42)))))

(ert-deftest herdr-dispatch-protect-reconciles-a-stale-cache-before-reporting ()
  "`not_found' usually means the cache is stale, so it is corrected first.

Asserting only that some message appeared would pass against a wrapper
that reported and left the dead pane on screen, which is the failure
this branch exists to prevent — hence the ordering assertion."
  (skip-unless (featurep 'magit-section))
  (let* ((calls nil)
         (messages
          (herdr-dispatch-test-with-messages
            (setq calls
                  (herdr-dispatch-test-with-recorders
                      (herdr-state-reconcile-panes herdr-dispatch-refresh)
                    (herdr-dispatch--protect
                     (lambda ()
                       (signal 'herdr-error
                               (list "not_found" "no such pane")))))))))
    (should (equal '((herdr-state-reconcile-panes) (herdr-dispatch-refresh))
                   calls))
    (should (equal '("herdr: no such pane [not_found]") messages))))

(ert-deftest herdr-dispatch-protect-leaves-a-good-cache-alone ()
  "Any error but `not_found' says nothing about the cache; do not redraw."
  (skip-unless (featurep 'magit-section))
  (let* ((calls nil)
         (messages
          (herdr-dispatch-test-with-messages
            (setq calls
                  (herdr-dispatch-test-with-recorders
                      (herdr-state-reconcile-panes herdr-dispatch-refresh)
                    (herdr-dispatch--protect
                     (lambda ()
                       (signal 'herdr-error
                               (list "busy" "pane is busy")))))))))
    (should-not calls)
    (should (equal '("herdr: pane is busy [busy]") messages))))

(ert-deftest herdr-dispatch-protect-points-at-the-fix-for-no-server ()
  "A dead server has one cure, and the message names it instead of a code."
  (skip-unless (featurep 'magit-section))
  (should (equal '("herdr: not running (M-x herdr-start)")
                 (herdr-dispatch-test-with-messages
                   (herdr-dispatch--protect
                    (lambda ()
                      (signal 'herdr-error
                              (list "no_server" "not running"))))))))

;;; Verbs

(defun herdr-dispatch-test--visit-from (text)
  "Return the calls `herdr-dispatch-visit' makes from the line holding TEXT."
  (goto-char (point-min))
  (search-forward text)
  (herdr-dispatch-test-with-recorders
      (herdr-pane-focus herdr-tab-focus herdr-workspace-focus
                        herdr-dispatch-open-worktree)
    (herdr-dispatch-visit)))

(ert-deftest herdr-dispatch-visit-goes-to-the-thing-at-point ()
  "Each line type reaches its own command, innermost first.

A pane line sits inside a workspace, and a worktree line inside one too,
so a resolver checked in the wrong order would focus the workspace from
both and still look like it worked."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (equal '((herdr-pane-focus "w1:p2"))
                   (herdr-dispatch-test--visit-from "w1:p2")))
    (should (equal '((herdr-dispatch-open-worktree))
                   (herdr-dispatch-test--visit-from "open as w2")))
    (should (equal '((herdr-tab-focus "w2:t2"))
                   (herdr-dispatch-test--visit-from "spike")))
    (should (equal '((herdr-workspace-focus "w2"))
                   (herdr-dispatch-test--visit-from "api")))))

(ert-deftest herdr-dispatch-visit-refuses-a-line-with-nothing-on-it ()
  (herdr-dispatch-test-with-buffer nil
    (should-error (herdr-dispatch-visit) :type 'user-error)))

(ert-deftest herdr-dispatch-prompt-sends-to-the-agent-at-point ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (equal '((herdr-agent-prompt "ship it" "w1:p2"))
                   (cl-letf (((symbol-function 'read-string)
                              (lambda (&rest _) "ship it")))
                     (herdr-dispatch-test-with-recorders (herdr-agent-prompt)
                       (search-forward "w1:p2")
                       (herdr-dispatch-prompt)))))))

(ert-deftest herdr-dispatch-prompt-needs-an-agent ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "herdr.el")
    (should-error (herdr-dispatch-prompt) :type 'user-error)))

(ert-deftest herdr-dispatch-read-reads-the-pane-at-point ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (equal '((herdr-pane-read "w1:p2" "recent_unwrapped"))
                   (herdr-dispatch-test-with-recorders (herdr-pane-read)
                     (search-forward "w1:p2")
                     (herdr-dispatch-read))))))

(ert-deftest herdr-dispatch-read-needs-a-pane ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "herdr.el")
    (should-error (herdr-dispatch-read) :type 'user-error)))

(defun herdr-dispatch-test--focus-from (text)
  "Return the calls `herdr-dispatch-focus' makes from the line holding TEXT.
The following commands are recorded alongside `herdr-rpc-call' so that
reaching the server through one of them is distinguishable from calling
it directly — they issue the same request, and only the recorder tells
them apart."
  (goto-char (point-min))
  (search-forward text)
  (herdr-dispatch-test-with-recorders
      (herdr-rpc-call herdr-pane-focus herdr-tab-focus herdr-workspace-focus)
    (herdr-dispatch-focus)))

(ert-deftest herdr-dispatch-focus-stays-in-emacs ()
  "Focusing calls the server directly rather than the following commands.

`herdr-pane-focus' and friends move Emacs as well; `f' is the verb for
when you want the terminal to move and Emacs to stay put, so it must not
be implemented in terms of them."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (equal '((herdr-rpc-call "pane.focus" ((pane_id . "w1:p2"))))
                   (herdr-dispatch-test--focus-from "w1:p2")))
    (should (equal '((herdr-rpc-call "tab.focus" ((tab_id . "w2:t2"))))
                   (herdr-dispatch-test--focus-from "spike")))
    (should (equal '((herdr-rpc-call "workspace.focus"
                                     ((workspace_id . "w2"))))
                   (herdr-dispatch-test--focus-from "api")))))

(ert-deftest herdr-dispatch-focus-on-a-worktree-focuses-its-own-workspace ()
  "A worktree row has no `cond\\=' branch of its own unless one is written,
and without it `f\\=' falls through to the workspace enclosing the row —
silently focusing the repository the worktree list was expanded from
rather than the worktree under point.  The fixture separates the two:
the row sits inside `w1\\=' and is open as `w2\\='."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (branch . "fix")
                       (open_workspace_id . "w2")))))))
      (should (equal '((herdr-rpc-call "workspace.focus"
                                       ((workspace_id . "w2"))))
                     (herdr-dispatch-test--focus-from "open as w2"))))))

(ert-deftest herdr-dispatch-focus-refuses-a-worktree-that-is-not-open ()
  "There is no workspace to focus, and the enclosing one is the wrong
answer rather than an approximate one."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (branch . "fix")
                       (open_workspace_id . nil)))))))
      (search-forward "open as w2")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-rpc-call herdr-workspace-focus)
                       (should-error (herdr-dispatch-focus)
                                     :type 'user-error)))))))

(ert-deftest herdr-dispatch-verbs-report-rather-than-raise ()
  "Every verb goes through the protection, not just the ones tested above."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1:p2")
    (should (equal '("herdr: pane is busy [busy]")
                   (herdr-dispatch-test-with-messages
                     (cl-letf (((symbol-function 'herdr-pane-focus)
                                (lambda (&rest _)
                                  (signal 'herdr-error
                                          (list "busy" "pane is busy")))))
                       (herdr-dispatch-visit)))))))

(ert-deftest herdr-dispatch-binds-the-read-only-verbs ()
  (skip-unless (featurep 'magit-section))
  (should (eq #'herdr-dispatch-visit
              (lookup-key herdr-dispatch-mode-map (kbd "RET"))))
  (should (eq #'herdr-dispatch-prompt
              (lookup-key herdr-dispatch-mode-map "p")))
  (should (eq #'herdr-dispatch-read
              (lookup-key herdr-dispatch-mode-map "r")))
  (should (eq #'herdr-dispatch-focus
              (lookup-key herdr-dispatch-mode-map "f")))
  (dolist (verb '(herdr-dispatch-visit herdr-dispatch-prompt
                                       herdr-dispatch-read herdr-dispatch-focus))
    (should (commandp verb))))

;;; Worktrees

(ert-deftest herdr-dispatch-fetches-worktrees-once-per-workspace ()
  (skip-unless (featurep 'magit-section))
  (let ((calls 0)
        (herdr-dispatch--worktrees nil))
    (cl-letf (((symbol-function 'herdr-state-workspace-directory)
               (lambda (_state _id) "/tmp/project/"))
              ((symbol-function 'herdr-rpc-call)
               (lambda (method _params)
                 (should (equal "worktree.list" method))
                 (setq calls (1+ calls))
                 '((worktrees . (((path . "/tmp/project-feat")
                                  (branch . "feat/x")
                                  (label . "feat/x")
                                  (open_workspace_id . nil))))))))
      (should (equal 1 (length (herdr-dispatch--worktrees-for "w1"))))
      (should (equal 1 (length (herdr-dispatch--worktrees-for "w1"))))
      (should (equal 1 calls)))))

(ert-deftest herdr-dispatch-caches-a-workspace-with-no-worktrees ()
  "The cache must key on presence, not on a truthy value.

A workspace with zero worktrees still gets an entry — `(WORKSPACE-ID
. nil)' — so the second call must not re-fetch.  A guard written as
`(cdr (assoc ...))' rather than `(assoc ...)' would pass the
once-per-workspace test above, since that test's mock always returns a
non-empty list; this is the case that tells the two apart."
  (skip-unless (featurep 'magit-section))
  (let ((calls 0)
        (herdr-dispatch--worktrees nil))
    (cl-letf (((symbol-function 'herdr-state-workspace-directory)
               (lambda (_state _id) "/tmp/project/"))
              ((symbol-function 'herdr-rpc-call)
               (lambda (_method _params)
                 (setq calls (1+ calls))
                 '((worktrees . nil)))))
      (should-not (herdr-dispatch--worktrees-for "w1"))
      (should-not (herdr-dispatch--worktrees-for "w1"))
      (should (equal 1 calls))
      (should (assoc "w1" herdr-dispatch--worktrees)))))

(ert-deftest herdr-dispatch-worktree-events-drop-the-cache ()
  (skip-unless (featurep 'magit-section))
  (let ((herdr-dispatch--worktrees '(("w1" . (ignored)))))
    (herdr-dispatch--invalidate-worktrees "worktree_created" nil)
    (should-not herdr-dispatch--worktrees)))

(ert-deftest herdr-dispatch-unrelated-events-keep-the-cache ()
  (skip-unless (featurep 'magit-section))
  (let ((herdr-dispatch--worktrees '(("w1" . (ignored)))))
    (herdr-dispatch--invalidate-worktrees "pane_updated" nil)
    (should herdr-dispatch--worktrees)))

(ert-deftest herdr-dispatch-refresh-draws-a-populated-worktrees-cache ()
  "The worktrees branch of the renderer, exercised end-to-end.

Every other renderer test drives `herdr-dispatch--insert-nodes' from a
hand-written fixture; `herdr-dispatch--worktrees' is nil in all of them,
so nothing has ever pushed a real cache entry through
`herdr-dispatch-refresh' -> `herdr-tree-build' -> the renderer.  This
closes that gap."
  (skip-unless (featurep 'magit-section))
  (let ((herdr-state--current
         (herdr-state-from-snapshot herdr-dispatch-test--snapshot))
        (herdr-dispatch--worktrees
         '(("w1" . (((path . "/tmp/web-feat")
                     (branch . "feat/x")
                     (label . "feat/x")
                     (open_workspace_id . nil))))))
        (buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (unwind-protect
        (with-current-buffer buffer
          (herdr-dispatch-mode)
          (herdr-dispatch-refresh)
          (should (string-match-p "worktrees 1" (buffer-string)))
          (should (eq 'herdr-worktrees
                      (herdr-dispatch-test--type-at "worktrees 1")))
          (should (eq 'herdr-worktree
                      (herdr-dispatch-test--type-at "feat/x"))))
      (kill-buffer buffer))))

(ert-deftest herdr-dispatch-toggle-fetches-worktrees-on-first-open ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees nil))
      (cl-letf (((symbol-function 'herdr-dispatch--worktrees-for)
                 (lambda (workspace)
                   (push (cons workspace nil) herdr-dispatch--worktrees)))
                ((symbol-function 'herdr-dispatch-refresh) #'ignore)
                ((symbol-function 'magit-section-toggle) #'ignore))
        (search-forward "w1:p1")
        (herdr-dispatch-toggle)
        (should (assoc "w1" herdr-dispatch--worktrees))))))

(ert-deftest herdr-dispatch-toggle-does-not-refetch-an-expanded-workspace ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees '(("w1" . nil))))
      (cl-letf (((symbol-function 'herdr-dispatch--worktrees-for)
                 (lambda (&rest _) (error "should not be called")))
                ((symbol-function 'magit-section-toggle) #'ignore))
        (search-forward "w1:p1")
        (herdr-dispatch-toggle)))))

(ert-deftest herdr-dispatch-toggle-toggles-before-it-fetches-and-refreshes ()
  "The keystroke acts on the section that was under point when it was pressed.

Fetching worktrees ends in a redraw, and a redraw recreates every
section, so a toggle sequenced after it acts on a section rebuilt out
from under the user rather than the one they aimed at.  Only the order
of the three calls distinguishes the two arrangements — both fetch, both
refresh, both toggle — so the order is what is asserted."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((order nil)
          (herdr-dispatch--worktrees nil))
      (cl-letf (((symbol-function 'magit-section-toggle)
                 (lambda () (interactive) (push 'toggle order)))
                ((symbol-function 'herdr-dispatch--worktrees-for)
                 (lambda (workspace)
                   (push 'fetch order)
                   (push (cons workspace nil) herdr-dispatch--worktrees)))
                ((symbol-function 'herdr-dispatch-refresh)
                 (lambda (&rest _) (push 'refresh order))))
        (search-forward "w1:p1")
        (herdr-dispatch-toggle)
        (should (equal '(toggle fetch refresh) (nreverse order)))))))

(ert-deftest herdr-dispatch-folds-and-unfolds-across-intervening-refreshes ()
  "\"Cannot fold after unfolding\" was the report, so fold repeatedly.

Real sections and the real `magit-section-toggle', with a redraw driven
by a rendered change between every keystroke, because a single toggle in
a static buffer never meets the erase that broke this."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (cl-letf (((symbol-function 'herdr-dispatch--worktrees-for)
               (lambda (workspace)
                 (push (cons workspace nil) herdr-dispatch--worktrees)
                 nil)))
      (dotimes (i 4)
        (goto-char (point-min))
        (search-forward "web")
        (herdr-dispatch-toggle)
        (should (equal (cl-evenp i)
                       (and (oref (magit-current-section) hidden) t)))
        (herdr-dispatch-test--pane-event
         "w1:p1" (if (cl-evenp i) "idle" "working") i)
        (herdr-dispatch-refresh)
        (goto-char (point-min))
        (search-forward "web")
        (should (equal (cl-evenp i)
                       (and (oref (magit-current-section) hidden) t)))))))

(ert-deftest herdr-dispatch-open-worktree-focuses-an-already-open-worktree ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (branch . "fix")
                       (open_workspace_id . "w2")))))))
      (search-forward "open as w2")
      (should (equal '((herdr-workspace-focus "w2"))
                     (herdr-dispatch-test-with-recorders
                         (herdr-workspace-focus herdr-rpc-call)
                       (herdr-dispatch-open-worktree)))))))

(ert-deftest herdr-dispatch-open-worktree-opens-a-closed-worktree-in-its-own-directory ()
  "The cwd sent to `worktree.open\\=' must be the worktree's own workspace
directory, resolved the same way `herdr-dispatch--worktrees-for' does —
not `default-directory\\=', which in the dispatcher buffer names nothing
in particular.

`herdr-worktree-open' (the wrapped command `herdr-cmd' already has)
derives its `cwd\\=' from the calling buffer's `default-directory\\=' , so a
test that only records \"was `herdr-worktree-open' called\" would pass
even if the open request resolved against the wrong repository entirely.
Binding `default-directory\\=' here to something that is not the
worktree's directory, and asserting the exact params reaching
`herdr-rpc-call\\=', is what would catch that."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (branch . "fix")
                       (open_workspace_id . nil))))))
          (default-directory "/totally/unrelated/directory/"))
      (search-forward "open as w2")
      (cl-letf (((symbol-function 'herdr-state-workspace-directory)
                 (lambda (_state workspace-id)
                   (should (equal "w1" workspace-id))
                   "/tmp/herdr.el/")))
        (should (equal '((herdr-rpc-call "worktree.open"
                                         ((branch . "fix")
                                          (cwd . "/tmp/herdr.el/")
                                          (focus . t))))
                       (herdr-dispatch-test-with-recorders
                           (herdr-workspace-focus herdr-rpc-call)
                         (herdr-dispatch-open-worktree))))))))

(ert-deftest herdr-dispatch-binds-tab-to-toggle ()
  (skip-unless (featurep 'magit-section))
  (should (eq #'herdr-dispatch-toggle
              (lookup-key herdr-dispatch-mode-map (kbd "TAB")))))

(ert-deftest herdr-dispatch-binds-question-mark-to-the-transient ()
  (skip-unless (featurep 'magit-section))
  (should (eq #'herdr-transient
              (lookup-key herdr-dispatch-mode-map "?"))))

;;; Rename

(ert-deftest herdr-dispatch-rename-dispatches-on-section-type ()
  (skip-unless (featurep 'magit-section))
  (let ((called nil))
    (cl-letf (((symbol-function 'herdr-pane-rename)
               (lambda (label id) (setq called (list 'pane label id))))
              ((symbol-function 'read-string) (lambda (&rest _) "new")))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "w1:p1")
        (herdr-dispatch-rename)
        (should (equal '(pane "new" "w1:p1") called))))))

(ert-deftest herdr-dispatch-rename-on-a-workspace-renames-the-workspace ()
  (skip-unless (featurep 'magit-section))
  (let ((called nil))
    (cl-letf (((symbol-function 'herdr-workspace-rename)
               (lambda (label id) (setq called (list 'workspace label id))))
              ((symbol-function 'read-string) (lambda (&rest _) "new")))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "herdr.el")
        (herdr-dispatch-rename)
        (should (equal '(workspace "new" "w1") called))))))

(ert-deftest herdr-dispatch-rename-on-a-tab-renames-the-tab ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "spike")
    (should (equal '((herdr-tab-rename "new" "w2:t2"))
                   (cl-letf (((symbol-function 'read-string)
                              (lambda (&rest _) "new")))
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-rename herdr-tab-rename
                                            herdr-workspace-rename)
                       (herdr-dispatch-rename)))))))

(ert-deftest herdr-dispatch-rename-prefers-the-pane-over-its-tab-and-workspace ()
  "A pane nested under both a tab and a workspace must still rename the
pane: only `w2:p1\\=' has all three ancestors to distinguish a `cond\\=' that
checks the tab or the workspace first from one that checks the pane
first."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p1")
    (should (equal '((herdr-pane-rename "new" "w2:p1"))
                   (cl-letf (((symbol-function 'read-string)
                              (lambda (&rest _) "new")))
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-rename herdr-tab-rename
                                            herdr-workspace-rename)
                       (herdr-dispatch-rename)))))))

(ert-deftest herdr-dispatch-rename-refuses-a-worktree ()
  "There is no rename-a-worktree operation, so `R\\=' on a worktree row must
refuse rather than fall through to the workspace enclosing it — which
would silently rename the repository the worktree list was expanded
from, a different object under a name the user never aimed at."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "open as w2")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-rename herdr-tab-rename
                                          herdr-workspace-rename)
                     (should-error (herdr-dispatch-rename)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-rename-refuses-a-line-with-nothing-on-it ()
  (herdr-dispatch-test-with-buffer nil
    (should-error (herdr-dispatch-rename) :type 'user-error)))

;;; Close

(ert-deftest herdr-dispatch-close-prefers-the-pane-over-its-tab-and-workspace ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p1")
    (should (equal '((herdr-pane-close "w2:p1"))
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-tab-close herdr-workspace-close
                                         herdr-worktree-remove)
                     (herdr-dispatch-close))))))

(ert-deftest herdr-dispatch-close-on-a-tab-closes-the-tab ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "spike")
    (should (equal '((herdr-tab-close "w2:t2"))
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-tab-close herdr-workspace-close
                                         herdr-worktree-remove)
                     (herdr-dispatch-close))))))

(ert-deftest herdr-dispatch-close-on-a-workspace-closes-the-workspace ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "api")
    (should (equal '((herdr-workspace-close "w2"))
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-tab-close herdr-workspace-close
                                         herdr-worktree-remove)
                     (herdr-dispatch-close))))))

(ert-deftest herdr-dispatch-close-on-a-worktree-removes-that-worktree ()
  "A worktree line's close must remove the worktree under point — the
workspace it is open as — and not the workspace enclosing the row.

Those are different objects and the difference is destructive.  The
enclosing workspace is the repository whose worktree list was expanded;
when that repository is itself a worktree, its section lists its
siblings, so removing the enclosing workspace destroys the worktree you
are standing in rather than the sibling you aimed at.

The fixture is built so a resolver that reaches for the enclosing
workspace cannot pass by luck: the row sits inside `w1\\=' but names the
worktree open as `w2\\='."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (branch . "fix")
                       (open_workspace_id . "w2")))))))
      (search-forward "open as w2")
      (should (equal '((herdr-worktree-remove "w2"))
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-tab-close herdr-workspace-close
                                           herdr-worktree-remove)
                       (herdr-dispatch-close)))))))

(ert-deftest herdr-dispatch-close-refuses-a-worktree-that-is-not-open ()
  "`worktree.remove\\=' addresses a workspace, so a worktree herdr has not
opened as one cannot be removed at all.  Guessing at the enclosing
workspace is what made this destructive; refusing is the alternative, and
nothing may reach the server on the way out."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (branch . "fix")
                       (open_workspace_id . nil)))))))
      (search-forward "open as w2")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-tab-close herdr-workspace-close
                                           herdr-worktree-remove herdr-rpc-call)
                       (should-error (herdr-dispatch-close)
                                     :type 'user-error)))))))

(ert-deftest herdr-dispatch-close-refuses-a-line-with-nothing-on-it ()
  (herdr-dispatch-test-with-buffer nil
    (should-error (herdr-dispatch-close) :type 'user-error)))

(ert-deftest herdr-dispatch-binds-the-mutating-verbs ()
  (skip-unless (featurep 'magit-section))
  (should (eq #'herdr-dispatch-rename
              (lookup-key herdr-dispatch-mode-map "R")))
  (should (eq #'herdr-dispatch-close
              (lookup-key herdr-dispatch-mode-map "k")))
  (dolist (verb '(herdr-dispatch-rename herdr-dispatch-close))
    (should (commandp verb))))

;;; Create

(ert-deftest herdr-dispatch-create-tab-focuses-the-workspace-first ()
  "tab.create takes no workspace_id, so the workspace has to be focused."
  (skip-unless (featurep 'magit-section))
  (let ((calls nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (method params) (push (cons method params) calls) nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore)
              ((symbol-function 'transient-args) (lambda (_) nil))
              ((symbol-function 'read-string) (lambda (&rest _) "")))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "herdr.el")
        (herdr-dispatch-create-tab)
        (should (equal '("workspace.focus" "tab.create")
                       (reverse (mapcar #'car calls))))))))

(ert-deftest herdr-dispatch-create-pane-splits-a-pane-of-the-tab ()
  "pane.split needs a target_pane_id; a tab is not one."
  (skip-unless (featurep 'magit-section))
  (let ((target nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_method params)
                 (setq target (alist-get 'target_pane_id params))
                 nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore)
              ((symbol-function 'transient-args) (lambda (_) nil)))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "w1:p2")
        (herdr-dispatch-create-pane)
        (should (equal "w1:p2" target))))))

(ert-deftest herdr-dispatch-create-pane-resolves-a-tab-to-one-of-its-panes ()
  "A tab section is not a pane_id itself; splitting it must target the
pane_id of one of its panes, found by matching tab_id in the live
state's pane list — not the tab id passed straight through.  A real
state is built via `herdr-state-from-snapshot\\=' rather than mocking
`herdr-state-panes\\=', because that accessor is a `cl-defstruct\\=' slot
reader inlined at the call site, which a `cl-letf\\=' override of its
symbol-function does not reach."
  (skip-unless (featurep 'magit-section))
  (let ((target nil)
        (herdr-state--current
         (herdr-state-from-snapshot
          '((workspaces . (((workspace_id . "w2") (label . "api") (pane_count . 2))))
            (tabs . (((tab_id . "w2:t1") (workspace_id . "w2") (label . "main"))
                     ((tab_id . "w2:t2") (workspace_id . "w2") (label . "spike"))))
            (panes . (((pane_id . "w2:p1") (agent . "claude")
                       (agent_status . "working")
                       (workspace_id . "w2") (tab_id . "w2:t1"))
                      ((pane_id . "w2:p2") (agent . "gemini")
                       (agent_status . "idle")
                       (workspace_id . "w2") (tab_id . "w2:t2"))))))))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_method params)
                 (setq target (alist-get 'target_pane_id params))
                 nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore)
              ((symbol-function 'transient-args) (lambda (_) nil)))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "spike")
        (herdr-dispatch-create-pane)
        (should (equal "w2:p2" target))))))

(ert-deftest herdr-dispatch-create-reads-transient-arguments ()
  (skip-unless (featurep 'magit-section))
  (should (equal "main" (herdr-dispatch--arg '("--base=main") "--base")))
  (should-not (herdr-dispatch--arg '("--base=main") "--label")))

(ert-deftest herdr-dispatch-create-worktree-omits-an-empty-base ()
  "An empty --base means \"off the current ref\"; `herdr-worktree-create's
own contract (see herdr-cmd-test.el) is that a blank string must not
reach the server as one.  `herdr-dispatch-create-worktree' calls
`herdr-rpc-call\\=' directly rather than through that command, so the
same contract has to be reasserted here rather than inherited."
  (skip-unless (featurep 'magit-section))
  (let ((params nil)
        (transient-current-command 'herdr-dispatch-create))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_method p) (setq params p) nil))
              ((symbol-function 'herdr-state-workspace-directory)
               (lambda (_state _id) "/tmp/herdr.el/"))
              ((symbol-function 'read-string) (lambda (&rest _) "feature"))
              ((symbol-function 'transient-args) (lambda (_) '("--base=")))
              ((symbol-function 'herdr-dispatch-refresh) #'ignore))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "herdr.el")
        (herdr-dispatch-create-worktree)
        (should (equal "feature" (alist-get 'branch params)))
        (should-not (alist-get 'base params))
        (should (equal "/tmp/herdr.el/" (alist-get 'cwd params)))))))

(ert-deftest herdr-dispatch-create-workspace-uses-the-directory-argument-when-set ()
  "--directory short-circuits both the point-derived default and the prompt."
  (skip-unless (featurep 'magit-section))
  (let ((called nil)
        (transient-current-command 'herdr-dispatch-create))
    (cl-letf (((symbol-function 'herdr-workspace-create)
               (lambda (dir label) (setq called (list dir label))))
              ((symbol-function 'transient-args)
               (lambda (_) '("--directory=/tmp/proj" "--label=proj")))
              ((symbol-function 'read-directory-name)
               (lambda (&rest _) (error "should not prompt"))))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "herdr.el")
        (herdr-dispatch-create-workspace)
        (should (equal '("/tmp/proj" "proj") called))))))

(ert-deftest herdr-dispatch-create-agent-starts-in-the-pane-at-point ()
  "The agent kind and name come from the transient's arguments when set,
skipping both prompts."
  (skip-unless (featurep 'magit-section))
  (let ((called nil)
        (transient-current-command 'herdr-dispatch-create))
    (cl-letf (((symbol-function 'herdr-agent-start)
               (lambda (name kind pane) (setq called (list name kind pane))))
              ((symbol-function 'transient-args)
               (lambda (_) '("--kind=claude" "--label=scout")))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (error "should not prompt for kind")))
              ((symbol-function 'read-string)
               (lambda (&rest _) (error "should not prompt for name"))))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "w1:p2")
        (herdr-dispatch-create-agent)
        (should (equal '("scout" "claude" "w1:p2") called))))))

(ert-deftest herdr-dispatch-binds-the-create-verbs ()
  (skip-unless (featurep 'magit-section))
  (should (eq #'herdr-dispatch-create
              (lookup-key herdr-dispatch-mode-map "c")))
  (should (eq #'herdr-dispatch-create-workspace
              (lookup-key herdr-dispatch-mode-map "w")))
  (should (eq #'herdr-dispatch-create-tab
              (lookup-key herdr-dispatch-mode-map "t")))
  (should (eq #'herdr-dispatch-create-pane
              (lookup-key herdr-dispatch-mode-map "n")))
  (should (eq #'herdr-dispatch-create-agent
              (lookup-key herdr-dispatch-mode-map "a")))
  (should (eq #'herdr-dispatch-create-worktree
              (lookup-key herdr-dispatch-mode-map "%")))
  (dolist (verb '(herdr-dispatch-create herdr-dispatch-create-workspace
                                        herdr-dispatch-create-tab
                                        herdr-dispatch-create-pane
                                        herdr-dispatch-create-agent
                                        herdr-dispatch-create-worktree))
    (should (commandp verb))))

(provide 'herdr-dispatch-test)
;;; herdr-dispatch-test.el ends here
