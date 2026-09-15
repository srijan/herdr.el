# Flat Hierarchy, Tab-Per-Agent, Attach Without Adoption — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** herdr.el models herdr's own hierarchy — workspace → pane, agent = process inside a pane — with creation via tab-per-agent and attachment via `herdr terminal attach`, deleting the shell-adoption machinery.

**Architecture:** Three layers change bottom-up: state (attachability = every pane), term (one `terminal attach` code path), tree/dispatch (flat rendering, tab.create-based creation verbs). Each task keeps `make compile` and `make test` green.

**Tech Stack:** Emacs Lisp, ERT, herdr ≥ 0.8.2 socket RPC + CLI, ghostel.

**Spec:** Proof doc https://www.proofeditor.ai/d/wod2eba0 (approved 2026-08-26). Local copy of key facts in Global Constraints.

## Global Constraints

- Minimum herdr is 0.8.2 (README already states this; do not lower it). `herdr terminal attach <terminal_id>` attaches to ANY pane; `PaneInfo` carries `terminal_id`; `tab.create` accepts `workspace_id`, `cwd`, `label`, `focus` and replies with `root_pane`.
- Obsolete markers use version string `"0.2.0"` (package is at 0.1.0).
- `make compile` must pass under `byte-compile-error-on-warn`; run `make clean && make compile` if compilation order errors appear (stale .elc shadowing).
- Byte-compiled `.elc` files shadow edited `.el` in tests — run `make compile` before `make test` after every edit batch.
- CONTRIBUTING.md gates before the PR: `make compile`, `make test`, `make test-live`, results stated in the PR body; say what ran in a real frame.
- Work on branch `flat-hierarchy` off current `main` (182ec1e).

---

### Task 1: State layer — every pane is attachable

**Files:**
- Modify: `herdr-state.el:140-170` (herdr-shell-agent-name, herdr-state-shell-pane-p, herdr-state-attachable, herdr-state-agents)
- Test: `test/herdr-state-test.el:449-474`, `test/herdr-modeline-test.el:56`

**Interfaces:**
- Produces: `herdr-state-attachable STATE` → all panes; `herdr-state-agents STATE` → panes whose `agent` field is non-nil. Later tasks rely on exactly these semantics.

- [ ] **Step 1: Rewrite the state tests.** In `test/herdr-state-test.el`, replace the three tests in the `;;; Adopted shells` section (`herdr-state-attachable-includes-adopted-shells`, `herdr-state-agents-excludes-adopted-shells`, `herdr-state-shell-pane-p-keys-off-the-configured-name`) with:

```elisp
;;; Attachability

(ert-deftest herdr-state-attachable-is-every-pane ()
  "herdr terminal attach takes any pane, agent or not."
  (let ((state (herdr-state-test--state
                :panes '(((pane_id . "w1:p1") (agent . "claude"))
                         ((pane_id . "w1:p2") (agent . "shell"))
                         ((pane_id . "w1:p3"))))))
    (should (equal '("w1:p1" "w1:p2" "w1:p3")
                   (mapcar (lambda (p) (alist-get 'pane_id p))
                           (herdr-state-attachable state))))))

(ert-deftest herdr-state-agents-is-every-pane-with-an-agent ()
  "An agent is a process herdr recognizes inside a pane — nothing more."
  (let ((state (herdr-state-test--state
                :panes '(((pane_id . "w1:p1") (agent . "claude"))
                         ((pane_id . "w1:p2"))))))
    (should (equal '("w1:p1")
                   (mapcar (lambda (p) (alist-get 'pane_id p))
                           (herdr-state-agents state))))))
```

Adapt the constructor call to whatever helper the existing tests in that file use to build a state (read the deleted tests first — reuse their exact state-building idiom, only the pane lists and assertions change).

- [ ] **Step 2: Run the new tests to verify they fail** (`make compile && make test` — expect the two new tests failing, old three gone).

- [ ] **Step 3: Implement.** In `herdr-state.el`:

