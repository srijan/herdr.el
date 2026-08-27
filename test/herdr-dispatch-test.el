;;; herdr-dispatch-test.el --- Tests for the dispatcher buffer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-tree)
(require 'herdr-test-helper)

;; Required outright rather than guarded.  These tests used to open with
;; `(when (require 'magit-section nil t) (require 'herdr-dispatch))' and
;; every one of them with a `skip-unless', which made a bare `make test'
;; skip 97 of 325 tests — all of them these — and report success.  It
;; also made a magit-section that failed to load indistinguishable from
;; one that was not installed, so a broken dependency read as a skip.
;; `test/herdr-deps.el' now finds magit-section before any test file is
;; loaded, and fails loudly when it cannot, so there is nothing left
;; here to be conditional about.
(require 'herdr-dispatch)

(defmacro herdr-dispatch-test-with-buffer (nodes &rest body)
  "Render NODES into a temporary dispatcher buffer and run BODY there."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (herdr-dispatch-mode)
     (let ((inhibit-read-only t))
       (magit-insert-section (herdr-root)
         (herdr-dispatch--insert-nodes ,nodes)))
     (goto-char (point-min))
     ,@body))

(defconst herdr-dispatch-test--nodes
  '((herdr-workspace "w1" "herdr.el  /tmp/herdr.el  2 panes"
     ((herdr-panes "w1" "main 2"
       ((herdr-pane "w1:p1" "> claude working w1:p1" nil)
        (herdr-pane "w1:p2" "| codex blocked w1:p2" nil)))
      (herdr-worktree "/tmp/herdr.el-fix" "fix  open as w2" nil)))
    (herdr-workspace "w2" "api  /tmp/api  2 panes"
     ((herdr-pane "w2:p1" "> claude working w2:p1" nil)
      (herdr-pane "w2:p2" "· gemini idle w2:p2" nil))))
  "One workspace of each shape `herdr-tree-build' emits.
`w1' has worktrees, so its own panes sit in a `main (N)' group and the
worktree hangs off the workspace beside it; `w2' has none, so its panes
sit directly under it.  There is no tab level in either —
`herdr-tree-build' never nests a pane under one — so between them every
node type the renderer must handle still appears.")

(defun herdr-dispatch-test--section-at (text)
  "Return the section whose line contains TEXT."
  (goto-char (point-min))
  (search-forward text)
  (magit-current-section))

(defun herdr-dispatch-test--type-at (text)
  "Return the type of the section whose line contains TEXT."
  (oref (herdr-dispatch-test--section-at text) type))

(defun herdr-dispatch-test--face-at (text)
  "Return the face on the first character of the line holding TEXT.
Read off `font-lock-face\\=', which the dashboard writes beside `face\\='
on every faced character; the two are asserted to agree by
`herdr-dispatch-writes-every-face-under-both-properties\\=', which is
also where the reason both exist is written down."
  (herdr-dispatch-test--section-at text)
  (get-text-property (line-beginning-position) 'font-lock-face))

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
  "A workspace without worktrees holds its panes directly; one with them
holds them in the `main' group, which is itself a child of the
workspace.  Either way a pane is inside its own workspace and nothing
else."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p1")
    (should (eq 'herdr-workspace
                (oref (oref (magit-current-section) parent) type)))
    (goto-char (point-min))
    (search-forward "w1:p1")
    (let ((group (oref (magit-current-section) parent)))
      (should (eq 'herdr-panes (oref group type)))
      (should (eq 'herdr-workspace (oref (oref group parent) type)))
      (should (equal "w1" (oref (oref group parent) value))))))

(ert-deftest herdr-dispatch-renders-every-node-type ()
  "Every node type must reach a branch of its own.

The `pcase' in `herdr-dispatch--insert-nodes' has no fallback clause, so
a mistyped branch head — `herdr-worktree' where `herdr-panes' was
meant — drops that node and everything under it without signalling.
herdr-tree-test covers the model emitting these types; this covers the
renderer consuming them, which is the seam such a typo would hide in."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (eq 'herdr-workspace (herdr-dispatch-test--type-at "herdr.el")))
    (should (eq 'herdr-pane      (herdr-dispatch-test--type-at "w1:p1")))
    (should (eq 'herdr-panes     (herdr-dispatch-test--type-at "main 2")))
    (should (eq 'herdr-worktree  (herdr-dispatch-test--type-at "open as w2")))))

(defun herdr-dispatch-test--indent-at (text)
  "Return the leading whitespace width of the line containing TEXT."
  (goto-char (point-min))
  (search-forward text)
  (goto-char (line-beginning-position))
  (skip-chars-forward " ")
  (current-column))

(ert-deftest herdr-dispatch-panes-of-a-two-tab-workspace-render-at-the-same-depth ()
  "The hierarchy has to be visible, not just navigable.

`w2\\=' used to keep its tab level because it had more than one tab;
`herdr-tree-build\\=' no longer nests panes under a tab at all, so both of
`w2\\='s panes must now hang directly off the workspace, indented one
level below its heading and no deeper than each other."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p1")
    (should (eq 'herdr-workspace (oref (oref (magit-current-section) parent)
                                       type)))
    (let ((workspace-indent (herdr-dispatch-test--indent-at "api"))
          (first-pane-indent (herdr-dispatch-test--indent-at "w2:p1"))
          (second-pane-indent (herdr-dispatch-test--indent-at "w2:p2")))
      (should (< workspace-indent first-pane-indent))
      (should (= first-pane-indent second-pane-indent)))))

;;; Headings and leaves

(ert-deftest herdr-dispatch-heads-containers-only ()
  "Only a container gets a heading; a leaf is content.

Every node used to be inserted with `magit-insert-heading', which is why
the buffer read as a wall of same-weight text: `magit-section-heading' on
every line distinguishes nothing, and magit-section treats a heading as
the foldable part of a section, so leaves with nothing to fold were
offered as foldable too.

The `content' slot is the seam.  `magit-insert-heading' is the only thing
that sets it, and everything downstream — the fold indicator, the
heading keymap, `magit-section-content-p' — keys on it, so it is the
assertion that catches a leaf promoted back to a heading no matter how
the promotion is spelled."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (dolist (text '("herdr.el" "api" "main 2"))
      (should (oref (herdr-dispatch-test--section-at text) content)))
    (dolist (text '("w1:p1" "w2:p2" "open as w2"))
      (should-not (oref (herdr-dispatch-test--section-at text) content)))))

(ert-deftest herdr-dispatch-faces-container-headings-and-leaves-differently ()
  "The `content' slot is invisible; the face is what the user reads.

A heading whose face said nothing was the reported problem, so the
difference is asserted where it shows: `magit-section-heading' begins a
container line and does not begin a leaf line."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (dolist (text '("herdr.el" "api" "main 2"))
      (should (eq 'magit-section-heading (herdr-dispatch-test--face-at text))))
    (dolist (text '("w1:p1" "w2:p2" "open as w2"))
      (should-not (eq 'magit-section-heading
                      (herdr-dispatch-test--face-at text))))))

(ert-deftest herdr-dispatch-keeps-a-faced-field-and-still-heads-the-rest ()
  "`magit-insert-heading' faces the whole string, but only if no part of
it is faced already — so one dimmed field in a heading line would
otherwise cost the whole line its heading face.  Both halves are
asserted from one line: the propertised field keeps the face herdr-tree
gave it, and the characters around it read as a heading."
  (herdr-dispatch-test-with-buffer
      (list (list 'herdr-workspace "w1"
                  (concat "repo (1) "
                          (propertize "/tmp/repo" 'font-lock-face 'shadow))
                  nil))
    (goto-char (point-min))
    (should (eq 'magit-section-heading
                (get-text-property (point) 'font-lock-face)))
    (search-forward "/tmp/repo")
    (should (eq 'shadow
                (get-text-property (match-beginning 0) 'font-lock-face)))))

(ert-deftest herdr-dispatch-writes-every-face-under-both-properties ()
  "Every faced character in the dashboard must carry `face' AND
`font-lock-face'.

The two cover each other's blind spot.  `face' is erased by
`font-lock-default-unfontify-region' before a line is first fontified,
which is why the original `face'-only styling was invisible; and
`font-lock-face' is not a display property at all — only a
`char-property-alias-alist' entry `font-lock-mode' installs — so the
`font-lock-face'-only fix that replaced it rendered as nothing wherever
font-lock was off, verified with `face-at-point' answering nil across
the whole buffer.  magit sets both.

Batch cannot see either failure: `font-lock-mode' refuses to enable
itself under `noninteractive', so 302 tests passed over a completely
unstyled dashboard.  The properties are what batch can see.

Both sources of a face are covered — the fields herdr-tree propertised,
and the heading face `herdr-dispatch--heading' paints into the gaps
between them — because they are written by different code and were
wrong independently.  The scan walks every character rather than
sampling, so a gap-filler that wrote one property and a field that wrote
the other would both be caught."
  (herdr-dispatch-test-with-buffer
      (list (list 'herdr-workspace "w1"
                  (concat "repo (1)  "
                          (herdr-tree--faced "/tmp/repo"
                                             'font-lock-comment-face))
                  (list (list 'herdr-pane "w1:p1"
                              (concat (herdr-tree--faced "blocked" 'warning)
                                      "  "
                                      (herdr-tree--faced "w1:p1" 'shadow))
                              nil))))
    (let ((faced 0))
      (goto-char (point-min))
      (while (not (eobp))
        (unless (eolp)
          (let ((font-lock (get-text-property (point) 'font-lock-face))
                (face (get-text-property (point) 'face)))
            (when (or font-lock face)
              (setq faced (1+ faced))
              (should (eq font-lock face)))))
        (forward-char 1))
      ;; A buffer with nothing faced would satisfy the loop above.
      (should (> faced 0)))
    ;; Named explicitly as well, so that a change which faced only the
    ;; heading gaps — or only the fields — cannot pass by weight of the
    ;; other's characters.
    (goto-char (point-min))
    (should (eq 'magit-section-heading (get-text-property (point) 'face)))
    (search-forward "/tmp/repo")
    (should (eq 'font-lock-comment-face
                (get-text-property (match-beginning 0) 'face)))
    (goto-char (point-min))
    (search-forward "blocked")
    (should (eq 'warning (get-text-property (match-beginning 0) 'face)))))

(ert-deftest herdr-dispatch-faces-survive-being-fontified ()
  "A face has to be written where fontification will not delete it.

`magit-section-mode\\=' sets `font-lock-defaults\\=', so
`global-font-lock-mode\\=' — on by default — turns `font-lock-mode\\=' on in
the dashboard, and the first thing done to a region before it is
fontified is `font-lock-default-unfontify-region\\=', which removes `face\\='
and does not remove `font-lock-face\\='.  Every face in this buffer
therefore used to last exactly as long as it took redisplay to reach the
line: drawn correctly, then repainted in the default face.  No test
caught it, because they all read the property back in the same instant
it was written, which is the one moment it is still there.

The control is what makes this test mean anything.  A field faced with
`face\\=' is rendered beside the others and asserted to LOSE its face —
without that, this test would pass just as happily in a buffer where
fontification never ran at all, which is the failure mode of every test
that tries to prove something about redisplay in batch.

The dashboard now writes `face\\=' as well, and the `face\\=' it writes is
erased here too — asserted below, because that is the fact that makes
the pair necessary rather than redundant.  Neither property survives
both situations: `font-lock-face\\=' is what renders once font-lock has
run, `face\\=' is what renders while it has not."
  (let ((buffer (generate-new-buffer "herdr-fontification-test")))
    (unwind-protect
        (with-current-buffer buffer
          (herdr-dispatch-mode)
          (font-lock-mode 1)
          (let ((inhibit-read-only t))
            (magit-insert-section (herdr-root)
              (herdr-dispatch--insert-nodes
               (list
                (list 'herdr-workspace "w1"
                      (concat "repo (1)  "
                              (herdr-tree--faced "/tmp/repo"
                                                 'font-lock-comment-face))
                      (list (list 'herdr-pane "w1:p1"
                                  (concat (herdr-tree--faced "blocked"
                                                             'warning)
                                          "  "
                                          (propertize "CONTROL"
                                                      'face 'shadow))
                                  nil)))))))
          (goto-char (point-min))
          (should (search-forward "CONTROL" nil t))
          (should (eq 'shadow (get-text-property (match-beginning 0) 'face)))
          (font-lock-ensure)
          ;; The control proves fontification reached these lines.
          (goto-char (point-min))
          (search-forward "CONTROL")
          (should-not (get-text-property (match-beginning 0) 'face))
          ;; Everything herdr draws is still there.
          (goto-char (point-min))
          (should (eq 'magit-section-heading
                      (get-text-property (point) 'font-lock-face)))
          (search-forward "/tmp/repo")
          (should (eq 'font-lock-comment-face
                      (get-text-property (match-beginning 0) 'font-lock-face)))
          (goto-char (point-min))
          (search-forward "blocked")
          (should (eq 'warning
                      (get-text-property (match-beginning 0)
                                         'font-lock-face)))
          ;; And our own `face' went the same way the control's did,
          ;; which is why `font-lock-face' has to be there beside it.
          (should-not (get-text-property (match-beginning 0) 'face))
          (goto-char (point-min))
          (should-not (get-text-property (point) 'face)))
      (kill-buffer buffer))))

(ert-deftest herdr-dispatch-gives-every-node-its-own-section ()
  "Presentation changed; resolution did not.

A leaf that stopped being a heading must not stop being a section: every
verb in this buffer resolves the object under point by walking up from
`magit-current-section', so a pane row folded into its workspace's
section would answer `RET', `k' and `R' with the workspace.  Type and
value are checked for all four node types, leaves included, because that
pair is the entire interface the verbs have to the tree."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (dolist (spec '(("herdr.el"    herdr-workspace "w1")
                    ("w1:p1"       herdr-pane      "w1:p1")
                    ("w2:p2"       herdr-pane      "w2:p2")
                    ("main 2"      herdr-panes     "w1")
                    ("open as w2"  herdr-worktree  "/tmp/herdr.el-fix")))
      (let ((section (herdr-dispatch-test--section-at (nth 0 spec))))
        (should (eq (nth 1 spec) (oref section type)))
        (should (equal (nth 2 spec) (oref section value)))))))

(ert-deftest herdr-dispatch-separates-top-level-workspaces-with-a-blank-line ()
  "Workspaces are set apart the way magit sets its sections apart.

The gap goes between them rather than after each, so the buffer does not
end in one, and outside the section rather than inside it, so folding a
workspace does not take the gap with it and run the collapsed heading
into the next workspace.  Asserting it sits past the first workspace's
`end' is what says \"outside\"; a blank line printed as the section's
last line would satisfy a test that only looked at the text."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((first (herdr-dispatch-test--section-at "herdr.el")))
      (goto-char (point-min))
      (search-forward "api")
      (forward-line -1)
      (should (looking-at-p "^$"))
      (should (>= (point) (oref first end))))
    ;; Not before the first, and not after the last.
    (goto-char (point-min))
    (should-not (looking-at-p "^$"))
    (should-not (string-match-p "\n\n\\'" (buffer-string)))))

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
next as a workspace mysteriously already asked for.

`herdr-dispatch--known-project-roots\\=' is stubbed to nil for the same
reason project.el must not be: it reads the real `project-list-file\\=' on
whatever machine runs the suite, so an unstubbed test would see a
different known-project list — and, since `herdr-dispatch-refresh\\=' now
fetches worktrees for each one, a different set of `worktree.list\\=' calls
too — in CI than on a contributor's machine with years of project
history.  A test that means to exercise known projects wraps its own body
in a nested `cl-letf\\=' on the same symbol; the inner binding wins for its
extent and this one still restores it afterwards."
  (declare (indent 1) (debug t))
  `(let ((herdr-state--current (herdr-state-from-snapshot ,snapshot))
         (herdr-dispatch--worktrees nil)
         (herdr-dispatch--worktrees-pending nil)
         (herdr-dispatch--worktrees-unanswered nil)
         (herdr-dispatch--worktrees-generation 0)
         (herdr-dispatch--refresh-timer nil)
         (buffer (get-buffer-create herdr-dispatch-buffer-name)))
     (unwind-protect
         (cl-letf (((symbol-function 'herdr-dispatch--known-project-roots)
                    (lambda () nil)))
           (with-current-buffer buffer
             (herdr-dispatch-mode)
             ,@body))
       (herdr-dispatch--cancel-refresh)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

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

(ert-deftest herdr-dispatch-schedule-refresh-keeps-a-pending-timer ()
  "Sustained traffic must not starve the redraw.

This used to assert the opposite shape — cancel the pending timer, arm
a replacement — and that shape never fired while events kept coming:
the stream's median event gap (0.105s) is shorter than the debounce
(0.2s), so each event pushed the redraw past the next event and the
dashboard stayed stale for exactly as long as something was happening
on it.  Now the first event of a burst arms the one timer and later
events leave it alone, so staleness is bounded by the debounce rather
than by the length of the burst.

The rebuild-counting tests cannot see this either way — a starved
timer eventually fires once when the stream quiets, and one rebuild is
what they count.  So the timer discipline itself is what is asserted:
a second and third schedule against a pending timer arm nothing and
cancel nothing."
  (let ((cancelled nil) (armed 0))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (intern (format "timer%d" (cl-incf armed)))))
              ((symbol-function 'cancel-timer)
               (lambda (timer) (push timer cancelled))))
      (let ((herdr-dispatch--refresh-timer nil))
        (herdr-dispatch--schedule-refresh)
        (should (eq 'timer1 herdr-dispatch--refresh-timer))
        (herdr-dispatch--schedule-refresh)
        (herdr-dispatch--schedule-refresh)
        (should (eq 'timer1 herdr-dispatch--refresh-timer))
        (should (= 1 armed))
        (should-not cancelled)))))

(ert-deftest herdr-dispatch-refresh-hook-cancels-its-timer-with-the-buffer ()
  "A pending redraw must not outlive the buffer it would draw into."
  (let ((herdr-state-change-functions (list #'herdr-dispatch--refresh-hook))
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
                            herdr-state-change-functions)))
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
  "One pane line has to answer for its workspace as well."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p2")
    (should (equal "w2:p2" (herdr-dispatch--value-at-point 'herdr-pane)))
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
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (herdr-dispatch--protect
       (lambda () (signal 'herdr-error (list "busy" "pane is busy")))))
    (should (string-match-p "busy" (car messages)))
    (should (equal '("herdr: pane is busy [busy]") messages))))

(ert-deftest herdr-dispatch-protect-passes-a-result-through ()
  "Protection must not cost the return value of the command it wraps."
  (should (equal 42 (herdr-dispatch--protect (lambda () 42)))))

(ert-deftest herdr-dispatch-protect-reconciles-a-stale-cache-before-reporting ()
  "`not_found' usually means the cache is stale, so it is corrected first.

Asserting only that some message appeared would pass against a wrapper
that reported and left the dead pane on screen, which is the failure
this branch exists to prevent — hence the ordering assertion."
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
      (herdr-pane-focus herdr-workspace-focus herdr-dispatch-open-worktree)
    (herdr-dispatch-visit)))

(ert-deftest herdr-dispatch-visit-goes-to-the-thing-at-point ()
  "Each line type reaches its own command, innermost first.

A pane line sits inside a workspace, and a worktree line inside one too,
so a resolver checked in the wrong order would focus the workspace from
both and still look like it worked.  Two panes from different workspaces
are checked, so a resolver that always answers the first pane still
looks wrong."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (equal '((herdr-pane-focus "w1:p2"))
                   (herdr-dispatch-test--visit-from "w1:p2")))
    (should (equal '((herdr-dispatch-open-worktree))
                   (herdr-dispatch-test--visit-from "open as w2")))
    (should (equal '((herdr-pane-focus "w2:p1"))
                   (herdr-dispatch-test--visit-from "w2:p1")))
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
      (herdr-rpc-call herdr-pane-focus herdr-workspace-focus)
    (herdr-dispatch-focus)))

(ert-deftest herdr-dispatch-focus-stays-in-emacs ()
  "Focusing calls the server directly rather than the following commands.

`herdr-pane-focus' and friends move Emacs as well; `f' is the verb for
when you want the terminal to move and Emacs to stay put, so it must not
be implemented in terms of them.  Two panes from different workspaces are
checked alongside a workspace, so a resolver that always answers the
same pane still looks wrong."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (should (equal '((herdr-rpc-call "pane.focus" ((pane_id . "w1:p2"))))
                   (herdr-dispatch-test--focus-from "w1:p2")))
    (should (equal '((herdr-rpc-call "pane.focus" ((pane_id . "w2:p1"))))
                   (herdr-dispatch-test--focus-from "w2:p1")))
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
                       (is_linked_worktree . t)
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
                       (is_linked_worktree . t)
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

(ert-deftest herdr-dispatch-fetches-worktrees-for-known-projects-too ()
  "The known-project sibling of the once-per-workspace guarantee above: a
root with no workspace open still gets its own worktrees fetched, the
same way an open workspace's do, and still only once."
  (herdr-dispatch-test-in-dispatcher herdr-dispatch-test--worktree-snapshot
    (cl-letf (((symbol-function 'herdr-dispatch--known-project-roots)
               (lambda () '("/tmp/known-a/" "/tmp/known-b/"))))
      (herdr-dispatch-test-with-async
        (herdr-dispatch-refresh t)
        (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/known-a/" "/tmp/known-b/")
                       (herdr-dispatch-test--requested)))
        (dotimes (_ 19) (herdr-dispatch-refresh))
        (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/known-a/" "/tmp/known-b/")
                       (herdr-dispatch-test--requested)))))))

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
        (should-not (string-match-p "feat/x" (buffer-string)))
        (should-not (string-match-p "main (" (buffer-string)))
        (herdr-dispatch-test--reply
         0 '((worktrees . (((path . "/tmp/web-feat")
                            (is_linked_worktree . t)
                            (branch . "feat/x")
                            (open_workspace_id . nil))))))
        (sit-for 0.2)
        (should (string-match-p "main (" (buffer-string)))
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
                                               (is_linked_worktree . t)
                                               (branch . "feat/x"))))))
                           (herdr-dispatch-test--reply
                            1 '((worktrees . (((path . "/tmp/api-spike")
                                               (is_linked_worktree . t)
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
       1 '((worktrees . (((path . "/tmp/api-spike")
                          (is_linked_worktree . t) (branch . "spike"))))))
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
       1 '((worktrees . (((path . "/tmp/api-spike")
                          (is_linked_worktree . t) (branch . "spike"))))))
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

`herdr-dispatch--fetch-worktrees' arms `herdr-rpc-timeout', so a request
that goes unanswered does eventually come back as an error — but only
after that timeout, and until it does the pending marker stays set, which
is exactly what stops the workspace being asked again.  This test stands
in that window: the reply is simply never delivered, so the workspace
shows no worktrees and no keystroke may have to wait the timeout out.
\\[herdr-dispatch-refresh] has to be able to break that, which means
clearing the pending set and not merely the cache.

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
`herdr-state-change-functions' when the dashboard dies, so a worktree created
between closing the dashboard and reopening it is one nothing hears
about.  \\[herdr-dispatch-refresh] is no cure — it re-asks the
workspaces that could not be answered, not the ones that were — so
without this the answer would outlive its truth with nothing able to
correct it.

Returning to a dashboard that is already open is the other half, and it
must not forget: that would make every invocation of the command a full
refetch of the session."
  (let ((herdr-state--current
         (herdr-state-from-snapshot herdr-dispatch-test--worktree-snapshot))
        (herdr-state-change-functions nil)
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
           0 '((worktrees . (((path . "/tmp/web-feat")
                              (is_linked_worktree . t) (branch . "feat/x"))))))
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
  (let ((herdr-dispatch--worktrees '(("w1" . (ignored))))
        (herdr-dispatch--worktrees-pending '("w2"))
        (herdr-dispatch--worktrees-unanswered '(("w3" . error)))
        (herdr-dispatch--worktrees-generation 7))
    (herdr-dispatch--invalidate-worktrees "worktree_created" nil)
    (should-not herdr-dispatch--worktrees)
    (should-not herdr-dispatch--worktrees-pending)
    (should-not herdr-dispatch--worktrees-unanswered)
    (should (equal 8 herdr-dispatch--worktrees-generation))))

(ert-deftest herdr-dispatch-closing-a-workspace-drops-the-cache ()
  "A worktree listing must not outlive the workspaces it describes.

`workspace_closed' did not invalidate anything, so a closed workspace's
entry sat in the cache for the rest of the session — and
`herdr-dispatch--worktree-at-point' flattens every cached listing
together before searching it, so that dead entry could still supply the
record a worktree row resolved to.

The sibling entry is asserted gone as well, and that is the half that
says why this drops the whole cache rather than one entry.  Every other
workspace's listing carries `open_workspace_id' for the workspace that
just closed: `w2' here still claims a worktree is \"open as w1\".
Dropping only `w1' would leave that claim standing, on a row a user
would then press RET on."
  (let ((herdr-dispatch--worktrees
         '(("w1" . (((path . "/tmp/gone") (is_linked_worktree . t))))
           ("w2" . (((path . "/tmp/sibling") (is_linked_worktree . t)
                     (open_workspace_id . "w1"))))))
        (herdr-dispatch--worktrees-pending '("w3"))
        (herdr-dispatch--worktrees-unanswered '(("w4" . error)))
        (herdr-dispatch--worktrees-generation 7))
    (herdr-dispatch--invalidate-worktrees "workspace_closed"
                                          '((workspace_id . "w1")))
    (should-not (assoc "w1" herdr-dispatch--worktrees))
    (should-not (assoc "w2" herdr-dispatch--worktrees))
    (should-not herdr-dispatch--worktrees-pending)
    (should-not herdr-dispatch--worktrees-unanswered)
    ;; Requests already on the wire have to be abandoned too, or one
    ;; lands afterwards and writes the entry straight back.
    (should (equal 8 herdr-dispatch--worktrees-generation))))

(ert-deftest herdr-dispatch-every-worktree-event-drops-the-cache ()
  "Four events change what worktrees exist or where they are open.

Two of them had a test.  `worktree_opened' and `worktree_removed' did
not, so removing either from the list left the dashboard showing a
worktree that had been removed, or claiming one was not open when it
was, with nothing to say so."
  (dolist (kind '("worktree_created" "worktree_opened"
                  "worktree_removed" "workspace_closed"))
    (let ((herdr-dispatch--worktrees '(("w1" . (ignored))))
          (herdr-dispatch--worktrees-generation 7))
      (herdr-dispatch--invalidate-worktrees kind '((workspace_id . "w1")))
      (should-not herdr-dispatch--worktrees)
      (should (equal 8 herdr-dispatch--worktrees-generation)))))

(ert-deftest herdr-dispatch-worktree-invalidation-unhooks-with-the-buffer ()
  "Left on the hook after the dashboard dies, this goes on dropping a
cache nothing reads and making the next open re-ask for every workspace."
  (let ((herdr-state-change-functions
         (list #'herdr-dispatch--invalidate-worktrees))
        (herdr-dispatch--worktrees nil)
        (herdr-dispatch--worktrees-generation 0)
        (buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (unwind-protect
        (progn
          (herdr-dispatch--invalidate-worktrees "pane_updated" nil)
          (should (memq #'herdr-dispatch--invalidate-worktrees
                        herdr-state-change-functions))
          (kill-buffer buffer)
          (herdr-dispatch--invalidate-worktrees "pane_updated" nil)
          (should-not (memq #'herdr-dispatch--invalidate-worktrees
                            herdr-state-change-functions)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest herdr-dispatch-opening-a-fresh-dashboard-forgets-old-worktrees ()
  "Worktree knowledge belongs to an open dashboard.

While the buffer is gone nothing is on the hook to invalidate, so a
worktree created in the meantime is one this cache never hears about,
and \\[herdr-dispatch-refresh] is no cure — it re-asks the workspaces
that could not be answered, not the ones that were.  So opening starts
from none.  Reopening a dashboard that is already up must not forget,
or every visit pays for a full re-fetch."
  (let ((herdr-state-change-functions nil))
    (cl-letf (((symbol-function 'herdr-dispatch-refresh) #'ignore)
              ((symbol-function 'pop-to-buffer) #'ignore))
      (let ((buffer (get-buffer herdr-dispatch-buffer-name)))
        (when buffer (kill-buffer buffer)))
      (let ((herdr-dispatch--worktrees '(("w1" . (stale))))
            (herdr-dispatch--worktrees-generation 3))
        (unwind-protect
            (progn
              (herdr-agents)
              (should-not herdr-dispatch--worktrees)
              (should (equal 4 herdr-dispatch--worktrees-generation))
              ;; The buffer it made has to be a dispatcher, or every key
              ;; the dashboard binds lands in fundamental-mode.
              (should (with-current-buffer herdr-dispatch-buffer-name
                        (derived-mode-p 'herdr-dispatch-mode)))
              ;; Already open: reopening keeps what is known.
              (setq herdr-dispatch--worktrees '(("w1" . (fresh))))
              (herdr-agents)
              (should (equal '(("w1" . (fresh))) herdr-dispatch--worktrees))
              (should (equal 4 herdr-dispatch--worktrees-generation)))
          (let ((buffer (get-buffer herdr-dispatch-buffer-name)))
            (when buffer (kill-buffer buffer))))))))

(ert-deftest herdr-dispatch-unrelated-events-keep-the-cache ()
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
  (let ((herdr-state--current
         (herdr-state-from-snapshot herdr-dispatch-test--snapshot))
        (herdr-dispatch--worktrees
         '(("w1" . (((path . "/tmp/web-feat")
                     (is_linked_worktree . t)
                     (branch . "feat/x")
                     (label . "feat/x")
                     (open_workspace_id . nil))))))
        (buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (unwind-protect
        (with-current-buffer buffer
          (herdr-dispatch-mode)
          (herdr-dispatch-refresh)
          (should (string-match-p "main (" (buffer-string)))
          (should (eq 'herdr-panes
                      (herdr-dispatch-test--type-at "main (")))
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

;;; Fold indicators and the current-section highlight

(defun herdr-dispatch-test--fold-glyph (text)
  "Return the fold indicator drawn beside the line holding TEXT, or nil.
The indicator is a margin overlay carrying a `display' property, which is
where the character actually ends up — reading it back out is the only
way to tell a configured indicator from a drawn one."
  (goto-char (point-min))
  (search-forward text)
  (goto-char (line-beginning-position))
  (seq-some (lambda (overlay)
              (when (eq 'margin (overlay-get overlay 'magit-vis-indicator))
                (aref (cadr (get-text-property
                             0 'display (overlay-get overlay 'before-string)))
                      0)))
            (overlays-in (point) (1+ (point)))))

(defun herdr-dispatch-test--hidden-p (text)
  "Return non-nil when the line holding TEXT is invisible on screen."
  (goto-char (point-min))
  (search-forward text)
  (and (invisible-p (point)) t))

(ert-deftest herdr-dispatch-marks-foldable-headings-in-any-frame ()
  "The default indicators are illegible in a graphical frame and absent
from a terminal one.

`magit-section-visibility-indicators' defaults to fringe bitmaps in
graphical frames — off past the window edge, and low-contrast under many
themes — and to an ellipsis appended to collapsed headings in terminal
frames, which marks nothing at all on the expanded ones.  herdr never set
it, so both applied.

A character in the left margin is the one form both frame types can
draw, which is why the same pair is given for each; the margin must have
room for it, or the overlay is silently dropped."
  (herdr-dispatch-test-with-dispatcher
    (should (local-variable-p 'magit-section-visibility-indicators))
    (should (equal (herdr-dispatch--fold-indicators)
                   magit-section-visibility-indicators))
    (should (equal 2 (length magit-section-visibility-indicators)))
    (dolist (pair magit-section-visibility-indicators)
      (should (characterp (car pair)))
      (should (characterp (cdr pair)))
      (should-not (equal (car pair) (cdr pair))))
    (should (> left-margin-width 0))))

(ert-deftest herdr-dispatch-fold-indicators-are-chosen-per-frame-and-settable ()
  "Asking at load time is asking the wrong frame.

`herdr-dispatch-fold-indicators\\=' used to be a `defconst\\=' whose value
came from `char-displayable-p\\=' as the library loaded.  Under
`emacs --daemon\\=' that runs before any frame exists, so the answer is
given for a display nobody is looking at and the ASCII fallback is then
frozen for the whole session — and a `defconst\\=' cannot be customised
out of it either, unlike the magit option it replaces.  The choice is
now made on mode entry, and the user\\='s setting wins outright."
  (herdr-dispatch-test-with-dispatcher
    (let ((herdr-dispatch-fold-indicators '((?+ . ?-) (?+ . ?-))))
      (should (equal '((?+ . ?-) (?+ . ?-)) (herdr-dispatch--fold-indicators)))
      (herdr-dispatch-mode)
      (should (equal '((?+ . ?-) (?+ . ?-))
                     magit-section-visibility-indicators)))
    ;; Nil, the default, still answers with a usable pair.
    (let ((herdr-dispatch-fold-indicators nil))
      (dolist (pair (herdr-dispatch--fold-indicators))
        (should (characterp (car pair)))
        (should (characterp (cdr pair)))))))

(ert-deftest herdr-dispatch-draws-fold-indicators-on-a-fresh-render ()
  "magit writes indicators in `magit-section-show' and
`magit-section-hide' and nowhere else, so a buffer that has only ever
been drawn has none — configuring the option is not the same as showing
one.  A leaf has nothing to fold and must stay unmarked."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (should (equal (cdar (herdr-dispatch--fold-indicators))
                   (herdr-dispatch-test--fold-glyph "web")))
    (should-not (herdr-dispatch-test--fold-glyph "w1:p1"))))

(ert-deftest herdr-dispatch-a-fold-survives-a-redraw-in-full ()
  "The `hidden' slot survived a redraw; nothing else did.

`magit-insert-section' restores the slot from the visibility cache but
never acts on it, so a folded workspace came back with its panes listed
under it while the slot still said it was folded — and the next toggle
therefore appeared to do nothing, because it hid a section the buffer had
already forgotten was open.  The existing fold test reads the slot, which
is exactly the half that was never broken; what is asserted here is the
screen: the panes stay invisible and the heading keeps the collapsed
glyph."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (should-not (herdr-dispatch-test--hidden-p "w1:p1"))
    (goto-char (point-min))
    (search-forward "web")
    (magit-section-hide (magit-current-section))
    (should (herdr-dispatch-test--hidden-p "w1:p1"))
    (should (equal (caar (herdr-dispatch--fold-indicators))
                   (herdr-dispatch-test--fold-glyph "web")))
    (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
    (herdr-dispatch-refresh)
    (should (herdr-dispatch-test--hidden-p "w1:p1"))
    (should (equal (caar (herdr-dispatch--fold-indicators))
                   (herdr-dispatch-test--fold-glyph "web")))))

(ert-deftest herdr-dispatch-highlights-the-section-at-point ()
  "magit-section wires this up itself, and the point is that we add nothing.

`magit-section-mode' puts `magit-section-post-command-hook' on the
buffer-local `post-command-hook', and that calls
`magit-section-update-highlight' after every command; `herdr-dispatch-mode'
derives from it and so inherits the whole arrangement.  Adding a hook of
our own would have been a second highlighter fighting the first.

The hook is asserted because it is the mechanism, and the overlay because
the mechanism has to reach a leaf: a pane row is no longer a heading, and
the highlight faces headings and bodies through different branches of
`magit-section-highlight'."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (should (memq #'magit-section-post-command-hook post-command-hook))
    (goto-char (point-min))
    (search-forward "w1:p2")
    (magit-section-update-highlight t)
    (should (seq-some (lambda (overlay)
                        (eq 'magit-section-highlight
                            (overlay-get overlay 'font-lock-face)))
                      (overlays-at (point))))))

(defun herdr-dispatch-test--highlighted-p ()
  "Return non-nil when a section highlight overlay covers point."
  (and (seq-some (lambda (overlay)
                   (eq 'magit-section-highlight
                       (overlay-get overlay 'font-lock-face)))
                 (overlays-at (point)))
       t))

(defun herdr-dispatch-test--title-event (id title)
  "Fold a `pane_updated' for pane ID carrying TITLE into the cache.
The status is the one `herdr-dispatch-test--snapshot' already gives
`w1:p1', so a sequence of these differs in the title and in nothing
else — which is the whole point, and is not true of an event that
quietly changes the status as well."
  (setq herdr-state--current
        (herdr-state-reduce herdr-state--current "pane_updated"
                            `((pane . ((pane_id . ,id)
                                       (agent . "claude")
                                       (agent_status . "blocked")
                                       (workspace_id . "w1")
                                       (tab_id . "w1:t1")
                                       (terminal_title_stripped . ,title)))))))

(ert-deftest herdr-dispatch-a-redraw-restores-the-section-highlight ()
  "A redraw used to leave the line you were reading unmarked.

The highlight is an overlay on text `erase-buffer' takes away, and
nothing recreates it: magit refreshes it from
`magit-section-post-command-hook', and a redraw driven by the event
stream is not a command.  Verified before this fix — one overlay before,
zero after.

The redraw here is driven by a rendered change rather than by FORCE, and
no command runs between the two assertions, which is the shape the bug
actually had: the dashboard redrawing itself out from under a user who
pressed nothing."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (goto-char (point-min))
    (search-forward "w1:p2")
    (magit-section-update-highlight t)
    (should (herdr-dispatch-test--highlighted-p))
    (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
    (herdr-dispatch-refresh)
    (goto-char (point-min))
    (search-forward "w1:p2")
    (should (herdr-dispatch-test--highlighted-p))))

(ert-deftest herdr-dispatch-a-spinning-title-does-not-force-a-redraw ()
  "The skip has to engage while an agent is working, which is when it matters.

`terminal_title_stripped' carries Claude's animated spinner glyph and
the dashboard renders it, so the tree used to differ on every
`pane_updated' — several a second — and the unchanged-tree skip never
engaged.  That is what made the redraw that destroys the highlight fire
about once a second rather than rarely.

Rebuilds are counted rather than buffer text compared, because a redraw
that lays down the same characters is exactly what is being ruled out.
A real status change is driven afterwards, so this cannot pass by the
refresh having become incapable of redrawing at all."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (herdr-dispatch-test--title-event "w1:p1" "◐ Reviewing the herdr package")
    (herdr-dispatch-refresh)
    (should (equal 0 (herdr-dispatch-test-counting-rebuilds
                       (dolist (glyph '("◑" "◐" "◑" "◐"))
                         (herdr-dispatch-test--title-event
                          "w1:p1" (concat glyph " Reviewing the herdr package"))
                         (herdr-dispatch-refresh)))))
    (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                       (herdr-dispatch-test--title-event
                        "w1:p1" "Reviewing something else entirely")
                       (herdr-dispatch-refresh))))))

(ert-deftest herdr-dispatch-a-spinning-title-does-not-lose-the-highlight ()
  "The other half of the same defect, at the level the user feels it.

`herdr-dispatch-a-redraw-restores-the-section-highlight' covers the
redraws that do happen.  This covers the ones that should not: with the
spinner normalised away, a working agent's stream of `pane_updated'
events costs no redraw at all, so the highlight is never destroyed in
the first place.

The title is established and the buffer drawn before the highlight is
placed, so that the only thing varying afterwards is the glyph.  Both
facts are asserted from the same run — nothing rebuilt, and the
highlight still there — because a test that only counted rebuilds would
pass over a refresh that had stopped drawing anything at all."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-test--title-event "w1:p1" "◐ Reviewing the herdr package")
    (herdr-dispatch-refresh t)
    (goto-char (point-min))
    (search-forward "w1:p2")
    (magit-section-update-highlight t)
    (should (herdr-dispatch-test--highlighted-p))
    (should (equal 0 (herdr-dispatch-test-counting-rebuilds
                       (dolist (glyph '("◑" "◐" "◑" "◐"))
                         (herdr-dispatch-test--title-event
                          "w1:p1" (concat glyph " Reviewing the herdr package"))
                         (herdr-dispatch-refresh)))))
    (should (herdr-dispatch-test--highlighted-p))))

(ert-deftest herdr-dispatch-open-worktree-refuses-what-the-other-verbs-refuse ()
  "RET reached the server on rows every other worktree verb refuses.

`herdr-dispatch-open-worktree' read `open_workspace_id' straight off the
cached record rather than resolving through the checked path, so on a
stale main-checkout row it focused the enclosing workspace — and where
that field was nil it fell through to `worktree.open', a MUTATING call,
against the enclosing workspace's own directory.  The one verb that
reaches the server unguarded was the one that skipped the guard.

Three rows, one per refusal, and `herdr-rpc-call' is recorded in each so
that a refusal arriving after the request went out would not pass.  The
nil-`open_workspace_id' row is the important one: that is the case that
used to take the mutating branch rather than the focusing one."
  (dolist (worktree '(((path . "/tmp/herdr.el-fix")
                       (branch . "main")
                       (is_linked_worktree . nil)
                       (open_workspace_id . "w1"))
                      ((path . "/tmp/herdr.el-fix")
                       (branch . "main")
                       (is_linked_worktree . nil)
                       (open_workspace_id . nil))
                      ((path . "/tmp/herdr.el-fix")
                       (branch . "fix")
                       (is_linked_worktree . t)
                       (open_workspace_id . "w1"))))
    (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
      (let ((herdr-dispatch--worktrees (list (cons "w1" (list worktree)))))
        (search-forward "open as w2")
        (should (equal nil
                       (herdr-dispatch-test-with-recorders
                           (herdr-rpc-call herdr-workspace-focus)
                         (should-error (herdr-dispatch-open-worktree)
                                       :type 'user-error))))))))

(ert-deftest herdr-dispatch-open-worktree-focuses-an-already-open-worktree ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (is_linked_worktree . t)
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
                       (is_linked_worktree . t)
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

;;; Known projects with no workspace open

(ert-deftest herdr-dispatch-live-project-root-p-answers-for-the-filesystem ()
  "project.el remembers a project until told to forget one, and nothing
tells it when a directory is deleted -- so a removed worktree kept an
`Inactive' row for a path that is not there."
  (let ((directory (make-temp-file "herdr-dispatch-test-" t)))
    (unwind-protect
        (progn
          (should (herdr-dispatch--live-project-root-p directory))
          (should-not (herdr-dispatch--live-project-root-p
                       (expand-file-name "gone/" directory))))
      (delete-directory directory t))
    (should-not (herdr-dispatch--live-project-root-p directory))))

(ert-deftest herdr-dispatch-live-project-root-p-trusts-a-remote-root ()
  "`file-directory-p' over TRAMP is a round trip to another machine, and
this runs on every redraw.  A stale row costs a line; a redraw that
blocks on an unreachable host costs the dashboard.  No connection is
attempted here -- `file-remote-p' answers from the name alone."
  (should (herdr-dispatch--live-project-root-p
           "/ssh:nowhere.invalid:/tmp/never-existed/")))

(ert-deftest herdr-dispatch-known-project-roots-drops-a-deleted-directory ()
  "The filter runs where project.el's answer enters the dashboard, so
everything downstream -- the `Inactive' rows and the `worktree.list'
round trip each one would otherwise cost -- sees only live roots."
  (let ((directory (make-temp-file "herdr-dispatch-test-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'project-known-project-roots)
                   (lambda () (list directory
                                    (expand-file-name "gone/" directory)))))
          (should (equal (list directory)
                         (herdr-dispatch--known-project-roots))))
      (delete-directory directory t))))

(defconst herdr-dispatch-test--known-project-nodes
  '((herdr-known-project "/tmp/other-project/" "other-project (0)  /tmp/other-project/" nil))
  "One `herdr-known-project\\=' row, for the tests below.")

(ert-deftest herdr-dispatch-visit-creates-a-workspace-for-a-known-project ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-project-nodes
    (let ((herdr-state--current (herdr-state-empty)))
      (search-forward "other-project (0)")
      (should (equal '((herdr-rpc-call "workspace.create"
                                       ((cwd . "/tmp/other-project/")
                                        (label . "other-project")))
                       (herdr-term-display))
                     (herdr-dispatch-test-with-recorders
                         (herdr-rpc-call herdr-term-display)
                       (herdr-dispatch-visit)))))))

(ert-deftest herdr-dispatch-visit-focuses-rather-than-double-creates ()
  "The row is built only for a root with no workspace open, but the
render can be one poll tick behind by the time RET lands — this is the
same TOCTOU `herdr-state-workspace-for-directory' exists to close, and
the test that would catch losing the check."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-project-nodes
    (let ((herdr-state--current
           (herdr-state-from-snapshot
            '((workspaces . (((workspace_id . "w9"))))
              (panes . (((pane_id . "w9:p1") (workspace_id . "w9")
                         (cwd . "/tmp/other-project"))))))))
      (search-forward "other-project (0)")
      (should (equal '((herdr-rpc-call "workspace.focus"
                                       ((workspace_id . "w9")))
                       (herdr-term-display))
                     (herdr-dispatch-test-with-recorders
                         (herdr-rpc-call herdr-term-display)
                       (herdr-dispatch-visit)))))))

(ert-deftest herdr-dispatch-focus-refuses-a-known-project-and-points-at-ret ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-project-nodes
    (search-forward "other-project (0)")
    (should-error (herdr-dispatch-focus) :type 'user-error)
    (let ((message
           (condition-case err
               (herdr-dispatch-focus)
             (user-error (error-message-string err)))))
      (should (string-match-p "other-project" message))
      (should (string-match-p "RET" message)))))

(ert-deftest herdr-dispatch-rename-refuses-a-known-project ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-project-nodes
    (search-forward "other-project (0)")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-rename herdr-tab-rename
                                          herdr-workspace-rename)
                     (should-error (herdr-dispatch-rename)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-close-refuses-a-known-project ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-project-nodes
    (search-forward "other-project (0)")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-tab-close herdr-workspace-close
                                         herdr-worktree-remove herdr-rpc-call)
                     (should-error (herdr-dispatch-close)
                                   :type 'user-error))))))

(defconst herdr-dispatch-test--known-projects-container-nodes
  '((herdr-known-projects "inactive" "Inactive (2)"
     ((herdr-known-project "/tmp/a/" "a (0)  /tmp/a/" nil)
      (herdr-known-project "/tmp/b/" "b (0)  /tmp/b/" nil))))
  "One `herdr-known-projects\\=' container holding two rows.")

(ert-deftest herdr-dispatch-close-refuses-the-inactive-heading ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-projects-container-nodes
    (search-forward "Inactive (2)")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-tab-close herdr-workspace-close
                                         herdr-worktree-remove herdr-rpc-call)
                     (should-error (herdr-dispatch-close)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-rename-refuses-the-inactive-heading ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-projects-container-nodes
    (search-forward "Inactive (2)")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-rename herdr-tab-rename
                                          herdr-workspace-rename)
                     (should-error (herdr-dispatch-rename)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-focus-refuses-the-inactive-heading ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-projects-container-nodes
    (search-forward "Inactive (2)")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-rpc-call herdr-pane-focus herdr-tab-focus
                                       herdr-workspace-focus)
                     (should-error (herdr-dispatch-focus)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-visit-refuses-the-inactive-heading ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-projects-container-nodes
    (search-forward "Inactive (2)")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-focus herdr-tab-focus herdr-workspace-focus
                                         herdr-rpc-call)
                     (should-error (herdr-dispatch-visit)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-inactive-heading-folds-and-has-no-gap-between-its-rows ()
  "The container is what removes the blank line: only top-level siblings
get one from `herdr-dispatch--insert-nodes', and inside `Inactive (N)'
these rows are children of it, not siblings of the workspaces above."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--known-projects-container-nodes
    (goto-char (point-min))
    (should (herdr-dispatch-test--section-at "Inactive (2)"))
    (search-forward "a (0)")
    (let ((after-a (line-end-position)))
      (forward-line 1)
      (should (looking-at-p "\\s-*b (0)"))
      (should (= after-a (1- (point)))))))

(ert-deftest herdr-dispatch-binds-question-mark-to-the-transient ()
  (should (eq #'herdr-transient
              (lookup-key herdr-dispatch-mode-map "?"))))

;;; Rename

(ert-deftest herdr-dispatch-rename-dispatches-on-section-type ()
  (let ((called nil))
    (cl-letf (((symbol-function 'herdr-pane-rename)
               (lambda (label id) (setq called (list 'pane label id))))
              ((symbol-function 'read-string) (lambda (&rest _) "new")))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "w1:p1")
        (herdr-dispatch-rename)
        (should (equal '(pane "new" "w1:p1") called))))))

(ert-deftest herdr-dispatch-rename-on-a-workspace-renames-the-workspace ()
  (let ((called nil))
    (cl-letf (((symbol-function 'herdr-workspace-rename)
               (lambda (label id) (setq called (list 'workspace label id))))
              ((symbol-function 'read-string) (lambda (&rest _) "new")))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "herdr.el")
        (herdr-dispatch-rename)
        (should (equal '(workspace "new" "w1") called))))))

(ert-deftest herdr-dispatch-rename-prefers-the-pane-over-its-workspace ()
  "A pane nested under a workspace must still rename the pane: `w2:p1\\='
has both ancestors, which distinguishes a `cond\\=' that checks the
workspace first from one that checks the pane first."
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

(ert-deftest herdr-dispatch-close-prefers-the-pane-over-its-workspace ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p1")
    (should (equal '((herdr-pane-close "w2:p1"))
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
                       (is_linked_worktree . t)
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
                       (is_linked_worktree . t)
                       (branch . "fix")
                       (open_workspace_id . nil)))))))
      (search-forward "open as w2")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-tab-close herdr-workspace-close
                                           herdr-worktree-remove herdr-rpc-call)
                       (should-error (herdr-dispatch-close)
                                     :type 'user-error)))))))

(ert-deftest herdr-dispatch-close-refuses-a-row-naming-the-main-checkout ()
  "The destructive case, guarded a second time at the verb.

`worktree.list' returns the repository's own checkout with
`open_workspace_id' set to the enclosing workspace, so `k' on such a row
resolved to `(herdr-worktree-remove \"w1\")' — the workspace the row
lives inside.  The model no longer renders these rows at all, which is
the fix; this asserts what happens if one is reached anyway, from a
cache entry that predates the filter or a reply missing the required
field.

The fixture is the live shape exactly: the row sits inside `w1' and its
`open_workspace_id' is `w1'.  A guard that only checked
`open_workspace_id' for nil would let this straight through, which is
how the bug survived the previous fix."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (is_linked_worktree . nil)
                       (branch . "main")
                       (open_workspace_id . "w1")))))))
      (search-forward "open as w2")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-tab-close herdr-workspace-close
                                           herdr-worktree-remove herdr-rpc-call)
                       (should-error (herdr-dispatch-close)
                                     :type 'user-error)))))))

(ert-deftest herdr-dispatch-close-refuses-a-row-naming-its-own-workspace ()
  "A linked worktree opened as a workspace lists itself, and `k' on that
row removed the workspace it is nested under.

This is the shape `herdr-tree-own-workspace-p' describes, and this
package's own RET is what creates it.  `is_linked_worktree' is true
here, so the main-checkout guard does not fire — this row is a real
worktree, and it is also this section's own workspace."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/herdr.el-fix")
                       (is_linked_worktree . t)
                       (branch . "fix")
                       (open_workspace_id . "w1")))))))
      (search-forward "open as w2")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-tab-close herdr-workspace-close
                                           herdr-worktree-remove herdr-rpc-call)
                       (should-error (herdr-dispatch-close)
                                     :type 'user-error)))))))

(ert-deftest herdr-dispatch-close-refuses-a-row-with-no-cached-record ()
  "A row whose record cannot be found must say so, not misdiagnose itself.

The checks read fields off the record, so the missing-record case has to
come first.  Run second, it reads them off nil and announces — with
every appearance of confidence — that the row is the repository's own
checkout, which is a different problem with a different fix."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-dispatch--worktrees
           '(("w1" . (((path . "/tmp/somewhere-else")
                       (is_linked_worktree . t)
                       (branch . "other")))))))
      (search-forward "open as w2")
      (let ((message (cadr (should-error (herdr-dispatch--checked-worktree-at-point)
                                         :type 'user-error))))
        (should (string-match-p "no worktree listing" message))
        (should-not (string-match-p "own checkout" message))))))

(ert-deftest herdr-dispatch-close-refuses-a-line-with-nothing-on-it ()
  (herdr-dispatch-test-with-buffer nil
    (should-error (herdr-dispatch-close) :type 'user-error)))

;;; The main group heading

(ert-deftest herdr-dispatch-close-refuses-the-main-heading ()
  "`k' on `main (N)' must not close the enclosing workspace.

There was no `cond' arm for `herdr-worktrees', and
`herdr-dispatch--value-at-point' walks up from point, so the verb did
not fail — it found `w1' and closed it.  Nothing may reach the server,
which is what tells a refusal apart from a fall-through that happened to
be harmless."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "main 2")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-tab-close herdr-workspace-close
                                         herdr-worktree-remove herdr-rpc-call)
                     (should-error (herdr-dispatch-close)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-rename-refuses-the-main-heading ()
  "`R' on `main (N)' must not rename the enclosing workspace, giving
the workspace a name the user had aimed at a group of its panes."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "main 2")
    (should (equal nil
                   (cl-letf (((symbol-function 'read-string)
                              (lambda (&rest _) "new")))
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-rename herdr-tab-rename
                                            herdr-workspace-rename)
                       (should-error (herdr-dispatch-rename)
                                     :type 'user-error)))))))

(ert-deftest herdr-dispatch-focus-refuses-the-main-heading ()
  "`f' on `main (N)' must not focus the enclosing workspace, which
moves the user's terminal to somewhere they did not ask to go."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "main 2")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-rpc-call herdr-pane-focus herdr-tab-focus
                                       herdr-workspace-focus)
                     (should-error (herdr-dispatch-focus)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-visit-refuses-the-main-heading ()
  "`RET' on `main (N)' must not focus and follow the enclosing
workspace.

Refusing is a decision rather than an omission: there is no server-side
object under this heading to go to, and sending `RET' to the enclosing
workspace would be the old fall-through dressed up as an answer.  The
message points at TAB, which is the heading's one real action."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "main 2")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-focus herdr-tab-focus herdr-workspace-focus
                                         herdr-rpc-call)
                     (should-error (herdr-dispatch-visit)
                                   :type 'user-error))))
    (should (string-match-p
             "TAB"
             (cadr (should-error (herdr-dispatch--refuse-heading "x")
                                 :type 'user-error))))))

(defconst herdr-dispatch-test--nested-nodes
  '((herdr-workspace "w1" "herdr.el  /tmp/herdr.el  1 pane"
     ((herdr-panes "w1" "main 1"
       ((herdr-pane "w1:p1" "> claude working w1:p1" nil)))
      (herdr-workspace "w2" "project-el  /tmp/herdr.el-feat  1 pane"
       ((herdr-pane "w2:p1" "- shell idle w2:p1" nil))))))
  "The shape `herdr-tree-build' emits for a worktree open as a workspace.
`w2' is a child of `w1' rather than a sibling, and `w1''s own panes sit
in the `main' group beside it -- so a pane has a heading or a second
workspace above it either way.")

(ert-deftest herdr-dispatch-close-closes-a-pane-inside-a-nested-workspace ()
  "The heading arms used to walk up, and a pane two levels inside a
worktrees section found that heading before its own arm was reached: `k'
on an agent running in a worktree answered \"a group of worktrees cannot
be closed\" and touched nothing.  Point is on the pane, so the pane is
what closes."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nested-nodes
    (search-forward "w2:p1")
    (should (equal '((herdr-pane-close "w2:p1"))
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-workspace-close
                                         herdr-worktree-remove)
                     (herdr-dispatch-close))))))

(ert-deftest herdr-dispatch-close-closes-a-nested-workspace-itself ()
  "The row is a workspace wherever it is drawn, and closing it must not
reach the repository it is nested under."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nested-nodes
    (search-forward "project-el")
    (should (equal '((herdr-workspace-close "w2"))
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-workspace-close
                                         herdr-worktree-remove)
                     (herdr-dispatch-close))))))

(ert-deftest herdr-dispatch-focus-follows-a-pane-inside-a-nested-workspace ()
  "Every verb shared the walking-up heading arms, so every verb refused
the same rows; `f' is the one whose refusal was silent about what it had
aimed at."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nested-nodes
    (search-forward "w2:p1")
    (should (equal '((herdr-rpc-call "pane.focus" ((pane_id . "w2:p1"))))
                   (herdr-dispatch-test-with-recorders
                       (herdr-rpc-call herdr-pane-focus herdr-workspace-focus)
                     (herdr-dispatch-focus))))))

(ert-deftest herdr-dispatch-still-refuses-the-heading-above-a-nested-workspace ()
  "Aiming the refusal at the section under point rather than at an
ancestor must not stop it firing when point really is on the heading."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nested-nodes
    (search-forward "main 1")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-workspace-close
                                         herdr-worktree-remove herdr-rpc-call)
                     (should-error (herdr-dispatch-close)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-binds-the-mutating-verbs ()
  (should (eq #'herdr-dispatch-rename
              (lookup-key herdr-dispatch-mode-map "R")))
  (should (eq #'herdr-dispatch-close
              (lookup-key herdr-dispatch-mode-map "k")))
  (dolist (verb '(herdr-dispatch-rename herdr-dispatch-close))
    (should (commandp verb))))

;;; Create

(ert-deftest herdr-dispatch-create-pane-creates-a-tab-in-the-workspace-at-point ()
  "tab.create takes a workspace_id rather than a pane to split into."
  (let ((params nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_method p) (setq params p) nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "w1:p2")
        (herdr-dispatch-create-pane)
        (should (equal "w1" (alist-get 'workspace_id params)))
        (should (eq t (alist-get 'focus params)))))))

(ert-deftest herdr-dispatch-workspace-target-resolves-a-pane-through-its-own-record ()
  "A pane row is not always nested under a `herdr-workspace\\=' section —
the agents buffer can list panes on their own — so the fallback has to
consult the pane's own `workspace_id\\=' rather than assume nesting."
  (let ((herdr-state--current
         (herdr-state-from-snapshot
          '((panes . (((pane_id . "w9:p1") (workspace_id . "w9"))))))))
    (herdr-dispatch-test-with-buffer
        '((herdr-pane "w9:p1" "orphan pane w9:p1" nil))
      (search-forward "w9:p1")
      (should (equal "w9" (herdr-dispatch--workspace-target))))))

(ert-deftest herdr-dispatch-create-reads-transient-arguments ()
  (should (equal "main" (herdr-dispatch--arg '("--base=main") "--base")))
  (should-not (herdr-dispatch--arg '("--base=main") "--label")))

(ert-deftest herdr-dispatch-create-worktree-omits-an-empty-base ()
  "An empty --base means \"off the current ref\"; `herdr-worktree-create's
own contract (see herdr-cmd-test.el) is that a blank string must not
reach the server as one.  `herdr-dispatch-create-worktree' calls
`herdr-rpc-call\\=' directly rather than through that command, so the
same contract has to be reasserted here rather than inherited."
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

;;; Starting an agent from anywhere in the tree

(defconst herdr-dispatch-test--start-nodes
  '((herdr-workspace "w1" "herdr.el  /tmp/herdr.el  3 panes"
     ((herdr-pane "w1:p1" "> claude working w1:p1" nil)
      (herdr-pane "w1:p2" "· shell           w1:p2" nil)
      (herdr-pane "w1:p3" "  shell           w1:p3" nil)))
    (herdr-workspace "w2" "api  /tmp/api  2 panes"
     ((herdr-pane "w2:p1" "  shell           w2:p1" nil)
      (herdr-pane "w2:p2" "· gemini idle w2:p2" nil))))
  "A tree holding every case `a\\=' has to answer for.

Every heading encloses no `herdr-tab\\=' section — `herdr-tree-build\\='
never nests a pane under one — which is the case the split-target chain
used to dead-end on for a single-tab workspace like `w1\\='.  Its panes
are, in order, one running a real agent, one adopted as a shell, and one
with no agent.")

(defconst herdr-dispatch-test--start-snapshot
  '((workspaces . (((workspace_id . "w1") (label . "herdr.el"))
                   ((workspace_id . "w2") (label . "api"))))
    (tabs . (((tab_id . "w1:t1") (workspace_id . "w1"))
             ((tab_id . "w2:t1") (workspace_id . "w2"))
             ((tab_id . "w2:t2") (workspace_id . "w2"))))
    (panes . (((pane_id . "w1:p1") (workspace_id . "w1") (tab_id . "w1:t1")
               (agent . "claude") (agent_status . "working"))
              ;; Adopted: no agent is running in it, but `pane.report_agent'
              ;; has put a label on it, and that is what `agent.start'
              ;; refuses.
              ((pane_id . "w1:p2") (workspace_id . "w1") (tab_id . "w1:t1")
               (agent . "shell") (agent_status . "idle"))
              ((pane_id . "w1:p3") (workspace_id . "w1") (tab_id . "w1:t1"))
              ((pane_id . "w2:p1") (workspace_id . "w2") (tab_id . "w2:t1"))
              ((pane_id . "w2:p2") (workspace_id . "w2") (tab_id . "w2:t2")
               (agent . "gemini")))))
  "The state `herdr-dispatch-test--start-nodes\\=' was drawn from.
Real state rather than mocked accessors, for the reason given in
`herdr-dispatch-create-pane-resolves-a-tab-to-one-of-its-panes\\='.")

(defmacro herdr-dispatch-test-with-start-tree (&rest body)
  "Render the agent-start fixture over its own state and run BODY there."
  (declare (indent 0) (debug t))
  `(let ((herdr-state--current
          (herdr-state-from-snapshot herdr-dispatch-test--start-snapshot)))
     (herdr-dispatch-test-with-buffer herdr-dispatch-test--start-nodes
       ,@body)))

(ert-deftest herdr-dispatch-create-agent-starts-in-a-free-pane-at-point ()
  "A pane with no agent is the one case that needs no new pane, so
nothing may be split when point is on one.  The kind and name come from
the transient's arguments when set, skipping both prompts."
  (let ((calls nil)
        (started nil)
        (transient-current-command 'herdr-dispatch-create))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (method params) (push (cons method params) calls) nil))
              ((symbol-function 'herdr-agent-start)
               (lambda (name kind pane) (setq started (list name kind pane))))
              ((symbol-function 'transient-args)
               (lambda (_) '("--kind=claude" "--label=scout")))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (error "should not prompt for kind")))
              ((symbol-function 'read-string)
               (lambda (&rest _) (error "should not prompt for name"))))
      (herdr-dispatch-test-with-start-tree
        (search-forward "w1:p3")
        (herdr-dispatch-create-agent)
        (should (equal '("scout" "claude" "w1:p3") started))
        (should-not (assoc "pane.split" calls))))))

(ert-deftest herdr-dispatch-create-agent-creates-a-tab-when-the-pane-at-point-is-taken ()
  "`agent.start\\=' refuses any pane carrying a reported agent, which is
the `agent_pane_busy\\=' the user hit by pressing `a\\=' on a `shell*\\=' pane.
So a taken pane is not a target to retry but a reason to create a fresh
tab in its workspace, and the agent starts in the tab's root pane.

Both flavours of taken are checked: a real agent, and an adopted shell
that runs nothing at all.  The second is the reported case and the one a
\"has no agent running\" test would wave through."
  (dolist (pane '("w1:p1" "w1:p2"))
    (let ((workspace-id nil)
          (started nil)
          (transient-current-command 'herdr-dispatch-create))
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (_method params)
                   (setq workspace-id (alist-get 'workspace_id params))
                   '((root_pane . ((pane_id . "w1:p9"))))))
                ((symbol-function 'herdr-agent-start)
                 (lambda (name kind pane) (setq started (list name kind pane))))
                ((symbol-function 'transient-args)
                 (lambda (_) '("--kind=claude" "--label=scout"))))
        (herdr-dispatch-test-with-start-tree
          (search-forward pane)
          (herdr-dispatch-create-agent)
          (should (equal "w1" workspace-id))
          (should (equal '("scout" "claude" "w1:p9") started)))))))

(ert-deftest herdr-dispatch-create-agent-works-on-a-flattened-workspace-heading ()
  "A single-tab workspace is rendered with its tab level dropped, so its
heading encloses no `herdr-tab\\=' section: the workspace id is the
heading's own value, not something resolved through a pane."
  (let ((workspace-id nil)
        (started nil)
        (transient-current-command 'herdr-dispatch-create))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_method params)
                 (setq workspace-id (alist-get 'workspace_id params))
                 '((root_pane . ((pane_id . "w1:p9"))))))
              ((symbol-function 'herdr-agent-start)
               (lambda (name kind pane) (setq started (list name kind pane))))
              ((symbol-function 'transient-args)
               (lambda (_) '("--kind=claude" "--label=scout"))))
      (herdr-dispatch-test-with-start-tree
        (search-forward "herdr.el")
        (herdr-dispatch-create-agent)
        (should (equal "w1" workspace-id))
        (should (equal '("scout" "claude" "w1:p9") started))))))

(ert-deftest herdr-dispatch-create-agent-creates-a-tab-for-the-agent ()
  "The wire is the assertion, because the failure this guards against —
adopting the pane before starting the agent in it — is a call that
should not be made rather than one whose return value would show it.
The whole conversation is the tab creation, the start, and the focus
that surfaces it, with no `pane.report_agent\\=' in between."
  (let ((methods nil)
        (transient-current-command 'herdr-dispatch-create))
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) t))
              ((symbol-function 'transient-args)
               (lambda (_) '("--kind=claude" "--label=scout"))))
      (herdr-test-with-server
          (lambda (req)
            (let ((method (alist-get 'method req)))
              (push method methods)
              (cons (herdr-test-ok
                     req (if (equal method "tab.create")
                             '((type . "tab_created")
                               (root_pane . ((pane_id . "w1:p9"))))
                           '((type . "ok"))))
                    nil)))
        (herdr-dispatch-test-with-start-tree
          (search-forward "w1:p2")
          (herdr-dispatch-create-agent))))
    (should (equal '("tab.create" "agent.start" "pane.focus")
                   (reverse methods)))))

(ert-deftest herdr-dispatch-create-agent-defaults-the-name-to-the-kind ()
  "`agent.start\\=' requires a name, so the prompt cannot be skipped — but
RET must be enough to answer it.  Both halves are checked: the prompt
offers the kind as its default, and a name that comes back empty is
still the kind rather than an empty string on the wire."
  (dolist (answer '(:take-the-default ""))
    (let ((started nil)
          (prompt nil))
      (cl-letf (((symbol-function 'herdr-agent-start)
                 (lambda (name kind pane) (setq started (list name kind pane))))
                ((symbol-function 'transient-args) (lambda (_) nil))
                ((symbol-function 'completing-read) (lambda (&rest _) "codex"))
                ((symbol-function 'read-string)
                 (lambda (given &optional _initial _history default &rest _)
                   (setq prompt given)
                   (if (eq answer :take-the-default) default answer))))
        (herdr-dispatch-test-with-start-tree
          (search-forward "w1:p3")
          (herdr-dispatch-create-agent)
          (should (equal '("codex" "codex" "w1:p3") started))
          (should (string-match-p "codex" prompt)))))))

(ert-deftest herdr-dispatch-create-pane-creates-a-tab-from-a-flattened-workspace-heading ()
  "`herdr-tree\\=' renders a single-tab workspace flattened, dropping the
tab level, so on such a heading there is no `herdr-tab\\=' section
underneath — but `tab.create\\=' needs a workspace id, not a pane, and the
heading is that id directly."
  (let ((params nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_method p) (setq params p) nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore))
      (herdr-dispatch-test-with-start-tree
        (search-forward "herdr.el")
        (herdr-dispatch-create-pane)
        (should (equal "w1" (alist-get 'workspace_id params)))))))

(ert-deftest herdr-dispatch-binds-the-create-verbs ()
  (should (eq #'herdr-dispatch-create
              (lookup-key herdr-dispatch-mode-map "c")))
  (should (eq #'herdr-dispatch-create-workspace
              (lookup-key herdr-dispatch-mode-map "w")))
  (should (eq #'herdr-dispatch-create-pane
              (lookup-key herdr-dispatch-mode-map "n")))
  (should (eq #'herdr-dispatch-create-agent
              (lookup-key herdr-dispatch-mode-map "a")))
  (should (eq #'herdr-dispatch-create-worktree
              (lookup-key herdr-dispatch-mode-map "%")))
  (dolist (verb '(herdr-dispatch-create herdr-dispatch-create-workspace
                                        herdr-dispatch-create-pane
                                        herdr-dispatch-create-agent
                                        herdr-dispatch-create-worktree))
    (should (commandp verb))))

(provide 'herdr-dispatch-test)
;;; herdr-dispatch-test.el ends here
