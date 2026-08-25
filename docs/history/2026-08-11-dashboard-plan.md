> **Historical record.** This document shows the plan or the design at the date in its
> title. It is not current documentation. The code has moved since. For current
> documentation, see [`docs/`](../README.md).

# herdr dispatcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `*herdr-agents*` into the central dispatcher for a herdr session — a foldable
workspace → tab → pane tree from which you can create and act on workspaces, tabs, panes, agents
and worktrees.

**Architecture:** A pure tree model (`herdr-tree.el`, no dependencies) produces a nested list of
`(TYPE VALUE LINE CHILDREN)` from the state cache. A thin renderer (`herdr-dispatch.el`) walks
that list emitting `magit-insert-section`, and every verb resolves the object at point and calls
an existing `herdr-cmd` function with an explicit id. Almost all logic lives in the pure half, so
almost all of it is testable without a socket or a display.

**Tech Stack:** Emacs Lisp (28.1 floor), `magit-section` 3.3, `transient` 0.4, ERT, `make`.

Spec: `docs/superpowers/specs/2026-08-11-herdr-dispatch-design.md`

## Global Constraints

- Emacs 28.1 floor. No Emacs 29+ functions (`seq-keep`, `outline-search-function`, `setopt`).
- All files use `-*- lexical-binding: t; -*-` and end with `(provide 'FEATURE)` plus a
  `;;; FILE ends here` line.
- `make compile` sets `byte-compile-error-on-warn`. A warning fails the build. Declare every
  external function with `declare-function` and every external variable with `defvar`.
- `make test` runs `emacs -Q --batch -L . -L test`. **`magit-section` is not on that load path.**
  Anything requiring it must be guarded with `(skip-unless (require 'magit-section nil t))`.
- **The dispatcher's dependency set is six directories, not one** — confirmed empirically:
  `magit-section`, `compat`, `dash`, `llama`, `transient`, `cond-let`. Loading only
  `magit-section` dies with "Cannot open load file: cond-let".
- **Canonical command for running dispatcher tests** (referred to below as THE DEPS COMMAND):

  ```bash
  B=$HOME/.emacs.d/var/elpaca/builds
  DEPS="$B/magit-section $B/compat $B/dash $B/llama $B/transient $B/cond-let"
  make test EXTRA_LOAD_PATH="$DEPS"
  make compile EXTRA_LOAD_PATH="$DEPS"
  ```

  For a single test file, substitute directly:

  ```bash
  emacs -Q --batch -L . -L test $(for d in $DEPS; do printf -- '-L %s ' "$d"; done) \
    -l test/herdr-dispatch-test.el \
    --eval '(ert-run-tests-batch-and-exit "herdr-dispatch")'
  ```
- Tests needing a live herdr server are tagged `:live` and run only under `make test-live`.
- Every new curated method must be added to `herdr-cmd-methods` in `herdr-cmd.el`.
- Commit after every task. Work on branch `herdr-dispatch`.
- **Run `make clean` before `make test`.** `.elc` files are git-ignored and persist between
  tasks, so a stale one silently shadows your source edit and the suite tests the old code. This
  cost Task 2 a confusing run.
- **KNOWN-RED BASELINE — read before you run the suite.** Four tests in
  `test/herdr-transient-test.el` fail on pristine upstream `fe8bc41`, before any work on this
  branch, and they are not yours to fix:

  ```
  herdr-transient-adoption-is-offered-and-hidden-under-session
  herdr-transient-every-curated-command-is-reachable
  herdr-transient-every-prefix-has-suffixes
  herdr-transient-lowercase-noun-navigates-uppercase-opens-a-menu
  ```

  Cause: they introspect `transient`'s internals and the installed `transient` is newer than the
  API they were written against, so the helper returns zero suffixes and `(> 0 2)` fails. Loading
  `transient` onto the path does not help — verified.

  **Therefore the passing gate everywhere in this plan is "no NEW failures beyond those four",
  never "all tests pass".** `make test` exits non-zero because of them; that is expected. Judge
  by the failure list, not the exit code. `make compile` must still exit 0.
- Docstrings: first line a complete sentence ending in a period. To stop Emacs converting a
  quote to a curly quote, write `\\='` in source (two backslashes), which puts `\='` in the
  runtime docstring. Note that several pre-existing docstrings in this repo write a single
  backslash, which renders a stray `=` — do not copy that; it is a known pre-existing bug.

## File Structure

| File | Responsibility | Depends on |
| --- | --- | --- |
| `herdr-state.el` *(modify)* | add `agent-info` slot, agent-name and workspace-directory helpers | — |
| `herdr.el` *(modify)* | fix `herdr-project`; `herdr` opens the dispatcher | `herdr-state` |
| `herdr-tree.el` *(create)* | pure tree model and line formatting, plus the canonical status glyphs | `herdr-state` |
| `herdr-agents.el` *(modify)* | modeline segment and notifications only; buffer code removed | `herdr-state`, `herdr-tree` |
| `herdr-dispatch.el` *(create)* | buffer, sections, keymap, verbs, worktree cache, create transient | `herdr-tree`, `herdr-cmd`, `magit-section` |
| `herdr-cmd.el` *(modify)* | drift table entries for new methods; fix `agent.read` entry | — |

**Deviation from the spec, deliberate:** the spec placed the tree model inside
`herdr-dispatch.el`. It is split into `herdr-tree.el` because `magit-section` is absent from the
hermetic test load path, and a model that cannot be tested by `make test` is the wrong trade. The
module boundary is otherwise exactly as specced.

---

### Task 1: State — keep the agents array and derive workspace directories

**Files:**
- Modify: `herdr-state.el:67-88` (struct and snapshot), and append two functions after
  `herdr-state-pane-directory` (`herdr-state.el:122-132`)
- Test: `test/herdr-state-test.el` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `(herdr-state-agent-info STATE)` → list of AgentInfo alists
  - `(herdr-state-agent-name STATE PANE-ID)` → string or nil
  - `(herdr-state-workspace-directory STATE WORKSPACE-ID)` → directory name string or nil

**Critical naming note:** the slot must be called `agent-info`, not `agents`. A slot named
`agents` generates the accessor `herdr-state-agents`, which would silently clobber the existing
function of that name at `herdr-state.el:116`.

- [ ] **Step 1: Write the failing tests**

Append to `test/herdr-state-test.el`:

```elisp
(ert-deftest herdr-state-keeps-the-agents-array ()
  "session.snapshot carries agent names that no pane record has."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (agent . "claude"))))
                  (agents . (((pane_id . "w1:p1") (agent . "claude")
                              (name . "reviewer"))))))))
    (should (equal "reviewer" (herdr-state-agent-name state "w1:p1")))))

(ert-deftest herdr-state-agent-name-is-nil-until-renamed ()
  "AgentInfo.name is null until someone calls agent.rename."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (agent . "claude"))))
                  (agents . (((pane_id . "w1:p1") (agent . "claude")
                              (name . nil))))))))
    (should-not (herdr-state-agent-name state "w1:p1"))
    (should-not (herdr-state-agent-name state "w1:p9"))))

(ert-deftest herdr-state-workspace-directory-comes-from-panes ()
  "Protocol 19 WorkspaceInfo has no cwd, so it is derived."
  (let ((state (herdr-state-from-snapshot
                '((workspaces . (((workspace_id . "w1"))))
                  (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (cwd . "/tmp/project"))
                            ((pane_id . "w1:p2") (workspace_id . "w1")
                             (cwd . "/tmp/project/sub"))))))))
    (should (equal "/tmp/project/"
                   (herdr-state-workspace-directory state "w1")))))

(ert-deftest herdr-state-workspace-directory-skips-panes-without-cwd ()
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1"))
                            ((pane_id . "w1:p2") (workspace_id . "w1")
                             (cwd . "/tmp/project"))))))))
    (should (equal "/tmp/project/"
                   (herdr-state-workspace-directory state "w1")))))

(ert-deftest herdr-state-workspace-directory-is-nil-when-unknown ()
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1"))))))))
    (should-not (herdr-state-workspace-directory state "w1"))
    (should-not (herdr-state-workspace-directory state "w9"))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
emacs -Q --batch -L . -L test -l test/herdr-state-test.el \
  --eval '(ert-run-tests-batch-and-exit "herdr-state-keeps-the-agents-array")'
```
Expected: FAIL, `herdr-state-agent-name` void-function.

