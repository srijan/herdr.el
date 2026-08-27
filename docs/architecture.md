# Architecture

This document tells you how herdr.el is built. Read it before you change the code.

## The shape of the package

Each file has one duty.

| File | Duty |
|---|---|
| `herdr.el` | The entry points, and the protocol check. |
| `herdr-rpc.el` | The transport for the socket API. |
| `herdr-state.el` | The cache of the session, and the two event streams. |
| `herdr-term.el` | The terminal buffers, and directory tracking. |
| `herdr-cmd.el` | The curated commands. |
| `herdr-call.el` | The generic caller for every server method. |
| `herdr-schema.el` | The reader for the JSON Schema of the server. |
| `herdr-select.el` | The `completing-read` pickers. |
| `herdr-tree.el` | The dashboard tree, as data only. |
| `herdr-dispatch.el` | The dashboard renderer, and its verbs. |
| `herdr-modeline.el` | The modeline segment, and the notifications. |

## The data flow

```
herdr server
    |
    |  1. session.snapshot          (one time, at start)
    |  2. events.subscribe          (connection A: the global event types)
    |  3. events.subscribe          (connection B: pane.agent_status_changed)
    v
herdr-state.el   --- the cache ---
    |
    +--> herdr-tree.el   --> herdr-dispatch.el   --> the dashboard buffer
    +--> herdr-modeline.el                       --> the modeline
    +--> herdr-select.el                         --> the pickers
```

Nothing reads the server to draw a frame. Every surface reads the cache. A redraw therefore
costs no socket traffic.

## The two connections

herdr.el holds two long-lived connections.

**Connection A** carries the global event types. The types cover workspaces, panes, worktrees
and the layout. Connection A never changes after the start.

There is no `tab.*` subscription. herdr.el models no tab: a tab's only visual form is the TUI's
tab bar, and nothing here draws one. A closing tab still reaches you, because each of its panes
sends `pane.closed`.

**Connection B** carries one `pane.agent_status_changed` subscription for each agent pane.
herdr.el rebuilds connection B when the set of agent panes changes.

Connection B exists because the global stream reports a status change late. The measured lag was
6.18 seconds in one case and 31.79 seconds in another. See
[Protocol notes](protocol.md).

Connection B watches the agent panes only, not every pane. `pane.agent_status_changed` has
nothing to say about a pane with no agent, and each per-pane subscription makes the server send a
`pane.get` into its main loop every 100 milliseconds. Subscribing every pane would cost a session
with twelve plain shells about 120 server requests each second.

## Reconciliation

The event stream alone cannot keep the cache correct. Two faults break it:

1. A disconnect drops the events that happen during the gap. The server never sends them again.
2. A new subscription replays the full event ring of the server. The replay creates panes and
   workspaces that closed long ago.

herdr.el therefore compares its cache against the server. Two functions do this:

| Function | Method | Corrects |
|---|---|---|
| `herdr-state-reconcile-panes` | `pane.list` | The pane set. |
| `herdr-state-reconcile-workspaces` | `workspace.list` | The workspace set. |

Both methods need no parameters. Each returns the full live set. Each is therefore a symmetric
target: herdr.el adds what is missing and removes what is extra.

The reconcile runs at `herdr-state-settle-delay` after a connect. The reconcile then runs at
every directory poll, which is every `herdr-term-directory-interval` seconds.

Reconcile the workspace set as well as the pane set. Reconciling panes alone lets ghost
workspaces collect for the life of a session.

## The pure half and the impure half

The dashboard has two layers. The split is the reason that the test suite can cover it.

`herdr-tree.el` is pure. It requires `herdr-state.el` only. `herdr-tree-build` takes a state and
returns a nested list of nodes. Each node has this shape:

```elisp
(TYPE VALUE LINE CHILDREN)
```

- `TYPE` is one of `herdr-workspace`, `herdr-panes` (a workspace's `main` group),
  `herdr-pane`, `herdr-worktree`, `herdr-known-project` or `herdr-known-projects` (the
  `Inactive` container). The renderer's `pcase` has no fallback clause, so a type with no branch
  is dropped silently along with everything under it.
- `VALUE` is the identifier that a command acts on. It must never be `nil` for a real row.
- `LINE` is the propertized string to insert.
- `CHILDREN` is a list of more nodes, or `nil`.

`herdr-dispatch.el` is impure. It requires `herdr-tree.el` and `magit-section`. It walks the
node list and calls `magit-insert-section` for each node. Its verbs read the node at point and
call a `herdr-cmd` function with an explicit identifier.

Put new logic in the pure half. A test for the pure half needs no socket and no display.

## Column widths

Two columns size themselves to their content: the agent column and the worktree column.

`herdr-tree-build` measures each column one time for the whole state. It then passes the width
down as a parameter to every function that draws a row. A row therefore cannot disagree with its
neighbours.

Do not measure a column inside a row function. That gives each row its own width.

## Display and identity

A row shows a directory with `~/` in place of the home directory. The function
`abbreviate-file-name` does this.

Apply the abbreviation to the `LINE` string only. Never apply it to `VALUE`. A command sends
`VALUE` to the server, and the server needs the real path.

## Rules for a change

- Emacs 28.1 is the floor. Do not use a function that arrived in Emacs 29, such as `seq-keep`,
  `outline-search-function` or `setopt`.
- `make compile` treats a warning as an error. Declare each external function with
  `declare-function`. Declare each external variable with `defvar`.
- Every file starts with `-*- lexical-binding: t; -*-`. Every file ends with `(provide 'FEATURE)`
  and a `;;; FILE ends here` line.
- A synchronous call on a timer must bind `herdr-rpc-timeout` to
  `herdr-rpc-background-timeout`. A slow server must not freeze the editor.
- Guard every use of `project.el` with `fboundp`.
- Stub `herdr-dispatch--known-project-roots` in a test. Without the stub, the test reads the real
  project list of the machine.
