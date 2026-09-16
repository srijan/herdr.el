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

(defun herdr-tree-test--nodes-of-type (type nodes)
  "Return the nodes among NODES whose node type is TYPE."
  (seq-filter (lambda (node) (eq type (nth 0 node))) nodes))

(defun herdr-tree-test--worktree-rows (children)
  "Return the worktree rows a workspace node\\='s CHILDREN hold.

They sit under one `herdr-worktrees' heading now rather than beside the
panes, so this looks inside it.  A nested workspace is spliced in where
its worktree row would have gone, so it counts as one too."
  (seq-filter (lambda (node)
                (memq (nth 0 node) '(herdr-worktree herdr-workspace)))
              (seq-mapcat (lambda (node)
                            (if (eq 'herdr-worktrees (nth 0 node))
                                (nth 3 node)
                              (list node)))
                          children)))

(defun herdr-tree-test--pane-nodes (workspace)
  "Return the pane nodes of WORKSPACE, a node from `herdr-tree-build'.
Always its own children now: there is no tab group between them."
  (herdr-tree-test--nodes-of-type 'herdr-pane (nth 3 workspace)))

(defun herdr-tree-test--types (nodes)
  "Return the nested (TYPE . CHILD-TYPES) shape of NODES."
  (mapcar (lambda (node)
            (cons (nth 0 node) (herdr-tree-test--types (nth 3 node))))
          nodes))

(ert-deftest herdr-tree-pane-row-shows-the-label-and-the-title ()
  "The whole point: a renamed pane's name reaches the dashboard row
without costing the row what the agent is working on."
  (let* ((state (herdr-tree-test--state
                 '(panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude")
                             (agent_status . "working") (label . "Lantern")
                             (terminal_title_stripped . "fixing tests"))))))
         (node (herdr-tree--pane-node state (herdr-state-pane state "w1:p1")
                                      10)))
    (should (string-match-p "Lantern" (nth 2 node)))
    (should (string-match-p "fixing tests" (nth 2 node)))))

(ert-deftest herdr-tree-renders-panes-flat-under-the-workspace ()
  "Multi-tab workspaces render panes directly under the workspace.
The fixture has two tabs holding three panes between them; the built
tree must show all three as the workspace's own direct children, with
no `herdr-tab' node anywhere in the shape."
  (should (equal '((herdr-workspace (herdr-pane) (herdr-pane) (herdr-pane)))
                 (herdr-tree-test--types
                  (herdr-tree-build (herdr-tree-test--state) nil)))))

(ert-deftest herdr-tree-flattens-a-single-tab-workspace ()
  "A lone tab is not structure either — same flat listing either way."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1") (label . "solo")
                                  (pane_count . 1) (tab_count . 1))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude"))))))))
    (should (equal '((herdr-workspace (herdr-pane)))
                   (herdr-tree-test--types (herdr-tree-build state nil))))))

(ert-deftest herdr-tree-workspace-line-carries-directory-and-rollup ()
  (let ((line (nth 2 (car (herdr-tree-build (herdr-tree-test--state) nil)))))
    (should (string-match-p "herdr.el" line))
    (should (string-match-p "/tmp/herdr.el" line))
    (should (string-match-p (herdr-tree-glyph "blocked") line))))

(ert-deftest herdr-tree-workspace-line-names-an-unlabelled-workspace-by-its-id ()
  "An empty label is what the server sends for a workspace nobody has
named, and an empty string is truthy, so the plain `or' fallback this
replaced never fired and the heading rendered with no name at all."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w2F") (label . "")
                                   (pane_count . 1))))
                   (panes . (((pane_id . "w2F:p1") (workspace_id . "w2F")
                              (tab_id . "w2F:t1") (agent . "claude")))))))
         (line (nth 2 (car (herdr-tree-build state nil)))))
    (should (string-match-p "\\`w2F" line))))

(ert-deftest herdr-tree-workspace-line-names-a-labelled-workspace-by-its-label ()
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w2F") (label . "web")
                                   (pane_count . 1))))
                   (panes . (((pane_id . "w2F:p1") (workspace_id . "w2F")
                              (tab_id . "w2F:t1") (agent . "claude")))))))
         (line (nth 2 (car (herdr-tree-build state nil)))))
    (should (string-match-p "\\`web" line))
    (should-not (string-match-p "w2F" line))))

(ert-deftest herdr-tree-workspace-line-abbreviates-a-home-relative-directory ()
  "A known-project row already shows `~/' for free, since
`project-known-project-roots' hands those back pre-abbreviated; a
workspace's directory is derived from a pane's cwd instead and had
nothing shortening it, so the two looked inconsistent side by side."
  (let* ((dir (expand-file-name "~/herdr-test-project"))
         (state (herdr-tree-test--state
                 `(panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude")
                             (agent_status . "working") (cwd . ,dir)))))))
    (let ((line (nth 2 (car (herdr-tree-build state nil)))))
      (should (string-match-p "~/herdr-test-project" line))
      (should-not (string-match-p (regexp-quote dir) line)))))

(ert-deftest herdr-tree-counts-children-in-parentheses ()
  "magit\\='s idiom, because the dashboard is read next to magit-status.

`Unstaged changes (1)' is a heading that owns a countable number of
children; `.emacs.d (2)' says the same thing about the same kind of
line.  A `2 panes' column in the middle of the line said it too, but
said it in a place the eye has to travel to and in a shape shared with
the leaf rows, which own nothing.  Both halves are asserted: the count is
in parentheses on the label, and the column it replaced is gone rather
than duplicated beside it.

Each row counts what it owns.  The workspace row itself owns no count
any more: it names the workspace, the branch and the directory, which is
what herdr\\='s own sidebar shows, and the checkouts it used to count are
behind the `worktrees (N)' heading that actually holds them."
  (let* ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/wt")
                                (is_linked_worktree . t)
                                (branch . "feat/x"))))))))
         (workspace (car (herdr-tree-build (herdr-tree-test--state) worktrees)))
         (children (nth 3 workspace)))
    ;; No count on the workspace row; the one worktree is counted on the
    ;; heading that holds it.
    (should (string-match-p "herdr\\.el" (nth 2 workspace)))
    (should-not (string-match-p "herdr\\.el (" (nth 2 workspace)))
    (should (seq-find (lambda (node)
                        (and (eq 'herdr-worktrees (nth 0 node))
                             (string-match-p "worktrees (1)" (nth 2 node))))
                      children))
    (should-not (string-match-p "panes" (nth 2 workspace)))))