```elisp
(defcustom herdr-shell-agent-name "shell"
  "Agent name `herdr-adopt-shell' used to report for plain shells.
Obsolete: since herdr 0.8.2, `herdr terminal attach' takes any pane, so
nothing needs to be reported to make a pane attachable."
  :type 'string
  :group 'herdr)
(make-obsolete-variable 'herdr-shell-agent-name nil "0.2.0")

(defun herdr-state-shell-pane-p (pane)
  "Return non-nil when PANE was adopted via `herdr-adopt-shell'."
  (equal (alist-get 'agent pane) herdr-shell-agent-name))
(make-obsolete 'herdr-state-shell-pane-p
               "test (alist-get 'agent pane) instead; every pane is attachable now."
               "0.2.0")

(defun herdr-state-attachable (state)
  "Return the panes in STATE a terminal client can attach to.
`herdr terminal attach' takes any pane's raw terminal stream, so that
is every pane; the function survives as the single place that says so."
  (herdr-state-panes state))

(defun herdr-state-agents (state)
  "Return the panes in STATE with a detected or reported agent."
  (seq-filter (lambda (pane) (alist-get 'agent pane))
              (herdr-state-panes state)))
```

Keep `herdr-state-shell-pane-p`'s body compiling without an obsolete-variable warning: reference the variable via `(bound-and-true-p herdr-shell-agent-name)` if the byte compiler complains under `byte-compile-error-on-warn`.

- [ ] **Step 4: Delete `herdr-modeline-segment-ignores-adopted-shells`** (`test/herdr-modeline-test.el:56`) — with agents = "panes with an agent", a pane reporting `shell` counts; nothing in the package creates those anymore. Also fix `herdr-tree-status-counts`'s docstring in `herdr-tree.el:111-116`, which claims agents excludes adopted shells: it now reads "Real agents only" — reword to "over the agent panes in STATE (panes whose `agent' field is set)".

- [ ] **Step 5: Run `make compile && make test`.** Expect failures ONLY in areas later tasks own: `herdr-select-available-shell-excludes-adopted-shells` (Task 4 deletes it), tree `shell*` tests (Task 3), term reconcile tests (Task 2). If any of those fail already, note it and confirm the failure matches the later task's planned rewrite; everything else must pass. If `herdr-select-test.el:229` fails now, delete that test in this step instead of waiting (it asserts adopted shells are excluded from the picker — semantics Task 1 already changed).

- [ ] **Step 6: Commit** `git add herdr-state.el herdr-tree.el test/herdr-state-test.el test/herdr-modeline-test.el test/herdr-select-test.el && git commit` — subject: `Make every pane attachable in the state layer`.

---

### Task 2: Term layer — one attach path via `herdr terminal attach`

**Files:**
- Modify: `herdr-term.el` — commentary (lines 15–55), `herdr-term-attach-args` (164), `herdr-term-reconcile` (173), `herdr-term--attach-if-possible` (277), `herdr-term--attach-1` (~325), `herdr-term-agent-buffer-name` kind fallback
- Test: `test/herdr-term-test.el:115,181,193,202`

**Interfaces:**
- Consumes: Task 1's `herdr-state-attachable` (all panes).
- Produces: `herdr-term-attach-args PANE TAKEOVER` — takes the pane ALIST (was: pane id), returns `("terminal" "attach" TERMINAL-ID)` plus `("--takeover")` when TAKEOVER. Signals `user-error` when PANE has no `terminal_id`.

- [ ] **Step 1: Rewrite the term tests.** Replace `herdr-term-attach-args-target-the-pane` (line 181):

```elisp
(ert-deftest herdr-term-attach-args-target-the-terminal-stream ()
  "Attach goes through `herdr terminal attach', which takes any pane."
  (should (equal '("terminal" "attach" "t7")
                 (herdr-term-attach-args '((pane_id . "w1:p1") (terminal_id . "t7")) nil)))
  (should (equal '("terminal" "attach" "t7" "--takeover")
                 (herdr-term-attach-args '((pane_id . "w1:p1") (terminal_id . "t7")) t))))

(ert-deftest herdr-term-attach-args-refuses-a-pane-without-a-terminal-id ()
  (should-error (herdr-term-attach-args '((pane_id . "w1:p1")) nil)
                :type 'user-error))
```

Replace `herdr-term-reconcile-creates-a-buffer-for-an-adopted-shell` (193) and `herdr-term-reconcile-reaps-a-released-shell` (202):

```elisp
(ert-deftest herdr-term-reconcile-offers-every-pane ()
  "TO-CREATE covers agentless panes too; attach needs no agent."
  ;; Build a state holding one agent pane and one plain pane, no buffers.
  ;; Reuse the state/buffer fixture idiom of the surrounding tests.
  ;; Assert both pane ids are in (car plan).
  )

(ert-deftest herdr-term-reconcile-reaps-only-when-the-pane-is-gone ()
  "A pane losing its agent keeps its buffer; only a closed pane is reaped."
  ;; Fixture: buffers for "w1:p1" (still in state, now agentless) and
  ;; "w1:p9" (absent from state).  Assert (cdr plan) holds only p9's buffer.
  )
```

Fill the two bodies by copying the fixture code from the two tests being replaced (they already build states and fake buffer alists) and changing only pane fields and assertions.

Rewrite `herdr-term-agent-buffer-name-reads-an-adopted-shell-naturally` (115): the input pane loses its `(agent . "shell")` field (a plain pane has none), and the expected name keeps whatever that test expects for a label-less shell — with the kind fallback below it becomes `*herdr: shell@WS*` shape. Read the current test body first; preserve its intent (a shell buffer must not be named `agent@...`).

- [ ] **Step 2: Run to verify failures** (`make compile && make test`).

- [ ] **Step 3: Implement in `herdr-term.el`.**

```elisp
(defun herdr-term-attach-args (pane takeover)
  "Return argv tail for attaching to PANE, stealing it when TAKEOVER.
PANE is the pane's alist from the cache; `herdr terminal attach' wants
the raw terminal stream id, which only the pane record knows."
  (let ((terminal (alist-get 'terminal_id pane)))
    (unless terminal
      (user-error "herdr: pane %s has no terminal_id; herdr 0.8.2+ required"
                  (alist-get 'pane_id pane)))
    (append (list "terminal" "attach" terminal)
            (when takeover '("--takeover")))))
```

In `herdr-term--attach-1`, both `ghostel-exec` calls change `(herdr-term-attach-args pane-id nil)` / `... t)` to `(herdr-term-attach-args pane nil)` / `... t)` (the `pane` alist is already in scope).

`herdr-term--attach-if-possible` drops the agent gate:

```elisp
(defun herdr-term--attach-if-possible (pane-id)
  "Attach to PANE-ID now, if this backend attaches and the cache knows it."
  (when (eq herdr-terminal-backend 'agent-windows)
    (let ((state (herdr-state-current)))
      (when-let* ((pane (herdr-state-pane state pane-id)))
        (herdr-term--attach state pane)))))
```

`herdr-term-reconcile`: `(herdr-state-attachable state)` already returns all panes after Task 1 — update only the docstring (drop "Attachability, not agenthood..." paragraph; new criterion sentence: "Every pane can hold a buffer; TO-REAP is buffers whose pane is gone from STATE."). Rename the local `agents`/`agent-ids` to `panes`/`pane-ids`.

`herdr-term-agent-buffer-name`: the kind fallback `"agent"` becomes `"shell"` — `(or (alist-get 'display_agent pane) (alist-get 'agent pane) "shell")` — so an agentless pane's buffer reads `*herdr: shell@ws*`, not `*herdr: agent@ws*`.

- [ ] **Step 4: Rewrite the stale commentary.** File header lines 29–35: the bullet "`agent attach' refuses a pane with no detected agent, which is why reconciliation considers agents rather than panes." becomes "Attachment goes through `herdr terminal attach', which takes any pane's raw stream — agent or plain shell — so reconciliation considers panes." Line 21's "each holding a `herdr agent attach'" → "each holding a `herdr terminal attach'". The `herdr-terminal-backend` defcustom docstring drops "plain shell panes are then not represented, since herdr will not attach to a pane without an agent" — replace with "plain shell panes get buffers on demand, the first time you go to one."

- [ ] **Step 5: `make compile && make test`** — term tests green; remaining reds only in Task 3/4 territory.

- [ ] **Step 6: Commit** — subject: `Attach every pane through herdr terminal attach`.

---

### Task 3: Tree — flat workspace → panes

**Files:**
- Modify: `herdr-tree.el:138-150` (agent-label), `246-320` (pane/tab node fns, workspace-node children)
- Modify: `herdr-dispatch.el:330-333` (herdr-tab renderer case)
- Test: `test/herdr-tree-test.el:29,401`, `test/herdr-dispatch-test.el:101,115,2490` region

**Interfaces:**
- Consumes: Task 1 semantics.
- Produces: `herdr-tree--panes-in-workspace STATE WORKSPACE-ID WIDTH` → list of pane nodes; no `herdr-tab` sections are ever emitted; `herdr-tree--agent-label` returns `"shell"` for a pane with no `agent`.

- [ ] **Step 1: Update tree tests.** `herdr-tree-marks-adopted-shells` (401) becomes:

```elisp
(ert-deftest herdr-tree-marks-agentless-panes-as-shells ()
  "A pane with no agent reads as a shell — no caste star, no status."
  ;; Same fixture as before but the pane has NO agent field at all.
  ;; Assert the row matches "~" and "shell" and does NOT match "shell\\*".
  )
```

The shared fixture at line 29 keeps `(agent . "shell")` panes working (they still render as agent panes named shell now — update assertions that expected `shell*`). Add a flat-rendering test:

```elisp
(ert-deftest herdr-tree-renders-panes-flat-under-the-workspace ()
  "Multi-tab workspaces render panes directly under the workspace."
  ;; Fixture: one workspace, two tabs, one pane in each.
  ;; Assert the built tree has pane nodes as direct children of the
  ;; workspace node and contains no herdr-tab node anywhere.
  )
```

Write both bodies against the file's existing tree-building helpers (the fixtures at the top of `herdr-tree-test.el` show the idiom; the dispatch tests at `herdr-dispatch-test.el:101` show how nodes were asserted under tabs — invert that assertion).

- [ ] **Step 2: Run to verify failures.**

- [ ] **Step 3: Implement in `herdr-tree.el`.** Replace `herdr-tree--panes-in-tab` + `herdr-tree--orphan-panes-in-workspace` + `herdr-tree--tab-node` + `herdr-tree--tabs-in-workspace` with:

```elisp
(defun herdr-tree--panes-in-workspace (state workspace-id width)
  "Return nodes for every pane of WORKSPACE-ID in STATE, agent column WIDTH.
Tabs are server-side layout: under `agent-windows' every pane is its own
Emacs buffer, so grouping rows by tab explained nothing and cost a level.
Listing panes directly also closes the lost-pane hole the old orphan
handling existed for — a pane whose tab the cache does not hold is just
another pane of its workspace here."
  (mapcar (lambda (pane) (herdr-tree--pane-node state pane width))
          (seq-filter (lambda (pane)
                        (equal workspace-id (alist-get 'workspace_id pane)))
                      (herdr-state-panes state))))
```

`herdr-tree--workspace-node`'s `children` binding becomes `(herdr-tree--panes-in-workspace state id width)` (delete the tabs `let*` binding and the one-tab special case comment).

`herdr-tree--pane-node`: `(shell (herdr-state-shell-pane-p pane))` → `(shell (not (alist-get 'agent pane)))`.

`herdr-tree--agent-label`: the `herdr-state-shell-pane-p` branch returning `"shell*"` becomes `(if (not (alist-get 'agent pane)) "shell" ...)`.

- [ ] **Step 4: Remove the dead tab renderer case** in `herdr-dispatch.el:330-333` (`('herdr-tab ...)` in the section-insertion pcase). Update dispatch tests `herdr-dispatch-nests-children-under-a-tab` (101) and `herdr-dispatch-indents-a-pane-under-a-tab-deeper-than-one-under-a-workspace` (115): both become one test asserting panes of a two-tab workspace render at the same depth directly under the workspace heading. The fixture comment at 2490 ("w2 keeps its tab level") and its fixture panes stay valid data — only depth assertions change.

- [ ] **Step 5: `make compile && make test`** — tree and dispatch rendering tests green.

- [ ] **Step 6: Commit** — subject: `Render panes flat under their workspace`.

---

### Task 4: Creation — tab-per-agent, new-terminal verb, adoption retired

**Files:**
- Modify: `herdr-cmd.el` — `herdr-cmd--follow-new-pane` (98), `herdr-cmd--offer-to-adopt` (245), `herdr-cmd--split-new-shell` (526→delete), `herdr-agent-start` (553), `herdr-adopt-shell`/`herdr-release-shell` (obsolete markers), `herdr-adopt-created-shells` (obsolete)
- Modify: `herdr-dispatch.el` — `herdr-dispatch--split-target`/`--require-split-target` (1010→delete), `herdr-dispatch-create-pane` (1069), `herdr-dispatch-create-agent` (1078), `herdr-dispatch-create-tab` (988→delete), verb tab branches (843, 883, 917, 951), create heading + menu (1129, 1138), keymap `"t"` (134)
- Modify: `herdr-select.el` — `herdr-select-create-new-shell` text, `herdr-select--available-shell-ids` docstring
- Test: `test/herdr-cmd-test.el:142,158,177,443,534`, `test/herdr-select-test.el:220-290`, `test/herdr-dispatch-test.el:2546,2595` region, `test/herdr-transient-test.el:217`

**Interfaces:**
- Consumes: `herdr-cmd--created-pane-id` (existing, handles `root_pane`), Task 2's attach path.
- Produces: `herdr-cmd--new-tab-pane &optional WORKSPACE-ID CWD` → pane id string; `herdr-dispatch--workspace-target` → workspace id or nil (nil = server's focused workspace).

- [ ] **Step 1: Write/rewrite tests first.**

`herdr-cmd-test.el`: delete `herdr-cmd-created-pane-is-adopted-so-it-gets-a-buffer` (142), `herdr-cmd-created-pane-is-not-adopted-when-disabled` (158), `herdr-cmd-existing-agent-pane-is-selected-not-adopted` (177), `herdr-workspace-focus-offers-to-adopt-an-unattachable-pane` (443). Add, reusing the RPC-stubbing idiom those tests used:

```elisp
(ert-deftest herdr-cmd-new-tab-pane-creates-a-tab-and-returns-its-root-pane ()
  ;; Stub herdr-rpc-call: assert method is "tab.create", params carry
  ;; (workspace_id . "wZ") and (focus . t); answer with
  ;; ((root_pane . ((pane_id . "wZ:p9")))).
  ;; (should (equal "wZ:p9" (herdr-cmd--new-tab-pane "wZ")))
  )

(ert-deftest herdr-cmd-follow-new-pane-selects-or-waits ()
  ;; Under agent-windows: when herdr-term-select-pane returns nil (cache
  ;; behind), herdr-cmd--select-pane-when-ready is invoked — no
  ;; pane.report_agent call may occur.  Stub both and assert.
  )
```

Rewrite `herdr-agent-start-create-new-splits-then-starts-on-the-new-pane` (534) as `...-creates-a-tab-then-starts-on-its-root-pane`: same structure, the stub now expects `tab.create` (not `pane.split`) before `agent.start`.

`herdr-select-test.el`: delete `herdr-select-available-shell-excludes-adopted-shells` (229) if not already gone from Task 1. The others (220, 246, 261, 272, 281) survive — only the sentinel's text changes, so update string literals to the new value below.

`herdr-dispatch-test.el`: `herdr-dispatch-create-agent-never-adopts-the-pane-it-creates` (2595) becomes `...-creates-a-tab-for-the-agent`: stub expects `tab.create` then `agent.start`, no `pane.report_agent`.

`herdr-transient-test.el`: `herdr-transient-adoption-is-offered-and-hidden-under-session` (217) — delete, and remove the adopt/release entries from the transient it tests (see Step 3).

- [ ] **Step 2: Run to verify failures.**

- [ ] **Step 3: Implement.**

`herdr-cmd.el`:

```elisp
(defun herdr-cmd--new-tab-pane (&optional workspace-id cwd)
  "Create a tab and return its root pane's id.
WORKSPACE-ID nil means whatever workspace the server has focused; CWD
nil inherits the workspace directory.  One tab per agent, rather than a
split: Emacs ignores herdr's layout, but the TUI does not, and N agents
as N full-width tabs beats N slivers of one tab."
  (herdr-cmd--created-pane-id
   (herdr-rpc-call "tab.create"
                   `((workspace_id . ,workspace-id)
                     (cwd . ,cwd)
                     (focus . t)))))
```

Delete `herdr-cmd--split-new-shell`. In `herdr-agent-start`, `(setq pane (herdr-cmd--split-new-shell))` → `(setq pane (herdr-cmd--new-tab-pane))`; update its docstring ("splits a fresh shell" → "creates a fresh tab").

`herdr-cmd--follow-new-pane` shrinks to:

```elisp
(defun herdr-cmd--follow-new-pane (pane-id)
  "Show PANE-ID, the pane a create command just made.
PANE-ID comes from the creating call's own response rather than a
follow-up `pane.current': herdr.el reaches the socket as a paneless
client, for which `pane.current' answers with the server's global focus.
The cache may not hold the pane yet — creation was announced on the
event stream — so a miss waits for reconciliation instead of failing."
  (when (and pane-id (eq herdr-terminal-backend 'agent-windows))
    (unless (herdr-term-select-pane pane-id)
      (herdr-cmd--select-pane-when-ready pane-id))))
```

`herdr-cmd--offer-to-adopt` is deleted; its two callers (`herdr-workspace-focus` path at 231, `herdr-cmd--follow-focus` at 243) call `(herdr-cmd--select-pane-when-ready pane)` on a nil select instead — attach works on any pane now, so the only reason select fails is a cache that has not caught up.

`herdr-adopt-created-shells`: keep the defcustom, add `(make-obsolete-variable 'herdr-adopt-created-shells nil "0.2.0")`, delete its remaining uses. `herdr-adopt-shell` / `herdr-release-shell`: keep as working commands (they wrap real server methods), add `(make-obsolete 'herdr-adopt-shell "every pane is attachable; adoption buys nothing since herdr 0.8.2." "0.2.0")` and the same for release; rewrite both docstrings to one short paragraph saying what they still do (report/release an agent label) and that buffers no longer need them. Keep both rows in `herdr-cmd-methods` (the drift test only checks the params exist in the schema).

`herdr-dispatch.el`:

```elisp
(defun herdr-dispatch--workspace-target ()
  "Return the workspace id point resolves to, or nil for the focused one.
A pane row resolves through its own record; a workspace heading is
itself; anywhere else defers to the server's focused workspace, which is
what `tab.create' does with a nil workspace_id."
  (or (herdr-dispatch--value-at-point 'herdr-workspace)
      (when-let* ((pane-id (herdr-dispatch--value-at-point 'herdr-pane))
                  (pane (herdr-state-pane (herdr-state-current) pane-id)))
        (alist-get 'workspace_id pane))))

(herdr-dispatch-defverb herdr-dispatch-create-pane ()
  "Create a new terminal: a fresh tab in the workspace at point."
  (herdr-cmd--follow-new-pane
   (herdr-cmd--new-tab-pane (herdr-dispatch--workspace-target))))

(herdr-dispatch-defverb herdr-dispatch-create-agent ()
  "Start an agent in the pane at point, or in a fresh tab.
The pane at point is used only when it has no agent; anywhere else a new
tab is created in the workspace at point, so `a' has an answer
everywhere in the buffer.  Both prompts come before the create, so
abandoning either leaves nothing behind."
  (let* ((args (herdr-dispatch--args))
         (kind (or (herdr-dispatch--arg args "--kind")
                   (completing-read "Agent kind: " herdr-agent-kinds nil nil)))
         (name (or (herdr-dispatch--arg args "--label")
                   (herdr-dispatch--read-agent-name kind)))
         (pane (or (herdr-dispatch--free-pane-at-point)
                   (herdr-cmd--new-tab-pane (herdr-dispatch--workspace-target)))))
    (herdr-agent-start name kind pane)))
```

Delete: `herdr-dispatch--split-target`, `herdr-dispatch--require-split-target`, `herdr-dispatch-create-tab` (the `herdr-tab-create` M-x command remains for TUI users), the `"t"` keymap binding (134) and the `("t" "tab" ...)` create-menu row (1138). Remove the `herdr-tab` branches from the focus (843), prompt (883), rename (917) and close (951) verbs, and the `herdr-tab` line from `herdr-dispatch--create-heading` (1129). `herdr-dispatch--free-pane-at-point`'s docstring drops the adopted-shell sentences.

`herdr-select.el`: `herdr-select-create-new-shell` value becomes `"＋ new terminal"` (docstring: "`herdr-agent-start' turns that into a fresh tab"); `herdr-select--available-shell-ids` docstring drops the adopted-shell paragraph (the predicate is already agent-nil-based). Menu label in `herdr-dispatch-create`: `("n" "terminal" herdr-dispatch-create-pane)`. Remove the adopt/release rows from `herdr-transient.el`'s pane menu (grep `herdr-adopt-shell` there).

- [ ] **Step 4: `make compile && make test`** — full suite green now. Fix any straggler the run names (expected stragglers: string literals of the old sentinel, docstring-asserting tests).

- [ ] **Step 5: Commit** — subject: `Create agents and terminals as tabs, retiring shell adoption`.

---

### Task 5: Docs, live gate, manual verification, PR

**Files:**
- Modify: `README.md` (agent-windows description if it mentions adoption/attach constraints), `CONTRIBUTING.md` untouched
- Test: `make test-live`, real frame

- [ ] **Step 1: Sweep prose.** `grep -rn "adopt\|agent attach\|shell\*" README.md *.el` — update every stale claim (the attach constraint, `shell*` marker mentions, adoption workflow). README's backend comparison keeps `session` unchanged.

- [ ] **Step 2: `make clean && make compile && make test`** — record the counts.

- [ ] **Step 3: `make test-live`** against the running herdr 0.8.2. If a live test asserts adoption behavior (`test/herdr-state-live-test.el` matched the adopt grep), update it to the new semantics before running.

- [ ] **Step 4: Manual checks in a real frame** (ask the user to run, or use their live Emacs only with permission): (a) `herdr terminal attach` parity — open an *agent* pane's buffer, confirm keys and rendering behave as before; (b) dashboard `a` on a workspace heading → new tab appears, agent starts, buffer shows; (c) dashboard `n` → new terminal tab with buffer; (d) tree shows flat panes for a multi-tab workspace.

- [ ] **Step 5: Commit docs, push `flat-hierarchy`, open PR** against `srijan/herdr.el` main (remember `-R srijan/herdr.el`). PR body per CONTRIBUTING.md: outcome-named subject, gates stated with counts, real-frame checks listed, manual parity result stated.

