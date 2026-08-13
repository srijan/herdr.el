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

(defmacro herdr-dispatch-test-in-dispatcher (snapshot &rest body)
  "Run BODY in a real dispatcher buffer built from SNAPSHOT.
Every piece of worktree state is rebound, not just the cache: the pending
set, the unanswered list and the generation counter are globals that
outlive a buffer, and a test that left one behind would arrive in the
next as a workspace mysteriously already asked for."
  (declare (indent 1) (debug t))
  `(progn
     (skip-unless (featurep 'magit-section))
     (let ((herdr-state--current (herdr-state-from-snapshot ,snapshot))
           (herdr-dispatch--worktrees nil)
           (herdr-dispatch--worktrees-pending nil)
           (herdr-dispatch--worktrees-unanswered nil)
           (herdr-dispatch--worktrees-generation 0)
           (herdr-dispatch--refresh-timer nil)
           (buffer (get-buffer-create herdr-dispatch-buffer-name)))
       (unwind-protect
           (with-current-buffer buffer
             (herdr-dispatch-mode)
             ,@body)
         (herdr-dispatch--cancel-refresh)
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defmacro herdr-dispatch-test-with-dispatcher (&rest body)
  "Run BODY in a real dispatcher buffer built from the test snapshot.
`herdr-dispatch-refresh' finds its buffer by name, so this has to be the
real one rather than a temporary."
  (declare (indent 0) (debug t))
  `(herdr-dispatch-test-in-dispatcher herdr-dispatch-test--snapshot ,@body))

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

(defconst herdr-dispatch-test--worktree-snapshot
  '((workspaces . (((workspace_id . "w1") (label . "web") (pane_count . 1))
                   ((workspace_id . "w2") (label . "api") (pane_count . 1))
                   ((workspace_id . "w3") (label . "empty") (pane_count . 0))))
    (tabs . (((tab_id . "w1:t1") (workspace_id . "w1") (label . "main"))
             ((tab_id . "w2:t1") (workspace_id . "w2") (label . "main"))))
    (panes . (((pane_id . "w1:p1") (agent . "claude") (agent_status . "idle")
               (workspace_id . "w1") (tab_id . "w1:t1") (cwd . "/tmp/web"))
              ((pane_id . "w2:p1") (agent . "claude") (agent_status . "idle")
               (workspace_id . "w2") (tab_id . "w2:t1") (cwd . "/tmp/api")))))
  "A session for the worktree tests, with all three cases in it.
`w1' and `w2' have a pane reporting a cwd, so a directory can be derived
for them; `w3' has no panes, which is the workspace
`herdr-state-workspace-directory' answers nil for and which renders like
any other.")

(defun herdr-dispatch-test--snapshot-with-pane (snapshot pane)
  "Return SNAPSHOT with PANE appended to its panes.
Appended rather than prepended because `herdr-state-workspace-directory'
answers with the oldest pane it was told about, and a test that added a
pane to the front would be describing a different session from the one it
meant to."
  (cons (cons 'panes (append (alist-get 'panes snapshot) (list pane)))
        (assq-delete-all 'panes (copy-sequence snapshot))))

(defvar herdr-dispatch-test--async nil
  "Async calls captured by `herdr-dispatch-test-with-async', oldest first.
Each is (METHOD PARAMS CALLBACK TIMEOUT).")

(defmacro herdr-dispatch-test-with-async (&rest body)
  "Run BODY with `herdr-rpc-call-async' captured rather than performed.

Nothing is answered until the test says so, so the window between a
request going out and its reply landing — which is where every in-flight
bug lives, and which a stub that answers immediately closes before a test
can stand in it — is one BODY can hold open for as long as it likes."
  (declare (indent 0) (debug t))
  `(let ((herdr-dispatch-test--async nil))
     (cl-letf (((symbol-function 'herdr-rpc-call-async)
                (lambda (method params callback &optional timeout)
                  (setq herdr-dispatch-test--async
                        (append herdr-dispatch-test--async
                                (list (list method params callback timeout))))
                  'process))
               ((symbol-function 'herdr-rpc-call)
                (lambda (&rest _)
                  (error "the dashboard must not block on the server"))))
       ,@body)))

(defun herdr-dispatch-test--reply (index result &optional error)
  "Answer the INDEXth captured async call with RESULT, or with ERROR."
  (funcall (nth 2 (nth index herdr-dispatch-test--async)) result error))

(defun herdr-dispatch-test--requested ()
  "Return the cwd of each captured `worktree.list', oldest first."
  (mapcar (lambda (call)
            (should (equal "worktree.list" (nth 0 call)))
            (alist-get 'cwd (nth 1 call)))
          herdr-dispatch-test--async))

(ert-deftest herdr-dispatch-fetches-worktrees-once-per-workspace ()
  "A first render asks once per workspace, and asks nothing more meanwhile.

Nothing is cached until a reply lands, so the cache check cannot be what
holds the later refreshes back — only the pending set can, which is why
no reply is delivered before them.  The dashboard refreshes several times
a second off the event stream and a socket round trip does not finish
inside one, so this is the difference between one request per workspace
and one per workspace per redraw."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (should (equal '("/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal '("/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested))))))

(ert-deftest herdr-dispatch-caches-a-workspace-with-no-worktrees ()
  "The cache must key on presence, not on a truthy value.

A workspace with zero worktrees still gets an entry — `(WORKSPACE-ID
. nil)' — so no later refresh may ask again.  A guard written as
`(cdr (assoc ...))' rather than `(assoc ...)' would pass the
once-per-workspace test above, whose reply never arrives at all; this is
the case that tells the two apart."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (herdr-dispatch-test--reply 0 '((worktrees . nil)))
      (should (assoc "w1" herdr-dispatch--worktrees))
      (should-not (cdr (assoc "w1" herdr-dispatch--worktrees)))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal '("/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested))))))

(ert-deftest herdr-dispatch-renders-worktrees-when-the-reply-lands ()
  "The reported bug, from the user's end: no keystroke is involved.

The redraw is driven by letting the callback's own scheduled timer run,
not by calling `herdr-dispatch-refresh' afterwards — a callback that
cached the listing and never asked for a redraw would pass that and
still leave the worktrees off the screen until something else happened
to redraw."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (let ((herdr-dispatch-refresh-debounce 0.05))
      (herdr-dispatch-test-with-async
        (herdr-dispatch-refresh t)
        (should-not (string-match-p "worktrees" (buffer-string)))
        (herdr-dispatch-test--reply
         0 '((worktrees . (((path . "/tmp/web-feat")
                            (branch . "feat/x")
                            (open_workspace_id . nil))))))
        (sit-for 0.2)
        (should (string-match-p "worktrees 1" (buffer-string)))
        (should (string-match-p "feat/x" (buffer-string)))))))

(ert-deftest herdr-dispatch-several-replies-cost-one-redraw ()
  "Replies landing together must not each rebuild the buffer.

The callback schedules a redraw rather than performing or forcing one, so
the debounce that already absorbs event bursts absorbs these too.
Counting rebuilds is what tells that apart from two redraws that happen
to lay down the same characters."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (let ((herdr-dispatch-refresh-debounce 0.05))
      (herdr-dispatch-test-with-async
        (herdr-dispatch-refresh t)
        (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                           (herdr-dispatch-test--reply
                            0 '((worktrees . (((path . "/tmp/web-feat")
                                               (branch . "feat/x"))))))
                           (herdr-dispatch-test--reply
                            1 '((worktrees . (((path . "/tmp/api-spike")
                                               (branch . "spike"))))))
                           (sit-for 0.2))))
        (should (string-match-p "feat/x" (buffer-string)))
        (should (string-match-p "spike" (buffer-string)))))))

(ert-deftest herdr-dispatch-an-error-reply-neither-signals-nor-wedges ()
  "A failed `worktree.list' caches empty, and `g' is what retries it.

The reply arrives from a process sentinel, so signalling on it would land
the error in the event stream's process filter rather than anywhere a
user could act on — hence the error reaching the callback as data.

Caching the failure is the deliberate half: the ordinary cause is a
workspace directory that is not a git repository, which fails the same
way forever, and a workspace left uncached is one asked again on every
redraw for as long as the dashboard stays open.  It must not be
permanent either, so the retry on a forced refresh is asserted as well.

`w2' is answered before that forced refresh, and asserting that it is
*not* asked again is the other half of the same rule: \\[herdr-dispatch-refresh]
re-asks what could not be answered, and only that.  Answering it also
keeps this test honest now that a forced refresh abandons requests still
in flight — an unanswered `w2' would be re-asked for that reason instead,
and the assertion would no longer be about placeholders at all."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (herdr-dispatch-test--reply
       0 nil '((code . "not_found") (message . "not a git repository")))
      (herdr-dispatch-test--reply
       1 '((worktrees . (((path . "/tmp/api-spike") (branch . "spike"))))))
      (should (assoc "w1" herdr-dispatch--worktrees))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal '("/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      (herdr-dispatch-refresh t)
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/web/")
                     (herdr-dispatch-test--requested))))))

(ert-deftest herdr-dispatch-fetch-worktrees-passes-the-rpc-timeout ()
  "Every `worktree.list' must arm the client-side timeout.

`herdr-rpc-call-async' hangs forever with no TIMEOUT, which is exactly
the bug a never-answered listing produced.  `herdr-rpc-timeout' is the
existing, user-configurable value the synchronous path already uses, so
the async fetch here should use the same one rather than inventing a
second timeout to keep in sync with it."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (let ((herdr-rpc-timeout 7.5))
      (herdr-dispatch-test-with-async
        (herdr-dispatch-refresh t)
        (should (equal '(7.5 7.5) (mapcar (lambda (call) (nth 3 call))
                                          herdr-dispatch-test--async)))))))

