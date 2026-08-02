# herdr.el

Drive [herdr](https://herdr.dev) — a terminal workspace manager for AI coding agents — from
Emacs, with herdr's terminals hosted **inside** Emacs via
[ghostel](https://github.com/dakra/ghostel).

There is no second terminal application in the loop. Commands go over herdr's unix socket, a live
event stream keeps a cache of the session, and that cache feeds a
[transient](https://github.com/magit/transient) menu, a modeline segment, an agent status buffer,
and completion pickers.

```
M-x herdr        [w1:p1  claude:idle]   C-u on any command retargets
 Navigate            Act on              Session
  j pane              p pane…             g resync
  J agent             a agent…            G agents
  w workspace         T tab…              ? status
  t tab               W workspace…        x any method…
                      k worktree…
```

## Requirements

- Emacs 28.1+
- [herdr](https://herdr.dev) 0.7.5 (protocol 17)
- `ghostel`, `transient`

Optional, used when present, never required: `marginalia`, `embark`, `consult`, `alert`.

## Install

```elisp
(use-package herdr
  :load-path "~/src/herdr.el"
  :bind ("C-c h" . herdr)
  :custom (herdr-terminal-backend 'session)
  :config (herdr-agents-mode-line-mode 1))
```

`M-x herdr` starts the server if it is not running, brings up the terminals, connects the event
stream, and opens the menu.

## Terminal backends

Both are supported. Set `herdr-terminal-backend`.

### `session` (default)

One ghostel buffer, `*herdr*`, running the herdr TUI. herdr owns the layout. Plain shell panes
work normally. About sixty lines of glue and nothing to go wrong.

`herdr-display-action` controls placement and defaults to `display-buffer-full-frame`, because
herdr draws a 26-column sidebar beside its panes and a narrow window leaves it very little.

### `agent-windows`

One ghostel buffer per agent — `*herdr: claude w1:p1*` — each running `herdr agent attach`.
Emacs owns the layout; herdr's own layout tree goes unused, so there is no geometry to keep in
sync. Buffers are created and reaped from the event stream.

The reason to want it: **agents survive Emacs exiting**, because the herdr server is a daemon.
Quit Emacs, restart, `M-x herdr`, and every agent is still there and reattached. A plain ghostel
shell cannot do that — it is a child of Emacs and dies with it.

The cost: `herdr agent attach` refuses a pane with no detected agent, so plain shell panes have no
buffer under this backend. They stay reachable through `pane.read`, `pane.send_text`,
`pane.wait_for_output` and the menu. Use `ghostel-project` for interactive shells.

## What was measured

The design rests on behaviour probed from a live herdr 0.7.5 rather than from documentation.
Recorded here because most of it is not written down anywhere else.

| Behaviour | Finding |
|---|---|
| RPC connections | **One request per connection.** The server writes one response, then closes. No multiplexing, no id correlation. |
| `events.subscribe` | The one long-lived call. Acks `subscription_started`, then streams. |
| **Subscribe replays history** | Subscribing to an *idle* server returned **54 past events**; a real startup produced about 150. The cache is primed silently and listeners are notified once. |
| **`pane_updated` coalesces** | Driving a pane through working → blocked → idle produced **3** per-pane events but only **1** `pane_updated`. Global events alone silently lose status transitions, so per-pane `pane.agent_status_changed` subscriptions are required. |
| Throughput | Not a concern for either backend. A **12.2 MB** pane dump reached Emacs as **17 KB** (`session`) / **24 KB** (`agent-windows`), completing in 0.2s. herdr's VT only emits visible-frame diffs. |
| `agent attach` | Streams one pane full-screen; coexists with a session client; **exclusive per pane**; refuses panes without a detected agent. |
| PTY size | A zero-sized PTY renders nothing. Buffers are displayed before the process starts so ghostel can size the terminal. |
| OSC | OSC 7 and OSC 133 **are** forwarded through herdr's VT to an attach client. |
| `pane.read` shape | Text is nested under a `read` object, not a top-level field. |
| JSON arrays | Emacs's `json-serialize` cannot distinguish a list of alists from one alist. Array parameters must be vectors or `events.subscribe` is rejected. |

## Commands

Thirty-one curated commands cover the methods worth a keybinding; `M-x herdr-call` reaches all
**89**, prompting for each parameter from the server's own schema. Nothing is out of reach and
there is no generated 89-entry menu.

Worth knowing about:

- **`herdr-worktree-create`** — herdr has native git-worktree support, so one command takes a
  branch name to a worktree with its own herdr workspace.
- **`herdr-pane-read`** / **`herdr-agent-read`** — terminal output into a real Emacs buffer.
  `recent_unwrapped` undoes terminal line-wrapping, which is what makes the result greppable.
- **`herdr-agent-wait`** and **`herdr-pane-wait-for-output`** — asynchronous, so Emacs stays
  responsive. "Tell me when the dev server prints `Listening on`" is one command.
- **`herdr-project`** — focus or create the herdr workspace for the current `project.el` project.

## Agent awareness

- **Modeline** — `herdr-agents-mode-line-mode` shows e.g. `herdr:2⏸1✓`. Idle agents are omitted
  deliberately: a count that is always on screen stops being read.
- **`M-x herdr-agents`** — a tree of workspaces and panes with status. `RET` focuses, `p` prompts,
  `r` reads. Event-driven, no timer.
- **Desktop notifications** — off by default. `(setq herdr-notify-statuses '("blocked" "done"))`
  to opt in. Uses `alert` when available.

## Completion

Pickers are plain `completing-read` over the cache, so they inherit whatever completion stack you
already use. With `marginalia` the annotation shows agent, status, title and directory; with
`orderless` that makes `web claude blocked` a working query. `embark-act` on a pane candidate
offers focus, read, prompt, close and zoom.

## Development

```bash
make test        # hermetic; no herdr required, uses a fake server
make test-live   # needs a running herdr; includes the schema drift test
make compile     # byte-compile, warnings are errors
```

`make test-live` includes a drift test that checks every curated command's method and parameters
against the running server's schema. herdr is young and its API will move; when it does, that test
names the broken command instead of leaving it to fail in front of you. The round-trip test
asserts the session is left exactly as it was found.

## Design notes

Full design and rationale: [`docs/superpowers/specs/2026-08-01-herdr-el-design.md`](docs/superpowers/specs/2026-08-01-herdr-el-design.md).

## License

GPL-3.0-or-later.