(ert-deftest herdr-tree-workspace-rollup-omits-idle ()
  "Same omit-idle rule as the modeline, so the two never disagree.
Tabs no longer carry their own rollup — panes render flat — so this is
asserted on the one heading left that still has one: the workspace."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w1") (label . "herdr.el")
                                   (pane_count . 1) (agent_status . "idle"))))
                   (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                              (tab_id . "w1:t1") (agent . "claude")
                              (agent_status . "idle")))))))
         (line (nth 2 (car (herdr-tree-build state nil)))))
    (should-not (string-match-p (herdr-tree-glyph "blocked") line))
    (should-not (string-match-p (herdr-tree-glyph "idle") line))))

(ert-deftest herdr-tree-pane-line-shows-agent-status-and-title ()
  (let* ((panes (herdr-tree-test--pane-nodes (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (pane (nth 2 (car panes))))
    (should (string-match-p "claude" pane))
    (should (string-match-p "working" pane))
    (should (string-match-p "w1:p1" pane))
    (should (string-match-p "fixing tests" pane))))

;;; The animated spinner in a terminal title

(defun herdr-tree-test--spinning-state (title)
  "Return a one-pane state whose pane reports TITLE."
  (herdr-state-from-snapshot
   `((workspaces . (((workspace_id . "w1") (label . "w") (pane_count . 1))))
     (panes . (((pane_id . "w1:p1") (workspace_id . "w1") (tab_id . "w1:t1")
                (agent . "claude") (agent_status . "working")
                (terminal_title_stripped . ,title)))))))

(ert-deftest herdr-tree-normalises-the-spinner-out-of-a-title ()
  "Two titles that differ only in the spinner must build equal trees.

Claude animates a half-circle glyph at the head of the terminal title
and it survives into `terminal_title_stripped', which the dashboard
renders.  So while an agent works the rendered tree genuinely differs on
every event, the unchanged-tree skip in `herdr-dispatch-refresh' never
engages, and the buffer is erased and rebuilt about once a second —
taking the section highlight with it each time.

Measured over one 60-second window on a working pane: 485 titles, 239
\"◑ Debug webmentions from fed.brid.gy\", 238 the same with \"◐\", 8 with
no glyph.  All three shapes are used here, and all three must agree.

Tree equality is the assertion rather than the text of one line, because
tree equality is precisely what the redraw skip tests."
  (let ((spun-a (herdr-tree-build
                 (herdr-tree-test--spinning-state "◐ Debug webmentions") nil))
        (spun-b (herdr-tree-build
                 (herdr-tree-test--spinning-state "◑ Debug webmentions") nil))
        (still (herdr-tree-build
                (herdr-tree-test--spinning-state "Debug webmentions") nil)))
    (should (equal spun-a spun-b))
    (should (equal spun-a still))))

(ert-deftest herdr-tree-spinner-normalisation-reaches-the-pane-row ()
  "The strip has to happen where the line is built, not only in the helper.

A `herdr-pane-steady-title' that nothing calls would pass every
assertion above while the dashboard went on redrawing once a second."
  (let ((line (nth 2 (car (herdr-tree-test--pane-nodes (car (herdr-tree-build
                                       (herdr-tree-test--spinning-state
                                        "◐ Debug webmentions")
                                       nil)))))))
    (should (string-match-p "Debug webmentions" line))
    (should-not (string-match-p "◐" line))))

;;; Faces

(defun herdr-tree-test--face-of (line text)
  "Return the face LINE carries where TEXT begins in it.
Read off `font-lock-face', which is only half the answer — see
`herdr-tree-faces-a-field-with-both-properties' for the other half and
for why one property alone renders as nothing."
  (get-text-property (string-match text line) 'font-lock-face line))

(ert-deftest herdr-tree-faces-a-field-with-both-properties ()
  "A face has to be written twice or it is invisible half the time.

`face' alone is erased: `magit-section-mode' sets
`font-lock-defaults', so `font-lock-mode' comes on in the dashboard,
and `font-lock-default-unfontify-region' removes `face' before the
line is first fontified.  That was the original bug, and the fix moved
everything to `font-lock-face'.

`font-lock-face' alone renders as nothing: it is not a display
property, only a `char-property-alias-alist' entry that
`font-lock-mode' installs, so with font-lock off it means nothing to
redisplay.  That was the next bug, verified with `face-at-point'
answering nil across the whole dashboard.  magit sets both properties
for exactly this reason.

Neither failure is observable in batch — `font-lock-mode' forces
itself off under `noninteractive', which is why 302 tests passed over
a dashboard that rendered no faces at all.  The presence of both
properties is what a batch test can see, so that is what this asserts,
on a real pane row as well as on `herdr-tree--faced' directly."
  (let ((faced (herdr-tree--faced "working" 'warning)))
    (should (eq 'warning (get-text-property 0 'font-lock-face faced)))
    (should (eq 'warning (get-text-property 0 'face faced))))
  ;; Unfaced text gains neither, or every gap-filling scan over a line
  ;; would find no gaps.
  (let ((plain (herdr-tree--faced "working" nil)))
    (should-not (get-text-property 0 'font-lock-face plain))
    (should-not (get-text-property 0 'face plain)))
  (let* ((panes (herdr-tree-test--pane-nodes (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (pane (nth 2 (car panes))))
    (dolist (field '("working" "w1:p1" "fixing tests"))
      (let ((at (string-match field pane)))
        (should (get-text-property at 'font-lock-face pane))
        (should (equal (get-text-property at 'font-lock-face pane)
                       (get-text-property at 'face pane)))))))

(ert-deftest herdr-tree-colours-a-pane-row-by-its-status ()
  "Status is the one field worth finding without reading.

The glyph and the word take the same face, which turns the leading
column into a strip you can read down; blocked and working must not
share one, or the strip says only \"something is happening\"."
  (let* ((panes (herdr-tree-test--pane-nodes (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (working (nth 2 (car panes)))
         (blocked (nth 2 (nth 1 panes))))
    (should (eq (herdr-tree-status-face "working")
                (herdr-tree-test--face-of working "working")))
    (should (eq (herdr-tree-status-face "blocked")
                (herdr-tree-test--face-of blocked "blocked")))
    (should-not (eq (herdr-tree-status-face "working")
                    (herdr-tree-status-face "blocked")))
    ;; The glyph leads with the same colour as the word it stands for.
    (should (eq (herdr-tree-status-face "working")
                (get-text-property 0 'font-lock-face working)))
    (should (eq (herdr-tree-status-face "blocked")
                (get-text-property 0 'font-lock-face blocked)))))

(ert-deftest herdr-tree-status-faces-inherit-a-built-in ()
  "Retheming `warning' rethemes a blocked agent, with nothing else done.

Named faces so `customize-face' can reach one status on its own;
inheriting built-ins so that reaching for it is never necessary.  A
colour written here instead of inherited would satisfy every other face
test in this file, because they all compare a face against itself."
  (dolist (pair '(("blocked" . warning)
                 ("working" . font-lock-keyword-face)
                 ("done"    . success)
                 ("idle"    . shadow)))
    (let ((face (herdr-tree-status-face (car pair))))
      (should (string-prefix-p "herdr-tree-status-" (symbol-name face)))
      (should (eq (cdr pair) (face-attribute face :inherit))))))

(ert-deftest herdr-tree-dims-the-fields-that-are-not-the-news ()
  "The pane id and the terminal title are context, not the message.

Built-in faces rather than colours of our own, so a theme keeps working;
asserting the face name is what would catch a hardcoded colour creeping
back in."
  (let* ((workspace (car (herdr-tree-build (herdr-tree-test--state) nil)))
         (line (nth 2 workspace))
         (pane (nth 2 (car (herdr-tree-test--pane-nodes workspace)))))
    (should (eq 'font-lock-comment-face
                (herdr-tree-test--face-of line "/tmp/herdr\\.el")))
    (should (eq 'shadow (herdr-tree-test--face-of pane "w1:p1")))
    (should (eq 'font-lock-doc-face
                (herdr-tree-test--face-of pane "fixing tests")))
    ;; The rollup glyph on a collapsed heading keeps its status colour.
    (should (eq (herdr-tree-status-face "blocked")
                (get-text-property (1- (length line)) 'font-lock-face line)))))

(ert-deftest herdr-tree-faces-do-not-make-two-equal-trees-differ ()
  "Text properties must stay invisible to `equal'.

`herdr-dispatch-refresh' skips a redraw when the tree it just built
equals the one on screen, and the tree tests above compare lines with
`equal' and `string-match-p'.  Both would be wrong if a face could
change the identity of a string — which is the reason faces can live
here at all rather than in the renderer."
  (let ((state (herdr-tree-test--state)))
    (should (equal (herdr-tree-build state nil) (herdr-tree-build state nil)))
    (should (equal "working" (substring-no-properties
                              (herdr-tree--faced "working" 'warning))))
    (should (equal (herdr-tree--faced "working" 'warning)
                   (herdr-tree--faced "working" 'success)))))

(ert-deftest herdr-tree-agent-column-widens-to-fit-the-longest-label ()
  "A fixed column truncates nothing — `%-Ns' never cuts a longer
string — but a label wider than the fixed width breaks alignment: every
other row's status and pane_id columns drift out of place.  So the real
assertion is that the status column starts at the same offset on every
row, computed from the widest label actually present rather than a
constant."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w1") (label . "w")
                                   (pane_count . 2))))
                   (agents . (((pane_id . "w1:p2") (name . "schema-pipeline"))))
                   (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                              (tab_id . "w1:t1") (agent . "claude")
                              (agent_status . "working"))
                             ((pane_id . "w1:p2") (workspace_id . "w1")
                              (tab_id . "w1:t1") (agent . "claude")
                              (agent_status . "blocked")))))))
         (children (herdr-tree-test--pane-nodes (car (herdr-tree-build state nil))))
         (line1 (nth 2 (car children)))
         (line2 (nth 2 (nth 1 children)))
         (label-width (length "claude/schema-pipeline")))
    (should (string-match-p "claude/schema-pipeline" line2))
    (should (= (+ label-width 3) (string-match "working" line1)))
    (should (= (+ label-width 3) (string-match "blocked" line2)))))

(ert-deftest herdr-tree-agent-column-does-not-shrink-below-the-minimum ()
  "Every label here is well under the minimum, so fitting the widest one
present must not produce a cramped column."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w1") (label . "w")
                                   (pane_count . 1))))
                   (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                              (tab_id . "w1:t1") (agent . "claude")
                              (agent_status . "working")))))))
         (line (nth 2 (car (herdr-tree-test--pane-nodes (car (herdr-tree-build state nil)))))))
    (should (= (+ herdr-tree-agent-column-min 3) (string-match "working" line)))))

(ert-deftest herdr-tree-marks-agentless-panes-as-shells ()
  "A pane with no agent reads as a shell — no caste star, no status."
  (let* ((state (herdr-tree-test--state
                 '(panes . (((pane_id . "w1:p3") (workspace_id . "w1")
                             (tab_id . "w1:t2") (agent_status . "idle")
                             (cwd . "/tmp/herdr.el"))))))
         (panes (herdr-tree-test--pane-nodes (car (herdr-tree-build state nil))))
         (pane (nth 2 (car panes))))
    (should (string-match-p "~" pane))
    (should (string-match-p "shell" pane))
    (should-not (string-match-p "shell\\*" pane))))

(ert-deftest herdr-tree-appends-an-agent-name-when-set ()
  (let* ((state (herdr-tree-test--state
                 '(agents . (((pane_id . "w1:p1") (agent . "claude")
                              (name . "reviewer"))))))
         (panes (herdr-tree-test--pane-nodes (car (herdr-tree-build state nil))))
         (pane (nth 2 (car panes))))
    (should (string-match-p "claude/reviewer" pane))))

(ert-deftest herdr-tree-keeps-a-pane-whose-tab-is-not-cached ()
  "A pane must never be dropped for naming a tab the cache does not hold.

Panes hang off their tab, so a workspace whose tabs are missing used to
render as a heading with no children at all — while that heading went on
counting the pane, so the buffer both claimed the pane existed and
offered no row to read, prompt or close it.  The flat listing this tree
replaced could not lose a pane, so silence here is a regression, not a
gap.

Reachable rather than theoretical: `herdr-state' drops a `tab_created'
event that carries no `tab' payload, and a resync races the events
around it.  This is that state exactly — one workspace, one blocked pane,
no tabs."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1") (label . "repo")
                                  (pane_count . 1))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude")
                             (agent_status . "blocked"))))))))
    (let ((tree (herdr-tree-build state nil)))
      (should (equal '((herdr-workspace (herdr-pane)))
                     (herdr-tree-test--types tree)))
      ;; The row must name the pane, or it is reachable only in shape.
      (should (equal "w1:p1"
                     (nth 1 (car (herdr-tree-test--pane-nodes (car tree))))))
      (should (string-match-p
               "w1:p1"
               (nth 2 (car (herdr-tree-test--pane-nodes (car tree)))))))))

(ert-deftest herdr-tree-flat-listing-ignores-whether-a-panes-tab-is-cached ()
  "The partial case that used to need dedicated orphan handling: some
tabs known, one pane naming a tab that is not.  Flat listing filters
panes by `workspace_id' alone, so a pane whose tab the cache does not
hold renders exactly like any other pane of its workspace."
  (let* ((state (herdr-tree-test--state
                 '(panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude"))
                            ((pane_id . "w1:p3") (workspace_id . "w1")
                             (tab_id . "w1:t2") (agent . "codex"))
                            ((pane_id . "w1:p9") (workspace_id . "w1")
                             (tab_id . "w1:t9") (agent . "gemini"))))))
         (tree (herdr-tree-build state nil)))
    (should (equal '((herdr-workspace (herdr-pane) (herdr-pane) (herdr-pane)))
                   (herdr-tree-test--types tree)))
    (should (equal "w1:p9"
                   (nth 1 (nth 2 (herdr-tree-test--pane-nodes (car tree))))))))

(defun herdr-tree-test--pane-ids (nodes)
  "Return the id of every `herdr-pane' node anywhere under NODES.
Collected across the whole subtree rather than one level, so a pane
rendered twice — once under its tab and again beside it — shows up as the
duplicate it is instead of hiding at a level the test never looked at."
  (apply #'append
         (mapcar (lambda (node)
                   (append (when (eq 'herdr-pane (nth 0 node))
                             (list (nth 1 node)))
                           (herdr-tree-test--pane-ids (nth 3 node))))
                 nodes)))

(ert-deftest herdr-tree-does-not-repeat-a-pane-whose-tab-is-cached ()
  "Guards the other direction: the orphan pass must not also emit panes
their own tab already renders.  Every pane appears exactly once."
  (should (equal '("w1:p1" "w1:p2" "w1:p3")
                 (sort (herdr-tree-test--pane-ids
                        (herdr-tree-build (herdr-tree-test--state) nil))
                       #'string<))))

(ert-deftest herdr-tree-omits-worktrees-when-not-fetched ()
  "A workspace absent from WORKTREES gets no worktrees section."
  (should-not
   (seq-find (lambda (node) (eq 'herdr-worktrees (car node)))
             (herdr-tree-test--pane-nodes (car (herdr-tree-build (herdr-tree-test--state) nil))))))

(ert-deftest herdr-tree-includes-worktrees-when-fetched ()
  "A workspace present in WORKTREES gets a worktree node, after its panes."
  (let* ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-feat")
                                (is_linked_worktree . t)
                                (branch . "feat/dispatch")
                                (label . "feat/dispatch")
                                (open_workspace_id . nil))))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (rows (herdr-tree-test--worktree-rows children)))
    (should (equal 1 (length rows)))
    (should (eq 'herdr-worktree (nth 0 (car rows))))))

(ert-deftest herdr-tree-draws-no-worktrees-section-for-a-bare-checkout ()
  "The live session, exactly: one entry, and it is the workspace itself.

`worktree.list' returns the repository's own checkout alongside its
linked worktrees, and every workspace measured in the user's session
answered with that one entry and nothing else — `is_linked_worktree'
false, `open_workspace_id' naming the enclosing workspace.  So every
`worktrees (1)' heading on screen was listing the workspace its own
heading is one line above, and `k' on that row resolved to
`(herdr-worktree-remove \"w1\")' — destroying the workspace point was
standing in.

Both halves are asserted, because a filter that dropped the row and
still emitted the group would leave a `worktrees (0)' heading behind and
`k' on THAT heading falls through to the enclosing workspace just as
destructively."
  (let* ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/herdr.el")
                                (branch . "main")
                                (is_linked_worktree . nil)
                                (open_workspace_id . "w1"))))))))
         (children (herdr-tree-test--pane-nodes (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees)))))
    (should-not (seq-find (lambda (node) (eq 'herdr-worktrees (nth 0 node)))
                          children))
    (should-not (seq-find (lambda (node) (eq 'herdr-worktree (nth 0 node)))
                          children))))

(ert-deftest herdr-tree-lists-the-linked-worktrees-and-not-the-checkout ()
  "The mixed case, and the one that says the count follows the filter.

A repository with a worktree answers with two entries: itself and the
worktree.  Only the second is a row here: a checkout the user cannot
act on must not be drawn as one they can.

The entries are ordered checkout-first, which is the order git and the
server both report, so a filter that only ever dropped the last entry
would not pass."
  (let* ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/herdr.el")
                                (branch . "main")
                                (is_linked_worktree . nil)
                                (open_workspace_id . "w1"))
                               ((path . "/tmp/herdr.el-feat")
                                (branch . "feat/dispatch")
                                (is_linked_worktree . t)
                                (open_workspace_id . nil))))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees)))))
    (should (equal '("/tmp/herdr.el-feat")
                   (mapcar (lambda (node) (nth 1 node))
                           (herdr-tree-test--worktree-rows children))))))

(ert-deftest herdr-tree-draws-no-row-for-the-workspace-the-list-belongs-to ()
  "The same destruction, one shape over, and made by this package's own RET.

`is_linked_worktree' alone does not catch it.  Press RET on a worktree
row and `herdr-dispatch-open-worktree' opens it as a workspace of its
own; the next `worktree.list' for that workspace then returns its own
directory as a LINKED worktree whose `open_workspace_id' is that
workspace.  It renders inside its own worktrees section, and `k' there
resolves to the workspace the row is nested under — which is the
workspace you are standing in, exactly as before.

Not reachable in the session the first fix was measured against, which
had no linked worktrees at all, so nothing caught it.

The entry here is `is_linked_worktree' TRUE, which is what makes this a
different test from the bare-checkout one rather than the same test
twice."
  (let* ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-fix")
                                (branch . "fix")
                                (is_linked_worktree . t)
                                (open_workspace_id . "w1"))))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees)))))
    (should-not (herdr-tree-test--worktree-rows children))))

(ert-deftest herdr-tree-keeps-a-sibling-worktree-beside-the-self-row ()
  "Dropping the self row must not drop the section with it.

The workspace's own row goes; a genuine sibling worktree stays.  A
filter that keyed on the whole set rather than the row would pass the
test above and lose every real worktree here."
  (let* ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-fix")
                                (branch . "fix")
                                (is_linked_worktree . t)
                                (open_workspace_id . "w1"))
                               ((path . "/tmp/herdr.el-spike")
                                (branch . "spike")
                                (is_linked_worktree . t)
                                (open_workspace_id . nil))))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees)))))
    (should (equal '("/tmp/herdr.el-spike")
                   (mapcar (lambda (node) (nth 1 node))
                           (herdr-tree-test--worktree-rows children))))))

