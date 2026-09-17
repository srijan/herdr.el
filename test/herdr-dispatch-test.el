;;; herdr-dispatch-test.el --- Tests for the dispatcher buffer -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-tree)
(require 'herdr-test-helper)

;; Required outright: a guarded require once let a missing magit-section
;; skip every test here and report success.
(require 'herdr-dispatch)

(defun herdr-dispatch-test--machines (tree)
  "Return the children of TREE\\='s MACHINES container.
The dashboard leads with the attention queue, so the topology sits one
level in rather than at top level."
  (nth 3 (seq-find (lambda (node) (eq 'herdr-machines (nth 0 node))) tree)))

(defun herdr-dispatch-test--in-machines (text)
  "Move point past TEXT inside the MACHINES section.

The queue above lists every agent under its own status heading, so a
bare `search-forward' from point-min finds the queue\\='s copy of a name
first.  These tests mean the topology.

Fixtures built from raw nodes have no MACHINES container and nothing
above them to disambiguate from, so there the search is plain.

Case-sensitively: the header counts \"2 machines\" in lower case, and a
folding search matches that first and then finds the queue below it."
  (goto-char (point-min))
  (let ((case-fold-search nil))
    (when (save-excursion (search-forward "MACHINES" nil t))
      (search-forward "MACHINES")))
  (search-forward text)
  ;; On the row, not past it.  A row whose columns are all empty trims to
  ;; the text searched for, which leaves point at end of line, where
  ;; `magit-current-section\\=' answers with whatever section starts next.
  (goto-char (line-beginning-position)))

(defun herdr-dispatch-test--listing (key)
  "Return the worktree records cached under KEY on the current connection.
The cache holds the whole `worktree.list' reply; this is its array, so a
workspace with an entry but no worktrees still reads as nil here and
`herdr-dispatch--worktrees-answered-p' is what asks about presence."
  (herdr-worktree-listing-worktrees
   (cdr (assoc key (herdr-connection-worktrees (herdr-current-connection))))))

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
  '((herdr-workspace "w1" "herdr.el  main  /tmp/herdr.el"
     ((herdr-pane "w1:p1" "> claude working w1:p1" nil)
      (herdr-pane "w1:p2" "| codex blocked w1:p2" nil)
      (herdr-worktrees "w1" "worktrees (1)"
       ((herdr-worktree "/tmp/herdr.el-fix" "fix  open as w2" nil)))))
    (herdr-workspace "w2" "api  main  /tmp/api"
     ((herdr-pane "w2:p1" "> claude working w2:p1" nil)
      (herdr-pane "w2:p2" "· gemini idle w2:p2" nil))))
  "One workspace of each shape `herdr-tree-build' emits.
Panes hang directly off a workspace in both; `w1' also has a
`worktrees (N)' heading over its other checkouts and `w2' has none, so
between them every node type the renderer must handle appears.")

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
Read off `font-lock-face', which the dashboard writes beside `face'
on every faced character; the two are asserted to agree by
`herdr-dispatch-writes-every-face-under-both-properties', which is
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
  "A pane sits directly inside its own workspace, worktrees or not.
There is no level between them any more: the `main' group that used to
hold the panes of a workspace with worktrees is gone, and the
`worktrees (N)' heading beside them holds checkouts, never panes."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (dolist (pane '("w2:p1" "w1:p1"))
      (goto-char (point-min))
      (search-forward pane)
      (let ((parent (oref (magit-current-section) parent)))
        (should (eq 'herdr-workspace (oref parent type)))))
    (goto-char (point-min))
    (search-forward "w1:p1")
    (should (equal "w1" (oref (oref (magit-current-section) parent) value)))))

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
    (should (eq 'herdr-worktrees (herdr-dispatch-test--type-at "worktrees (1)")))
    (should (eq 'herdr-worktree  (herdr-dispatch-test--type-at "open as w2")))))

(defun herdr-dispatch-test--indent-at (text)
  "Return the leading whitespace width of the line containing TEXT.

Counted in characters rather than with `current-column', which measures
displayed width: a workspace starts collapsed, so its rows are invisible
and every one of them would measure zero."
  (goto-char (point-min))
  (search-forward text)
  (goto-char (line-beginning-position))
  (- (save-excursion (skip-chars-forward " ") (point))
     (line-beginning-position)))

(ert-deftest herdr-dispatch-panes-of-a-two-tab-workspace-render-at-the-same-depth ()
  "The hierarchy has to be visible, not just navigable.

`w2' used to keep its tab level because it had more than one tab;
`herdr-tree-build' no longer nests panes under a tab at all, so both of
`w2's panes must now hang directly off the workspace, indented one
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
    (dolist (text '("herdr.el" "api" "worktrees (1)"))
      (should (oref (herdr-dispatch-test--section-at text) content)))
    (dolist (text '("w1:p1" "w2:p2" "open as w2"))
      (should-not (oref (herdr-dispatch-test--section-at text) content)))))

(ert-deftest herdr-dispatch-faces-container-headings-and-leaves-differently ()
  "The `content' slot is invisible; the face is what the user reads.

A heading whose face said nothing was the reported problem, so the
difference is asserted where it shows: `magit-section-heading' begins a
container line and does not begin a leaf line."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (dolist (text '("herdr.el" "api" "worktrees (1)"))
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

`magit-section-mode' sets `font-lock-defaults', so
`global-font-lock-mode' — on by default — turns `font-lock-mode' on in
the dashboard, and the first thing done to a region before it is
fontified is `font-lock-default-unfontify-region', which removes `face'
and does not remove `font-lock-face'.  Every face in this buffer
therefore used to last exactly as long as it took redisplay to reach the
line: drawn correctly, then repainted in the default face.  No test
caught it, because they all read the property back in the same instant
it was written, which is the one moment it is still there.

The control is what makes this test mean anything.  A field faced with
`face' is rendered beside the others and asserted to LOSE its face —
without that, this test would pass just as happily in a buffer where
fontification never ran at all, which is the failure mode of every test
that tries to prove something about redisplay in batch.

The dashboard now writes `face' as well, and the `face' it writes is
erased here too — asserted below, because that is the fact that makes
the pair necessary rather than redundant.  Neither property survives
both situations: `font-lock-face' is what renders once font-lock has
run, `face' is what renders while it has not."
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
                    ("worktrees (1)" herdr-worktrees "w1")
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
    (panes . (((pane_id . "w1:p1") (agent . "claude")
               (agent_status . "blocked")
               (workspace_id . "w1") (tab_id . "w1:t1"))
              ((pane_id . "w1:p2") (agent . "codex")
               (agent_status . "working")
               (workspace_id . "w1") (tab_id . "w1:t1")))))
  "A session for the refresh tests to drive `herdr-state-current' from.")

(defmacro herdr-dispatch-test-in-dispatcher (snapshot &rest body)
  "Run BODY in a real dispatcher buffer built from SNAPSHOT.
The worktree cache needs no rebinding of its own: it lives in the
connection, and the connection here is a fresh one."
  (declare (indent 1) (debug t))
  `(let ((herdr-connections (herdr-test-connections (herdr-test-connection (herdr-state-from-snapshot ,snapshot))))
         (herdr-dispatch--refresh-timer nil)
         (buffer (get-buffer-create herdr-dispatch-buffer-name)))
     (unwind-protect
         (with-current-buffer buffer
           (herdr-dispatch-mode)
           ,@body)
       (herdr-dispatch--cancel-refresh)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defmacro herdr-dispatch-test--with-worktrees (listings &rest body)
  "Run BODY with the worktree cache seeded to LISTINGS.
The one place a test writes the cache's storage; everything else asks
the cache.  BODY may be preceded by `:pending', `:unanswered' and
`:generation' arguments.

Seeds a fresh connection rather than the one in scope, inheriting its
session cache, so that a test nesting this inside or outside a seeded
session gets the same thing either way."
  (declare (indent 1) (debug t))
  (let ((pending nil) (unanswered nil) (generation 0))
    (while (keywordp (car body))
      (let ((key (pop body)) (value (pop body)))
        (pcase key
          (:pending (setq pending value))
          (:unanswered (setq unanswered value))
          (:generation (setq generation value))
          (_ (error "Unknown worktree seed argument %S" key)))))
    `(let ((herdr-connections (herdr-test-connections (herdr-test-connection
             (herdr-connection-cache (herdr-current-connection))))))
       (setf (herdr-connection-worktrees (herdr-current-connection)) ,listings
             (herdr-connection-worktrees-pending (herdr-current-connection))
             ,pending
             (herdr-connection-worktrees-unanswered (herdr-current-connection))
             ,unanswered
             (herdr-connection-worktrees-generation (herdr-current-connection))
             ,generation)
       ,@body)))

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
  (setf (herdr-connection-cache (herdr-current-connection))
        (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "pane_updated"
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
              (format "1 workspace  2 panes  1%s1%s"
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
    ;; Open it first: a workspace starts folded, so the state worth
    ;; carrying across a redraw is the one the reader chose.
    (herdr-dispatch-test--in-machines "web")
    (magit-section-show (magit-current-section))
    (should-not (oref (magit-current-section) hidden))
    (herdr-dispatch-test--in-machines "w1:p2")
    (let ((ident (magit-section-ident (magit-current-section))))
      ;; No `herdr-worktrees' heading: the fixture has no worktrees.  The
      ;; ident is what point is restored through, so pin it — MACHINES
      ;; included, since the topology sits inside it now.
      (should (equal '((herdr-pane . "w1:p2")
                       (herdr-workspace . "w1")
                       (herdr-machines . "machines") (herdr-root))
                     ident))
      (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
      (should (equal 1 (herdr-dispatch-test-counting-rebuilds
                         (herdr-dispatch-refresh))))
      (should (equal ident (magit-section-ident (magit-current-section))))
      (herdr-dispatch-test--in-machines "web")
      (should-not (oref (magit-current-section) hidden)))))

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
      (setf (herdr-connection-cache (herdr-current-connection))
            (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "pane_created"
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

(ert-deftest herdr-dispatch-refresh-falls-back-to-a-sibling-when-the-row-dies ()
  "Killing the pane under point used to throw point to the end of the
buffer.  `magit-section-goto-successor' lands on a surviving sibling,
else the parent."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (herdr-dispatch-test--in-machines "w1:p2")
    (setf (herdr-connection-cache (herdr-current-connection))
          (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "pane_closed"
                              '((pane_id . "w1:p2"))))
    (herdr-dispatch-refresh)
    (should-not (= (point) (point-max)))
    (should (equal '((herdr-pane . "w1:p1") (herdr-workspace . "w1")
                     (herdr-machines . "machines") (herdr-root))
                   (magit-section-ident (magit-current-section))))))

(ert-deftest herdr-dispatch-refresh-lands-near-a-workspace-that-went-with-its-pane ()
  "Closing the last pane closes the workspace.  The successor walk runs
out of siblings and ancestors of the pane and settles on the workspace
that took the dead one's place, not the header."
  (herdr-dispatch-test-in-dispatcher
      '((workspaces . (((workspace_id . "w1") (label . "web") (pane_count . 1))
                       ((workspace_id . "w2") (label . "api") (pane_count . 1))))
        (panes . (((pane_id . "w1:p1") (agent . "claude") (agent_status . "idle")
                   (workspace_id . "w1"))
                  ((pane_id . "w2:p1") (agent . "codex") (agent_status . "idle")
                   (workspace_id . "w2")))))
    (herdr-dispatch-refresh t)
    (herdr-dispatch-test--in-machines "w1:p1")
    (setf (herdr-connection-cache (herdr-current-connection))
          (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "pane_closed"
                              '((pane_id . "w1:p1"))))
    (setf (herdr-connection-cache (herdr-current-connection))
          (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "workspace_closed"
                              '((workspace_id . "w1"))))
    (herdr-dispatch-refresh)
    ;; Neither end of the buffer, and on a real row: the one that took
    ;; the dead workspace's place, which is what closing a row in a list
    ;; is expected to leave you on.
    (should-not (= (point) (point-max)))
    (should-not (= (point) (point-min)))
    (should (equal '((herdr-workspace . "w2")
                     (herdr-machines . "machines") (herdr-root))
                   (magit-section-ident (magit-current-section))))))

(ert-deftest herdr-dispatch-refresh-skips-the-blank-line-between-rows ()
  "The positional fallback must not land on a separator.

The blank line between two top-level rows belongs to the root section,
so a fallback that stops there leaves the NEXT redraw with a root ident
to restore — and the root starts at the header.  Point crept to the top
of the buffer one redraw after the row it was on died, which is how this
was found in a live session rather than by the first fix.

The workspace here is the last one, so its saved position lands past the
end of the shrunken buffer and the clamp puts point on the trailing
blank line."
  (herdr-dispatch-test-in-dispatcher
      '((workspaces . (((workspace_id . "w1") (label . "web") (pane_count . 1))
                       ((workspace_id . "w2") (label . "api") (pane_count . 1))))
        (panes . (((pane_id . "w1:p1") (agent . "claude") (agent_status . "idle")
                   (workspace_id . "w1"))
                  ((pane_id . "w2:p1") (agent . "codex") (agent_status . "idle")
                   (workspace_id . "w2")))))
    (herdr-dispatch-refresh t)
    (goto-char (point-min))
    (search-forward "w2:p1")
    (goto-char (line-beginning-position))
    (setf (herdr-connection-cache (herdr-current-connection))
          (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "pane_closed"
                              '((pane_id . "w2:p1"))))
    (setf (herdr-connection-cache (herdr-current-connection))
          (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "workspace_closed"
                              '((workspace_id . "w2"))))
    (herdr-dispatch-refresh)
    ;; A real row, not a separator: its ident must be longer than the
    ;; root's, or the next redraw goes to the header.
    (should (cdr (magit-section-ident (magit-current-section))))
    ;; And it survives a second redraw, which is the symptom itself.
    (herdr-dispatch-test--pane-event "w1:p1" "working" 2)
    (herdr-dispatch-refresh)
    (should (cdr (magit-section-ident (magit-current-section))))
    (should-not (= (point) (point-min)))))

(ert-deftest herdr-dispatch-refresh-keeps-point-on-a-blank-line ()
  "Point on a separator must not be dragged to the top of the buffer.

The blank line between two top-level rows belongs to the root section,
and the restore went to that section's start — which is the header.  So
parking point between two workspaces and letting any redraw fire sent it
to the top, with nothing closing and nothing dying.  Redraws fire on
their own: the header carries a status summary, so an agent changing
state is enough.

Predates the closed-pane fix rather than following from it: the original
restore resolved the root ident the same way."
  (herdr-dispatch-test-in-dispatcher
      '((workspaces . (((workspace_id . "w1") (label . "web") (pane_count . 1))
                       ((workspace_id . "w2") (label . "api") (pane_count . 1))))
        (panes . (((pane_id . "w1:p1") (agent . "claude") (agent_status . "idle")
                   (workspace_id . "w1"))
                  ((pane_id . "w2:p1") (agent . "codex") (agent_status . "idle")
                   (workspace_id . "w2")))))
    (herdr-dispatch-refresh t)
    ;; The separator above MACHINES.  Workspaces sit inside it now, and
    ;; only top-level nodes get a blank line between them.
    (goto-char (point-min))
    (let ((case-fold-search nil)) (search-forward "MACHINES"))
    (forward-line -1)
    (goto-char (line-beginning-position))
    (should (looking-at-p "$"))
    (should (eq magit-root-section (magit-current-section)))
    (should-not (= (point) (point-min)))
    (herdr-dispatch-test--pane-event "w1:p1" "working" 2)
    (herdr-dispatch-refresh)
    (should-not (= (point) (point-min)))
    ;; The nearest row below, not the separator: a blank line has no
    ;; identity to restore, and the exact character position cannot
    ;; survive a row above it changing width.  The nearest row below the
    ;; separator is the MACHINES heading now.
    (should (equal '((herdr-machines . "machines") (herdr-root))
                   (magit-section-ident (magit-current-section))))))

(ert-deftest herdr-dispatch-refresh-keeps-point-on-the-header ()
  "The root section is a legitimate place to be — the header line is
inside it — so the walk stopping short of the root must not move point
that was already there."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (goto-char (point-min))
    (should (equal '((herdr-root)) (magit-section-ident (magit-current-section))))
    (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
    (herdr-dispatch-refresh)
    (should (equal '((herdr-root)) (magit-section-ident (magit-current-section))))))

(ert-deftest herdr-dispatch-refresh-falls-back-in-a-window-too ()
  "The window-point half of the restore has the same nil, and the hook
usually fires while the dashboard is not the selected window."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (let ((window (split-window)))
      (unwind-protect
          (progn
            (set-window-buffer window (current-buffer))
            (herdr-dispatch-test--in-machines "w1:p2")
            (set-window-point window (line-beginning-position))
            (goto-char (point-min))
            (setf (herdr-connection-cache (herdr-current-connection))
                  (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "pane_closed"
                                      '((pane_id . "w1:p2"))))
            (herdr-dispatch-refresh)
            (should-not (= (window-point window) (point-max)))
            (should (equal '((herdr-pane . "w1:p1") (herdr-workspace . "w1")
                             (herdr-machines . "machines") (herdr-root))
                           (save-excursion
                             (goto-char (window-point window))
                             (magit-section-ident (magit-current-section))))))
        (delete-window window)))))

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
                               (herdr-dispatch-target-value
                                (herdr-dispatch-target-at-point)))))
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
    (should (equal "w1:p2" (herdr-dispatch-target-value
                            (herdr-dispatch-target-at-point))))
    (should (equal 4 (current-column)))))

;;; What point is on

(ert-deftest herdr-dispatch-target-is-the-innermost-row ()
  "A pane line sits inside a workspace; the pane is what a verb is aimed at."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1:p2")
    (let ((target (herdr-dispatch-target-at-point)))
      (should (eq 'herdr-pane (herdr-dispatch-target-type target)))
      (should (equal "w1:p2" (herdr-dispatch-target-value target)))
      (should (equal "w1" (herdr-dispatch-target-workspace target))))))

(ert-deftest herdr-dispatch-target-carries-its-own-workspace ()
  "One pane line has to answer for its own workspace, not the first drawn."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p2")
    (let ((target (herdr-dispatch-target-at-point)))
      (should (equal "w2:p2" (herdr-dispatch-target-value target)))
      (should (equal "w2" (herdr-dispatch-target-workspace target))))))

(ert-deftest herdr-dispatch-target-prefers-the-innermost-workspace ()
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
    (should (equal "inner"
                   (herdr-dispatch-target-workspace
                    (herdr-dispatch-target-at-point))))))

(ert-deftest herdr-dispatch-target-is-nil-off-every-row ()
  "A line belonging to no herdr section is not a target, and every verb
ends on that arm."
  (herdr-dispatch-test-with-buffer nil
    (should-not (herdr-dispatch-target-at-point))))

(ert-deftest herdr-dispatch-target-of-a-heading-is-the-heading ()
  "The old resolver walked up, so a heading answered as the workspace it
was drawn inside, and every verb had to sit its heading arm above its
workspace arm to notice.  The innermost section is the heading itself,
which is why a `pcase' over the type cannot be mis-ordered."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (goto-char (point-min))
    (search-forward "worktrees (1)")
    (should (eq 'herdr-worktrees
                (herdr-dispatch-target-type (herdr-dispatch-target-at-point))))))

(ert-deftest herdr-dispatch-aimed-at-errors-with-a-specific-message ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "herdr.el")
    (let ((target (herdr-dispatch-target-at-point)))
      (should (equal "herdr: point is not on a pane"
                     (condition-case err
                         (herdr-dispatch--aimed-at target 'herdr-pane "a pane")
                       (user-error (error-message-string err)))))
      (should (equal "w1" (herdr-dispatch--aimed-at target 'herdr-workspace
                                                    "a workspace"))))))

(defvar herdr-dispatch-test--calls nil
  "Calls recorded by `herdr-dispatch-test--recorder', newest first.")

(defun herdr-dispatch-test--recorder (name)
  "Return a function recording each call to it as (NAME . ARGS).
A leading connection is dropped.  These assertions are about which
command ran with which parameters; that a connection was passed at all
is `herdr-rpc-call-refuses-to-guess-a-connection\\='s job."
  (lambda (&rest args)
    (push (cons name (if (herdr-connection-p (car args)) (cdr args) args))
          herdr-dispatch-test--calls)
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
    (let ((calls (herdr-dispatch-test--visit-from "open as w2")))
      (should (equal 1 (length calls)))
      (should (eq 'herdr-dispatch-open-worktree (caar calls)))
      ;; Handed the target already resolved, rather than resolving twice.
      (should (eq 'herdr-worktree
                  (herdr-dispatch-target-type (cadr (car calls))))))
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
  (dolist (verb '(herdr-dispatch-visit herdr-dispatch-prompt
                                       herdr-dispatch-read))
    (should (commandp verb))))

(ert-deftest herdr-dispatch-binds-no-server-side-focus ()
  "`f' focused server-side and deliberately did not move Emacs, which
only means something to a second client watching.  Every pane is its own
Emacs buffer here, and `RET' makes the same call and takes you there."
  (should-not (lookup-key herdr-dispatch-mode-map "f"))
  (should-not (fboundp 'herdr-dispatch-focus)))

;;; Worktrees

(defconst herdr-dispatch-test--worktree-snapshot
  '((workspaces . (((workspace_id . "w1") (label . "web") (pane_count . 1))
                   ((workspace_id . "w2") (label . "api") (pane_count . 1))
                   ((workspace_id . "w3") (label . "empty") (pane_count . 0))))
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
                (lambda (_connection method params callback &optional timeout)
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
      (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
      (should-not (herdr-dispatch-test--listing "w1"))
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
        (should-not (string-match-p "feat/x" (buffer-string)))
        (herdr-dispatch-test--reply
         0 '((worktrees . (((path . "/tmp/web-feat")
                            (is_linked_worktree . t)
                            (branch . "feat/x")
                            (open_workspace_id . nil))))))
        (sit-for 0.2)
        (should (string-match-p "worktrees (" (buffer-string)))
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
      (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
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
      (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
      (should-not (herdr-dispatch-test--listing "w1"))
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
                  (lambda (_connection id &rest _) (push id attempts)))
      (unwind-protect
          (herdr-dispatch-test-with-async
            (herdr-dispatch-refresh t)
            (dotimes (_ 19) (herdr-dispatch-refresh))
            (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w3"))
            (should-not (herdr-dispatch-test--listing "w3"))
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
      (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w3"))
      (setf (herdr-connection-cache (herdr-current-connection))
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
      (herdr-dispatch--invalidate-worktrees (herdr-current-connection) "worktree_created")
      (should-not (herdr-dispatch--worktrees-unanswered (herdr-current-connection)))
      (herdr-dispatch-refresh)
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      (herdr-dispatch-test--reply 0 '((worktrees . (stale))))
      (should-not (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
      (should (herdr-dispatch--worktrees-in-flight-p (herdr-current-connection) "w1"))
      (herdr-dispatch-refresh)
      (should (equal 4 (length herdr-dispatch-test--async)))
      (herdr-dispatch-test--reply 2 '((worktrees . (fresh))))
      (should (equal '(fresh) (herdr-dispatch-test--listing "w1"))))))

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
      (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
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
      (should (herdr-dispatch--worktrees-in-flight-p (herdr-current-connection) "w1"))
      (should (herdr-dispatch--worktrees-in-flight-p (herdr-current-connection) "w2"))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal '("/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      ;; `g'.
      (herdr-dispatch-refresh t)
      (should (equal '("/tmp/web/" "/tmp/api/" "/tmp/web/" "/tmp/api/")
                     (herdr-dispatch-test--requested)))
      ;; The reply nobody was waiting for any more.
      (herdr-dispatch-test--reply 0 '((worktrees . (stale))))
      (should-not (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
      (should (herdr-dispatch--worktrees-in-flight-p (herdr-current-connection) "w1"))
      (dotimes (_ 19) (herdr-dispatch-refresh))
      (should (equal 4 (length herdr-dispatch-test--async)))
      (herdr-dispatch-test--reply 2 '((worktrees . (fresh))))
      (should (equal '(fresh) (herdr-dispatch-test--listing "w1"))))))

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
        (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) id))
        (should-not (herdr-dispatch-test--listing id))
        (should (eq 'error (herdr-dispatch--worktrees-unanswered-reason (herdr-current-connection) id)))
        (should-not (herdr-dispatch--worktrees-in-flight-p (herdr-current-connection) id))))
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
      (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
      (should (eq 'error (herdr-dispatch--worktrees-unanswered-reason (herdr-current-connection) "w1")))
      (should-not (herdr-dispatch--worktrees-in-flight-p (herdr-current-connection) "w1")))))

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
  (herdr-test-with-state (:cache (herdr-state-from-snapshot herdr-dispatch-test--worktree-snapshot))
   (herdr-dispatch-test--with-worktrees '(("w1" . ((worktrees . (stale)))))
    (let* ((herdr-state-change-functions nil) (herdr-dispatch--refresh-timer nil))
    (should-not (get-buffer herdr-dispatch-buffer-name))
    (unwind-protect
        (herdr-dispatch-test-with-async
          (save-window-excursion (herdr-agents))
          (should-not (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
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
                                    (car (herdr-dispatch-test--listing "w1")))))
          (should (equal '("/tmp/web/" "/tmp/api/")
                         (herdr-dispatch-test--requested))))
      (herdr-dispatch--cancel-refresh)
      (when (get-buffer herdr-dispatch-buffer-name)
        (kill-buffer herdr-dispatch-buffer-name)))))))

(ert-deftest herdr-dispatch-worktree-events-drop-the-cache ()
  "Invalidation clears every record of every worktree, not just the cache.

The answers, the questions still outstanding and the failures all go, and
the generation moves so that the outstanding ones cannot come back.
Anything less leaves a workspace that is neither cached, nor pending, nor
asked again."
  (herdr-dispatch-test--with-worktrees '(("w1" . (ignored)))
    :pending '("w2") :unanswered '(("w3" . error)) :generation 7
    (let ((before (herdr-connection-worktrees-generation (herdr-current-connection))))
      (herdr-dispatch--invalidate-worktrees (herdr-current-connection) "worktree_created")
      (should-not (herdr-connection-worktrees (herdr-current-connection)))
      (should-not (herdr-dispatch--worktrees-unanswered (herdr-current-connection)))
      (should-not (equal before (herdr-connection-worktrees-generation (herdr-current-connection)))))))

(ert-deftest herdr-dispatch-closing-a-workspace-drops-the-cache ()
  "A worktree listing must not outlive the workspaces it describes.

`workspace_closed' did not invalidate anything, so a closed workspace's
entry sat in the cache for the rest of the session — and
`herdr-dispatch--worktree-record' flattens every cached listing
together before searching it, so that dead entry could still supply the
record a worktree row resolved to.

The sibling entry is asserted gone as well, and that is the half that
says why this drops the whole cache rather than one entry.  Every other
workspace's listing carries `open_workspace_id' for the workspace that
just closed: `w2' here still claims a worktree is \"open as w1\".
Dropping only `w1' would leave that claim standing, on a row a user
would then press RET on."
  (herdr-dispatch-test--with-worktrees
      '(("w1" . ((worktrees . (((path . "/tmp/gone") (is_linked_worktree . t))))))
        ("w2" . ((worktrees . (((path . "/tmp/sibling") (is_linked_worktree . t)
                  (open_workspace_id . "w1")))))))
    :pending '("w3") :unanswered '(("w4" . error)) :generation 7
    (let ((before (herdr-connection-worktrees-generation (herdr-current-connection))))
      (herdr-dispatch--invalidate-worktrees (herdr-current-connection) "workspace_closed")
      (should-not (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
      (should-not (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w2"))
      (should-not (herdr-dispatch--worktrees-unanswered (herdr-current-connection)))
      ;; Requests already on the wire have to be abandoned too, or one
      ;; lands afterwards and writes the entry straight back.
      (should-not (equal before (herdr-connection-worktrees-generation (herdr-current-connection)))))))

(ert-deftest herdr-dispatch-every-worktree-event-drops-the-cache ()
  "Four events change what worktrees exist or where they are open.

Two of them had a test.  `worktree_opened' and `worktree_removed' did
not, so removing either from the list left the dashboard showing a
worktree that had been removed, or claiming one was not open when it
was, with nothing to say so."
  (dolist (kind '("worktree_created" "worktree_opened"
                  "worktree_removed" "workspace_closed"))
    (herdr-dispatch-test--with-worktrees '(("w1" . (ignored)))
      :generation 7
      (let ((before (herdr-connection-worktrees-generation (herdr-current-connection))))
        (herdr-dispatch--invalidate-worktrees (herdr-current-connection) kind)
        (should-not (herdr-connection-worktrees (herdr-current-connection)))
        (should-not (equal before (herdr-connection-worktrees-generation (herdr-current-connection))))))))

(ert-deftest herdr-dispatch-worktree-invalidation-unhooks-with-the-buffer ()
  "Left on the hook after the dashboard dies, this goes on dropping a
cache nothing reads and making the next open re-ask for every workspace."
  (herdr-dispatch-test--with-worktrees nil
   (let ((herdr-state-change-functions
          (list #'herdr-dispatch--invalidate-worktrees))
         (buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (unwind-protect
        (progn
          (herdr-dispatch--invalidate-worktrees (herdr-current-connection) "pane_updated")
          (should (memq #'herdr-dispatch--invalidate-worktrees
                        herdr-state-change-functions))
          (kill-buffer buffer)
          (herdr-dispatch--invalidate-worktrees (herdr-current-connection) "pane_updated")
          (should-not (memq #'herdr-dispatch--invalidate-worktrees
                            herdr-state-change-functions)))
      (when (buffer-live-p buffer) (kill-buffer buffer))))))

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
      (herdr-dispatch-test--with-worktrees '(("w1" . ((worktrees . (stale)))))
        :generation 3
        (let ((before (herdr-connection-worktrees-generation (herdr-current-connection))))
         (unwind-protect
            (progn
              (herdr-agents)
              (should-not (herdr-connection-worktrees (herdr-current-connection)))
              (should-not (equal before (herdr-connection-worktrees-generation (herdr-current-connection))))
              ;; The buffer it made has to be a dispatcher, or every key
              ;; the dashboard binds lands in fundamental-mode.
              (should (with-current-buffer herdr-dispatch-buffer-name
                        (derived-mode-p 'herdr-dispatch-mode)))
              ;; Already open: reopening keeps what is known.
              (herdr-dispatch-test--with-worktrees '(("w1" . ((worktrees . (fresh)))))
                :generation (herdr-connection-worktrees-generation (herdr-current-connection))
                (let ((kept (herdr-connection-worktrees-generation (herdr-current-connection))))
                  (herdr-agents)
                  (should (equal '(fresh)
                                 (herdr-dispatch-test--listing "w1")))
                  (should (equal kept (herdr-connection-worktrees-generation (herdr-current-connection)))))))
          (let ((buffer (get-buffer herdr-dispatch-buffer-name)))
            (when buffer (kill-buffer buffer)))))))))

(ert-deftest herdr-dispatch-unrelated-events-keep-the-cache ()
  (herdr-dispatch-test--with-worktrees '(("w1" . (ignored)))
    :generation 7
    (let ((before (herdr-connection-worktrees-generation (herdr-current-connection))))
      (herdr-dispatch--invalidate-worktrees (herdr-current-connection) "pane_updated")
      (should (herdr-connection-worktrees (herdr-current-connection)))
      (should (equal before (herdr-connection-worktrees-generation (herdr-current-connection)))))))

(ert-deftest herdr-dispatch-refresh-draws-a-populated-worktrees-cache ()
  "The worktrees branch of the renderer, exercised end-to-end.

Every other renderer test drives `herdr-dispatch--insert-nodes' from a
hand-written fixture, and the cache is empty in all of them,
so nothing has ever pushed a real cache entry through
`herdr-dispatch-refresh' -> `herdr-tree-build' -> the renderer.  This
closes that gap."
  (herdr-test-with-state (:cache (herdr-state-from-snapshot herdr-dispatch-test--snapshot))
   (herdr-dispatch-test--with-worktrees
       '(("w1" . ((worktrees . (((path . "/tmp/web-feat")
                   (is_linked_worktree . t)
                   (branch . "feat/x")
                   (label . "feat/x")
                   (open_workspace_id . nil)))))))
    (let* ((buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (unwind-protect
        (with-current-buffer buffer
          (herdr-dispatch-mode)
          (herdr-dispatch-refresh)
          (should (string-match-p "worktrees (" (buffer-string)))
          (should (eq 'herdr-worktrees
                      (herdr-dispatch-test--type-at "worktrees (")))
          (should (eq 'herdr-worktree
                      (herdr-dispatch-test--type-at "feat/x"))))
      (kill-buffer buffer))))))

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
    ;; A workspace starts folded, so the first toggle opens it: hidden on
    ;; the odd passes rather than the even ones.
    (dotimes (i 4)
      (herdr-dispatch-test--in-machines "web")
      (call-interactively #'magit-section-toggle)
      (should (equal (cl-oddp i)
                     (and (oref (magit-current-section) hidden) t)))
      (herdr-dispatch-test--pane-event
       "w1:p1" (if (cl-evenp i) "idle" "working") i)
      (herdr-dispatch-refresh)
      (herdr-dispatch-test--in-machines "web")
      (should (equal (cl-oddp i)
                     (and (oref (magit-current-section) hidden) t))))))

;;; Fold indicators and the current-section highlight

(defun herdr-dispatch-test--fold-glyph (text)
  "Return the fold indicator drawn beside the line holding TEXT, or nil.
The indicator is a margin overlay carrying a `display' property, which is
where the character actually ends up — reading it back out is the only
way to tell a configured indicator from a drawn one.

Inside MACHINES: the queue above lists the same names, and a queue row is
a leaf with no indicator to find."
  (herdr-dispatch-test--in-machines text)
  (goto-char (line-beginning-position))
  (seq-some (lambda (overlay)
              (when (eq 'margin (overlay-get overlay 'magit-vis-indicator))
                (aref (cadr (get-text-property
                             0 'display (overlay-get overlay 'before-string)))
                      0)))
            (overlays-in (point) (1+ (point)))))

(defun herdr-dispatch-test--hidden-p (text)
  "Return non-nil when the MACHINES line holding TEXT is invisible.

Inside MACHINES: the queue lists every agent above, and a queue row is
never folded away — it is what folding the topology leaves you with."
  (herdr-dispatch-test--in-machines text)
  (end-of-line)
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

(ert-deftest herdr-dispatch-draws-fold-indicators-on-a-fresh-render ()
  "magit writes indicators in `magit-section-show' and
`magit-section-hide' and nowhere else, so a buffer that has only ever
been drawn has none — configuring the option is not the same as showing
one.  A leaf has nothing to fold and must stay unmarked.

A workspace starts collapsed now, so the indicator beside it is the
closed one: `herdr-dispatch--apply-fold' hides it on the way in, and
hiding is one of the two places magit draws an indicator at all."
  (herdr-dispatch-test-with-dispatcher
    (herdr-dispatch-refresh t)
    (should (equal (caar (herdr-dispatch--fold-indicators))
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
    ;; A workspace starts folded, so it is the unfold that has to
    ;; survive: the failure this guards is a redraw putting the tree back
    ;; the way the code wanted it rather than the way it was left.
    (should (herdr-dispatch-test--hidden-p "w1:p1"))
    (herdr-dispatch-test--in-machines "web")
    (magit-section-show (magit-current-section))
    (should-not (herdr-dispatch-test--hidden-p "w1:p1"))
    (should (equal (cdar (herdr-dispatch--fold-indicators))
                   (herdr-dispatch-test--fold-glyph "web")))
    (herdr-dispatch-test--pane-event "w1:p1" "idle" 1)
    (herdr-dispatch-refresh)
    (should-not (herdr-dispatch-test--hidden-p "w1:p1"))
    (should (equal (cdar (herdr-dispatch--fold-indicators))
                   (herdr-dispatch-test--fold-glyph "web")))
    ;; And folding it again survives just as well.
    (herdr-dispatch-test--in-machines "web")
    (magit-section-hide (magit-current-section))
    (herdr-dispatch-test--pane-event "w1:p1" "working" 2)
    (herdr-dispatch-refresh)
    (should (herdr-dispatch-test--hidden-p "w1:p1"))))

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
  (setf (herdr-connection-cache (herdr-current-connection))
        (herdr-state-reduce (herdr-connection-cache (herdr-current-connection)) "pane_updated"
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
      (herdr-dispatch-test--with-worktrees (list (cons "w1" (list worktree)))
        (search-forward "open as w2")
        (should (equal nil
                       (herdr-dispatch-test-with-recorders
                           (herdr-rpc-call herdr-workspace-focus)
                         (should-error (herdr-dispatch-open-worktree)
                                       :type 'user-error))))))))

(ert-deftest herdr-dispatch-open-worktree-focuses-an-already-open-worktree ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (herdr-dispatch-test--with-worktrees
           '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-fix")
                       (is_linked_worktree . t)
                       (branch . "fix")
                       (open_workspace_id . "w2")))))))
      (search-forward "open as w2")
      (should (equal '((herdr-workspace-focus "w2"))
                     (herdr-dispatch-test-with-recorders
                         (herdr-workspace-focus herdr-rpc-call)
                       (herdr-dispatch-open-worktree)))))))

(ert-deftest herdr-dispatch-open-worktree-opens-a-closed-worktree-in-its-own-directory ()
  "The cwd sent to `worktree.open' must be the worktree's own workspace
directory, resolved the same way `herdr-dispatch--worktree-record' does —
not `default-directory', which in the dispatcher buffer names nothing
in particular.

`herdr-worktree-open' (the wrapped command `herdr-cmd' already has)
derives its `cwd' from the calling buffer's `default-directory' , so a
test that only records \"was `herdr-worktree-open' called\" would pass
even if the open request resolved against the wrong repository entirely.
Binding `default-directory' here to something that is not the
worktree's directory, and asserting the exact params reaching
`herdr-rpc-call', is what would catch that."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (herdr-dispatch-test--with-worktrees
        '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-fix")
                    (is_linked_worktree . t)
                    (branch . "fix")
                    (open_workspace_id . nil)))))))
     (let ((default-directory "/totally/unrelated/directory/"))
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
                         (herdr-dispatch-open-worktree)))))))))

