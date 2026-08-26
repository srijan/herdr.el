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
      (tabs . (((tab_id . "w1:t1") (workspace_id . "w1") (label . "agents")
                (pane_count . 2) (agent_status . "blocked"))
               ((tab_id . "w1:t2") (workspace_id . "w1") (label . "checks")
                (pane_count . 1) (agent_status . "idle"))))
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

(defun herdr-tree-test--types (nodes)
  "Return the nested (TYPE . CHILD-TYPES) shape of NODES."
  (mapcar (lambda (node)
            (cons (nth 0 node) (herdr-tree-test--types (nth 3 node))))
          nodes))

(ert-deftest herdr-tree-pane-name-joins-the-label-and-the-title ()
  "Both halves: the label says which pane this is, the title says what it
is doing, and a row that dropped either lost something real."
  (should (equal "Lantern · fixing tests"
                 (herdr-tree-pane-name
                  '((pane_id . "w16:p2") (label . "Lantern")
                    (terminal_title_stripped . "fixing tests"))))))

(ert-deftest herdr-tree-pane-name-does-not-print-a-repeat ()
  (should (equal "Lantern"
                 (herdr-tree-pane-name
                  '((pane_id . "w16:p2") (label . "Lantern")
                    (terminal_title_stripped . "Lantern"))))))

(ert-deftest herdr-tree-pane-name-strips-the-spinner-from-the-title ()
  "The title half goes through `herdr-tree--steady-title' like it always
did, so a labelled pane does not reintroduce the churn."
  (should (equal "Lantern · fixing tests"
                 (herdr-tree-pane-name
                  '((pane_id . "w16:p2") (label . "Lantern")
                    (terminal_title_stripped . "◐ fixing tests"))))))