(ert-deftest herdr-tree-drops-a-checkout-that-is-not-this-workspace ()
  "The case only `herdr-worktree-linked-p' catches, in the renderer.

Every other bare-checkout test here has the checkout naming the
enclosing workspace, so `herdr-tree-own-workspace-p' catches those too
and the linked check could be deleted without a single failure — which
is exactly what a mutation run found.

This is the shape that separates them.  The listing is fetched for the
workspace's pane cwd, so a pane `cd'-ed into another repository — or a
workspace whose first pane sits inside a checkout herdr opened
separately — produces a reply whose main checkout names a DIFFERENT
workspace, or none at all.  Still not a worktree; still must not be a
row, because `k' on it would remove whatever workspace it does name."
  (dolist (open '("w9" nil))
    (let* ((worktrees `(("w1" . ((worktrees . (((path . "/tmp/elsewhere")
                                  (branch . "main")
                                  (is_linked_worktree . nil)
                                  (open_workspace_id . ,open))))))))
           (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                   worktrees)))))
      (should-not (herdr-tree-test--worktree-rows children)))))

(ert-deftest herdr-tree-own-workspace-p-asks-only-about-this-listing ()
  "Neither predicate subsumes the other, so both get applied.

`herdr-tree-own-workspace-p' asks \\='is this row the workspace it is
nested under?\\=', which a main checkout also answers yes to — but not
always.  The listing is fetched for the workspace's pane cwd, and a pane
`cd'-ed into another repository produces a reply whose main checkout
names some OTHER workspace, or none: that is the third case here, and it
is why `herdr-worktree-linked-p' still has to be asked."
  (should (herdr-tree-own-workspace-p '((open_workspace_id . "w1")) "w1"))
  (should-not (herdr-tree-own-workspace-p '((open_workspace_id . "w2")) "w1"))
  (should-not (herdr-tree-own-workspace-p '((open_workspace_id . nil)) "w1"))
  ;; Not "both nil, therefore the same thing".
  (should-not (herdr-tree-own-workspace-p '((open_workspace_id . nil)) nil)))

(ert-deftest herdr-tree-treats-a-missing-linked-flag-as-not-linked ()
  "`is_linked_worktree' is a required field, so its absence is a reply the
schema does not describe.  Dropping the row costs a line the workspace
heading above it already shows; keeping it costs the workspace, because
`open_workspace_id' on a main checkout names the enclosing workspace.
So absence reads as not linked."
  (should-not (herdr-worktree-linked-p '((path . "/tmp/x")
                                              (branch . "main"))))
  (should-not (herdr-worktree-linked-p '((is_linked_worktree . nil))))
  (should (herdr-worktree-linked-p '((is_linked_worktree . t)))))

(ert-deftest herdr-tree-worktree-row-shows-its-own-directory ()
  "A worktree row named only by branch gave no way to tell two
same-named branches in different repositories apart, or to see where a
worktree actually lives without opening it first -- the same directory
column a workspace row already carries."
  (let* ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-feat")
                                (is_linked_worktree . t)
                                (branch . "feat/dispatch"))))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (worktree (car (herdr-tree-test--worktree-rows children))))
    (should (string-match-p "/tmp/herdr.el-feat" (nth 2 worktree)))))

(ert-deftest herdr-tree-worktree-row-abbreviates-a-home-relative-path ()
  "The path the server reports is the full absolute one, unlike a
known-project root, which `project-known-project-roots' already hands
back abbreviated -- so this is the one place that had nothing shortening
it."
  (let* ((dir (expand-file-name "~/herdr-test-worktree"))
         (line (nth 2 (herdr-tree--worktree-node
                       `((path . ,dir) (branch . "feat/dispatch"))
                       20))))
    (should (string-match-p "~/herdr-test-worktree" line))
    (should-not (string-match-p (regexp-quote dir) line))))

(ert-deftest herdr-tree-worktree-row-is-dimmed-like-a-known-project-row ()
  "The whole row is dimmed, not just the path -- the same `shadow'
treatment an unopened worktree row gets,
since a worktree is not itself running anything either.  Only dimming
the path made a worktree row look like it belonged to a different kind
of row than an inactive project, when they mean the same thing."
  (let ((line (nth 2 (herdr-tree--worktree-node
                      '((path . "/tmp/herdr.el-feat") (branch . "feat/dispatch"))
                      20))))
    (should (eq 'shadow (get-text-property 0 'font-lock-face line)))
    (should (eq 'shadow (get-text-property
                         (string-match "/tmp/herdr.el-feat" line)
                         'font-lock-face line)))))

(ert-deftest herdr-tree-worktree-column-widens-to-fit-the-longest-branch ()
  "A fixed column ran long branch names straight into the directory
column with no gap at all; this is computed the same way the agent
column is, from the widest name actually present."
  (let ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/a") (branch . "short"))
                              ((path . "/tmp/b")
                               (branch . "a-rather-long-feature-branch-name")))))))))
    (should (= (length "a-rather-long-feature-branch-name")
               (herdr-tree--worktree-column-width worktrees)))))

(ert-deftest herdr-tree-worktree-column-width-has-a-floor ()
  (should (= herdr-tree-worktree-column-min
             (herdr-tree--worktree-column-width nil)))
  (should (= herdr-tree-worktree-column-min
             (herdr-tree--worktree-column-width
              '(("w1" . ((worktrees . (((path . "/tmp/a") (branch . "x")))))))))))

(ert-deftest herdr-tree-dims-a-worktree-already-open-as-a-workspace ()
  (let* ((worktrees '(("w1" . ((worktrees . (((path . "/tmp/herdr.el-feat")
                                (is_linked_worktree . t)
                                (branch . "feat/dispatch")
                                (label . "feat/dispatch")
                                (open_workspace_id . "w2"))))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (worktree (car (herdr-tree-test--worktree-rows children))))
    (should (equal 'herdr-worktree (nth 0 worktree)))
    (should (string-match-p "open" (nth 2 worktree)))))

;;; A worktree open as a workspace of its own

(defconst herdr-tree-test--worktree-reply
  '(((path . "/tmp/herdr.el") (branch . "main")
     (is_linked_worktree . nil) (open_workspace_id . "w1"))
    ((path . "/tmp/herdr.el-feat") (branch . "feat")
     (is_linked_worktree . t) (open_workspace_id . "w2"))
    ((path . "/tmp/herdr.el-other") (branch . "other")
     (is_linked_worktree . t)))
  "One repository: its main checkout, a worktree open as w2, and one not open.")

(defun herdr-tree-test--worktree-state (&rest workspace-ids)
  "Return a state with one workspace per id in WORKSPACE-IDS.
`w1' is the repository at /tmp/herdr.el; `w2' is its worktree at
/tmp/herdr.el-feat.  Each gets one pane, since a workspace with no pane
has no directory and so no repository either."
  (let ((directories '(("w1" . "/tmp/herdr.el")
                       ("w2" . "/tmp/herdr.el-feat"))))
    (herdr-state-from-snapshot
     `((workspaces . ,(mapcar (lambda (id)
                                `((workspace_id . ,id) (label . ,id)
                                  (pane_count . 1)))
                              workspace-ids))
       (panes . ,(mapcar (lambda (id)
                           `((pane_id . ,(concat id ":p1"))
                             (workspace_id . ,id) (agent . "claude")
                             (agent_status . "idle")
                             (cwd . ,(cdr (assoc id directories)))))
                         workspace-ids))))))

(defconst herdr-tree-test--worktree-source
  '((repo_key . "/tmp/herdr.el/.git") (repo_name . "herdr.el")
    (repo_root . "/tmp/herdr.el")
    (source_checkout_path . "/tmp/herdr.el"))
  "The `source' object `worktree.list' answers with beside its array.
`repo_root' is the main checkout, which the package reads rather than
inferring from the entry that is not a linked worktree.")

(defun herdr-tree-test--repository-cache (&rest ids)
  "Return a worktree cache answering `herdr-tree-test--worktree-reply' for IDS."
  (mapcar (lambda (id)
            (cons id `((source . ,herdr-tree-test--worktree-source)
                       (worktrees . ,herdr-tree-test--worktree-reply))))
          ids))

(ert-deftest herdr-tree-workspace-repository-names-the-open-repository ()
  "The worktree workspace has a repository on screen; the repository
itself does not, being its own main checkout."
  (let ((state (herdr-tree-test--worktree-state "w1" "w2"))
        (worktrees (herdr-tree-test--repository-cache "w1" "w2")))
    (should (equal "w1" (herdr-tree--workspace-repository state "w2" worktrees)))
    (should-not (herdr-tree--workspace-repository state "w1" worktrees))))

(ert-deftest herdr-tree-workspace-repository-needs-the-repository-open ()
  "A worktree whose repository has no workspace open has nowhere to nest,
and a workspace whose reply has not landed cannot be placed at all."
  (should-not (herdr-tree--workspace-repository
               (herdr-tree-test--worktree-state "w2") "w2"
               (herdr-tree-test--repository-cache "w2")))
  (should-not (herdr-tree--workspace-repository
               (herdr-tree-test--worktree-state "w1" "w2") "w2" nil)))

(ert-deftest herdr-tree-build-nests-a-worktree-workspace-under-its-repository ()
  "The reported shape: `project-el' drew a top-level workspace row beside
the repository it is a worktree of, while that repository's worktrees
section drew a dimmed pointer at it -- the same worktree twice.  The
workspace now takes the pointer's place, panes and all."
  (should (equal '((herdr-workspace
                    (herdr-pane)
                    (herdr-worktrees
                     (herdr-workspace (herdr-pane))
                     (herdr-worktree))))
                 (herdr-tree-test--types
                  (herdr-tree-build (herdr-tree-test--worktree-state "w1" "w2")
                                    (herdr-tree-test--repository-cache "w1" "w2"))))))

(ert-deftest herdr-tree-a-nested-workspace-draws-no-worktrees-of-its-own ()
  "A nested workspace's own reply names its siblings, and those siblings
are drawn beside it under the same repository.  Repeating them one level
deeper would file every worktree of the repository under every other one."
  (let* ((tree (herdr-tree-build (herdr-tree-test--worktree-state "w1" "w2")
                                 (herdr-tree-test--repository-cache "w1" "w2")))
         (rows (herdr-tree-test--worktree-rows (nth 3 (car tree))))
         (nested (car rows)))
    (should (= 2 (length rows)))
    (should (equal 'herdr-workspace (nth 0 nested)))
    (should (equal "w2" (nth 1 nested)))
    (should (equal '(herdr-pane)
                   (mapcar (lambda (n) (nth 0 n)) (nth 3 nested))))))

(ert-deftest herdr-tree-build-leaves-a-worktree-workspace-with-no-repository-open ()
  "Nothing to nest under means nothing moves, and the workspace keeps the
worktrees section it draws for its own siblings."
  (should (equal '((herdr-workspace
                    (herdr-pane)
                    (herdr-worktrees (herdr-worktree))))
                 (herdr-tree-test--types
                  (herdr-tree-build (herdr-tree-test--worktree-state "w2")
                                    (herdr-tree-test--repository-cache "w2"))))))

(ert-deftest herdr-tree-nesting-refuses-a-chain ()
  "A worktree's main checkout is the repository, so no chain of length
two can form from a well-formed reply.  Were one to form anyway, the
grandchild would be spliced into a section its parent never draws and
would vanish; it stays at top level instead."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1")) ((workspace_id . "w2"))
                                 ((workspace_id . "w3"))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (cwd . "/tmp/a"))
                            ((pane_id . "w2:p1") (workspace_id . "w2")
                             (cwd . "/tmp/a-w2"))
                            ((pane_id . "w3:p1") (workspace_id . "w3")
                             (cwd . "/tmp/a-w3")))))))
        ;; A reply whose repository is itself a worktree: w2 under w3,
        ;; w3 under w1.  Nesting is decided by `source.repo_root' alone,
        ;; so the array is not needed here.
        (worktrees '(("w2" . ((source . ((repo_root . "/tmp/a-w3")))))
                     ("w3" . ((source . ((repo_root . "/tmp/a"))))))))
    (should (equal '(("w3" . "w1"))
                   (herdr-tree--nesting state (herdr-state-workspaces state)
                                        worktrees)))))

(ert-deftest herdr-tree-worktree-nodes-still-point-at-an-unnested-workspace ()
  "The `open as W' row is the fallback now, not the rule -- it is what a