(ert-deftest herdr-dispatch-a-timed-out-reply-caches-as-an-error-and-g-cures-it ()
  "A never-answered `worktree.list' now surfaces as an ordinary error reply.

Before this task, a hung request left the pending marker set for the life
of the session, and `g' had no reply to work with — clearing the marker
was the whole cure.  Now `herdr-rpc-call-async' itself times out and
hands the callback a `code' of \"timeout\", which is just data to
`herdr-dispatch--worktrees-received': it is handled by the exact same
path as `not_found' in the test above, and `g' still cures it the same
way.  Nothing about the recovery machinery needed to change for that to
be true — this test is what confirms it rather than assumes it."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (herdr-dispatch-test--reply
       0 nil '((code . "timeout") (message . "no response from herdr")))
      (herdr-dispatch-test--reply
       1 '((worktrees . (((path . "/tmp/api-spike") (branch . "spike"))))))
      (should (assoc "w1" herdr-dispatch--worktrees))
      (should-not (cdr (assoc "w1" herdr-dispatch--worktrees)))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal '("/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      (herdr-dispatch-refresh t)
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/web/")
                     (herdr-dispatch-test--requested))))))

(ert-deftest herdr-dispatch-does-not-retry-a-workspace-it-cannot-address ()
  "`w3' has no panes, so no directory can be derived for it — ever.

It still renders, so a fetch keyed on rendering reaches it on every
single redraw.  No request can go out for it, which makes the request
count blind to the loop; what is counted here is the attempt, and the
cache entry that stops it."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (let ((attempts nil))
      (advice-add 'herdr-dispatch--fetch-worktrees :before
                  (lambda (id &rest _) (push id attempts)))
      (unwind-protect
          (herdr-dispatch-test-with-async
            (herdr-dispatch-refresh t)
            (dotimes (_ 19) (herdr-dispatch-refresh))
            (should (assoc "w3" herdr-dispatch--worktrees))
            (should-not (cdr (assoc "w3" herdr-dispatch--worktrees)))
            (should (equal '("w1" "w2" "w3") (nreverse attempts)))
            (should (equal '("/tmp/web/" "/tmp/api/")
                           (herdr-dispatch-test--requested))))
        (advice-mapc (lambda (fn _props)
                       (advice-remove 'herdr-dispatch--fetch-worktrees fn))
                     'herdr-dispatch--fetch-worktrees)))))

(ert-deftest herdr-dispatch-asks-a-workspace-once-it-has-a-directory ()
  "A workspace with no directory yet is asked as soon as it has one.

`workspace_created' and the `pane_created' that gives the workspace its
first pane are two events, and a redraw can fall between them — so the
workspace is cached empty for want of a directory it is about to have.
Leaving it there until the next \\[herdr-dispatch-refresh] would be the
reported bug wearing a different hat: worktrees that show up only when a
key is pressed.  The cure must not become a retry loop either, so the
refreshes after the request are counted too."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (should (equal '("/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      (should (assoc "w3" herdr-dispatch--worktrees))
      (setq herdr-state--current
            (herdr-state-from-snapshot
             (herdr-dispatch-test--snapshot-with-pane
              herdr-dispatch-test--worktree-snapshot
              '((pane_id . "w3:p1") (agent . "claude") (agent_status . "idle")
                (workspace_id . "w3") (cwd . "/tmp/late")))))
      (herdr-dispatch-refresh)
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/late/")
                     (herdr-dispatch-test--requested)))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/late/")
                     (herdr-dispatch-test--requested)))
      (herdr-dispatch-test--reply 2 '((worktrees . nil)))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/late/")
                     (herdr-dispatch-test--requested))))))

