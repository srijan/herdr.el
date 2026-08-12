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
                                (branch . "feat/dispatch")
                                (label . "feat/dispatch")
                                (open_workspace_id . nil))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees))))
         (section (car (last children))))
    (should (eq 'herdr-worktrees (car section)))
    (should (equal 1 (length (nth 3 section))))))

(ert-deftest herdr-tree-dims-a-worktree-already-open-as-a-workspace ()
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-feat")
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
