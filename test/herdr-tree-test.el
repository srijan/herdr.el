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

(ert-deftest herdr-tree-nests-workspace-tab-pane ()
  (should (equal '((herdr-workspace
                    (herdr-tab (herdr-pane) (herdr-pane))
                    (herdr-tab (herdr-pane))))
                 (herdr-tree-test--types
                  (herdr-tree-build (herdr-tree-test--state) nil)))))

(ert-deftest herdr-tree-flattens-a-single-tab-workspace ()
  "Unnamed tabs get numeric labels, so one tab is noise, not structure."
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
         (tab (car children))
         (worktrees-node (car (last children))))
    (should (string-match-p "herdr\\.el (3)" (nth 2 workspace)))
    (should (string-match-p "agents (2)" (nth 2 tab)))
    (should (string-match-p "worktrees (1)" (nth 2 worktrees-node)))
    (should-not (string-match-p "panes" (nth 2 workspace)))
    (should-not (string-match-p "panes" (nth 2 tab)))))

(ert-deftest herdr-tree-collapsed-idle-section-shows-no-glyph ()
  "Same omit-idle rule as the modeline, so the two never disagree."
  (let* ((tabs (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (checks (nth 2 (nth 1 tabs))))
    (should-not (string-match-p (herdr-tree-glyph "blocked") checks))
    (should-not (string-match-p (herdr-tree-glyph "idle") checks))))

(ert-deftest herdr-tree-pane-line-shows-agent-status-and-title ()
  (let* ((tabs (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (pane (nth 2 (car (nth 3 (car tabs))))))
    (should (string-match-p "claude" pane))
    (should (string-match-p "working" pane))
    (should (string-match-p "w1:p1" pane))
    (should (string-match-p "fixing tests" pane))))

;;; Faces

(defun herdr-tree-test--face-of (line text)
  "Return the face LINE carries where TEXT begins in it.
`font-lock-face\\=' rather than `face\\=', because `face\\=' is the property
fontification deletes; see `herdr-tree--faced\\='."
  (get-text-property (string-match text line) 'font-lock-face line))

(ert-deftest herdr-tree-colours-a-pane-row-by-its-status ()
  "Status is the one field worth finding without reading.

The glyph and the word take the same face, which turns the leading
column into a strip you can read down; blocked and working must not
share one, or the strip says only \"something is happening\"."
  (let* ((tabs (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (panes (nth 3 (car tabs)))
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
         (pane (nth 2 (car (nth 3 (car (nth 3 workspace)))))))
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

(ert-deftest herdr-tree-marks-adopted-shells ()
  (let* ((tabs (nth 3 (car (herdr-tree-build (herdr-tree-test--state) nil))))
         (pane (nth 2 (car (nth 3 (nth 1 tabs))))))
    (should (string-match-p "shell\\*" pane))))

(ert-deftest herdr-tree-appends-an-agent-name-when-set ()
  (let* ((state (herdr-tree-test--state
                 '(agents . (((pane_id . "w1:p1") (agent . "claude")
                              (name . "reviewer"))))))
         (tabs (nth 3 (car (herdr-tree-build state nil))))
         (pane (nth 2 (car (nth 3 (car tabs))))))
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

(ert-deftest herdr-tree-shows-an-uncached-tabs-pane-beside-the-tabs-it-has ()
  "The partial case: some tabs known, one pane naming a tab that is not.
The known tabs must keep their own panes and their own level, and the
orphan must appear alongside them rather than displacing or joining
them."
  (let* ((state (herdr-tree-test--state
                 '(panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (tab_id . "w1:t1") (agent . "claude"))
                            ((pane_id . "w1:p3") (workspace_id . "w1")
                             (tab_id . "w1:t2") (agent . "codex"))
                            ((pane_id . "w1:p9") (workspace_id . "w1")
                             (tab_id . "w1:t9") (agent . "gemini"))))))
         (tree (herdr-tree-build state nil)))
    (should (equal '((herdr-workspace
                      (herdr-tab (herdr-pane))
                      (herdr-tab (herdr-pane))
                      (herdr-pane)))
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

(provide 'herdr-tree-test)
;;; herdr-tree-test.el ends here