(ert-deftest herdr-dispatch-invalidation-abandons-a-reply-in-flight ()
  "A listing invalidated while it was on the wire must not be written back.

`worktree_created' says the answer we are waiting for is already stale,
so the reply carrying it is dropped whole rather than merely allowed to
lose a race: it neither populates the cache nor clears a pending marker.

Clearing the marker is the subtle half.  By the time the abandoned reply
lands, the pending entry for its workspace belongs to the refetch that
replaced it — so a callback that cleared it would leave the refetch
unguarded, and the next of the many refreshes would issue a third
request for the same workspace."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (herdr-dispatch--invalidate-worktrees "worktree_created" nil)
      (should-not herdr-dispatch--worktrees-pending)
      (herdr-dispatch-refresh)
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      (herdr-dispatch-test--reply 0 '((worktrees . (stale))))
      (should-not (assoc "w1" herdr-dispatch--worktrees))
      (should (member "w1" herdr-dispatch--worktrees-pending))
      (herdr-dispatch-refresh)
      (should (equal 4 (length herdr-dispatch-test--async)))
      (herdr-dispatch-test--reply 2 '((worktrees . (fresh))))
      (should (equal '(fresh) (cdr (assoc "w1" herdr-dispatch--worktrees)))))))

(ert-deftest herdr-dispatch-a-reply-after-the-buffer-is-killed-is-harmless ()
  "The dashboard can be killed between the request and the reply.

`q' does exactly that, and the reply lands in a process sentinel where an
error is unhandled and ends up in the event stream's filter.

Asserting that no timer is left behind is what makes this a test rather
than a smoke check: a callback that scheduled a redraw regardless would
raise no error here, and would simply leave a timer pointing at a buffer
that no longer exists."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (kill-buffer herdr-dispatch-buffer-name)
      (herdr-dispatch-test--reply 0 '((worktrees . nil)))
      (should (assoc "w1" herdr-dispatch--worktrees))
      (should-not herdr-dispatch--refresh-timer))))