(ert-deftest herdr-dispatch-visit-still-refuses-a-worktree-row-with-no-record ()
  "A worktree row whose record is not cached says so rather than being
opened on a guess."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (let ((herdr-connections (herdr-test-connections (herdr-test-connection (herdr-state-empty)))))
     (herdr-dispatch-test--with-worktrees nil
      (search-forward "fix")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-rpc-call herdr-term-select-pane
                                         herdr-term-select-focused)
                       (should-error (herdr-dispatch-visit) :type 'user-error))))))))

(ert-deftest herdr-dispatch-binds-no-help-key ()
  "Not nil but \"not one of ours\": `magit-section-mode' links
`special-mode-map' into the parent chain once a dispatcher buffer
exists, and `?' is `describe-mode' there."
  (should (memq (lookup-key herdr-dispatch-mode-map "?") '(nil describe-mode)))
  (should-not (fboundp 'herdr-transient)))

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
  "A pane nested under a workspace must still rename the pane: `w2:p1'
has both ancestors, which distinguishes a `cond' that checks the
workspace first from one that checks the pane first."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w2:p1")
    (should (equal '((herdr-pane-rename "new" "w2:p1"))
                   (cl-letf (((symbol-function 'read-string)
                              (lambda (&rest _) "new")))
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-rename
                                            herdr-workspace-rename)
                       (herdr-dispatch-rename)))))))

(ert-deftest herdr-dispatch-rename-refuses-a-worktree ()
  "There is no rename-a-worktree operation, so `R' on a worktree row must
refuse rather than fall through to the workspace enclosing it — which
would silently rename the repository the worktree list was expanded
from, a different object under a name the user never aimed at."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "open as w2")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-rename
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
                       (herdr-pane-close herdr-workspace-close
                                         herdr-worktree-remove)
                     (herdr-dispatch-close))))))

(ert-deftest herdr-dispatch-close-on-a-workspace-closes-the-workspace ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "api")
    (should (equal '((herdr-workspace-close "w2"))
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-workspace-close
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
workspace cannot pass by luck: the row sits inside `w1' but names the
worktree open as `w2'."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (herdr-dispatch-test--with-worktrees
           '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-fix")
                       (is_linked_worktree . t)
                       (branch . "fix")
                       (open_workspace_id . "w2")))))))
      (search-forward "open as w2")
      (should (equal '((herdr-worktree-remove "w2"))
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-workspace-close
                                           herdr-worktree-remove)
                       (herdr-dispatch-close)))))))