- [ ] **Step 3: Add the slot**

In `herdr-state.el`, replace the struct definition at line 67:

```elisp
(cl-defstruct (herdr-state (:constructor herdr-state--make)
                           (:copier herdr-state-copy))
  (panes nil)
  (tabs nil)
  (workspaces nil)
  ;; Named `agent-info' rather than `agents': a slot called `agents'
  ;; would generate `herdr-state-agents', clobbering the function of that
  ;; name below.  This holds the raw AgentInfo array from
  ;; `session.snapshot', which carries `name' — the one field no
  ;; PaneInfo has.
  (agent-info nil)
  (focused-pane-id nil)
  (focused-tab-id nil)
  (focused-workspace-id nil))
```

And in `herdr-state-from-snapshot`, add one line after `:workspaces`:

```elisp
   :agent-info (alist-get 'agents snapshot)
```

- [ ] **Step 4: Add the two helpers**

Append after `herdr-state-pane-directory` in `herdr-state.el`:

```elisp
(defun herdr-state-agent-name (state pane-id)
  "Return the name reported for the agent in PANE-ID, or nil.

Names live only in `session.snapshot\\='s `agents\\=' array; neither
`pane.list\\=' nor the pane events carry one, so this is refreshed on the
snapshot cadence rather than off the event stream.  Nil until someone
calls `agent.rename\\='."
  (when-let* ((agent (seq-find (lambda (candidate)
                                 (equal pane-id (alist-get 'pane_id candidate)))
                               (herdr-state-agent-info state))))
    (alist-get 'name agent)))

(defun herdr-state-workspace-directory (state workspace-id)
  "Return WORKSPACE-ID\\='s directory in STATE, or nil.

Protocol 19\\='s WorkspaceInfo carries no cwd of any kind, so it is derived
from the workspace\\='s panes: the first one that reports a `cwd\\='.  Panes
are held in cache order — snapshot order with later arrivals appended —
so that is the oldest pane herdr told us about, which is the one the
workspace was created in."
  (when-let* ((dir (seq-some (lambda (pane)
                               (and (equal workspace-id
                                           (alist-get 'workspace_id pane))
                                    (alist-get 'cwd pane)))
                             (herdr-state-panes state))))
    (file-name-as-directory dir)))
```

- [ ] **Step 5: Run the full hermetic suite**

Run: `make test`
Expected: all pass, including the four new tests.

- [ ] **Step 6: Byte-compile**

Run: `make compile`
Expected: exit 0, no warnings.

- [ ] **Step 7: Commit**

```bash
git add herdr-state.el test/herdr-state-test.el
git commit -m "Keep the snapshot agents array and derive workspace directories

session.snapshot returns an AgentInfo array carrying agent names, which
herdr-state-from-snapshot was discarding.  Protocol 19 WorkspaceInfo has
no cwd field, so a workspace's directory has to come from its panes."
```

---

### Task 2: Fix `herdr-project`'s duplicate workspaces

**Files:**
- Modify: `herdr.el:80-102`
- Test: `test/herdr-project-test.el` (create)

**Interfaces:**
- Consumes: `herdr-state-workspace-directory` from Task 1.
- Produces: `(herdr--workspace-for-directory STATE ROOT)` → workspace alist or nil.

`herdr-project` matches on `(alist-get 'identity_cwd workspace)`, a field protocol 19 does not
have. The comparison is always `(equal "./" "/real/root/")`, so it never finds an existing
workspace and creates a duplicate on every invocation. The matching is extracted into a pure
function so it can be tested without a server.

- [ ] **Step 1: Write the failing test**

Create `test/herdr-project-test.el`:

```elisp
;;; herdr-project-test.el --- Tests for project workspace matching -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
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
  (let ((found (herdr--workspace-for-directory
                (herdr-project-test--state) "/tmp/project")))
    (should (equal "w1" (alist-get 'workspace_id found)))))

(ert-deftest herdr-project-matches-with-or-without-a-trailing-slash ()
  (let ((state (herdr-project-test--state)))
    (should (equal "w1" (alist-get 'workspace_id
                                   (herdr--workspace-for-directory
                                    state "/tmp/project/"))))))

(ert-deftest herdr-project-returns-nil-for-an-unknown-root ()
  (should-not (herdr--workspace-for-directory
               (herdr-project-test--state) "/tmp/nowhere")))

(provide 'herdr-project-test)
;;; herdr-project-test.el ends here
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
emacs -Q --batch -L . -L test -l test/herdr-project-test.el \
  --eval '(ert-run-tests-batch-and-exit "herdr-project-finds-the-workspace-for-a-root")'
```
Expected: FAIL, `herdr--workspace-for-directory` void-function.

- [ ] **Step 3: Add the helper and use it**

In `herdr.el`, add before `herdr-project`:

```elisp
(defun herdr--workspace-for-directory (state root)
  "Return the workspace in STATE rooted at ROOT, or nil.

Compared through `herdr-state-workspace-directory\\=' because protocol 19
workspaces carry no cwd.  This used to compare against an `identity_cwd\\='
field that does not exist, so it never matched and `herdr-project\\=' made a
fresh workspace every time."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (seq-find (lambda (workspace)
                (equal root
                       (herdr-state-workspace-directory
                        state (alist-get 'workspace_id workspace))))
              (herdr-state-workspaces state))))
```

Then replace the `existing` binding inside `herdr-project` (currently `herdr.el:88-94`) with:

```elisp
         (existing (herdr--workspace-for-directory (herdr-state-current) root))
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all pass.

- [ ] **Step 5: Byte-compile**

Run: `make compile`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add herdr.el test/herdr-project-test.el
git commit -m "Fix herdr-project creating a duplicate workspace every time

It matched existing workspaces on identity_cwd, which protocol 19's
WorkspaceInfo does not have, so the comparison was always \"./\" against
a real root and never matched."
```

---

### Task 3: `herdr-tree.el` — the pure tree model

**Files:**
- Create: `herdr-tree.el`
- Test: `test/herdr-tree-test.el` (create)

**Interfaces:**
- Consumes: `herdr-state-*` accessors, `herdr-state-agent-name`,
  `herdr-state-workspace-directory`, `herdr-state-shell-pane-p`.
- Produces:
  - `herdr-tree-status-glyphs` — alist of (STATUS . GLYPH), the canonical set
  - `(herdr-tree-glyph STATUS)` → string, one character
  - `(herdr-tree-build STATE WORKTREES)` → list of nodes, where a node is the list
    `(TYPE VALUE LINE CHILDREN)`. TYPE is one of `herdr-workspace`, `herdr-tab`, `herdr-pane`,
    `herdr-worktrees`, `herdr-worktree`. WORKTREES is an alist of
    `(WORKSPACE-ID . LIST-OF-WORKTREEINFO)` and may be nil.

Nodes are plain lists so tests compare with `equal`.

- [ ] **Step 1: Write the failing tests**

Create `test/herdr-tree-test.el`:

```elisp
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

(ert-deftest herdr-tree-adds-a-worktrees-section-only-when-known ()
  (should (equal '(herdr-workspace herdr-tab herdr-tab)
                 (cons 'herdr-workspace
                       (mapcar #'car (nth 3 (car (herdr-tree-build
                                                  (herdr-tree-test--state)
                                                  nil))))))
          )
  (let* ((worktrees '(("w1" . (((path . "/tmp/herdr.el-feat")
                                (branch . "feat/dispatch")
                                (label . "feat/dispatch")
                                (open_workspace_id . nil))))))
         (children (nth 3 (car (herdr-tree-build (herdr-tree-test--state)
                                                 worktrees)))))
    (should (equal 'herdr-worktrees (car (car (last children)))))))

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

(provide 'herdr-tree-test)
;;; herdr-tree-test.el ends here
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
emacs -Q --batch -L . -L test -l test/herdr-tree-test.el \
  --eval '(ert-run-tests-batch-and-exit "herdr-tree")'
```
Expected: FAIL, cannot open load file `herdr-tree`.

- [ ] **Step 3: Write `herdr-tree.el`**

```elisp
;;; herdr-tree.el --- Pure tree model for the herdr dispatcher -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; The dispatcher's tree, as data.  `herdr-tree-build' turns the state
;; cache into a nested list of (TYPE VALUE LINE CHILDREN); `herdr-dispatch'
;; walks that list emitting magit sections.
;;
;; Kept separate from the renderer for one concrete reason: `make test'
;; runs under `emacs -Q -L .', where magit-section is not on the load
;; path.  A model that the hermetic suite cannot reach is a model that
;; does not get tested, and nearly all the logic worth testing is here.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'herdr-state)

(defconst herdr-tree-status-glyphs
  '(("working" . "▶") ("blocked" . "⏸") ("done" . "✓") ("idle" . "·"))
  "Glyph shown for each agent status.
The canonical set: the modeline segment and the dispatcher both read it,
so the two surfaces cannot disagree about what a status looks like.")

(defun herdr-tree-glyph (status)
  "Return the glyph for STATUS, or a space when it has none."
  (alist-get status herdr-tree-status-glyphs " " nil #'equal))

(defconst herdr-tree-noteworthy-statuses '("blocked" "working" "done")
  "Statuses worth showing on a collapsed section.
Idle is omitted for the same reason the modeline omits it: a marker that
is always on screen stops being read.")

(defun herdr-tree--rollup (status)
  "Return the glyph for STATUS on a collapsed section, or an empty string."
  (if (member status herdr-tree-noteworthy-statuses)
      (herdr-tree-glyph status)
    ""))

(defun herdr-tree--agent-label (state pane)
  "Return the agent column for PANE in STATE.
Adopted shells are marked rather than named, since they have no agent
lifecycle.  A name set through `agent.rename\\=' is appended to the kind."
  (if (herdr-state-shell-pane-p pane)
      "shell*"
    (let* ((kind (or (alist-get 'display_agent pane)
                     (alist-get 'agent pane)
                     "shell"))
           (name (herdr-state-agent-name state (alist-get 'pane_id pane))))
      (if name (concat kind "/" name) kind))))

(defun herdr-tree--pane-node (state pane)
  "Return the node for PANE in STATE."
  (let ((id (alist-get 'pane_id pane))
        (shell (herdr-state-shell-pane-p pane)))
    (list 'herdr-pane id
          (string-trim-right
           (format "%s %-14s %-8s %-8s %s"
                   (if shell "~" (herdr-tree-glyph
                                  (alist-get 'agent_status pane)))
                   (herdr-tree--agent-label state pane)
                   (if shell "" (or (alist-get 'agent_status pane) ""))
                   id
                   (or (alist-get 'terminal_title_stripped pane) "")))
          nil)))

(defun herdr-tree--panes-in-tab (state tab-id)
  "Return the nodes for every pane of TAB-ID in STATE."
  (mapcar (lambda (pane) (herdr-tree--pane-node state pane))
          (seq-filter (lambda (pane)
                        (equal tab-id (alist-get 'tab_id pane)))
                      (herdr-state-panes state))))

(defun herdr-tree--tab-node (state tab)
  "Return the node for TAB in STATE."
  (let ((id (alist-get 'tab_id tab)))
    (list 'herdr-tab id
          (string-trim-right
           (format "%-24s %s %s"
                   (or (alist-get 'label tab) id)
                   (format "%s panes" (or (alist-get 'pane_count tab) 0))
                   (herdr-tree--rollup (alist-get 'agent_status tab))))
          (herdr-tree--panes-in-tab state id))))

(defun herdr-tree--tabs-in-workspace (state workspace-id)
  "Return TABs of WORKSPACE-ID in STATE, in cache order."
  (seq-filter (lambda (tab)
                (equal workspace-id (alist-get 'workspace_id tab)))
              (herdr-state-tabs state)))

(defun herdr-tree--worktree-node (worktree)
  "Return the node for WORKTREE.
A worktree already open as a workspace is shown above as that workspace,
so it is marked rather than repeated."
  (let ((open (alist-get 'open_workspace_id worktree)))
    (list 'herdr-worktree (alist-get 'path worktree)
          (string-trim-right
           (format "%-24s %s"
                   (or (alist-get 'branch worktree)
                       (alist-get 'label worktree)
                       "?")
                   (if open (format "open as %s" open) "")))
          nil)))

(defun herdr-tree--worktrees-node (workspace-id worktrees)
  "Return the worktrees node for WORKSPACE-ID, or nil when there are none.
WORKTREES is the alist passed to `herdr-tree-build\\='.  A workspace absent
from it has not been expanded yet, which is different from having none."
  (when-let* ((entry (assoc workspace-id worktrees))
              (found (cdr entry)))
    (list 'herdr-worktrees workspace-id
          (format "worktrees %s" (length found))
          (mapcar #'herdr-tree--worktree-node found))))

(defun herdr-tree--workspace-node (state workspace worktrees)
  "Return the node for WORKSPACE in STATE, including WORKTREES."
  (let* ((id (alist-get 'workspace_id workspace))
         (tabs (herdr-tree--tabs-in-workspace state id))
         ;; One tab is not structure.  Unnamed tabs are labelled by
         ;; number, so keeping the level would indent every pane behind a
         ;; heading that reads "1".
         (children (if (= (length tabs) 1)
                       (herdr-tree--panes-in-tab
                        state (alist-get 'tab_id (car tabs)))
                     (mapcar (lambda (tab) (herdr-tree--tab-node state tab))
                             tabs)))
         (worktree-node (herdr-tree--worktrees-node id worktrees)))
    (list 'herdr-workspace id
          (string-trim-right
           (format "%-24s %-28s %s %s"
                   (or (alist-get 'label workspace) id)
                   (or (herdr-state-workspace-directory state id) "")
                   (format "%s panes" (or (alist-get 'pane_count workspace) 0))
                   (herdr-tree--rollup (alist-get 'agent_status workspace))))
          (if worktree-node (append children (list worktree-node)) children))))

(defun herdr-tree-build (state worktrees)
  "Return the dispatcher tree for STATE.

Each node is the list (TYPE VALUE LINE CHILDREN).  TYPE is one of
`herdr-workspace\\=', `herdr-tab\\=', `herdr-pane\\=', `herdr-worktrees\\=' or
`herdr-worktree\\='; VALUE is the id a command needs; LINE is the rendered
text; CHILDREN is a list of nodes.

WORKTREES is an alist of (WORKSPACE-ID . LIST-OF-WORKTREEINFO) for the
workspaces whose worktrees have been fetched.  A workspace missing from
it simply gets no worktrees section — absence of knowledge, not absence
of worktrees."
  (mapcar (lambda (workspace)
            (herdr-tree--workspace-node state workspace worktrees))
          (herdr-state-workspaces state)))

(provide 'herdr-tree)
;;; herdr-tree.el ends here
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all pass, including the nine `herdr-tree-*` tests.

- [ ] **Step 5: Byte-compile**

Run: `make compile`
Expected: exit 0, no warnings.

- [ ] **Step 6: Commit**

```bash
git add herdr-tree.el test/herdr-tree-test.el
git commit -m "Add the pure tree model for the dispatcher

Kept out of the renderer so the hermetic suite can reach it: make test
runs under emacs -Q -L ., where magit-section is not on the load path."
```

---

### Tasks 4 and 5: executed together as one dispatch

> **Ruling (pre-flight, 2026-08-11):** Tasks 4 and 5 are implemented by a single implementer in
> one dispatch, ending in **one commit**. Task 4 alone leaves `M-x herdr-agents` undefined, and
> committing a knowingly broken branch state is not worth the extra review gate. Use Task 4's
> commit message, extended with Task 5's second paragraph. Ignore Task 4 Step 5's instruction to
> comment out the transient's `l` entry and Task 4 Step 7's separate commit — neither is needed
> when the replacement lands in the same change.

### Task 4: Move the glyphs, slim `herdr-agents.el` to modeline and notifications

**Files:**
- Modify: `herdr-agents.el` — delete `herdr-agents-status-glyphs` (lines 37-39), the agents-buffer
  code (lines 153-246), and the `require` of `herdr-cmd` (line 24); add a `require` of
  `herdr-tree`
- Modify: `test/herdr-agents-test.el` — drop any test of the removed buffer code
- Test: `test/herdr-agents-test.el`

**Interfaces:**
- Consumes: `herdr-tree-status-glyphs`, `herdr-tree-glyph` from Task 3.
- Produces: `herdr-agents.el` exporting only `herdr-agents-mode-line-mode`,
  `herdr-agents-mode-line-string`, `herdr-agents--segment`, `herdr-agents--maybe-notify`.

After this task `M-x herdr-agents` is temporarily undefined. Task 5 restores it. This is the one
task boundary where the branch is not fully usable; it is drawn here because moving the glyphs
and deleting the old buffer are the same change.

- [ ] **Step 1: Update the existing segment test to the shared glyphs**

In `test/herdr-agents-test.el`, the existing tests already assert literal glyph characters
(`"herdr:2⏸1✓"`). They stay valid. Add one test asserting the segment now reads the
shared constant:

```elisp
(ert-deftest herdr-agents-segment-uses-the-shared-glyphs ()
  "The modeline and the dispatcher must not disagree about a status."
  (should (equal (concat "herdr:1" (herdr-tree-glyph "blocked"))
                 (herdr-agents--segment
                  (herdr-agents-test--state '("w1:p1" "claude" "blocked"))))))
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
emacs -Q --batch -L . -L test -l test/herdr-agents-test.el \
  --eval '(ert-run-tests-batch-and-exit "herdr-agents-segment-uses-the-shared-glyphs")'
```
Expected: FAIL, `herdr-tree-glyph` void-function.

- [ ] **Step 3: Rewrite the header and delete the buffer code**

In `herdr-agents.el`, replace the requires (lines 22-24) with:

```elisp
(require 'subr-x)
(require 'herdr-state)
(require 'herdr-tree)
```

Delete the `herdr-agents-status-glyphs` defconst entirely. In `herdr-agents--segment`, replace
the glyph lookup with `(herdr-tree-glyph status)`:

```elisp
                           (when (> n 0)
                             (format "%d%s" n (herdr-tree-glyph status)))
```

Delete everything from `;;; The agents buffer` (line 153) through
`herdr-agents--refresh-hook` (line 246) inclusive. Keep the trailing
`(add-hook 'herdr-state-change-hook #'herdr-agents--maybe-notify)` and the `provide`.

Update the Commentary to describe two surfaces rather than three:

```elisp
;; Knowing which agents are blocked or finished without going to look.
;;
;; A modeline segment that is always on, fed by `herdr-state-change-hook'
;; and doing no I/O, plus desktop notifications that are available but
;; off, because an agent changing state is not by default worth
;; interrupting for.  The buffer those used to sit beside now lives in
;; `herdr-dispatch'.
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: all pass. If a test referenced `herdr-agents--insert-tree` or `herdr-agents-refresh`,
delete it — Task 5 covers the replacement.

- [ ] **Step 5: Byte-compile**

Run: `make compile`
Expected: exit 0. `herdr-transient.el` will warn about `herdr-agents` being undefined; that is
fixed in Task 5, so if `make compile` fails here, comment out the `("l" "agents" herdr-agents)`
line in `herdr-transient.el:109` and restore it in Task 5 Step 6.

- [ ] **Step 6: Commit**

```bash
git add herdr-agents.el test/herdr-agents-test.el herdr-transient.el
git commit -m "Move the status glyphs to herdr-tree and slim herdr-agents

herdr-agents.el held three unrelated concerns.  The buffer moves to
herdr-dispatch next; the glyphs become shared so the modeline and the
dispatcher cannot disagree."
```

---

### Task 5: `herdr-dispatch.el` — render, fold, refresh

**Files:**
- Create: `herdr-dispatch.el`
- Test: `test/herdr-dispatch-test.el` (create)

**Interfaces:**
- Consumes: `herdr-tree-build` from Task 3.
- Produces:
  - `herdr-dispatch-mode` — major mode derived from `magit-section-mode`
  - `(herdr-agents)` — interactive, opens `*herdr-agents*`
  - `(herdr-dispatch--insert-nodes NODES)` — renderer
  - `(herdr-dispatch-refresh)` — interactive redraw
  - `herdr-dispatch--worktrees` — alist passed to `herdr-tree-build`, filled in Task 7

Verbs land in Task 6. This task delivers a buffer you can open, read and fold.

- [ ] **Step 1: Write the failing tests**

Create `test/herdr-dispatch-test.el`:

```elisp
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
      (herdr-pane "w1:p2" "| codex blocked w1:p2" nil))))
  "A two-pane workspace, already in tree form.")

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

(provide 'herdr-dispatch-test)
;;; herdr-dispatch-test.el ends here
```

- [ ] **Step 2: Run the tests to verify they fail**

Run THE DEPS COMMAND's single-file form (see Global Constraints):
```bash
B=$HOME/.emacs.d/var/elpaca/builds
DEPS="$B/magit-section $B/compat $B/dash $B/llama $B/transient $B/cond-let"
emacs -Q --batch -L . -L test $(for d in $DEPS; do printf -- '-L %s ' "$d"; done) \
  -l test/herdr-dispatch-test.el \
  --eval '(ert-run-tests-batch-and-exit "herdr-dispatch")'
```
Expected: FAIL, cannot open load file `herdr-dispatch`.
This command is referred to below as THE DISPATCHER TEST COMMAND.

Note: under plain `make test` these skip rather than fail, which is correct — the tree model
carries the coverage that matters.

- [ ] **Step 3: Write `herdr-dispatch.el`**

```elisp
;;; herdr-dispatch.el --- The herdr dispatcher buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (magit-section "3.3"))

;;; Commentary:

;; `*herdr-agents*': one buffer showing the whole session as a foldable
;; workspace/tab/pane tree, and the place every command is reachable
;; from.
;;
;; The tree itself is data, built by `herdr-tree'.  This file only
;; renders it, resolves the object under point, and hands that object to
;; the commands in `herdr-cmd' — which already take explicit ids, so no
;; command logic is duplicated here.

;;; Code:

(require 'subr-x)
(require 'magit-section)
(require 'herdr-tree)
(require 'herdr-state)

(defcustom herdr-dispatch-buffer-name "*herdr-agents*"
  "Name of the dispatcher buffer."
  :type 'string
  :group 'herdr)

(defvar herdr-dispatch--worktrees nil
  "Alist of (WORKSPACE-ID . LIST-OF-WORKTREEINFO) for expanded workspaces.
Filled lazily; see `herdr-dispatch--worktrees-for'.")

(defvar herdr-dispatch-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map "g" #'herdr-dispatch-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `herdr-dispatch-mode'.
Verbs are added in the command-surface layer; this holds only what the
buffer needs to be readable.")

(define-derived-mode herdr-dispatch-mode magit-section-mode "herdr"
  "Major mode for the herdr dispatcher."
  (setq-local revert-buffer-function
              (lambda (&rest _) (herdr-dispatch-refresh))))

(defun herdr-dispatch--insert-nodes (nodes)
  "Insert NODES, each (TYPE VALUE LINE CHILDREN), as magit sections.

`magit-insert-section\\=' takes its type as an unevaluated symbol, so the
five types are spelled out rather than passed through.  A runtime `eval\\='
would collapse these into one branch; five explicit branches byte-compile
and do not need defending."
  (dolist (node nodes)
    (let ((value (nth 1 node))
          (line (nth 2 node))
          (children (nth 3 node)))
      (pcase (nth 0 node)
        ('herdr-workspace
         (magit-insert-section (herdr-workspace value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))
        ('herdr-tab
         (magit-insert-section (herdr-tab value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))
        ('herdr-pane
         (magit-insert-section (herdr-pane value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))
        ('herdr-worktrees
         (magit-insert-section (herdr-worktrees value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))
        ('herdr-worktree
         (magit-insert-section (herdr-worktree value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))))))

(defun herdr-dispatch--header (state)
  "Return the header line summarising STATE."
  (format "herdr   %d workspaces  %d panes  %d agents"
          (length (herdr-state-workspaces state))
          (length (herdr-state-panes state))
          (length (herdr-state-agents state))))

(defun herdr-dispatch-refresh ()
  "Redraw the dispatcher from the cache, keeping point and fold state."
  (interactive)
  (when-let* ((buffer (get-buffer herdr-dispatch-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (state (herdr-state-current)))
        ;; Point is restored by section identity rather than by line
        ;; number: a pane closing above point used to move you to a
        ;; different agent than the one you were reading.
        ;; No `magit-section-cache-visibility' call here.  With no
        ;; argument it defaults to `magit-insert-section--current', which
        ;; is nil outside an insert, so it signals wrong-type-argument on
        ;; every refresh -- verified.  It is also unnecessary: magit
        ;; caches visibility on hide/show and restores through
        ;; `magit-section-set-visibility-hook'.  Fold survival across a
        ;; refresh was confirmed end to end.
        (let ((ident (and (magit-current-section)
                          (magit-section-ident (magit-current-section)))))
          (erase-buffer)
          (magit-insert-section (herdr-root)
            (magit-insert-heading (herdr-dispatch--header state))
            (herdr-dispatch--insert-nodes
             (herdr-tree-build state herdr-dispatch--worktrees)))
          (when ident
            (when-let* ((section (magit-get-section ident)))
              (goto-char (oref section start)))))))))

(defun herdr-dispatch--refresh-hook (&rest _)
  "Refresh the dispatcher, or unhook when its buffer is gone."
  (if (get-buffer herdr-dispatch-buffer-name)
      (herdr-dispatch-refresh)
    (remove-hook 'herdr-state-change-hook #'herdr-dispatch--refresh-hook)))

;;;###autoload
(defun herdr-agents ()
  "Show the herdr dispatcher: workspaces, tabs, panes and agents."
  (interactive)
  (let ((buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-dispatch-mode) (herdr-dispatch-mode))
      (add-hook 'herdr-state-change-hook #'herdr-dispatch--refresh-hook))
    (herdr-dispatch-refresh)
    (pop-to-buffer buffer)))

(provide 'herdr-dispatch)
;;; herdr-dispatch.el ends here
```

- [ ] **Step 4: Run the dispatcher tests with magit-section on the path**

Run the command from Step 2 again.
Expected: 3 tests PASS.

- [ ] **Step 5: Run the hermetic suite**

Run: `make test`
Expected: all pass; the three dispatcher tests report as skipped.

- [ ] **Step 6: Restore the transient entry and byte-compile**

If Task 4 Step 5 required commenting out `("l" "agents" herdr-agents)` in
`herdr-transient.el:109`, restore it now. Add to `herdr-transient.el` near the existing
`herdr-project` declaration (line 29-30):

```elisp
(declare-function herdr-agents "herdr-dispatch" ())
(autoload 'herdr-agents "herdr-dispatch" nil t)
```

`herdr-dispatch.el` requires `magit-section`, which bare `make compile` cannot resolve. Add an
opt-in load path to the Makefile — the first two lines only:

```make
EMACS ?= emacs
EXTRA_LOAD_PATH ?=
BATCH := $(EMACS) -Q --batch -L . -L test $(addprefix -L ,$(EXTRA_LOAD_PATH))
```

Bare `make test` keeps working with no packages installed, and skips the dispatcher tests.
Run both forms and expect exit 0 from each:

```bash
make test && make compile
B=$HOME/.emacs.d/var/elpaca/builds
DEPS="$B/magit-section $B/compat $B/dash $B/llama $B/transient $B/cond-let"
make test EXTRA_LOAD_PATH="$DEPS" && make compile EXTRA_LOAD_PATH="$DEPS"
```

- [ ] **Step 7: Commit**

```bash
git add herdr-dispatch.el test/herdr-dispatch-test.el herdr-transient.el Makefile
git commit -m "Add the dispatcher buffer: render, fold, refresh

Point is restored by section ident rather than line number, so a pane
closing above point no longer moves you to a different agent."
```

---

### Task 6: Object at point and the read-only verbs

**Files:**
- Modify: `herdr-dispatch.el` — add resolution, the error wrapper, and `RET p r f`
- Test: `test/herdr-dispatch-test.el` (append)

**Interfaces:**
- Consumes: `herdr-dispatch-mode` from Task 5; `herdr-pane-focus`, `herdr-agent-prompt`,
  `herdr-agent-read`, `herdr-tab-focus`, `herdr-workspace-focus`, `herdr-cmd--follow-focus` from
  `herdr-cmd.el`.
- Produces:
  - `(herdr-dispatch--value-at-point TYPE)` → value of the nearest enclosing TYPE section, or nil
  - `(herdr-dispatch--require TYPE WHAT)` → value, or `user-error`
  - `(herdr-dispatch--protect FN)` → runs FN, turning `herdr-error` into a message

- [ ] **Step 1: Write the failing tests**

Append to `test/herdr-dispatch-test.el`:

```elisp
(ert-deftest herdr-dispatch-resolves-the-nearest-enclosing-section ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "w1:p2")
    (should (equal "w1:p2" (herdr-dispatch--value-at-point 'herdr-pane)))
    (should (equal "w1" (herdr-dispatch--value-at-point 'herdr-workspace)))))

(ert-deftest herdr-dispatch-resolution-is-nil-when-absent ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "herdr.el")
    (should-not (herdr-dispatch--value-at-point 'herdr-pane))))

(ert-deftest herdr-dispatch-require-errors-with-a-specific-message ()
  (herdr-dispatch-test-with-buffer herdr-dispatch-test--nodes
    (search-forward "herdr.el")
    (should-error (herdr-dispatch--require 'herdr-pane "a pane")
                  :type 'user-error)))

(ert-deftest herdr-dispatch-protect-reports-a-server-error ()
  (skip-unless (featurep 'magit-section))
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (herdr-dispatch--protect
       (lambda () (signal 'herdr-error (list "busy" "pane is busy")))))
    (should (string-match-p "busy" (car messages)))))
```

- [ ] **Step 2: Run to verify they fail**

Run THE DISPATCHER TEST COMMAND (Task 5 Step 2).
Expected: FAIL, `herdr-dispatch--value-at-point` void-function.

- [ ] **Step 3: Add resolution, protection and verbs**

Add to `herdr-dispatch.el` after `herdr-dispatch--insert-nodes`, and add
`(require 'herdr-cmd)` to the requires:

```elisp
(defun herdr-dispatch--value-at-point (type)
  "Return the value of the nearest enclosing section of TYPE, or nil.
Walks up rather than down: a verb invoked on a pane line inside a
workspace should reach the workspace too."
  (let ((section (magit-current-section))
        (found nil))
    (while (and section (not found))
      (when (eq type (oref section type))
        (setq found (oref section value)))
      (setq section (oref section parent)))
    found))

(defun herdr-dispatch--require (type what)
  "Return the nearest enclosing TYPE value, or signal that WHAT is needed."
  (or (herdr-dispatch--value-at-point type)
      (user-error "herdr: point is not on %s" what)))

(defun herdr-dispatch--protect (fn)
  "Call FN, reporting a `herdr-error\\=' rather than letting it escape.

A stale cache is the usual cause — the pane closed while you were
looking at it — so `not_found\\=' reconciles and redraws before reporting.
Seeing a correct tree alongside the message is the difference between
\"that pane is gone\" and an opaque failure."
  (condition-case err
      (funcall fn)
    (herdr-error
     (let ((code (herdr-error-code err)))
       (when (equal code "not_found")
         (herdr-state-reconcile-panes)
         (herdr-dispatch-refresh))
       (message "herdr: %s%s" (herdr-error-message err)
                (if (equal code "no_server")
                    " (M-x herdr-start)"
                  (format " [%s]" code)))))))

(defmacro herdr-dispatch-defverb (name args docstring &rest body)
  "Define interactive command NAME taking ARGS, with BODY wrapped in
`herdr-dispatch--protect\\='.  DOCSTRING documents the command."
  (declare (indent 3) (doc-string 3))
  `(defun ,name ,args
     ,docstring
     (interactive)
     (herdr-dispatch--protect (lambda () ,@body))))

(herdr-dispatch-defverb herdr-dispatch-visit ()
  "Go to the thing at point.
A pane is focused and its buffer shown; a tab or workspace is focused
and then followed to whichever pane herdr lands on, which is the
server\\='s choice rather than ours."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-focus (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-worktree)
    (herdr-dispatch-open-worktree))
   ((herdr-dispatch--value-at-point 'herdr-tab)
    (herdr-tab-focus (herdr-dispatch--value-at-point 'herdr-tab)))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-focus (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point"))))

(herdr-dispatch-defverb herdr-dispatch-prompt ()
  "Prompt the agent at point."
  (let ((pane (herdr-dispatch--require 'herdr-pane "an agent")))
    (herdr-agent-prompt (read-string "Prompt: ") pane)))

(herdr-dispatch-defverb herdr-dispatch-read ()
  "Read the pane at point into a buffer."
  (herdr-pane-read (herdr-dispatch--require 'herdr-pane "a pane")
                   "recent_unwrapped"))

(herdr-dispatch-defverb herdr-dispatch-focus ()
  "Focus the thing at point server-side, without moving Emacs."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-rpc-call "pane.focus"
                    `((pane_id . ,(herdr-dispatch--value-at-point 'herdr-pane)))))
   ((herdr-dispatch--value-at-point 'herdr-tab)
    (herdr-rpc-call "tab.focus"
                    `((tab_id . ,(herdr-dispatch--value-at-point 'herdr-tab)))))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-rpc-call "workspace.focus"
                    `((workspace_id . ,(herdr-dispatch--value-at-point
                                        'herdr-workspace)))))
   (t (user-error "herdr: nothing at point"))))
```

`herdr-dispatch-open-worktree` is defined in Task 7. Until then, add a stub so this compiles:

```elisp
(declare-function herdr-dispatch-open-worktree "herdr-dispatch" ())
```

Bind them in `herdr-dispatch-mode-map`:

```elisp
    (define-key map (kbd "RET") #'herdr-dispatch-visit)
    (define-key map "p" #'herdr-dispatch-prompt)
    (define-key map "r" #'herdr-dispatch-read)
    (define-key map "f" #'herdr-dispatch-focus)
```

- [ ] **Step 4: Run the tests**

Run THE DISPATCHER TEST COMMAND (Task 5 Step 2).
Expected: 7 tests PASS.

- [ ] **Step 5: Run the hermetic suite and compile**

Run `make test && make compile`, then both again with `EXTRA_LOAD_PATH="$DEPS"` (Global Constraints).
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add herdr-dispatch.el test/herdr-dispatch-test.el
git commit -m "Resolve the object at point and add the read-only verbs

Verbs walk up the section tree, so acting from a pane line reaches its
tab and workspace too.  herdr-error is reported rather than raised, and
not_found reconciles first so the tree you are shown is correct."
```

---

### Task 7: Lazy worktrees

**Files:**
- Modify: `herdr-dispatch.el` — worktree fetch, cache, invalidation, `herdr-dispatch-open-worktree`
- Test: `test/herdr-dispatch-test.el` (append)

**Interfaces:**
- Consumes: `herdr-dispatch--worktrees` from Task 5, `herdr-state-workspace-directory` from Task 1.
- Produces:
  - `(herdr-dispatch--worktrees-for WORKSPACE-ID)` → list of WorktreeInfo, fetching once
  - `(herdr-dispatch-toggle)` — TAB, fetching worktrees on first expand
  - `(herdr-dispatch-open-worktree)` — opens the worktree at point as a workspace

- [ ] **Step 1: Write the failing tests**

Append to `test/herdr-dispatch-test.el`:

```elisp
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
```

- [ ] **Step 2: Run to verify they fail**

Run THE DISPATCHER TEST COMMAND (Task 5 Step 2).
Expected: FAIL, `herdr-dispatch--worktrees-for` void-function.

- [ ] **Step 3: Implement**

Add to `herdr-dispatch.el`, replacing the `declare-function` stub from Task 6:

```elisp
(defun herdr-dispatch--worktrees-for (workspace-id)
  "Return WORKSPACE-ID\\='s git worktrees, fetching them once.

Fetched on first expand rather than on every draw: `worktree.list\\=' is a
blocking round trip and there is one per workspace, so drawing them
eagerly would put N synchronous calls in the refresh path."
  (if-let* ((entry (assoc workspace-id herdr-dispatch--worktrees)))
      (cdr entry)
    (let* ((dir (herdr-state-workspace-directory (herdr-state-current)
                                                 workspace-id))
           (found (when dir
                    (alist-get 'worktrees
                               (herdr-rpc-call "worktree.list"
                                               `((cwd . ,dir)))))))
      (push (cons workspace-id found) herdr-dispatch--worktrees)
      found)))

(defun herdr-dispatch--invalidate-worktrees (kind _data)
  "Drop the worktree cache when KIND changed the set of worktrees.
Whole-cache rather than per-workspace: the events carry a worktree, not
the workspace whose listing it belongs to, and the refetch is one call
per expanded workspace."
  (when (member kind '("worktree_created" "worktree_opened"
                       "worktree_removed"))
    (setq herdr-dispatch--worktrees nil)))

(herdr-dispatch-defverb herdr-dispatch-toggle ()
  "Fold or unfold the section at point, fetching worktrees on first open."
  (when-let* ((workspace (herdr-dispatch--value-at-point 'herdr-workspace))
              ((not (assoc workspace herdr-dispatch--worktrees))))
    (herdr-dispatch--worktrees-for workspace)
    (herdr-dispatch-refresh))
  (call-interactively #'magit-section-toggle))

(herdr-dispatch-defverb herdr-dispatch-open-worktree ()
  "Open the worktree at point as a workspace."
  (let* ((path (herdr-dispatch--require 'herdr-worktree "a worktree"))
         (worktree (seq-find (lambda (candidate)
                               (equal path (alist-get 'path candidate)))
                             (apply #'append
                                    (mapcar #'cdr herdr-dispatch--worktrees)))))
    (if-let* ((open (alist-get 'open_workspace_id worktree)))
        (herdr-workspace-focus open)
      (herdr-worktree-open (alist-get 'branch worktree)))))
```

Register the invalidator inside `herdr-agents` (the command), next to the refresh hook:

```elisp
      (add-hook 'herdr-state-change-hook #'herdr-dispatch--invalidate-worktrees)
```

Bind TAB in `herdr-dispatch-mode-map`:

```elisp
    (define-key map (kbd "TAB") #'herdr-dispatch-toggle)
```

- [ ] **Step 4: Run the tests**

Run THE DISPATCHER TEST COMMAND (Task 5 Step 2).
Expected: 10 tests PASS.

- [ ] **Step 5: Run the hermetic suite and compile**

Run `make test && make compile`, then both again with `EXTRA_LOAD_PATH="$DEPS"` (Global Constraints).
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add herdr-dispatch.el test/herdr-dispatch-test.el
git commit -m "Fetch worktrees lazily and open one from the buffer

worktree.list is a blocking call per workspace, so it runs on first
expand and is invalidated by the worktree events already subscribed."
```

---

### Task 8: Mutating verbs — rename and close

**Files:**
- Modify: `herdr-dispatch.el`
- Test: `test/herdr-dispatch-test.el` (append)

**Interfaces:**
- Consumes: `herdr-dispatch-defverb`, `herdr-dispatch--value-at-point` from Task 6.
- Produces: `herdr-dispatch-rename`, `herdr-dispatch-close`.

Confirmation is inherited: `herdr-pane-close`, `herdr-tab-close`, `herdr-workspace-close` and
`herdr-worktree-remove` all prompt. Do not add a second prompt.

- [ ] **Step 1: Write the failing test**

```elisp
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
```

- [ ] **Step 2: Run to verify they fail**

Run THE DISPATCHER TEST COMMAND (Task 5 Step 2).
Expected: FAIL, `herdr-dispatch-rename` void-function.

- [ ] **Step 3: Implement**

```elisp
(herdr-dispatch-defverb herdr-dispatch-rename ()
  "Rename the thing at point.
Most specific section wins: a pane line inside a workspace renames the
pane, which is the thing you are looking at."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-rename (read-string "Pane label: ")
                       (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-tab)
    (herdr-tab-rename (read-string "Tab label: ")
                      (herdr-dispatch--value-at-point 'herdr-tab)))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-rename (read-string "Workspace label: ")
                            (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point to rename"))))

(herdr-dispatch-defverb herdr-dispatch-close ()
  "Close or remove the thing at point.
The underlying commands confirm; this adds no second prompt."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-worktree)
    ;; The worktree at point, resolved the way `herdr-dispatch-open-worktree'
    ;; resolves it — NOT `(herdr-dispatch--value-at-point 'herdr-workspace)',
    ;; which walks up to the repository whose worktree list was expanded and
    ;; would remove that instead.  See `herdr-dispatch--worktree-workspace'.
    (herdr-worktree-remove (herdr-dispatch--worktree-workspace)))
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-close (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-tab)
    (herdr-tab-close (herdr-dispatch--value-at-point 'herdr-tab)))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-close (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point to close"))))
```

Bind:

```elisp
    (define-key map "R" #'herdr-dispatch-rename)
    (define-key map "k" #'herdr-dispatch-close)
```

- [ ] **Step 4: Run the tests**

Run THE DISPATCHER TEST COMMAND (Task 5 Step 2).
Expected: 12 tests PASS.

- [ ] **Step 5: Hermetic suite and compile**

Run `make test && make compile`, then both again with `EXTRA_LOAD_PATH="$DEPS"` (Global Constraints).
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add herdr-dispatch.el test/herdr-dispatch-test.el
git commit -m "Add rename and close, dispatching on the section at point"
```

---

### Task 9: The create transient

**Files:**
- Modify: `herdr-dispatch.el`
- Test: `test/herdr-dispatch-test.el` (append)

**Interfaces:**
- Consumes: everything from Tasks 6-8.
- Produces: `herdr-dispatch-create` (transient prefix), and the five commands
  `herdr-dispatch-create-workspace`, `-tab`, `-pane`, `-agent`, `-worktree`.

**Two API constraints, from the spec's Protocol facts:**
- `tab.create` takes no `workspace_id`, so creating a tab in a specific workspace means calling
  `workspace.focus` first.
- `pane.split` needs a `target_pane_id`, so creating a pane in a tab means splitting one of that
  tab's existing panes.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest herdr-dispatch-create-tab-focuses-the-workspace-first ()
  "tab.create takes no workspace_id, so the workspace has to be focused."
  (skip-unless (featurep 'magit-section))
  (let ((calls nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (method params) (push (cons method params) calls) nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore)
              ((symbol-function 'transient-args) (lambda (_) nil)))
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

(ert-deftest herdr-dispatch-create-reads-transient-arguments ()
  (skip-unless (featurep 'magit-section))
  (should (equal "main" (herdr-dispatch--arg '("--base=main") "--base")))
  (should-not (herdr-dispatch--arg '("--base=main") "--label")))
```

- [ ] **Step 2: Run to verify they fail**

Run THE DISPATCHER TEST COMMAND (Task 5 Step 2).
Expected: FAIL, `herdr-dispatch--arg` void-function.

- [ ] **Step 3: Implement**

Add `(require 'transient)` to the requires, then:

```elisp
(defun herdr-dispatch--arg (args flag)
  "Return the value of FLAG in transient ARGS, or nil."
  (when-let* ((hit (seq-find (lambda (arg)
                               (string-prefix-p (concat flag "=") arg))
                             args)))
    (substring hit (1+ (length flag)))))

(defun herdr-dispatch--args ()
  "Return the create transient\\='s arguments, or nil outside it."
  (when (and (boundp 'transient-current-command)
             (eq transient-current-command 'herdr-dispatch-create))
    (transient-args 'herdr-dispatch-create)))

(herdr-dispatch-defverb herdr-dispatch-create-workspace ()
  "Create a workspace.
A workspace has no parent section to inherit from, so the directory
comes from --directory when set, and otherwise from a prompt defaulting
to the directory of the workspace at point."
  (let* ((args (herdr-dispatch--args))
         (default (or (herdr-dispatch--arg args "--directory")
                      (when-let* ((id (herdr-dispatch--value-at-point
                                       'herdr-workspace)))
                        (herdr-state-workspace-directory
                         (herdr-state-current) id))
                      default-directory))
         (dir (or (herdr-dispatch--arg args "--directory")
                  (read-directory-name "Workspace directory: " default))))
    (herdr-workspace-create dir (herdr-dispatch--arg args "--label"))))

(herdr-dispatch-defverb herdr-dispatch-create-tab ()
  "Create a tab in the workspace at point."
  (let ((workspace (herdr-dispatch--require 'herdr-workspace "a workspace"))
        (label (or (herdr-dispatch--arg (herdr-dispatch--args) "--label")
                   (read-string "Tab label (optional): "))))
    ;; tab.create has no workspace_id parameter: it creates in whatever
    ;; workspace is focused, so focus first.
    (herdr-rpc-call "workspace.focus" `((workspace_id . ,workspace)))
    (herdr-cmd--follow-new-pane
     (herdr-cmd--created-pane-id
      (herdr-rpc-call "tab.create"
                      `((label . ,(unless (string-empty-p label) label))
                        (focus . t)))))))

(herdr-dispatch-defverb herdr-dispatch-create-pane ()
  "Split a pane in the tab at point.
pane.split needs a pane to split, so a tab section splits its first."
  (let ((target (or (herdr-dispatch--value-at-point 'herdr-pane)
                    (when-let* ((tab (herdr-dispatch--value-at-point 'herdr-tab)))
                      (alist-get 'pane_id
                                 (seq-find (lambda (pane)
                                             (equal tab (alist-get 'tab_id pane)))
                                           (herdr-state-panes
                                            (herdr-state-current))))))))
    (unless target (user-error "herdr: no pane here to split"))
    (herdr-cmd--follow-new-pane
     (herdr-cmd--created-pane-id
      (herdr-rpc-call "pane.split" `((direction . "right")
                                     (target_pane_id . ,target)
                                     (focus . t)))))))

(herdr-dispatch-defverb herdr-dispatch-create-agent ()
  "Start an agent in the pane at point."
  (let* ((args (herdr-dispatch--args))
         (pane (herdr-dispatch--require 'herdr-pane "a pane"))
         (kind (or (herdr-dispatch--arg args "--kind")
                   (completing-read "Agent kind: " herdr-agent-kinds nil nil)))
         (name (or (herdr-dispatch--arg args "--label")
                   (read-string "Agent name: "))))
    (herdr-agent-start name kind pane)))

(herdr-dispatch-defverb herdr-dispatch-create-worktree ()
  "Create a git worktree from the workspace at point."
  (let* ((args (herdr-dispatch--args))
         (workspace (herdr-dispatch--require 'herdr-workspace "a workspace"))
         (default-directory (or (herdr-state-workspace-directory
                                 (herdr-state-current) workspace)
                                default-directory)))
    (herdr-worktree-create (read-string "New worktree branch: ")
                           (herdr-dispatch--arg args "--base"))
    (setq herdr-dispatch--worktrees nil)
    (herdr-dispatch-refresh)))

(defun herdr-dispatch--create-heading ()
  "Return the create menu heading, naming what point resolves to."
  (format "Create   [%s]"
          (or (herdr-dispatch--value-at-point 'herdr-pane)
              (herdr-dispatch--value-at-point 'herdr-tab)
              (herdr-dispatch--value-at-point 'herdr-workspace)
              "nothing at point")))

(transient-define-prefix herdr-dispatch-create ()
  "Create a herdr object, taking its parent from point."
  [:description herdr-dispatch--create-heading
   ["Create"
    ("w" "workspace" herdr-dispatch-create-workspace)
    ("t" "tab"       herdr-dispatch-create-tab)
    ("n" "pane"      herdr-dispatch-create-pane)
    ("a" "agent"     herdr-dispatch-create-agent)
    ("%" "worktree"  herdr-dispatch-create-worktree)]
   ["Arguments"
    ("-b" "base ref"  "--base=")
    ("-l" "label"     "--label=")
    ("-k" "agent kind" "--kind=")
    ("-d" "directory" "--directory=")]])
```

Bind the transient and the five direct keys:

```elisp
    (define-key map "c" #'herdr-dispatch-create)
    (define-key map "w" #'herdr-dispatch-create-workspace)
    (define-key map "t" #'herdr-dispatch-create-tab)
    (define-key map "n" #'herdr-dispatch-create-pane)
    (define-key map "a" #'herdr-dispatch-create-agent)
    (define-key map "%" #'herdr-dispatch-create-worktree)
```

- [ ] **Step 4: Run the tests**

Run THE DISPATCHER TEST COMMAND (Task 5 Step 2).
Expected: 15 tests PASS.

- [ ] **Step 5: Hermetic suite and compile**

Run `make test && make compile`, then both again with `EXTRA_LOAD_PATH="$DEPS"` (Global Constraints).
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add herdr-dispatch.el test/herdr-dispatch-test.el
git commit -m "Add the create transient and its five direct keys

tab.create takes no workspace_id and pane.split needs a target pane, so
creating in context means focusing a workspace first and splitting one
of a tab's existing panes."
```

---

### Task 10: Wire up, cover the new methods, document

**Files:**
- Modify: `herdr.el` — `herdr` opens the dispatcher; add `?` binding
- Modify: `herdr-dispatch.el` — `?` runs `herdr-transient`
- Modify: `herdr-cmd.el:32-66` — drift table entries
- Modify: `README.md`
- Test: `test/herdr-dispatch-live-test.el` (create)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing new.

- [ ] **Step 1: Add the live round-trip test**

Create `test/herdr-dispatch-live-test.el`:

```elisp
;;; herdr-dispatch-live-test.el --- Live dispatcher round trip -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-rpc)
(require 'herdr-state)

(defun herdr-dispatch-live-test--server-p ()
  "Return non-nil when a herdr server is reachable."
  (condition-case nil (progn (herdr-rpc-call "ping") t) (herdr-error nil)))

(ert-deftest herdr-dispatch-create-round-trip-leaves-the-session-unchanged ()
  "Create a workspace, tab, pane and agent, then put it all back."
  :tags '(:live)
  (skip-unless (and (herdr-dispatch-live-test--server-p)
                    (require 'magit-section nil t)))
  (require 'herdr-dispatch)
  (let* ((before (mapcar (lambda (w) (alist-get 'workspace_id w))
                         (alist-get 'workspaces
                                    (alist-get 'snapshot
                                               (herdr-rpc-call
                                                "session.snapshot")))))
         (workspace (alist-get 'workspace_id
                               (herdr-rpc-call
                                "workspace.create"
                                `((cwd . ,(expand-file-name
                                           temporary-file-directory))
                                  (label . "herdr-el-dispatch")
                                  (focus . t))))))
    (unwind-protect
        (progn
          (herdr-state-resync)
          (should (herdr-state-workspace-directory (herdr-state-current)
                                                   workspace)))
      (herdr-rpc-call "workspace.close" `((workspace_id . ,workspace))))
    (sleep-for 1)
    (let ((after (mapcar (lambda (w) (alist-get 'workspace_id w))
                         (alist-get 'workspaces
                                    (alist-get 'snapshot
                                               (herdr-rpc-call
                                                "session.snapshot"))))))
      (should (equal before after)))))

(provide 'herdr-dispatch-live-test)
;;; herdr-dispatch-live-test.el ends here
```

- [ ] **Step 2: Run it against a live server**

Run: `make test-live`
Expected: PASS, or skip when no server is running.

- [ ] **Step 3: Point `herdr` at the dispatcher**

In `herdr.el`, replace the body of `herdr` (lines 105-110):

```elisp
;;;###autoload
(defun herdr ()
  "Start herdr if needed and open the dispatcher.
The transient stays on `herdr-transient\\=', which is the right surface
when you are inside an agent\\='s terminal buffer and do not want to leave
it."
  (interactive)
  (herdr-start)
  (herdr-term-display)
  (herdr-agents))
```

Add near the other declarations at `herdr.el:35-36`:

```elisp
(declare-function herdr-agents "herdr-dispatch" ())
(autoload 'herdr-agents "herdr-dispatch" nil t)
```

In `herdr-dispatch.el`, bind `?` and declare the transient without requiring it — requiring it
would close a load cycle, since `herdr-transient` autoloads `herdr-agents`:

```elisp
(declare-function herdr-transient "herdr-transient" ())
(autoload 'herdr-transient "herdr-transient" nil t)
```

```elisp
    (define-key map "?" #'herdr-transient)
```

- [ ] **Step 4: Extend the drift table**

In `herdr-cmd.el`, add to `herdr-cmd-methods` and fix the `agent.read` entry, which omits the
`strip_ansi` the command actually sends:

```elisp
    (herdr-agent-read            "agent.read"           "target" "source" "lines" "format" "strip_ansi")
    (herdr-dispatch-create-tab   "tab.create"           "label" "focus")
    (herdr-dispatch-create-pane  "pane.split"           "direction" "target_pane_id" "focus")
    (herdr-dispatch-focus        "pane.focus"           "pane_id")
    (herdr-dispatch--worktrees-for "worktree.list"      "cwd")
```

- [ ] **Step 5: Run everything**

Run: `make test && make compile && make test-live`
Expected: all exit 0.

- [ ] **Step 6: Document in README.md**

Replace the section describing `*herdr-agents*` with:

```markdown
### The dispatcher

`M-x herdr` (or `C-c H`) opens `*herdr-agents*`: the whole session as a foldable
workspace → tab → pane tree, and the place every command is reachable from.

| Key | Action |
| --- | --- |
| `RET` | go to the thing at point |
| `TAB` | fold; fetches a workspace's worktrees on first open |
| `c` | create menu, with its parent taken from point |
| `w` `t` `n` `a` `%` | create workspace / tab / pane / agent / worktree directly |
| `p` `r` | prompt / read the agent at point |
| `f` `R` `k` | focus / rename / close the thing at point |
| `g` `q` `?` | refresh / quit / the transient menu |

Workspaces with a single tab omit the tab level, since an unnamed tab is labelled by
number and adds nothing. A collapsed section still shows the worst status inside it,
so folding never hides a blocked agent.

`herdr-transient` is unchanged and still globally bound — it is the surface to use from
inside an agent's terminal buffer, where leaving for the dispatcher is the wrong move.
```

- [ ] **Step 7: Commit**

```bash
git add herdr.el herdr-dispatch.el herdr-cmd.el README.md test/herdr-dispatch-live-test.el
git commit -m "Make the dispatcher the primary surface and document it

M-x herdr opens the buffer; herdr-transient stays globally bound for use
from inside an agent's terminal.  New methods join the drift table, and
agent.read's entry gains the strip_ansi it was always sending."
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: architecture and the agent-info slot → 1;
`herdr-project` fix → 2; tree model, flattening, rollup, worktree dedup → 3; module split → 4;
rendering, refresh, ident-based point → 5; object resolution, verbs, error handling → 6; lazy
worktrees → 7; rename/close → 8; create transient → 9; entry point, drift table, README, live
test → 10.

**Deliberate deviation.** The spec put the tree model in `herdr-dispatch.el`; the plan splits it
into `herdr-tree.el` so `make test` can reach it without `magit-section`. Noted in File Structure.

**Known rough edge.** Task 4 leaves `M-x herdr-agents` undefined until Task 5. The boundary is
drawn there because moving the glyphs and deleting the old buffer are one change; executing
Tasks 4 and 5 together is reasonable.

**Type consistency.** `herdr-state-agent-info` (slot) vs `herdr-state-agents` (existing function)
verified distinct. Node shape `(TYPE VALUE LINE CHILDREN)` is used identically in Tasks 3, 5 and
the tests. `herdr-dispatch--worktrees` is introduced in Task 5, filled in Task 7, cleared in Task
9 — same name throughout. `herdr-dispatch-defverb` is defined in Task 6 and used in Tasks 7, 8
and 9.