(ert-deftest herdr-dispatch-a-reply-that-never-comes-is-cured-by-g ()
  "A request that is never answered must not wedge its workspace forever.

`herdr-rpc-call-async' has no timeout, unlike `herdr-rpc-call'.  A server
that accepts the connection and then never replies therefore leaves the
pending marker set for the life of the Emacs session — and that marker is
exactly what stops the workspace being asked again, so the workspace
shows no worktrees for the rest of the session.  \\[herdr-dispatch-refresh]
has to be able to break that, which means clearing the pending set and
not merely the cache.

Bumping the generation while doing so is not optional, and the tail of
this test is what says so: the abandoned reply is delivered afterwards,
and must neither write the cache nor clear the marker that by then
belongs to the refetch.  A version that cleared pending without moving
the generation would pass everything above and then issue a third
request for the same workspace here."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (should (equal '("w2" "w1") herdr-dispatch--worktrees-pending))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal '("/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      ;; `g'.
      (herdr-dispatch-refresh t)
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      ;; The reply nobody was waiting for any more.
      (herdr-dispatch-test--reply 0 '((worktrees . (stale))))
      (should-not (assoc "w1" herdr-dispatch--worktrees))
      (should (member "w1" herdr-dispatch--worktrees-pending))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal 4 (length herdr-dispatch-test--async)))
      (herdr-dispatch-test--reply 2 '((worktrees . (fresh))))
      (should (equal '(fresh) (cdr (assoc "w1" herdr-dispatch--worktrees)))))))

(ert-deftest herdr-dispatch-a-dead-server-caches-rather-than-signalling ()
  "Opening the dashboard while herdr is not running is the common failure.

`herdr-rpc-call-async' hands a *server* error to the callback as data,
but an unreachable socket is not a server error: `herdr-rpc-connect'
signals `herdr-error' with code \"no_server\" synchronously, inside the
refresh.  Neither caller of `herdr-dispatch-refresh' — the debounce timer
and \\[herdr-dispatch-refresh] — is wrapped in `herdr-dispatch--protect',
so letting that escape means a backtrace out of a timer, and a pending
marker left set behind it that nothing would ever clear.

Every workspace is asserted, not just the first: the signal happens once
per workspace, and a handler placed outside the loop would abandon the
rest of the session after the first failure."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (cl-letf (((symbol-function 'herdr-rpc-call-async)
               (lambda (&rest _)
                 (signal 'herdr-error (list "no_server" "not running")))))
      (herdr-dispatch-refresh t)
      (dolist (id '("w1" "w2"))
        (should (assoc id herdr-dispatch--worktrees))
        (should-not (cdr (assoc id herdr-dispatch--worktrees)))
        (should (eq 'error (alist-get id herdr-dispatch--worktrees-unanswered
                                      nil nil #'equal)))
        (should-not (member id herdr-dispatch--worktrees-pending))))
    ;; And the dashboard still draws, which is the point of not signalling.
    (should (string-match-p "web" (buffer-string)))))

(ert-deftest herdr-dispatch-a-failed-send-caches-rather-than-signalling ()
  "The socket can also fail in a way that is not a `herdr-error'.

`herdr-rpc-call-async' connects and then calls `process-send-string',
which signals a plain `error' if the peer closed in between — so a
handler for `herdr-error' alone still lets a signal escape into the
refresh, with the pending marker already set.  The condition is the
signal reaching us, not its type."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (cl-letf (((symbol-function 'herdr-rpc-call-async)
               (lambda (&rest _)
                 (error "process nil: no longer connected to pipe"))))
      (herdr-dispatch-refresh t)
      (should (assoc "w1" herdr-dispatch--worktrees))
      (should (eq 'error (alist-get "w1" herdr-dispatch--worktrees-unanswered
                                    nil nil #'equal)))
      (should-not herdr-dispatch--worktrees-pending))))

(ert-deftest herdr-dispatch-opening-the-dashboard-forgets-stale-worktrees ()
  "Worktree knowledge does not outlive the buffer it was fetched for.

`herdr-dispatch--invalidate-worktrees' takes itself off
`herdr-state-change-hook' when the dashboard dies, so a worktree created
between closing the dashboard and reopening it is one nothing hears
about.  \\[herdr-dispatch-refresh] is no cure — it re-asks the
workspaces that could not be answered, not the ones that were — so
without this the answer would outlive its truth with nothing able to
correct it.

Returning to a dashboard that is already open is the other half, and it
must not forget: that would make every invocation of the command a full
refetch of the session."
  (skip-unless (featurep 'magit-section))
  (let ((herdr-state--current
         (herdr-state-from-snapshot herdr-dispatch-test--worktree-snapshot))
        (herdr-state-change-hook nil)
        (herdr-dispatch--worktrees '(("w1" . (stale))))
        (herdr-dispatch--worktrees-pending nil)
        (herdr-dispatch--worktrees-unanswered nil)
        (herdr-dispatch--worktrees-generation 0)
        (herdr-dispatch--refresh-timer nil))
    (should-not (get-buffer herdr-dispatch-buffer-name))
    (unwind-protect
        (herdr-dispatch-test-with-async
          (save-window-excursion (herdr-agents))
          (should-not (assoc "w1" herdr-dispatch--worktrees))
          (should (equal '("/tmp/web/" "/tmp/api/")
                         (herdr-dispatch-test--requested)))
          ;; Both, so that nothing is left in flight for the forced
          ;; refresh inside the second `herdr-agents' to reissue — that
          ;; rescue has its own test, and leaving it to fire here would
          ;; put a second reason in the way of the one thing this half
          ;; asserts.
          (herdr-dispatch-test--reply
           0 '((worktrees . (((path . "/tmp/web-feat") (branch . "feat/x"))))))
          (herdr-dispatch-test--reply 1 '((worktrees . nil)))
          (save-window-excursion (herdr-agents))
          (should (equal "/tmp/web-feat"
                         (alist-get 'path
                                    (car (cdr (assoc
                                               "w1"
                                               herdr-dispatch--worktrees))))))
          (should (equal '("/tmp/web/" "/tmp/api/")
                         (herdr-dispatch-test--requested))))
      (herdr-dispatch--cancel-refresh)
      (when (get-buffer herdr-dispatch-buffer-name)
        (kill-buffer herdr-dispatch-buffer-name)))))

(ert-deftest herdr-dispatch-worktree-events-drop-the-cache ()
  "Invalidation clears every record of every worktree, not just the cache.

The answers, the questions still outstanding and the failures all go, and
the generation moves so that the outstanding ones cannot come back.
Anything less leaves a workspace that is neither cached, nor pending, nor
asked again."
  (skip-unless (featurep 'magit-section))
  (let ((herdr-dispatch--worktrees '(("w1" . (ignored))))
        (herdr-dispatch--worktrees-pending '("w2"))
        (herdr-dispatch--worktrees-unanswered '(("w3" . error)))
        (herdr-dispatch--worktrees-generation 7))
    (herdr-dispatch--invalidate-worktrees "worktree_created" nil)
    (should-not herdr-dispatch--worktrees)
    (should-not herdr-dispatch--worktrees-pending)
    (should-not herdr-dispatch--worktrees-unanswered)
    (should (equal 8 herdr-dispatch--worktrees-generation))))

(ert-deftest herdr-dispatch-unrelated-events-keep-the-cache ()
  (skip-unless (featurep 'magit-section))
  (let ((herdr-dispatch--worktrees '(("w1" . (ignored))))
        (herdr-dispatch--worktrees-generation 7))
    (herdr-dispatch--invalidate-worktrees "pane_updated" nil)
    (should herdr-dispatch--worktrees)
    (should (equal 7 herdr-dispatch--worktrees-generation))))

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

(ert-deftest herdr-dispatch-tab-fetches-nothing ()
  "TAB is the plain section toggle, and reaches the server not at all.

Binding the fetch to it was the reported bug: a blocking `worktree.list'
on a keystroke, and — because the toggle collapses the workspace before
the fetch draws into it — a TAB on a workspace line that hid the very
worktrees it had just fetched.  They showed up only when TAB was pressed
on an agent line, where a leaf section makes the toggle a no-op.  Both
lines are pressed here, and the workspace line twice, so a fetch left on
any of those paths is caught.

Pressing the key and counting requests is the assertion that states the
requirement; the binding is checked too, but a TAB that reaches the
server is the bug whatever it is bound to."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (should (eq #'magit-section-toggle
                (lookup-key herdr-dispatch-mode-map (kbd "TAB"))))
    (herdr-dispatch-test-with-async
      (herdr-dispatch-refresh t)
      (let ((requested (herdr-dispatch-test--requested)))
        (dolist (line '("web" "w1:p1" "web"))
          (goto-char (point-min))
          (search-forward line)
          (call-interactively (lookup-key herdr-dispatch-mode-map (kbd "TAB"))))
        (should (equal requested (herdr-dispatch-test--requested)))))))

(ert-deftest herdr-dispatch-folds-and-unfolds-across-intervening-refreshes ()
  "\"Cannot fold after unfolding\" was the report, so fold repeatedly.

Real sections and the real `magit-section-toggle', with a redraw driven
by a rendered change between every keystroke, because a single toggle in
a static buffer never meets the erase that broke this."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (dotimes (i 4)
      (goto-char (point-min))
      (search-forward "web")
      (call-interactively #'magit-section-toggle)
      (should (equal (cl-evenp i)
                     (and (oref (magit-current-section) hidden) t)))
      (herdr-dispatch-test--pane-event
       "w1:p1" (if (cl-evenp i) "idle" "working") i)
      (herdr-dispatch-refresh)
      (goto-char (point-min))
      (search-forward "web")
      (should (equal (cl-evenp i)
                     (and (oref (magit-current-section) hidden) t))))))

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