(ert-deftest herdr-dispatch-close-refuses-a-worktree-that-is-not-open ()
  "`worktree.remove' addresses a workspace, so a worktree herdr has not
opened as one cannot be removed at all.  Guessing at the enclosing
workspace is what made this destructive; refusing is the alternative, and
nothing may reach the server on the way out."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (herdr-dispatch-test--with-worktrees
           '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-fix")
                       (is_linked_worktree . t)
                       (branch . "fix")
                       (open_workspace_id . nil)))))))
      (search-forward "open as w2")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-workspace-close
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
    (herdr-dispatch-test--with-worktrees
           '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-fix")
                       (is_linked_worktree . nil)
                       (branch . "main")
                       (open_workspace_id . "w1")))))))
      (search-forward "open as w2")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-workspace-close
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
    (herdr-dispatch-test--with-worktrees
           '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-fix")
                       (is_linked_worktree . t)
                       (branch . "fix")
                       (open_workspace_id . "w1")))))))
      (search-forward "open as w2")
      (should (equal nil
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-close herdr-workspace-close
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
    (herdr-dispatch-test--with-worktrees
           '(("w1" . ((worktrees . (((path . "/tmp/somewhere-else")
                       (is_linked_worktree . t)
                       (branch . "other")))))))
      (search-forward "open as w2")
      (let ((message (cadr (should-error
                            (herdr-dispatch--checked-worktree
                             (herdr-dispatch-target-at-point))
                            :type 'user-error))))
        (should (string-match-p "no worktree listing" message))
        (should-not (string-match-p "own checkout" message))))))

(ert-deftest herdr-dispatch-close-refuses-a-line-with-nothing-on-it ()
  (herdr-dispatch-test-with-buffer nil
    (should-error (herdr-dispatch-close) :type 'user-error)))

;;; The main group heading

(ert-deftest herdr-dispatch-close-refuses-a-grouping-heading ()
  "`k' on `main (N)' must not close the enclosing workspace.

There was no `cond' arm for `herdr-worktrees', and
`herdr-dispatch--value-at-point' walks up from point, so the verb did
not fail — it found `w1' and closed it.  Nothing may reach the server,
which is what tells a refusal apart from a fall-through that happened to
be harmless."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "worktrees (1)")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-close herdr-workspace-close
                                         herdr-worktree-remove herdr-rpc-call)
                     (should-error (herdr-dispatch-close)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-rename-refuses-a-grouping-heading ()
  "`R' on `main (N)' must not rename the enclosing workspace, giving
the workspace a name the user had aimed at a group of its panes."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "worktrees (1)")
    (should (equal nil
                   (cl-letf (((symbol-function 'read-string)
                              (lambda (&rest _) "new")))
                     (herdr-dispatch-test-with-recorders
                         (herdr-pane-rename
                                            herdr-workspace-rename)
                       (should-error (herdr-dispatch-rename)
                                     :type 'user-error)))))))

(ert-deftest herdr-dispatch-visit-refuses-a-grouping-heading ()
  "`RET' on `main (N)' must not focus and follow the enclosing
workspace.

Refusing is a decision rather than an omission: there is no server-side
object under this heading to go to, and sending `RET' to the enclosing
workspace would be the old fall-through dressed up as an answer.  The
message points at TAB, which is the heading's one real action."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "worktrees (1)")
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-pane-focus herdr-workspace-focus
                                         herdr-rpc-call)
                     (should-error (herdr-dispatch-visit)
                                   :type 'user-error))))
    (should (string-match-p
             "TAB"
             (cadr (should-error (herdr-dispatch--refuse-heading "x")
                                 :type 'user-error))))))

(defconst herdr-dispatch-test--nested-nodes
  '((herdr-workspace "w1" "herdr.el  main  /tmp/herdr.el"
     ((herdr-pane "w1:p1" "> claude working w1:p1" nil)
      (herdr-worktrees "w1" "worktrees (1)"
       ((herdr-workspace "w2" "project-el  feat  /tmp/herdr.el-feat"
         ((herdr-pane "w2:p1" "- shell idle w2:p1" nil))))))))
  "The shape `herdr-tree-build' emits for a worktree open as a workspace.
`w2' takes the place its worktree row would have had, inside `w1''s
`worktrees (N)' heading, while `w1''s own pane hangs directly off it.")

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

(ert-deftest herdr-dispatch-still-refuses-the-heading-above-a-nested-workspace ()
  "Aiming the refusal at the section under point rather than at an
ancestor must not stop it firing when point really is on the heading."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nested-nodes
    (search-forward "worktrees (1)")
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

(ert-deftest herdr-dispatch-create-terminal-creates-a-tab-in-the-workspace-at-point ()
  "tab.create takes a workspace_id rather than a pane to split into."
  (let ((params nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_connection _method p) (setq params p) nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "w1:p2")
        (herdr-dispatch-create-terminal)
        (should (equal "w1" (alist-get 'workspace_id params)))
        (should (eq t (alist-get 'focus params)))))))

(ert-deftest herdr-dispatch-terminal-workspace-reads-an-unnested-pane-record ()
  "A pane row is not always nested under a `herdr-workspace' section —
the agents buffer can list panes on their own — so `n' falls back to the
pane\\='s own `workspace_id' rather than assuming nesting.

Only `n'.  The target\\='s WORKSPACE stays the section it sits in, because
`w' and `%' create things against a workspace on screen and must refuse
a row that shows none - reaching through a record for one would make `%'
build a worktree for a workspace the row never named."
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
          '((panes . (((pane_id . "w9:p1") (workspace_id . "w9")))))))
    (herdr-dispatch-test-with-buffer
        '((herdr-pane "w9:p1" "orphan pane w9:p1" nil))
      (search-forward "w9:p1")
      (let ((target (herdr-dispatch-target-at-point)))
        (should-not (herdr-dispatch-target-workspace target))
        (should (equal "w9" (herdr-dispatch--terminal-workspace target)))))))

(ert-deftest herdr-dispatch-open-worktree-refuses-a-row-that-is-not-one ()
  "Reachable as a command, so it has to answer for a row it was not aimed
at: a struct accessor on a nil target would say `wrong-type-argument'
where the verb it replaced said which row you needed."
  (herdr-dispatch-test-with-buffer nil
    (should (equal "herdr: point is not on a worktree"
                   (condition-case err
                       (herdr-dispatch--checked-worktree
                        (herdr-dispatch-target-at-point))
                     (user-error (error-message-string err)))))))

(ert-deftest herdr-dispatch-open-worktree-acts-on-the-target-it-is-given ()
  "`herdr-dispatch-visit' hands over the target it already resolved, and
this is the half of that which the visit test cannot see: point is
somewhere else entirely while the verb runs."
  (herdr-dispatch-test--with-worktrees
         '(("w1" . ((worktrees . (((path . "/tmp/wt") (is_linked_worktree . t)
                     (branch . "topic") (open_workspace_id . "w5")))))))
    (herdr-dispatch-test-with-buffer
        '((herdr-workspace "w1" "workspace w1"
                           ((herdr-worktree "/tmp/wt" "topic /tmp/wt" nil))))
      (search-forward "topic")
      (let ((target (herdr-dispatch-target-at-point)))
        (goto-char (point-min))
        (should (equal '((herdr-workspace-focus "w5"))
                       (herdr-dispatch-test-with-recorders (herdr-workspace-focus)
                         (herdr-dispatch-open-worktree target))))))))

(ert-deftest herdr-dispatch-create-worktree-omits-an-empty-base ()
  "A blank base must not reach the server as an empty string."
  (let ((params nil)
        (prompts nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_connection _method p) (setq params p) nil))
              ((symbol-function 'herdr-state-workspace-directory)
               (lambda (_state _id) "/tmp/herdr.el/"))
              ((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (push prompt prompts)
                 (if (string-match-p "branch" prompt) "feature" "")))
              ((symbol-function 'herdr-dispatch-refresh) #'ignore))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "herdr.el")
        (herdr-dispatch-create-worktree)
        (should (equal "feature" (alist-get 'branch params)))
        (should-not (alist-get 'base params))
        (should (equal "/tmp/herdr.el/" (alist-get 'cwd params)))
        ;; Branch first, then base: the order the prompts must come in.
        (should (= 2 (length prompts)))
        (should (string-match-p "branch" (nth 1 prompts)))
        (should (string-match-p "Base ref" (nth 0 prompts)))))))

(ert-deftest herdr-dispatch-create-worktree-refuses-a-workspace-with-no-directory ()
  "A workspace with no pane yet has no directory; the worktree must not
be created off the dashboard buffer's own directory instead."
  (cl-letf (((symbol-function 'herdr-rpc-call)
             (lambda (&rest _) (error "must not be called")))
            ((symbol-function 'herdr-state-workspace-directory)
             (lambda (_state _id) nil))
            ((symbol-function 'read-string) (lambda (&rest _) "feature")))
    (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
      (search-forward "herdr.el")
      (should-error (herdr-dispatch-create-worktree) :type 'user-error))))

(ert-deftest herdr-dispatch-create-worktree-passes-a-base-that-was-given ()
  "The capability the prompt replaced: a worktree off something other
than the current HEAD."
  (let ((params nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_connection _method p) (setq params p) nil))
              ((symbol-function 'herdr-state-workspace-directory)
               (lambda (_state _id) "/tmp/herdr.el/"))
              ((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (if (string-match-p "branch" prompt) "feature" "v1.4")))
              ((symbol-function 'herdr-dispatch-refresh) #'ignore))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "herdr.el")
        (herdr-dispatch-create-worktree)
        (should (equal "v1.4" (alist-get 'base params)))))))

(ert-deftest herdr-dispatch-create-workspace-prompts-from-the-row-at-point ()
  "The default offered is the directory of the workspace at point."
  (let ((called nil)
        (default nil))
    (cl-letf (((symbol-function 'herdr-workspace-create)
               (lambda (dir &optional label) (setq called (list dir label))))
              ((symbol-function 'herdr-state-workspace-directory)
               (lambda (_state _id) "/tmp/herdr.el/"))
              ((symbol-function 'read-directory-name)
               (lambda (_prompt &optional given &rest _)
                 (setq default given)
                 "/tmp/proj")))
      (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
        (search-forward "herdr.el")
        (herdr-dispatch-create-workspace)
        (should (equal "/tmp/herdr.el/" default))
        (should (equal '("/tmp/proj" nil) called))))))

;;; Starting an agent from anywhere in the tree

(defconst herdr-dispatch-test--start-nodes
  '((herdr-workspace "w1" "herdr.el  /tmp/herdr.el  3 panes"
     ((herdr-pane "w1:p1" "> claude working w1:p1" nil)
      (herdr-pane "w1:p2" "· shell           w1:p2" nil)
      (herdr-pane "w1:p3" "  shell           w1:p3" nil)))
    (herdr-workspace "w2" "api  /tmp/api  2 panes"
     ((herdr-pane "w2:p1" "  shell           w2:p1" nil)
      (herdr-pane "w2:p2" "· gemini idle w2:p2" nil))))
  "A tree holding every case `a' has to answer for.

Every heading encloses no `herdr-tab' section — `herdr-tree-build'
never nests a pane under one — which is the case the split-target chain
used to dead-end on for a single-tab workspace like `w1'.  Its panes
are, in order, one running a real agent, one plain shell, and one
with no agent.")

(defconst herdr-dispatch-test--start-snapshot
  '((workspaces . (((workspace_id . "w1") (label . "herdr.el"))
                   ((workspace_id . "w2") (label . "api"))))
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
  "The state `herdr-dispatch-test--start-nodes' was drawn from.
Real state rather than mocked accessors, for the reason given in
`herdr-dispatch-create-terminal-resolves-a-tab-to-one-of-its-panes'.")

(defmacro herdr-dispatch-test-with-start-tree (&rest body)
  "Render the agent-start fixture over its own state and run BODY there."
  (declare (indent 0) (debug t))
  `(herdr-test-with-state (:cache (herdr-state-from-snapshot herdr-dispatch-test--start-snapshot))
     (herdr-dispatch-test-with-buffer herdr-dispatch-test--start-nodes
       ,@body)))

(ert-deftest herdr-dispatch-create-terminal-creates-a-tab-in-the-workspace-of-the-pane ()
  "A pane row resolves through its own record to its workspace."
  (let ((workspace-id nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_connection _method params)
                 (setq workspace-id (alist-get 'workspace_id params))
                 '((root_pane . ((pane_id . "w1:p9"))))))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore))
      (herdr-dispatch-test-with-start-tree
        (search-forward "w1:p1")
        (herdr-dispatch-create-terminal)
        (should (equal "w1" workspace-id))))))

(ert-deftest herdr-dispatch-create-terminal-follows-the-pane-it-creates ()
  "A terminal that opens somewhere you cannot see reads as a no-op."
  (let ((methods nil)
        (followed nil))
    (cl-letf (((symbol-function 'herdr-cmd--follow-new-pane)
               (lambda (pane) (setq followed pane))))
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
          (herdr-dispatch-create-terminal))))
    (should (equal '("tab.create") (reverse methods)))
    (should (equal "w1:p9" followed))))

;;; `n' on a row that names a directory rather than a workspace

(ert-deftest herdr-dispatch-create-terminal-prefers-a-worktree-row-to-its-repository ()
  "Walking up would open the terminal in the repository the user was
pointing past."
  (herdr-dispatch-test-with-buffer
      '((herdr-workspace "w1" "herdr.el (2)"
         ((herdr-worktrees "w1" "worktrees (1)" ((herdr-pane "w1:p1" "claude" nil)))
          (herdr-worktree "/tmp/herdr.el-fix/" "fix" nil))))
    (herdr-test-with-state (:cache (herdr-state-from-snapshot
            '((workspaces . (((workspace_id . "w1"))))
              (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                         (cwd . "/tmp/herdr.el")))))))(let* ((calls nil))
      (search-forward "fix")
      (cl-letf (((symbol-function 'herdr-rpc-call)
                 (lambda (_connection method params)
                   (push (cons method params) calls)
                   '((root_pane . ((pane_id . "w8:p1"))))))
                ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore))
        (herdr-dispatch-create-terminal))
      (should (equal "workspace.create" (car (car (reverse calls)))))
      (should (equal "/tmp/herdr.el-fix/"
                     (alist-get 'cwd (cdr (car (reverse calls))))))))))

(ert-deftest herdr-dispatch-create-terminal-refuses-a-row-naming-no-workspace ()
  "A server row names no workspace, and a nil `workspace_id' would send
the terminal to whichever workspace the server has focused rather than
refusing.

A `main (N)' heading is not refused: it sits inside a workspace, so the
terminal goes there.  Only a row with no workspace above it has nowhere
to send one."
  (herdr-dispatch-test-with-buffer
      '((herdr-machine "local" "local (1)" nil))
    (goto-char (point-min))
    (should (equal nil
                   (herdr-dispatch-test-with-recorders
                       (herdr-rpc-call herdr-cmd--follow-new-pane)
                     (should-error (herdr-dispatch-create-terminal)
                                   :type 'user-error))))))

(ert-deftest herdr-dispatch-create-terminal-creates-a-tab-from-a-flattened-workspace-heading ()
  "`herdr-tree' renders a single-tab workspace flattened, dropping the
tab level, so on such a heading there is no `herdr-tab' section
underneath — but `tab.create' needs a workspace id, not a pane, and the
heading is that id directly."
  (let ((params nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_connection _method p) (setq params p) nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore))
      (herdr-dispatch-test-with-start-tree
        (search-forward "herdr.el")
        (herdr-dispatch-create-terminal)
        (should (equal "w1" (alist-get 'workspace_id params)))))))

(ert-deftest herdr-dispatch-binds-the-create-verbs ()
  (should (eq #'herdr-dispatch-create-workspace
              (lookup-key herdr-dispatch-mode-map "w")))
  (should (eq #'herdr-dispatch-create-terminal
              (lookup-key herdr-dispatch-mode-map "n")))
  (should (eq #'herdr-dispatch-create-worktree
              (lookup-key herdr-dispatch-mode-map "%")))
  (dolist (verb '(herdr-dispatch-create-workspace
                  herdr-dispatch-create-terminal
                  herdr-dispatch-create-worktree))
    (should (commandp verb))))

(ert-deftest herdr-dispatch-binds-no-create-menu ()
  "`c' offered the same verbs as `w', `n' and `%' plus three
arguments, and was the last transient prefix in the package."
  (should-not (lookup-key herdr-dispatch-mode-map "c"))
  (should-not (fboundp 'herdr-dispatch-create))
  (should-not (fboundp 'herdr-dispatch--args))
  (should-not (fboundp 'herdr-dispatch--arg)))

(ert-deftest herdr-dispatch-offers-no-second-way-to-create-a-place-to-run-in ()
  "`a' called `agent.start', asking for a kind and a name that herdr\\='s
own TUI never asks for.

The key is bound again, to answering a blocked agent, so the absent verb
is what this asserts.  Pinning the keystroke only ever pinned where the
cut verb happened to live."
  (should-not (fboundp 'herdr-dispatch-create-agent))
  (should-not (fboundp 'herdr-agent-start))
  (should (eq 'herdr-dispatch-send-keys
              (lookup-key herdr-dispatch-mode-map "a"))))

;;; The worktree cache answers questions


(ert-deftest herdr-dispatch-an-empty-answer-is-an-answer ()
  "A repository with no worktrees caches as an entry whose value is nil
and must not be asked again, which is why every guard uses `assoc'."
  (herdr-dispatch-test--with-worktrees '(("w1" . nil))
    (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
    (should-not (herdr-dispatch-test--listing "w1"))
    (should-not (herdr-dispatch--worktrees-wanted-p (herdr-current-connection) "w1"))))

(ert-deftest herdr-dispatch-a-key-never-asked-is-wanted ()
  (herdr-dispatch-test--with-worktrees nil
    (should-not (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
    (should (herdr-dispatch--worktrees-wanted-p (herdr-current-connection) "w1"))))

(ert-deftest herdr-dispatch-a-key-in-flight-is-not-wanted-again ()
  (herdr-dispatch-test--with-worktrees nil :pending '("w1")
    (should-not (herdr-dispatch--worktrees-wanted-p (herdr-current-connection) "w1"))))

(ert-deftest herdr-dispatch-unanswered-covers-all-three-categories ()
  "Errored, no-directory, and still in flight.  The third is easy to omit
and omitting it is a regression: clearing a pending marker is the only
thing that can rescue an in-flight request before its timeout."
  (herdr-dispatch-test--with-worktrees '(("w1" . nil) ("w2" . nil) ("w4" . (found)))
    :pending '("w3")
    :unanswered '(("w1" . error) ("w2" . no-directory))
    (let ((unanswered (herdr-dispatch--worktrees-unanswered (herdr-current-connection))))
      (should (member "w1" unanswered))
      (should (member "w2" unanswered))
      (should (member "w3" unanswered))
      (should-not (member "w4" unanswered)))))

(ert-deftest herdr-dispatch-the-unanswered-reason-survives ()
  "A no-directory entry is retried once a directory exists; an errored
one waits for the keystroke.  Collapsing the two loses that."
  (herdr-dispatch-test--with-worktrees '(("w1" . nil) ("w2" . nil))
    :unanswered '(("w1" . error) ("w2" . no-directory))
    (should (eq 'error (herdr-dispatch--worktrees-unanswered-reason (herdr-current-connection) "w1")))
    (should (eq 'no-directory (herdr-dispatch--worktrees-unanswered-reason (herdr-current-connection) "w2")))
    (should-not (herdr-dispatch--worktrees-unanswered-reason (herdr-current-connection) "w9"))))

(ert-deftest herdr-dispatch-a-forced-retry-keeps-a-genuinely-empty-answer ()
  (herdr-dispatch-test--with-worktrees '(("w1" . nil) ("w2" . nil))
    :unanswered '(("w1" . error))
    (herdr-dispatch--retry-unanswered-worktrees (herdr-current-connection))
    (should-not (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w1"))
    (should (herdr-dispatch--worktrees-answered-p (herdr-current-connection) "w2"))
    (should-not (herdr-dispatch--worktrees-unanswered (herdr-current-connection)))))

(ert-deftest herdr-dispatch-a-path-resolves-through-any-listing ()
  "A worktree row knows its path and not which listing answered for it,
so the search flattens every listing together."
  (herdr-dispatch-test--with-worktrees
      '(("w1" . ((worktrees . (((path . "/tmp/a/")))))) ("w2" . ((worktrees . (((path . "/tmp/b/")))))))
    (should (equal '((path . "/tmp/b/")) (herdr-dispatch--worktree-record (herdr-current-connection) "/tmp/b/")))
    (should-not (herdr-dispatch--worktree-record (herdr-current-connection) "/tmp/missing/"))))

(ert-deftest herdr-dispatch-an-event-that-changes-worktrees-is-stale-making ()
  "`workspace_closed' belongs on the list even though it announces no
worktree: every other listing carries `open_workspace_id'."
  (dolist (kind '("worktree_created" "worktree_opened" "worktree_removed"
                  "workspace_closed"))
    (should (herdr-dispatch--worktrees-stale-p kind)))
  (dolist (kind '("pane_updated" "workspace_renamed" "resync"))
    (should-not (herdr-dispatch--worktrees-stale-p kind))))

(ert-deftest herdr-dispatch-two-connections-do-not-share-worktrees ()
  "Ids are per-server counters, so two servers can each answer for a `w1'.
One cache holding both would draw one server's worktrees under the
other's workspace, which is the whole reason the cache moved into the
connection."
  (let ((one (herdr-test-connection))
        (two (herdr-test-connection)))
    (herdr-dispatch--worktrees-received
     one "w1" (herdr-connection-worktrees-generation one)
     '(((path . "/tmp/one-feat"))) nil)
    (should (herdr-dispatch--worktrees-answered-p one "w1"))
    (should-not (herdr-dispatch--worktrees-answered-p two "w1"))
    (should (herdr-dispatch--worktrees-wanted-p two "w1"))
    (herdr-dispatch--forget-worktrees two)
    (should (herdr-dispatch--worktrees-answered-p one "w1"))))

(ert-deftest herdr-dispatch-two-connections-do-not-share-a-worktree-epoch ()
  "The epoch drops replies invalidated in flight.  Shared, one server's
invalidation would throw away another's answer as though it were stale."
  (let ((one (herdr-test-connection))
        (two (herdr-test-connection))
        (kept nil))
    (setq kept (herdr-connection-worktrees-generation one))
    (herdr-dispatch--forget-worktrees two)
    (should (equal kept (herdr-connection-worktrees-generation one)))
    (should-not (equal kept (herdr-connection-worktrees-generation two)))))

(ert-deftest herdr-dispatch-a-path-resolves-only-within-its-own-server ()
  "A path is a path on some machine.  Two servers can each hold a
`~/workspace/repo', and they are not the same directory or the same
repository — so a row's path must be looked up in the listings of the
connection the row came from and nowhere else."
  (let ((one (herdr-test-connection))
        (two (herdr-test-connection)))
    (setf (herdr-connection-worktrees one)
          '(("w1" . ((worktrees . (((path . "/tmp/repo/") (branch . "on-one")))))))
          (herdr-connection-worktrees two)
          '(("w1" . ((worktrees . (((path . "/tmp/repo/") (branch . "on-two"))))))))
    (should (equal "on-one"
                   (herdr-worktree-branch
                    (herdr-dispatch--worktree-record one "/tmp/repo/"))))
    (should (equal "on-two"
                   (herdr-worktree-branch
                    (herdr-dispatch--worktree-record two "/tmp/repo/"))))
    ;; A path only the other server has is not found here.
    (setf (herdr-connection-worktrees two)
          '(("w1" . ((worktrees . (((path . "/tmp/only-on-two/"))))))))
    (should-not (herdr-dispatch--worktree-record one "/tmp/only-on-two/"))))

(ert-deftest herdr-dispatch-a-target-carries-the-server-its-row-came-from ()
  "A verb acts on the server the row came from.  Carrying the value on
and letting something else decide where to send it is how a command ends
up acting on whichever server the user looked at next."
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1")
    (let ((target (herdr-dispatch-target-at-point)))
      (should (herdr-connection-p (herdr-dispatch-target-connection target)))
      (should (eq (herdr-current-connection)
                  (herdr-dispatch-target-connection target))))))

(ert-deftest herdr-dispatch-answers-the-resolver-from-the-dashboard ()
  "A verb invoked by name rather than through the target resolver still
has to reach the server the row came from, which is what the resolver
hook is for.  Outside the dashboard it says nothing and falls through."
  (should (memq #'herdr-dispatch--resolve-connection
                herdr-connection-resolvers))
  (with-temp-buffer
    (should-not (herdr-dispatch--resolve-connection)))
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1")
    (should (eq (herdr-current-connection)
                (herdr-dispatch--resolve-connection)))))

;;; One dashboard, several servers

(defmacro herdr-dispatch-test--with-two-servers (&rest body)
  "Run BODY with two connections whose servers issued the same ids.
Binds ONE and TWO, and draws the dashboard from both."
  (declare (indent 0) (debug t))
  `(let* ((one (herdr-test-connection
                (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w1") (label . "on-one"))))
                   (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                              (agent . "claude"))))))))
          (two (herdr-test-connection
                (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w1") (label . "on-two"))))
                   (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                              (agent . "codex"))))))))
          (herdr-connections (list (cons "one" one) (cons "two" two)))
          (herdr-dispatch--refresh-timer nil)
          (buffer (get-buffer-create herdr-dispatch-buffer-name)))
     (setf (herdr-connection-name one) "one"
           (herdr-connection-name two) "two"
           (herdr-connection-running one) t
           (herdr-connection-running two) t)
     (unwind-protect
         (cl-letf (((symbol-function 'herdr-dispatch--request-worktrees)
                    #'ignore))
           (with-current-buffer buffer
             (herdr-dispatch-mode)
             (herdr-dispatch-refresh t)
             ,@body))
       (herdr-dispatch--cancel-refresh)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest herdr-dispatch-two-servers-render-as-two-subtrees ()
  "Both servers issued `w1' and `w1:p1'.  One flat tree would draw them
as one workspace, and whichever verb ran would reach whichever server
answered last."
  (herdr-dispatch-test--with-two-servers
    (let ((text (buffer-string)))
      (should (string-match-p "^ *one (" text))
      (should (string-match-p "^ *two (" text))
      (should (string-match-p "on-one" text))
      (should (string-match-p "on-two" text)))
    ;; The header counts across both.
    (should (string-match-p "2 machines" herdr-dispatch--rendered-header))
    (should (string-match-p "2 workspaces" herdr-dispatch--rendered-header))))

(ert-deftest herdr-dispatch-a-row-resolves-to-the-server-it-came-from ()
  "The guard this unit owes: a colliding id has to reach the connection
whose subtree the row sits in, not whichever the resolver would answer."
  (herdr-dispatch-test--with-two-servers
    (herdr-dispatch-test--in-machines "on-one")
    (let ((target (herdr-dispatch-target-at-point)))
      (should (eq one (herdr-dispatch-target-connection target)))
      (should (equal "on-one" (herdr-workspace-label
                               (herdr-dispatch-target-record target)))))
    (herdr-dispatch-test--in-machines "on-two")
    (let ((target (herdr-dispatch-target-at-point)))
      (should (eq two (herdr-dispatch-target-connection target)))
      (should (equal "on-two" (herdr-workspace-label
                               (herdr-dispatch-target-record target)))))
    ;; And a verb invoked by name reaches the same one.
    (herdr-dispatch-test--in-machines "on-two")
    (should (eq two (herdr-current-connection)))))

(ert-deftest herdr-dispatch-a-queue-row-resolves-to-its-own-machine ()
  "The same guard for the queue, which is where it is hardest: a queue is
ordered by attention, so a row has no machine heading above it to walk up
to, and both machines here issued `w1:p1'.

The row carries the machine name on its own line instead, which is what
`herdr-dispatch--row-connection' reads when there is no heading.  A name
rather than the connection, because a section outlives the redraws around
it and a reconnect replaces the struct."
  (herdr-dispatch-test--with-two-servers
    (dolist (case (list (cons "claude" one) (cons "codex" two)))
      (goto-char (point-min))
      ;; The queue is above MACHINES, so this finds the queue row.
      (search-forward (car case))
      (let ((target (herdr-dispatch-target-at-point)))
        (should (eq 'herdr-pane (herdr-dispatch-target-type target)))
        (should (equal "w1:p1" (herdr-dispatch-target-value target)))
        (should (eq (cdr case) (herdr-dispatch-target-connection target)))))))

(ert-deftest herdr-dispatch-one-connection-draws-no-server-level ()
  "Nobody following one server should see a row that says nothing."
  (let* ((connection (herdr-test-connection
                      (herdr-state-from-snapshot
                       '((workspaces . (((workspace_id . "w1")
                                         (label . "solo")))))))))
    (setf (herdr-connection-name connection) "local")
    (let ((herdr-connections (herdr-test-connections connection)))
      (let ((machines (herdr-dispatch-test--machines
                       (herdr-dispatch--tree (herdr-connection-list)))))
        (should-not (seq-find (lambda (node) (eq 'herdr-machine (car node)))
                              machines))
        (should (eq 'herdr-workspace (car (car machines)))))
      (should-not (string-match-p
                   "machines" (herdr-dispatch--header
                              (herdr-connection-list)))))))

(ert-deftest herdr-dispatch-a-server-that-is-down-is-drawn-as-itself ()
  "An empty dashboard and an unreachable server are different facts, and
a row that vanishes when a laptop sleeps tells you the wrong one."
  (herdr-dispatch-test--with-two-servers
    (setf (herdr-connection-running two) nil
          (herdr-connection-cache two) (herdr-state-empty))
    (herdr-dispatch-refresh t)
    (let ((text (buffer-string)))
      (should (string-match-p "^ *two  not connected" text))
      ;; The other is still fully there.
      (should (string-match-p "on-one" text)))
    ;; And still navigable.
    (herdr-dispatch-test--in-machines "on-one")
    (should (eq one (herdr-dispatch-target-connection
                     (herdr-dispatch-target-at-point))))))

(ert-deftest herdr-dispatch-worktrees-start-folded ()
  "A repository's other checkouts are worth one line until asked for.
Through `magit-section-initial-visibility-alist' rather than a hidden
slot set by hand, so a redraw keeps whatever the reader has since
toggled instead of folding it shut under them again."
  (herdr-dispatch-test-with-buffer
      '((herdr-workspace "w1" "web  main  /tmp/web"
         ((herdr-pane "w1:p1" "> claude working w1:p1" nil)
          (herdr-worktrees "w1" "worktrees (1)"
           ((herdr-worktree "/tmp/web-feat" "feat/x  /tmp/web-feat" nil))))))
    (should (eq 'hide (alist-get 'herdr-worktrees
                                 magit-section-initial-visibility-alist)))
    (let ((section (herdr-dispatch-test--section-at "worktrees (")))
      (should section)
      (should (oref section hidden)))
    ;; The panes beside it are not folded away with them.
    (should-not (oref (herdr-dispatch-test--section-at "claude") hidden))))