worktree gets when its repository is not on screen as a workspace to
nest it under."
  (let ((rows (herdr-tree--worktree-nodes
               "w1" (herdr-tree-test--repository-cache "w1") 20)))
    (should (equal '(herdr-worktree herdr-worktree)
                   (mapcar (lambda (row) (nth 0 row)) rows)))
    (should (string-match-p "open as w2" (nth 2 (car rows))))))

;;; Status summary

(defun herdr-tree-test--status-state (&rest specs)
  "Build a state from SPECS, each (ID AGENT STATUS)."
  (herdr-state-from-snapshot
   `((panes . ,(mapcar (lambda (spec)
                         `((pane_id . ,(nth 0 spec))
                           (agent . ,(nth 1 spec))
                           (agent_status . ,(nth 2 spec))
                           (workspace_id . "w1")))
                       specs)))))

(ert-deftest herdr-tree-status-summary-omits-idle ()
  "An always-on marker stops being read; idle is not news."
  (should (equal "" (herdr-tree-status-summary
                     (herdr-tree-test--status-state
                      '("w1:p1" "claude" "idle"))))))

(ert-deftest herdr-tree-status-summary-uses-the-established-order ()
  "Statuses appear in `herdr-tree-noteworthy-statuses' order — blocked,
then working, then done — regardless of the order agents were created in."
  (should (equal (concat "1" (herdr-tree-glyph "blocked")
                         "1" (herdr-tree-glyph "working")
                         "1" (herdr-tree-glyph "done"))
                 (herdr-tree-status-summary
                  (herdr-tree-test--status-state
                   '("w1:p1" "claude" "done")
                   '("w1:p2" "codex" "working")
                   '("w1:p3" "gemini" "blocked"))))))

(ert-deftest herdr-tree-status-summary-is-empty-with-nothing-noteworthy ()
  (should (equal "" (herdr-tree-status-summary (herdr-state-empty))))
  (should (equal "" (herdr-tree-status-summary
                     (herdr-tree-test--status-state
                      '("w1:p1" "claude" "idle"))))))

(ert-deftest herdr-tree-workspace-row-shows-the-branch-it-is-on ()
  "herdr\\='s own sidebar names a workspace and the branch its checkout is
on.  Only a `worktree.list' reply carries a branch — no snapshot field
does — and the entry naming this workspace as its open workspace is the
checkout to read it from, not whichever entry happens to come first."
  (let* ((tree (herdr-tree-build (herdr-tree-test--worktree-state "w1" "w2")
                                 (herdr-tree-test--repository-cache "w1" "w2")))
         (line (nth 2 (car tree))))
    ;; w1's own checkout is on `main'; `feat' belongs to the worktree.
    (should (string-match-p "main" line))
    (should-not (string-match-p "feat" line))))

(ert-deftest herdr-tree-workspace-row-has-no-branch-before-the-reply-lands ()
  "A workspace whose listing has not arrived, or whose directory is not a
repository at all, shows no branch rather than a placeholder."
  (let ((line (nth 2 (car (herdr-tree-build (herdr-tree-test--state) nil)))))
    (should (string-match-p "herdr\\.el" line))
    (should-not (string-match-p "main" line))))

(defun herdr-tree-test--queue-state (&rest specs)
  "Return a state whose agents are SPECS, each (ID STATUS SEQ).

A spec of `done' seeds the record as `idle' and marks the pane unseen,
because that is the only shape the server can produce: `done' never
crosses the wire, and a fixture writing it into `agent_status' would
test a record herdr cannot send."
  (let ((state (herdr-state-from-snapshot
                `((workspaces . (((workspace_id . "w1") (label . "web"))))
                  (panes . ,(mapcar
                             (lambda (spec)
                               `((pane_id . ,(nth 0 spec))
                                 (workspace_id . "w1")
                                 (agent . "claude")
                                 (agent_status
                                  . ,(if (equal (nth 1 spec) "done")
                                         "idle"
                                       (nth 1 spec)))
                                 (state_change_seq . ,(nth 2 spec))))
                             specs))))))
    (setf (herdr-state-done-panes state)
          (mapcar (lambda (spec) (nth 0 spec))
                  (seq-filter (lambda (spec) (equal (nth 1 spec) "done"))
                              specs)))
    state))

(ert-deftest herdr-tree-queue-heads-the-worst-first-and-omits-what-is-empty ()
  "Worst first, so the section that wants you most is the one you land on.
A status nothing is in gets no heading: a section reading (0) is a line
that never says anything."
  (let ((nodes (herdr-tree-queue-nodes
                (list (cons nil (herdr-tree-test--queue-state
                                 '("w1:p1" "idle" 1)
                                 '("w1:p2" "blocked" 2)
                                 '("w1:p3" "done" 3)))))))
    (should (equal '("BLOCKED (1)" "READY (1)" "IDLE (1)")
                   (mapcar (lambda (node) (nth 2 node)) nodes)))
    (should (equal '(herdr-queue herdr-queue herdr-queue)
                   (mapcar (lambda (node) (nth 0 node)) nodes)))))

(ert-deftest herdr-tree-queue-heads-a-real-completion-ready ()
  "The whole path, from the event herdr sends to the heading you read.

Every other queue test sets the done mark by hand.  This one drives the
only thing the server actually emits - working, then idle - so a change
that leaves the mark unset, or that reads the record instead of the
projection, cannot pass by agreeing with a fixture."
  (let* ((state (herdr-tree-test--queue-state '("w1:p1" "idle" 1)))
         (done (herdr-state-reduce
                (herdr-state-reduce state "pane.agent_status_changed"
                                    '((pane_id . "w1:p1")
                                      (agent_status . "working")))
                "pane.agent_status_changed"
                '((pane_id . "w1:p1") (agent_status . "idle")))))
    (should (equal '("READY (1)")
                   (mapcar (lambda (node) (nth 2 node))
                           (herdr-tree-queue-nodes (list (cons nil done))))))
    ;; Looking at it puts it back under IDLE.
    (should (equal '("IDLE (1)")
                   (mapcar (lambda (node) (nth 2 node))
                           (herdr-tree-queue-nodes
                            (list (cons nil (herdr-state-reduce
                                             done "pane_focused"
                                             '((pane_id . "w1:p1")))))))))))

(ert-deftest herdr-tree-queue-reads-done-as-ready-and-keeps-unknown-apart ()
  "herdr says `idle' and `done' both mean ready for input and uses its
seen state to tell them apart, so `done' is work nobody has looked at:
READY.  `unknown' keeps a heading of its own because herdr says it does
not prove completion — it must not read as nothing to do."
  (let ((headings (mapcar (lambda (node) (nth 2 node))
                          (herdr-tree-queue-nodes
                           (list (cons nil (herdr-tree-test--queue-state
                                            '("w1:p1" "done" 1)
                                            '("w1:p2" "unknown" 2))))))))
    (should (equal '("READY (1)" "UNKNOWN (1)") headings))))

(ert-deftest herdr-tree-queue-puts-the-newest-news-first-in-a-section ()
  "`state_change_seq' is the only ordering a pane record carries: no
field says when a change happened, so the highest seq is the most recent
news and leads its group."
  (let* ((nodes (herdr-tree-queue-nodes
                 (list (cons nil (herdr-tree-test--queue-state
                                  '("w1:p1" "done" 10)
                                  '("w1:p2" "done" 30)
                                  '("w1:p3" "done" 20))))))
         (ids (mapcar (lambda (row) (nth 1 row)) (nth 3 (car nodes)))))
    (should (equal '("w1:p2" "w1:p3" "w1:p1") ids))))

(ert-deftest herdr-tree-queue-rows-are-pane-nodes ()
  "A queue row is a `herdr-pane' node like any other, so every verb
already aimed at a pane row works on it with no arm of its own."
  (let ((row (car (nth 3 (car (herdr-tree-queue-nodes
                              (list (cons nil (herdr-tree-test--queue-state
                                               '("w1:p1" "blocked" 1))))))))))
    (should (eq 'herdr-pane (nth 0 row)))
    (should (equal "w1:p1" (nth 1 row)))
    (should-not (nth 3 row))))

(ert-deftest herdr-tree-queue-carries-the-machine-only-when-there-are-several ()
  "A queue is ordered by attention, not by machine, so a row has no
machine heading above it to be read off.  It carries the name on its own
line instead — and only when there is a choice to be made, so a
single-machine queue is free of a name that says nothing."
  (let* ((one (herdr-tree-test--queue-state '("w1:p1" "blocked" 1)))
         (alone (car (nth 3 (car (herdr-tree-queue-nodes
                                  (list (cons nil one)))))))
         (several (nth 3 (car (herdr-tree-queue-nodes
                               (list (cons "local" one)
                                     (cons "shadow" one)))))))
    (should-not (get-text-property 0 'herdr-machine (nth 2 alone)))
    (should (equal '("local" "shadow")
                   (mapcar (lambda (row)
                             (get-text-property
                              (string-match-p "claude" (nth 2 row))
                              'herdr-machine (nth 2 row)))
                           several)))))