(ert-deftest herdr-tree-pane-name-is-just-the-label-without-a-title ()
  (should (equal "Lantern"
                 (herdr-tree-pane-name
                  '((pane_id . "w16:p2") (label . "Lantern"))))))

(ert-deftest herdr-tree-pane-name-falls-back-to-the-steady-title ()
  "An unlabelled pane — most of them — reads exactly as it did before."
  (should (equal "fixing tests"
                 (herdr-tree-pane-name
                  '((pane_id . "w1:p1")
                    (terminal_title_stripped . "fixing tests"))))))

(ert-deftest herdr-tree-pane-name-is-empty-with-neither ()
  (should (equal "" (herdr-tree-pane-name '((pane_id . "w1:p1"))))))

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
                  (tabs . (((tab_id . "w1:t1") (workspace_id . "w1")
                            (label . "1") (pane_count . 1))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude"))))))))
    (should (equal '((herdr-workspace (herdr-pane)))
                   (herdr-tree-test--types (herdr-tree-build state nil))))))

(ert-deftest herdr-tree-workspace-line-carries-directory-and-rollup ()
  (let ((line (nth 2 (car (herdr-tree-build (herdr-tree-test--state) nil)))))
    (should (string-match-p "herdr.el" line))
    (should (string-match-p "/tmp/herdr.el" line))
    (should (string-match-p (herdr-tree-glyph "blocked") line))))

(ert-deftest herdr-tree-workspace-line-abbreviates-a-home-relative-directory ()
  "A known-project row already shows `~/\\=' for free, since
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

`Unstaged changes (1)\\=' is a heading that owns a countable number of
children; `.emacs.d (2)\\=' says the same thing about the same kind of
line.  A `2 panes\\=' column in the middle of the line said it too, but
said it in a place the eye has to travel to and in a shape shared with
the leaf rows, which own nothing.  Both halves are asserted: the count is
in parentheses on the label, and the column it replaced is gone rather
than duplicated beside it."
  (let* ((worktrees '(("w1" . (((path . "/tmp/wt")
                                (is_linked_worktree . t)
                                (branch . "feat/x"))))))
         (workspace (car (herdr-tree-build (herdr-tree-test--state) worktrees)))
         (children (nth 3 workspace))
         (worktrees-node (car (last children))))
    (should (string-match-p "herdr\\.el (3)" (nth 2 workspace)))
    (should (string-match-p "worktrees (1)" (nth 2 worktrees-node)))
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
  (let* ((panes (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
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

(ert-deftest herdr-tree-keeps-the-words-of-a-title-it-normalises ()
  "Only the leading glyph run and the space after it come off.

A title is the agent's own words; stripping is for the animation, not
for the message.  A title that is nothing but a spinner is the one case
that ends up empty, and it says nothing anyway."
  (should (equal "Debug webmentions from fed.brid.gy"
                 (herdr-tree--steady-title
                  "◐ Debug webmentions from fed.brid.gy")))
  (should (equal "Debug webmentions" (herdr-tree--steady-title
                                      "Debug webmentions")))
  (should (equal "" (herdr-tree--steady-title "◑ ")))
  (should (equal "" (herdr-tree--steady-title "")))
  ;; Not from the middle or the end: those are the agent's characters.
  (should (equal "phase ◐ two" (herdr-tree--steady-title "phase ◐ two")))
  (should (equal "done ◑" (herdr-tree--steady-title "done ◑"))))

(ert-deftest herdr-tree-spinner-glyphs-are-quoted-into-the-character-class ()
  "The constant is interpolated into a regexp, and it invites editing.

Its docstring says to add a glyph when another agent turns up, so the
next character in it is chosen by whoever hits that.  Interpolated raw
between brackets, some characters stop being characters:

  a leading `^' negates the class — `[^◐]' matches everything that is
  NOT the spinner, so the first title word is deleted and the rest of
  the line with it, on every pane, silently;

  a `-' between two others makes a range — `[a-z]' is twenty-six
  characters nobody put there.

`regexp-opt-charset' quotes both back into literals (`[◐^]', `[az-]'),
and these are the two sets that tell the two spellings apart.  A set of
`]', `^' and `-' does NOT: Emacs happens to read `[]^-]' as three
literals either way, so a test using that one passes over the raw
version — which a mutation run found it doing."
  (let ((herdr-tree-spinner-glyphs '(?^ ?◐)))
    (should (equal "working" (herdr-tree--steady-title "^ working")))
    (should (equal "working" (herdr-tree--steady-title "◐ working")))
    ;; The whole point: a title with no glyph at its head keeps every
    ;; character it had.
    (should (equal "hello world" (herdr-tree--steady-title "hello world"))))
  (let ((herdr-tree-spinner-glyphs '(?a ?- ?z)))
    (should (equal "hello world" (herdr-tree--steady-title "hello world")))
    (should (equal "world" (herdr-tree--steady-title "az- world"))))
  ;; A single glyph is a class of one, which needs no brackets at all and
  ;; must still not swallow the character after it.
  (let ((herdr-tree-spinner-glyphs '(?◐)))
    (should (equal "working" (herdr-tree--steady-title "◐ working")))
    (should (equal "◑ working" (herdr-tree--steady-title "◑ working")))))

(ert-deftest herdr-tree-spinner-normalisation-reaches-the-pane-row ()
  "The strip has to happen where the line is built, not only in the helper.

A `herdr-tree--steady-title' that nothing calls would pass every
assertion above while the dashboard went on redrawing once a second."
  (let ((line (nth 2 (car (nth 3 (car (herdr-tree-build
                                       (herdr-tree-test--spinning-state
                                        "◐ Debug webmentions")
                                       nil)))))))
    (should (string-match-p "Debug webmentions" line))
    (should-not (string-match-p "◐" line))))

;;; Faces

(defun herdr-tree-test--face-of (line text)
  "Return the face LINE carries where TEXT begins in it.
Read off `font-lock-face\\=', which is only half the answer — see
`herdr-tree-faces-a-field-with-both-properties\\=' for the other half and
for why one property alone renders as nothing."
  (get-text-property (string-match text line) 'font-lock-face line))

(ert-deftest herdr-tree-faces-a-field-with-both-properties ()
  "A face has to be written twice or it is invisible half the time.

`face\\=' alone is erased: `magit-section-mode\\=' sets
`font-lock-defaults\\=', so `font-lock-mode\\=' comes on in the dashboard,
and `font-lock-default-unfontify-region\\=' removes `face\\=' before the
line is first fontified.  That was the original bug, and the fix moved
everything to `font-lock-face\\='.

`font-lock-face\\=' alone renders as nothing: it is not a display
property, only a `char-property-alias-alist\\=' entry that
`font-lock-mode\\=' installs, so with font-lock off it means nothing to
redisplay.  That was the next bug, verified with `face-at-point\\='
answering nil across the whole dashboard.  magit sets both properties
for exactly this reason.

Neither failure is observable in batch — `font-lock-mode\\=' forces
itself off under `noninteractive\\=', which is why 302 tests passed over
a dashboard that rendered no faces at all.  The presence of both
properties is what a batch test can see, so that is what this asserts,
on a real pane row as well as on `herdr-tree--faced\\=' directly."
  (let ((faced (herdr-tree--faced "working" 'warning)))
    (should (eq 'warning (get-text-property 0 'font-lock-face faced)))
    (should (eq 'warning (get-text-property 0 'face faced))))
  ;; Unfaced text gains neither, or every gap-filling scan over a line
  ;; would find no gaps.
  (let ((plain (herdr-tree--faced "working" nil)))
    (should-not (get-text-property 0 'font-lock-face plain))
    (should-not (get-text-property 0 'face plain)))
  (let* ((panes (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
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
  (let* ((panes (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
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

(ert-deftest herdr-tree-dims-the-fields-that-are-not-the-news ()
  "The pane id and the terminal title are context, not the message.

Built-in faces rather than colours of our own, so a theme keeps working;
asserting the face name is what would catch a hardcoded colour creeping
back in."
  (let* ((workspace (car (herdr-tree-build (herdr-tree-test--state) nil)))
         (line (nth 2 workspace))
         (pane (nth 2 (car (nth 3 workspace)))))
    (should (eq 'font-lock-comment-face
                (herdr-tree-test--face-of line "/tmp/herdr\\.el")))
    (should (eq 'shadow (herdr-tree-test--face-of pane "w1:p1")))
    (should (eq 'font-lock-doc-face
                (herdr-tree-test--face-of pane "fixing tests")))
    ;; The rollup glyph on a collapsed heading keeps its status colour.
    (should (eq (herdr-tree-status-face "blocked")
                (get-text-property (1- (length line)) 'font-lock-face line)))))

(ert-deftest herdr-tree-faces-do-not-make-two-equal-trees-differ ()
  "Text properties must stay invisible to `equal\\='.

`herdr-dispatch-refresh\\=' skips a redraw when the tree it just built
equals the one on screen, and the tree tests above compare lines with
`equal\\=' and `string-match-p\\='.  Both would be wrong if a face could
change the identity of a string — which is the reason faces can live
here at all rather than in the renderer."
  (let ((state (herdr-tree-test--state)))
    (should (equal (herdr-tree-build state nil) (herdr-tree-build state nil)))
    (should (equal "working" (substring-no-properties
                              (herdr-tree--faced "working" 'warning))))
    (should (equal (herdr-tree--faced "working" 'warning)
                   (herdr-tree--faced "working" 'success)))))

(ert-deftest herdr-tree-agent-column-widens-to-fit-the-longest-label ()
  "A fixed column truncates nothing — `%-Ns\\=' never cuts a longer
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
         (children (nth 3 (car (herdr-tree-build state nil))))
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
         (line (nth 2 (car (nth 3 (car (herdr-tree-build state nil)))))))
    (should (= (+ herdr-tree-agent-column-min 3) (string-match "working" line)))))

(ert-deftest herdr-tree-marks-agentless-panes-as-shells ()
  "A pane with no agent reads as a shell — no caste star, no status."
  (let* ((state (herdr-tree-test--state
                 '(panes . (((pane_id . "w1:p3") (workspace_id . "w1")
                             (tab_id . "w1:t2") (agent_status . "idle")
                             (cwd . "/tmp/herdr.el"))))))
         (panes (nth 3 (car (herdr-tree-build state nil))))
         (pane (nth 2 (car panes))))
    (should (string-match-p "~" pane))
    (should (string-match-p "shell" pane))
    (should-not (string-match-p "shell\\*" pane))))

(ert-deftest herdr-tree-appends-an-agent-name-when-set ()
  (let* ((state (herdr-tree-test--state
                 '(agents . (((pane_id . "w1:p1") (agent . "claude")
                              (name . "reviewer"))))))
         (panes (nth 3 (car (herdr-tree-build state nil))))
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

Reachable rather than theoretical: `herdr-state' drops a `tab_created\\='
event that carries no `tab\\=' payload, and a resync races the events
around it.  This is that state exactly — one workspace, one blocked pane,
no tabs."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1") (label . "repo")
                                  (pane_count . 1))))
                  (tabs . nil)
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude")
                             (agent_status . "blocked"))))))))
    (let ((tree (herdr-tree-build state nil)))
      (should (equal '((herdr-workspace (herdr-pane)))
                     (herdr-tree-test--types tree)))
      ;; The row must name the pane, or it is reachable only in shape.
      (should (equal "w1:p1" (nth 1 (car (nth 3 (car tree))))))
      (should (string-match-p "w1:p1" (nth 2 (car (nth 3 (car tree)))))))))

(ert-deftest herdr-tree-flat-listing-ignores-whether-a-panes-tab-is-cached ()
  "The partial case that used to need dedicated orphan handling: some
tabs known, one pane naming a tab that is not.  Flat listing filters
panes by `workspace_id\\=' alone, so a pane whose tab the cache does not
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
    (should (equal "w1:p9" (nth 1 (nth 2 (nth 3 (car tree))))))))

(defun herdr-tree-test--pane-ids (nodes)
  "Return the id of every `herdr-pane\\=' node anywhere under NODES.
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
             (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))))

(ert-deftest herdr-tree-includes-worktrees-when-fetched ()
  "A workspace present in WORKTREES gets a worktrees section, last."
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-feat")
                                (is_linked_worktree . t)
                                (branch . "feat/dispatch")
                                (label . "feat/dispatch")
                                (open_workspace_id . nil))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (section (car (last children))))
    (should (eq 'herdr-worktrees (car section)))
    (should (equal 1 (length (nth 3 section))))))

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
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el")
                                (branch . "main")
                                (is_linked_worktree . nil)
                                (open_workspace_id . "w1"))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees)))))
    (should-not (seq-find (lambda (node) (eq 'herdr-worktrees (nth 0 node)))
                          children))
    (should-not (seq-find (lambda (node) (eq 'herdr-worktree (nth 0 node)))
                          children))))

(ert-deftest herdr-tree-lists-the-linked-worktrees-and-not-the-checkout ()
  "The mixed case, and the one that says the count follows the filter.

A repository with a worktree answers with two entries: itself and the
worktree.  Only the second is a row here — and the heading must say
`worktrees (1)', not `(2)', or the section counts a row the user cannot
see and the number stops meaning anything.

The entries are ordered checkout-first, which is the order git and the
server both report, so a filter that only ever dropped the last entry
would not pass."
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el")
                                (branch . "main")
                                (is_linked_worktree . nil)
                                (open_workspace_id . "w1"))
                               ((path . "/tmp/herdr.el-feat")
                                (branch . "feat/dispatch")
                                (is_linked_worktree . t)
                                (open_workspace_id . nil))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (section (car (last children))))
    (should (eq 'herdr-worktrees (nth 0 section)))
    (should (string-match-p "worktrees (1)" (nth 2 section)))
    (should (equal '("/tmp/herdr.el-feat")
                   (mapcar (lambda (node) (nth 1 node)) (nth 3 section))))))

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
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-fix")
                                (branch . "fix")
                                (is_linked_worktree . t)
                                (open_workspace_id . "w1"))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees)))))
    (should-not (seq-find (lambda (node) (eq 'herdr-worktrees (nth 0 node)))
                          children))))

(ert-deftest herdr-tree-keeps-a-sibling-worktree-beside-the-self-row ()
  "Dropping the self row must not drop the section with it.

The workspace's own row goes; a genuine sibling worktree stays, and the
count follows.  A filter that keyed on the section rather than the row
would pass the test above and lose every real worktree here."
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-fix")
                                (branch . "fix")
                                (is_linked_worktree . t)
                                (open_workspace_id . "w1"))
                               ((path . "/tmp/herdr.el-spike")
                                (branch . "spike")
                                (is_linked_worktree . t)
                                (open_workspace_id . nil))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (section (car (last children))))
    (should (eq 'herdr-worktrees (nth 0 section)))
    (should (string-match-p "worktrees (1)" (nth 2 section)))
    (should (equal '("/tmp/herdr.el-spike")
                   (mapcar (lambda (node) (nth 1 node)) (nth 3 section))))))

(ert-deftest herdr-tree-drops-a-checkout-that-is-not-this-workspace ()
  "The case only `herdr-tree-linked-worktree-p' catches, in the renderer.

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
    (let* ((worktrees `(("w1" . (((path . "/tmp/elsewhere")
                                  (branch . "main")
                                  (is_linked_worktree . nil)
                                  (open_workspace_id . ,open))))))
           (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                   worktrees)))))
      (should-not (seq-find (lambda (node) (eq 'herdr-worktrees (nth 0 node)))
                            children)))))

(ert-deftest herdr-tree-own-workspace-p-asks-only-about-this-listing ()
  "Neither predicate subsumes the other, so both get applied.

`herdr-tree-own-workspace-p' asks \\='is this row the workspace it is
nested under?\\=', which a main checkout also answers yes to — but not
always.  The listing is fetched for the workspace's pane cwd, and a pane
`cd'-ed into another repository produces a reply whose main checkout
names some OTHER workspace, or none: that is the third case here, and it
is why `herdr-tree-linked-worktree-p' still has to be asked."
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
  (should-not (herdr-tree-linked-worktree-p '((path . "/tmp/x")
                                              (branch . "main"))))
  (should-not (herdr-tree-linked-worktree-p '((is_linked_worktree . nil))))
  (should (herdr-tree-linked-worktree-p '((is_linked_worktree . t)))))

(ert-deftest herdr-tree-worktree-row-shows-its-own-directory ()
  "A worktree row named only by branch gave no way to tell two
same-named branches in different repositories apart, or to see where a
worktree actually lives without opening it first -- the same directory
column a workspace row already carries."
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-feat")
                                (is_linked_worktree . t)
                                (branch . "feat/dispatch"))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (worktree (car (nth 3 (car (last children))))))
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
treatment `herdr-tree--known-project-node' gives an unopened project,
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
  (let ((worktrees '(("w1" . (((path . "/tmp/a") (branch . "short"))
                              ((path . "/tmp/b")
                               (branch . "a-rather-long-feature-branch-name")))))))
    (should (= (length "a-rather-long-feature-branch-name")
               (herdr-tree--worktree-column-width worktrees)))))

(ert-deftest herdr-tree-worktree-column-width-has-a-floor ()
  (should (= herdr-tree-worktree-column-min
             (herdr-tree--worktree-column-width nil)))
  (should (= herdr-tree-worktree-column-min
             (herdr-tree--worktree-column-width
              '(("w1" . (((path . "/tmp/a") (branch . "x")))))))))

(ert-deftest herdr-tree-dims-a-worktree-already-open-as-a-workspace ()
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-feat")
                                (is_linked_worktree . t)
                                (branch . "feat/dispatch")
                                (label . "feat/dispatch")
                                (open_workspace_id . "w2"))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (worktree (car (nth 3 (car (last children))))))
    (should (equal 'herdr-worktree (nth 0 worktree)))
    (should (string-match-p "open" (nth 2 worktree)))))

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
  "Statuses appear in `herdr-tree-noteworthy-statuses\\=' order — blocked,
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

;;; Known projects with no workspace open

(ert-deftest herdr-tree-known-project-nodes-excludes-an-open-workspace ()
  "A project you already have open needs no second, dimmer entry for the
same directory at the bottom of its own tree."
  (should-not (herdr-tree--known-project-nodes
               (herdr-tree-test--state) '("/tmp/herdr.el/") nil 20)))

(ert-deftest herdr-tree-known-project-nodes-includes-an-unopened-root ()
  (let ((nodes (herdr-tree--known-project-nodes
                (herdr-tree-test--state) '("/tmp/other-project/") nil 20)))
    (should (= 1 (length nodes)))
    (should (equal 'herdr-known-project (nth 0 (car nodes))))
    (should (equal "/tmp/other-project/" (nth 1 (car nodes))))
    (should-not (nth 3 (car nodes)))))

(ert-deftest herdr-tree-known-project-node-shows-a-zero-count-and-is-dimmed ()
  "\"(0)\" is the tell: a real workspace cannot reach zero panes and
survive, so a workspace-shaped row with a zero count is unambiguously
one that is not actually open."
  (let ((line (nth 2 (herdr-tree--known-project-node
                      "/tmp/other-project/" nil 20))))
    (should (string-match-p "other-project (0)" line))
    (should (string-match-p "/tmp/other-project/" line))
    (should (eq 'shadow (get-text-property 0 'font-lock-face line)))))

(ert-deftest herdr-tree-known-project-node-includes-its-own-worktrees ()
  "A known project is still a repository, and its worktrees are shown the
same way an open workspace's are -- only `herdr-tree-linked-worktree-p'
filters here, since there is no open workspace id for
`herdr-tree-own-workspace-p' to compare against; the main checkout is
already excluded by not being a linked worktree at all."
  (let* ((worktrees `(("/tmp/other-project/"
                       . (((path . "/tmp/other-project/") (branch . "main")
                           (is_linked_worktree . nil))
                          ((path . "/tmp/other-project-fix/") (branch . "fix")
                           (is_linked_worktree . t))))))
         (node (herdr-tree--known-project-node
                "/tmp/other-project/" worktrees 20))
         (children (nth 3 node)))
    (should (= 1 (length children)))
    (should (equal 'herdr-worktrees (nth 0 (car children))))
    (should (equal "worktrees (1)" (nth 2 (car children))))))

(ert-deftest herdr-tree-known-project-node-has-no-worktrees-section-when-uncached ()
  "Absence of knowledge, not absence of worktrees -- the same contract
`herdr-tree--worktrees-node' keeps for an open workspace."
  (should-not (nth 3 (herdr-tree--known-project-node
                      "/tmp/other-project/" nil 20))))

(ert-deftest herdr-tree-known-project-worktrees-node-omits-the-root-itself ()
  "A directory that is itself a linked worktree of another repository
appears in its own `worktree.list' reply, flagged linked, because that is
what it is.  Only `herdr-tree-linked-worktree-p' filtered here, so that
entry survived and the root rendered as a child of its own heading."
  (let* ((worktrees '(("/tmp/repo-worktrees/feature/"
                       . (((path . "/tmp/repo") (branch . "main")
                           (is_linked_worktree . nil))
                          ((path . "/tmp/repo-worktrees/feature")
                           (branch . "feature") (is_linked_worktree . t))
                          ((path . "/tmp/repo-worktrees/other")
                           (branch . "other") (is_linked_worktree . t))))))
         (node (herdr-tree--known-project-worktrees-node
                "/tmp/repo-worktrees/feature/" worktrees 20)))
    (should (equal "worktrees (1)" (nth 2 node)))
    (should (equal '("/tmp/repo-worktrees/other")
                   (mapcar (lambda (child) (nth 1 child)) (nth 3 node))))))

(ert-deftest herdr-tree-main-checkout-is-the-entry-that-is-not-linked ()
  "The reply names no repository root of its own; the entry that is not a
linked worktree is that root, whatever the directory asked about was."
  (let ((worktrees '(("/tmp/repo-worktrees/feature/"
                      . (((path . "/tmp/repo-worktrees/feature")
                          (is_linked_worktree . t))
                         ((path . "/tmp/repo") (is_linked_worktree . nil)))))))
    (should (equal "/tmp/repo"
                   (herdr-tree--main-checkout
                    "/tmp/repo-worktrees/feature/" worktrees)))
    (should-not (herdr-tree--main-checkout "/tmp/never-fetched/" worktrees))
    (should-not (herdr-tree--main-checkout "/tmp/repo-worktrees/feature/" nil))))

(defun herdr-tree-test--worktree-cache (&rest roots)
  "Return a worktree cache answering for each of ROOTS with one repository.
Every root gets the same two-entry reply: `/tmp/repo' as the main
checkout and `/tmp/repo-worktrees/feature' as its one linked worktree,
which is the shape a repository and a worktree of it both produce."
  (mapcar (lambda (root)
            (cons root '(((path . "/tmp/repo") (branch . "main")
                          (is_linked_worktree . nil))
                         ((path . "/tmp/repo-worktrees/feature")
                          (branch . "feature") (is_linked_worktree . t)))))
          roots))

(ert-deftest herdr-tree-known-project-nodes-drops-a-worktree-of-a-listed-project ()
  "Opening a worktree as a project in Emacs makes project.el remember it
as a project in its own right, so the repository and its worktree both
drew a row -- each carrying a full copy of the same worktrees section.
The repository is the row worth keeping; its section already names the
worktree."
  (let* ((roots '("/tmp/repo/" "/tmp/repo-worktrees/feature/"))
         (nodes (herdr-tree--known-project-nodes
                 (herdr-tree-test--state) roots
                 (apply #'herdr-tree-test--worktree-cache roots)
                 20)))
    (should (equal '("/tmp/repo/")
                   (mapcar (lambda (node) (nth 1 node)) nodes)))))

(ert-deftest herdr-tree-known-project-nodes-drops-a-worktree-of-an-open-workspace ()
  "The repository need not be an inactive row to count as shown: a
worktree of a workspace that is open is already listed in that
workspace's own worktrees section."
  (let ((worktrees '(("/tmp/herdr.el-feat/"
                      . (((path . "/tmp/herdr.el") (is_linked_worktree . nil))
                         ((path . "/tmp/herdr.el-feat")
                          (is_linked_worktree . t)))))))
    (should-not (herdr-tree--known-project-nodes
                 (herdr-tree-test--state) '("/tmp/herdr.el-feat/")
                 worktrees 20))))

(ert-deftest herdr-tree-known-project-nodes-keeps-an-orphan-worktree ()
  "A worktree whose repository is neither open nor a known project keeps
its row.  Hiding it would take away the tree's only mention of it, which
is worse than the duplication this filter exists to remove."
  (let* ((roots '("/tmp/repo-worktrees/feature/"))
         (nodes (herdr-tree--known-project-nodes
                 (herdr-tree-test--state) roots
                 (apply #'herdr-tree-test--worktree-cache roots)
                 20)))
    (should (equal roots (mapcar (lambda (node) (nth 1 node)) nodes)))))

(ert-deftest herdr-tree-secondary-worktree-p-compares-normalized-paths ()
  "Known-project roots arrive slash-terminated from project.el and
worktree paths arrive bare from the server, so the comparison that
decides this is made on directory names rather than on the strings as
they came in."
  (let ((worktrees (herdr-tree-test--worktree-cache
                    "/tmp/repo-worktrees/feature")))
    (should (herdr-tree--secondary-worktree-p
             (herdr-tree-test--state) "/tmp/repo-worktrees/feature"
             '("/tmp/repo/") worktrees))
    (should-not (herdr-tree--secondary-worktree-p
                 (herdr-tree-test--state) "/tmp/repo-worktrees/feature"
                 '("/tmp/somewhere-else/") worktrees))))

(ert-deftest herdr-tree-secondary-worktree-p-never-drops-a-main-checkout ()
  "A repository's own root has itself as its main checkout, so the rule
cannot turn on the row it exists to keep."
  (let ((worktrees (herdr-tree-test--worktree-cache "/tmp/repo/")))
    (should-not (herdr-tree--secondary-worktree-p
                 (herdr-tree-test--state) "/tmp/repo/"
                 '("/tmp/repo/") worktrees))))

(ert-deftest herdr-tree-secondary-worktree-p-is-nil-before-the-reply-lands ()
  "Worktrees are fetched as the dashboard renders, so every root is
unfetched for a moment.  Absence of knowledge must show the row, not
hide it."
  (should-not (herdr-tree--secondary-worktree-p
               (herdr-tree-test--state) "/tmp/repo-worktrees/feature/"
               '("/tmp/repo/") nil)))

(ert-deftest herdr-tree-known-project-nodes-ignores-a-nil-root-list ()
  "The default when no caller passes anything -- most `herdr-tree-build'
callers in this file among them -- must add nothing, not error."
  (should-not (herdr-tree--known-project-nodes
              (herdr-tree-test--state) nil nil 20)))

(ert-deftest herdr-tree-known-projects-node-is-nil-with-nothing-to-show ()
  (should-not (herdr-tree--known-projects-node
              (herdr-tree-test--state) nil nil 20))
  (should-not (herdr-tree--known-projects-node
               (herdr-tree-test--state) '("/tmp/herdr.el/") nil 20)))

(ert-deftest herdr-tree-known-projects-node-counts-and-nests-its-rows ()
  "One container, not one row per project at the top level -- that is
what removes the blank line between them; see
`herdr-dispatch--insert-nodes'."
  (let ((node (herdr-tree--known-projects-node
               (herdr-tree-test--state)
               '("/tmp/a/" "/tmp/b/" "/tmp/herdr.el/") nil 20)))
    (should (equal 'herdr-known-projects (nth 0 node)))
    (should (equal "inactive" (nth 1 node)))
    (should (equal "Inactive (2)" (nth 2 node)))
    (should (equal '("/tmp/a/" "/tmp/b/")
                   (mapcar (lambda (n) (nth 1 n)) (nth 3 node))))))

(ert-deftest herdr-tree-build-appends-one-inactive-container-after-every-workspace ()
  (let ((tree (herdr-tree-build (herdr-tree-test--state) nil
                                '("/tmp/herdr.el/" "/tmp/other-project/"))))
    (should (equal '(herdr-workspace herdr-known-projects)
                   (mapcar (lambda (node) (nth 0 node)) tree)))
    (should (equal '("/tmp/other-project/")
                   (mapcar (lambda (n) (nth 1 n)) (nth 3 (nth 1 tree)))))))

(ert-deftest herdr-tree-build-adds-no-inactive-container-when-everything-is-open ()
  (let ((tree (herdr-tree-build (herdr-tree-test--state) nil
                                '("/tmp/herdr.el/"))))
    (should (equal '(herdr-workspace)
                   (mapcar (lambda (node) (nth 0 node)) tree)))))

(provide 'herdr-tree-test)
;;; herdr-tree-test.el ends here
