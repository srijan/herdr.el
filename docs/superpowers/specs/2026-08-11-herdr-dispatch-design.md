# herdr.el dispatcher — Design

Date: 2026-08-11
Status: Designed. Not yet implemented.

## Summary

Turn `*herdr-agents*` from a read-mostly status list into the central dispatcher for a herdr
session: a foldable workspace → tab → pane tree, built on
[magit-section](https://github.com/magit/magit), from which you can create workspaces, tabs,
panes, agents, and worktrees as well as act on them.

Today the buffer renders a flat workspace → pane list and offers five keys (`RET` visit, `p`
prompt, `r` read, `g` refresh, `q` quit). Creation of any kind happens elsewhere — in
`herdr-transient` or through minibuffer prompts that cannot see what you are looking at.

Target environment: Emacs 30.2, herdr 0.8.0 (protocol 19), macOS.

## Goals

1. **One surface.** Everything you do to a herdr session is reachable from one buffer, acting on
   the thing under point.
2. **Creation in context.** `c` on a workspace creates a tab in *that* workspace; `%` under a
   repo creates a worktree from *that* repo. Point supplies the parent.
3. **Structure made visible.** herdr's real hierarchy — including tabs, which the `agent-windows`
   backend hides entirely today — is shown and navigable.
4. **No regression in awareness.** The buffer stays live off the event stream and stays
   consistent with the modeline segment.

## Non-goals

Deliberately excluded from this change, though each is a real gap:

- **Named sessions** (`--session`, `HERDR_SOCKET_PATH`) and **`--remote`**. Transport-layer work
  in `herdr-rpc`; unrelated to this buffer.
- **`agent.rename`.** Agent names are *displayed* when set (see Protocol facts), but setting one
  is a separate command.
- **Plugins** (`plugin.*`), `agent.view.*`, `layout.apply`/`export`. Reachable via `herdr-call`.
- **Replacing `herdr-transient`.** It stays, and stays globally bound. See Decisions.

## Decisions and rationale

### The buffer becomes home; the transient stays

`M-x herdr` opens the dispatcher rather than the transient. The transient remains bound globally
and is reachable from `?` inside the buffer, scoped to point.

Deleting it was considered and rejected. The transient is the right surface when you are *inside*
an agent's terminal buffer and do not want to leave it — which under `agent-windows` is where you
spend most of your time. A dispatcher you must first navigate to is worse than a menu that
appears where you already are. Keeping both costs nothing: they call the same `herdr-cmd`
functions.

### magit-section rather than hand-rolled folding

Adds `(magit-section "3.3")` to `Package-Requires`, alongside `transient` — the same
ecosystem, and a library published standalone for exactly this use.

The alternative was `outline-minor-mode` (built in since Emacs 28, already the floor) or
hand-rolled overlays. Both give folding cheaply; neither gives *section identity*, which is the
part this design actually needs. Verbs resolve "the object at point" by walking up a typed
section tree, and point must survive a refresh by identity rather than by line number. That is
roughly 150 lines of machinery, and it is the machinery magit-section exists to provide.

### The dispatcher is a thin layer over existing commands

Every verb resolves an object at point and calls an existing `herdr-cmd` function with an
explicit id. All of them already accept optional ids, so no command logic is duplicated and
confirmation prompts on destructive verbs are inherited rather than reimplemented.

This is what keeps the new file's surface small enough to test: nearly all of it is tree
construction, which is pure.

### Creation is a transient, with direct keys as shortcuts

`c` opens a create transient showing all five creators with the defaults point supplies, plus
settable arguments a bare prompt cannot carry (`--base` for a worktree, `--label`, `--kind`).
`w t n a %` are also bound directly for the ones used constantly.

Contextual-`c`-only was considered — the purest magit rule — but "what will `c` do here?" depends
on reading point, and creating a workspace would require first moving point off every workspace.
Showing the five resolved options removes the ambiguity for one keystroke.

### Single-tab workspaces omit the tab level

Not cosmetic. Unnamed tabs get numeric labels (`"1"`, confirmed against a live server), so an
unflattened tree is mostly noise for the common one-tab workspace.

## Protocol facts

Verified against herdr 0.8.0 (protocol 19) by dumping `herdr api schema --json` and
`herdr api snapshot` from a live server. These are load-bearing; none are assumed.

### The cache already has what the tree needs

`TabInfo` carries `workspace_id`, so workspace → tab → pane renders from the existing snapshot
cache with no new RPC. `PaneInfo` carries `tab_id` and `workspace_id`, so a pane's parents are
unambiguous even when the tab level is flattened away.

### Status rolls up, which is what makes folding safe

`WorkspaceInfo` and `TabInfo` each carry an `agent_status`. A collapsed workspace can therefore
still show that something inside it is blocked. Without this, folding would hide exactly the
information the buffer exists to surface.

### `WorkspaceInfo` has no cwd — and `herdr-project` is broken because of it

Protocol 19's `WorkspaceInfo` is `workspace_id`, `number`, `label`, `focused`, `pane_count`,
`tab_count`, `active_tab_id`, `agent_status`, `tokens`, `worktree`. There is no `identity_cwd`
and no cwd of any kind, in the schema or in live payloads.

`herdr-project` (`herdr.el:92`) matches existing workspaces on `(alist-get 'identity_cwd
workspace)`, which is always nil. The comparison reduces to `(equal "./" "/real/root/")` — never
true — so **`herdr-project` creates a duplicate workspace on every invocation** instead of
focusing the existing one.

A workspace's directory must therefore be derived from its panes, whose `cwd` is populated. This
design adds that helper and fixes `herdr-project` with it.

### `session.snapshot` returns an `agents` array that the cache discards

`SessionSnapshot` has `agents`, an array of `AgentInfo`. `herdr-state-from-snapshot`
(`herdr-state.el:80-88`) reads only `panes`, `tabs`, `workspaces` and the three focus ids.

`AgentInfo` carries `name` — the role name from herdr's own multi-agent workflow (`herdr agent
prompt reviewer …`) — which no `PaneInfo` field provides. It is null until `agent.rename` is
called, so it renders only when set.

`AgentInfo.tokens` and `PaneInfo.tokens` are likewise absent from live payloads unless the agent
reports usage. Neither field earns a default column.

### `WorktreeInfo.open_workspace_id`

Non-nil when a worktree is already open as a workspace. This is what lets worktree rows avoid
duplicating the workspaces already shown above them.

### Two API constraints on creation

- `tab.create` takes `label` and `focus` only — no `workspace_id`. Creating a tab in a specific
  workspace means focusing that workspace first.
- `pane.split` requires a `target_pane_id`. Creating a pane in a tab means splitting one of that
  tab's existing panes.

## Architecture

### Modules

| File | Holds | Depends on |
| --- | --- | --- |
| `herdr-agents.el` | modeline segment, notifications | `herdr-state` |
| `herdr-dispatch.el` *(new)* | buffer, sections, keymap, create transient | `herdr-state`, `herdr-cmd`, `magit-section` |

`herdr-agents.el` is 251 lines holding three unrelated concerns; the dispatcher would push it
past 600. The buffer name `*herdr-agents*` and the command `herdr-agents` do not change — only
the implementation moves, so existing bindings keep working. The command therefore lives in
`herdr-dispatch.el` despite its name; the name is kept for compatibility, not for symmetry.

**Load order.** `herdr-dispatch` needs `herdr-transient` for the `?` binding, and
`herdr-transient` needs `herdr-agents` (the command) for its `l` entry — a cycle. Resolved the
way the package already resolves the `herdr.el` ↔ `herdr-transient` cycle (`herdr.el:112-117`):
`herdr-dispatch` declares and autoloads `herdr-transient` rather than requiring it, and
`herdr-transient` does the same for `herdr-agents`. Neither file requires the other.

### Data layer

One change to `herdr-state`: an `agents` slot on the struct, populated from `session.snapshot`'s
`agents` array.

The tree renders from **panes**, not from that array. Panes are event-driven and always fresh,
and `PaneInfo` already carries `display_agent`, `title`, `label`, `state_labels`. The `agents`
array is consulted only for `name`, which panes lack. It refreshes on the existing snapshot
cadence, so a name can lag a status change by one poll. Acceptable: names change rarely, statuses
constantly.

New helper in `herdr-state`:

```
herdr-state-workspace-directory (state workspace-id) => directory or nil
```

Returns the `cwd` shared by every pane in the workspace. When panes disagree — one has `cd`-ed
elsewhere — it returns the cwd of the workspace's lowest-numbered pane, which is the one the
workspace was created in. Returns nil when no pane reports a cwd. Used by both the dispatcher and
the fixed `herdr-project`.

### Section types

These are what verbs read off point.

| Type | Value | Source |
| --- | --- | --- |
| `herdr-workspace` | `workspace_id` | `WorkspaceInfo` |
| `herdr-tab` | `tab_id` | `TabInfo` |
| `herdr-pane` | `pane_id` | `PaneInfo` |
| `herdr-worktrees` | `workspace_id` | lazy container |
| `herdr-worktree` | `path` | `WorktreeInfo` |

### Rendering

```
herdr   3 workspaces  7 panes  1⏸ 1▶

▾ herdr.el                    ~/src/herdr.el     5 panes
  ▾ agents                                       2 panes
      ▶ claude    working  w1:p1  fixing tests
      ⏸ codex     blocked  w1:p2  needs input
  ▸ checks                                       1 pane
  ▸ worktrees                                    2
▾ emacs.d                     ~/.emacs.d         2 panes
      · claude    idle     w2:p1
      · shell*             w2:p2
▸ monorepo                    ~/src/mono         3 panes  ▶
```

The agent column prefers `display_agent`, falls back to `agent`, and appends `name` when set
(`claude/reviewer`). Adopted shells render as `shell*`, as today. Glyphs and the omit-idle rule
are shared with the modeline segment so the two never disagree.

### Refresh

Hangs off the existing `herdr-state-change-hook`, as today. Point is restored by section ident
rather than by line number — today's `herdr-agents-refresh` (`herdr-agents.el:222-229`) restores
`line-number-at-pos`, which moves you to a different agent whenever a pane appears or closes
above point. Fold state persists across refreshes through magit-section's visibility cache.

### Worktrees are lazy

Rendering unopened worktrees needs `worktree.list` per workspace cwd — one blocking RPC each.
Fetched on first expand, cached per workspace, invalidated by the `worktree.created`,
`worktree.opened` and `worktree.removed` events already present in
`herdr-state-global-subscriptions`. Nothing fires on a timer.

A worktree whose `open_workspace_id` is non-nil is already a workspace above; it renders dimmed
with a pointer to it rather than as a duplicate row.

## Command surface

| Key | Action | Resolves against |
| --- | --- | --- |
| `RET` | visit — focus and show buffer; worktree → open | any section |
| `TAB` | fold | any section |
| `c` | create transient | point supplies defaults |
| `w` `t` `n` `a` `%` | workspace / tab / pane / agent / worktree | walks up from point |
| `p` | prompt agent | nearest `herdr-pane` |
| `r` | read → buffer | nearest `herdr-pane` |
| `f` | focus, server-side only | dispatches on type |
| `R` | rename | dispatches on type |
| `k` | close / remove | dispatches on type |
| `g` | refresh | — |
| `q` | quit window | — |
| `?` | `herdr-transient`, scoped to point | — |

`RET`, `p`, `r`, `g` and `q` keep the meanings they have today.

`RET` is per type: a pane focuses it and shows its buffer (today's behaviour); a tab or workspace
focuses it server-side and then follows to whichever pane herdr lands on, as
`herdr-cmd--follow-focus` already does; a worktree opens it as a workspace.

Verbs that require a pane use the nearest enclosing `herdr-pane` section and `user-error` with a
specific message when there is none. Verbs that apply to several types dispatch on the section
type.

`w` has no parent to walk up to — a workspace is top level. It uses `--directory` when the create
transient set one, and otherwise prompts with `read-directory-name`, defaulting to the directory
of the workspace at point.

### Create transient

`herdr-dispatch-create`, with infix arguments `--label`, `--base`, `--kind` (completing from
`herdr-agent-kinds`), `--directory`. Its description line shows the context resolved from point:

```
point on: ▶ claude  w1:p2  (tab "agents", workspace herdr.el)

  Create
  w  workspace    in ~/src/
  t  tab          in herdr.el
  n  pane         in tab "agents"
  a  agent        in w1:p2
  %  worktree     from herdr.el

  Arguments
  -b --base       main
  -l --label
  -k --kind       claude
```

## Error handling

Verbs wrap `herdr-error` rather than letting it reach a backtrace.

A stale cache is the common cause — acting on a pane that has since closed. So on a `not_found`
code the handler reconciles via `herdr-state-reconcile-panes`, redraws, and *then* reports. The
user sees "that pane is gone" alongside a correct tree, rather than an opaque failure.

Other codes are reported through `message` with their code and message. `no_server` additionally
suggests `M-x herdr-start`.

## Testing

Following the existing split between pure tests and `:live`-tagged conformance tests.

**Pure**, no socket and no magit-section required. Rendering is factored as:

```
herdr-dispatch--tree (state worktrees) => ((TYPE VALUE LINE CHILDREN) ...)
```

Tested against fabricated states for: single-tab flattening, rolled-up status on collapsed
sections, worktree dedup via `open_workspace_id`, workspace-directory derivation including the
disagreeing-panes fallback, and the shell-pane rendering rule.

A thin renderer walks that list emitting `magit-insert-section`. Mechanical; not tested directly.

**Section resolution.** `herdr-dispatch--object-at-point` tested by constructing sections in a
temp buffer and asserting the walk-up behaviour for each verb class.

**Live**, tagged `:live`. One round trip: create workspace → tab → pane → agent from the buffer,
then assert the session is left as it was found — same shape as the existing
`herdr-drift-round-trip-leaves-the-session-unchanged`.

**Drift.** New methods are added to `herdr-cmd-methods` so the existing drift tests cover them.
While there, fix the `agent.read` entry, which omits the `strip_ansi` parameter the command
actually sends (`herdr-cmd.el:484`) and so is not drift-checked today.

## Fixes that fall out

Both are in the blast radius of this work and small:

1. **`herdr-project` duplicate workspaces.** Fixed by `herdr-state-workspace-directory`. See
   Protocol facts.
2. **Point jumping on refresh.** Fixed by ident-based restoration.

## Open questions

None blocking. One to settle during implementation rather than by assumption:

- **`WorkspaceInfo.worktree`.** The schema declares the field but its shape was not observable on
  the live server, because no workspace under test was a worktree. If it carries the worktree
  path, it may be a cheaper source for the worktree rows than `worktree.list`. To be checked
  against a workspace created by `worktree.create` before the lazy-fetch path is written.
