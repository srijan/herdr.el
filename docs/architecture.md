# Architecture

This document tells you how herdr.el is built. Read it before you change the code.

## The shape of the package

herdr.el has eleven source files. Each file has one duty.

| File | Lines | Duty |
|---|---|---|
| `herdr.el` | 151 | The entry points, and the protocol check. |
| `herdr-rpc.el` | 260 | The transport for the socket API. |
| `herdr-state.el` | 1192 | The cache of the session, and the two event streams. |
| `herdr-term.el` | 598 | The two terminal backends, and directory tracking. |
| `herdr-cmd.el` | 372 | The 11 curated commands. |
| `herdr-call.el` | 96 | The generic caller for all 91 methods. |
| `herdr-schema.el` | 245 | The reader for the JSON Schema of the server. |
| `herdr-select.el` | 281 | The `completing-read` pickers. |
| `herdr-tree.el` | 897 | The dashboard tree, as data only. |
| `herdr-dispatch.el` | 1370 | The dashboard renderer, and its verbs. |
| `herdr-modeline.el` | 191 | The modeline segment, and the notifications. |

## The data flow

```
herdr server
    |
    |  1. session.snapshot          (one time, at start)
    |  2. events.subscribe          (connection A: 23 global event types)
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

**Connection A** carries the 23 global event types. The types cover workspaces, tabs, panes,
worktrees and the layout. Connection A never changes after the start.

**Connection B** carries one `pane.agent_status_changed` subscription for each attachable pane.
herdr.el rebuilds connection B when the set of panes changes.

Connection B exists because the global stream reports a status change late. The measured lag was
6.18 seconds in one case and 31.79 seconds in another. See
[Protocol notes](protocol.md).

Connection B watches the attachable panes only. Each per-pane subscription makes the server
send a `pane.get` into its main loop every 100 milliseconds. A session with twelve shells
therefore cost about 120 server requests each second before this limit existed.

## Reconciliation

The event stream alone cannot keep the cache correct. Two faults break it:

1. A disconnect drops the events that happen during the gap. The server never sends them again.
2. A new subscription replays the full event ring of the server. The replay creates panes,
   tabs and workspaces that closed long ago.

herdr.el therefore compares its cache against the server. Three functions do this:

| Function | Method | Corrects |
|---|---|---|
| `herdr-state-reconcile-panes` | `pane.list` | The pane set. |
| `herdr-state-reconcile-workspaces` | `workspace.list` | The workspace set. |
| `herdr-state-reconcile-tabs` | `tab.list` | The tab set. |

The three methods need no parameters. Each returns the full live set. Each is therefore a
symmetric target: herdr.el adds what is missing and removes what is extra.

The reconcile runs at `herdr-state-settle-delay` after a connect. The reconcile then runs at
every directory poll, which is every `herdr-term-directory-interval` seconds.

Before this fork, only the pane set was reconciled. Ghost workspaces therefore collected for
the life of a session.

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
