# herdr.el

Drive [herdr](https://herdr.dev), a terminal workspace manager for AI coding agents, from Emacs,
with herdr's terminals hosted **inside** Emacs via [ghostel](https://github.com/dakra/ghostel).

No second terminal application sits in the loop. Commands go over herdr's unix socket. A live
event stream keeps a cache of the session, and that cache feeds a foldable dashboard, a modeline
segment, a [transient](https://github.com/magit/transient) menu, and completion pickers.

## This is a fork

Upstream is [eddof13/herdr.el](https://github.com/eddof13/herdr.el). This copy has moved a long
way from it: 82 commits, about 12,900 lines added against 970 removed, and three source files
that do not exist upstream.

| | Upstream | Here |
|---|---|---|
| herdr protocol | 19 | 20 (herdr 0.8.2) |
| Session view | `herdr-agents.el`, a flat list | `herdr-dispatch.el` and `herdr-tree.el`, a foldable magit-section tree |
| Modeline | inline in the agents buffer | `herdr-modeline.el`, its own file |
| Extra dependency | none | `magit-section` 3.3 |
| Tests | one agents test file | 473 offline tests across 16 files, plus a live suite |

The large additions are the dashboard and the pure tree layer behind it, a rewritten
`herdr-state.el` that reconciles workspaces and tabs rather than only panes, and the test suite.
Everything else started upstream and has been corrected in place.

Rebasing onto upstream is no longer realistic. Treat upstream as a source of ideas and protocol
news, not as a branch to merge.

## The dashboard

`M-x herdr` (or `C-c H`) opens `*herdr-agents*`: the whole session as a foldable tree of
repositories, their checkouts and their panes, and the place every command is reachable from.

```
M-x herdr   [w1:p1  claude:idle]   C-u on any command retargets

 Go to            Menus             Session
  p pane           P pane…           g resync
  a agent          A agent…          l agents
  w workspace      W workspace…      s status
  t tab *          T tab… *          : any method…
                   % worktree…

  * session backend only
```

| Key | Action |
| --- | --- |
| `RET` | go to the thing at point — a worktree that is not open yet is opened as a workspace |
| `TAB` | fold |
| `c` | create menu, with its parent taken from point |
| `w` / `n` / `a` / `%` | create workspace / terminal / agent / worktree directly |
| `p` | prompt the agent at point |
| `r` | read the pane at point into a buffer |
| `f` | focus the thing at point server-side, without moving Emacs |
| `R` | rename the thing at point |
| `k` | close or remove the thing at point |
| `g` | refresh from the cache |
| `q` | quit the window |
| `?` | open `herdr-transient` |

Every verb acts on the most specific thing under point. `a` on a row that names a directory
rather than a workspace — a worktree, a `main` row, an inactive project — starts the agent in
that directory, opening it as a workspace first if nothing is open there. A heading is not a
target: `TAB` folds it, and the other verbs say so rather than acting on what encloses it.

A collapsed section still shows the worst status inside it, so folding never hides a blocked
agent.

### The shape of the tree

The top level is one row per repository. A workspace holds its own panes in a `main` group and
hangs its worktrees off itself beside that group, so the two kinds of row are never mistaken for
each other:

```
example-api (1)              ~/src/example-api/
  main (2)
    · shell     idle      wA:p1   npm run watch
    ✓ claude    done      wA:p5   Add the pagination endpoint

herdr.el (2)                 ~/src/herdr.el/
  main (1)
    · claude    idle      wS:pR   Fix the reconcile order
  feat-dispatch (1)          ~/src/herdr.el-worktrees/feat-dispatch/ ▶
    main (1)
      ▶ claude  working   w19:p1  Nest worktrees under their repository
```

A worktree you have open as a workspace of its own is drawn where it belongs — inside the
repository it came from, panes and all — rather than as a second top-level row beside it. A
worktree that is not open is a dimmed one-line row in the same place.

The count on a repository row is its checkouts: its own, plus one per worktree. The pane count
sits on the `main` group, which is the thing that holds the panes.

### Inactive projects

Below the live workspaces sits one foldable `Inactive (N)` heading listing every `project.el`
known project that has no herdr workspace open. Each row is dimmed, folds, and carries the
repository's checkouts underneath — a `main` row for its own, then one per worktree:

```
Inactive (24)
  example-api (16)           ~/src/example-api/
    main                     ~/src/example-api
    release-1.4              ~/src/example-api-worktrees/release-1.4
    …
```

`RET` on the project row creates its workspace. `a` on any row under it starts an agent in that
directory, opening it as a workspace first if nothing is open there yet — so a worktree you have
not touched in a week is two keystrokes from having an agent in it.

Two kinds of row are left out. A worktree you have also opened as a project in Emacs gets no row
of its own: project.el remembers it as a project in its own right, and it is already listed under
the repository it belongs to. A project whose directory has been deleted gets no row either —
project.el remembers a project until it is told to forget one, and nothing tells it when a
directory goes away. Use `project-forget-zombie-projects` to drop those from project.el itself.

This comes from `project-known-project-roots`, not from herdr. A herdr workspace closes when its
last pane closes, so the server has no concept of a project you are not currently working in.
Hooking `project.el` is what makes the dashboard a place to start work from rather than only a
place to watch it.

Directories render with `~/` rather than the full home path. The abbreviation is display only;
the row still carries the real path for the commands that act on it.

### herdr-menu

`M-x herdr-menu` does the same startup as `herdr`, bringing up the server, terminals and event
stream, but ends on `herdr-transient`'s compact menu instead of the dashboard. Reach for `herdr`
when you want to survey the session. Reach for `herdr-menu` from inside an agent's terminal
buffer, where a full-window dashboard would pull you out of what you were doing.

Calling `herdr-transient` directly skips that startup, so from a cold Emacs it opens with no state
cache behind it. `herdr-menu` is the entry point that guarantees the startup has run.

## Targeting and keys

Commands act on the pane of the buffer you are in, if that is a herdr terminal, and otherwise on
the pane herdr has focused. `C-u` on any command prompts instead. The header names the pane that
will be acted on, so it is never a guess.

A lowercase noun jumps to that kind of thing; the same letter uppercased opens its menu. Inside a
menu the verbs stay constant: `c` create, `f` focus, `r` read, `R` rename, `k` close or remove,
`l` list. `?` and `C-h` belong to transient's own help, so status is `s`. Worktrees are on `%` and
the raw-method escape hatch on `:`, matching where magit puts those two ideas. Tests assert this,
not just review.

Tabs are hidden entirely under `agent-windows`. A tab is a grouping inside a workspace whose only
visual form is the TUI's tab bar, so where nothing renders a tab, nothing tab-shaped is offered.
`herdr-call` still reaches the methods if you want them. Workspaces are not hidden: they are keyed
by cwd, persist across restarts, group the dashboard, and back `herdr-project`. Going to one shows
that workspace's active pane, one buffer, in the current window.

## Requirements

- Emacs 28.1+
- [herdr](https://herdr.dev) 0.8.2 (protocol 20)
- `ghostel`, `transient`, `magit-section`

Optional, used when present and never required: `marginalia`, `embark`, `consult`, `alert`.

`magit-section` is the one dependency upstream does not have. The dashboard is built on it.

## Install

```elisp
(use-package herdr
  :ensure nil                          ; local checkout, not on MELPA
  :load-path "~/src/herdr.el"
  :bind (("C-x M" . herdr)             ; pairs with C-x m if you bind ghostel there
         ("C-c H" . herdr-agents)
         :map project-prefix-map
         ("h" . herdr-project))
  :custom (herdr-terminal-backend 'session)
  ;; (herdr-display-action '(display-buffer-full-frame))  ; TUI takes the frame
  :config (herdr-modeline-mode 1))
```

`:ensure nil` matters if you set `use-package-always-ensure`. Without it Emacs tries MELPA and
fails at startup.

`M-x herdr` starts the server if it is not running, brings up the terminals, connects the event
stream, and opens the dashboard.

## Terminal backends

Both work. Set `herdr-terminal-backend`.

### session (default)

One ghostel buffer, `*herdr*`, running the herdr TUI. herdr owns the layout. Plain shell panes
work normally. About sixty lines of glue and nothing to go wrong.

`herdr-display-action` controls placement, and every path that shows a herdr buffer goes through
it, so the same buffer cannot appear one way from `M-x herdr` and another from Go to.

It defaults to reusing the current window and leaving your splits alone. herdr's TUI wants width
for its 26-column sidebar, so under `session` you may prefer `'(display-buffer-full-frame)`,
which does delete your other windows, or a side window.

The TUI is mouse-first: click panes, drag borders, right-click menus. ghostel forwards those
clicks, but only under GUI Emacs. A TTY frame (`emacs -nw`) has no mouse events to forward, so
there drive the TUI by keyboard (its `ctrl+b` prefix) or use `agent-windows`, which is
keyboard-first and needs no TUI at all.

### agent-windows

One ghostel buffer per agent, each running `herdr terminal attach`. Emacs owns the layout,
herdr's own layout tree goes unused, and there is no geometry to keep in sync.

A buffer is named for whatever the pane is best known by, in order: a name set through
`agent.rename`, then the pane's own label — which is how a plugin pane arrives already named —
and otherwise `KIND@WORKSPACE`, so an unnamed Claude in the `web` workspace reads as
`*herdr: claude@web*` and a plain shell as `*herdr: shell@web*`.

Attaching is lazy and nothing splits. `M-x herdr` takes no windows and opens no buffers. A pane is
attached the first time you go to it, in the current window. Splitting stays yours: `C-x 2`,
`C-x 3`, `display-buffer-alist`.

Laziness is not only politeness. The attach client needs a window when it starts, so attaching
every agent up front would mean taking a window per agent before you had asked for anything. Once
started it survives being buried, so you can switch away freely.

The reason to want it: agents survive Emacs exiting, because the herdr server is a daemon. Quit
Emacs, restart, `M-x herdr`, and every agent is still there and reattached. A plain ghostel shell
cannot do that, being a child of Emacs that dies with it.

Since herdr 0.8.2, `herdr terminal attach` takes any pane — agent or plain shell alike — so a
shell pane gets a buffer the same way an agent pane does, on first visit; there is no longer a
class of pane it refuses. Before you attach to one, it stays reachable through `pane.read`,
`pane.send_text`, `pane.wait_for_output` and the menu, and `ghostel-project` covers ordinary
interactive shells outside herdr entirely.

## What a pane is

"Pane" here always means a herdr pane: a PTY and shell process owned by the herdr daemon, with an
id like `w2:p1`. It is not a ghostel buffer and not an Emacs window. The daemon forks the shell;
Emacs only ever asks it to. That is why a pane outlives Emacs. A ghostel buffer is a view onto a
pane, created the moment you attach to it — which, since herdr 0.8.2, needs nothing from the pane
first.

herdr panes you create from Emacs (split, new tab, new workspace) are shown immediately: creation
follows the new pane and attaches to it, the same as going to any other pane.

herdr names the agent in a pane itself. Open a terminal pane, start Claude in it, and the row
reads `claude` a few seconds later. Nothing needs reporting, and nothing needs adopting.

### Adoption is retired

Adoption was how a plain shell pane used to be made attachable and given a name. Since herdr
0.8.2 every pane is attachable already, so the concept is gone and its commands are obsolete:
`herdr-adopt-shell` and `herdr-release-shell` still work, `herdr-adopt-created-shells` is a no-op
kept so an old config does not error, and `herdr-promote-shell` and the poll behind it are
deleted — they existed to force a relabel herdr does on its own, at a cost of 936 `agent.explain`
calls in one session, three quarters of all the traffic herdr.el sent.

`herdr-adopt-shell` still has one use: reporting an agent named `shell` on a long-running pane,
such as a build, makes herdr itself watch it — a row in herdr's own sidebar, a place in the
modeline count, and eligibility for notifications — and the report is server-side, so it survives
an Emacs restart. It also takes the pane out of `herdr-agent-start`'s reach, since availability
there means "has no agent at all".

Reporting an agent on a pane where one is *already* running leaves a label that never corrects
itself. See [Troubleshooting](docs/troubleshooting.md#a-pane-is-labelled-shell-but-is-running-an-agent).

## What we measured

The design rests on behaviour probed from a live herdr rather than from documentation, and since
0.8.2 also from herdr's own source at
[herdrdev/herdr](https://github.com/herdrdev/herdr). Recorded here because most of it is not
written down anywhere else.

Some of it was probed against an older herdr and later turned out to be wrong. Those rows are
corrected in place rather than removed, with the superseded claim still visible. Deleting one only
means the next reader re-derives it from the same weak evidence, which is exactly how four of them
survived as long as they did.

| Behaviour | Finding |
|---|---|
| RPC connections | One request per connection. The server writes one response, then closes. No multiplexing, no id correlation. |
| Request ids must be strings | An integer `id` gets `invalid_request: invalid type: integer`. Easy to miss, because the error arrives on the same connection a subscription ack would. |
| `events.subscribe` | The one long-lived call. Acks `subscription_started`, then streams. It also replays the server's whole event ring. See below. |
| **`pane_updated` is output-coupled** | It does not coalesce (~~3 per-pane events produced only 1 `pane_updated`~~). It fires about 7.5/s carrying a full `PaneInfo`, `agent_status` included, but it is tied to title and output, so it stops firing exactly when an agent goes idle, which is the transition worth knowing about. Lag from the per-pane event reporting idle to the global stream reflecting it: 6.18s and 31.79s. This fork no longer subscribes to it at all. A second connection carrying per-pane `pane.agent_status_changed` covers the statuses, and `herdr-state-reconcile-panes` covers the rest. |
| Throughput | Not a concern for either backend. A 12.2 MB pane dump reached Emacs as 17 KB (`session`) or 24 KB (`agent-windows`), completing in 0.2s. herdr's VT only emits visible-frame diffs. |
| `agent attach` | Streams one pane full-screen, coexists with a session client, exclusive per pane, and refuses a pane with no agent (`agent_not_found`). ~~That refusal is what keeps adoption necessary.~~ Since 0.8.2 `herdr terminal attach` takes any pane instead, agent or not; this fork attaches through that, so adoption is no longer needed to make a pane attach. |
| Attach needs a window | The client needs a window when it starts and dies if that window is deleted. Being merely hidden is fine, so a buried terminal keeps running with its scrollback. A zero-sized PTY renders nothing. |
| **Ghost panes come from replay** | ~~The retained `pane.created` is for whatever pane was made last, so subscribing resurrects it.~~ Replay is not one retained event, it is the whole ring, and the ordering defence below is weaker than it looked. The pane set is reconciled against `pane.list` after connecting and on a poll thereafter. Since this fork, workspaces and tabs are reconciled the same way against `workspace.list` and `tab.list`, which is what stopped ghost workspaces accumulating forever. |
| **Detection outranks adoption** | Reporting an agent does not suppress detection; herdr's own docs now say the two operate independently. Measured: a pane reported as `shell` was relabelled `claude` about 3s after Claude started in it, over the reported label, unasked. ~~`pane.report_agent` takes lifecycle authority, so an adopted pane keeps its label.~~ That was true of an older herdr and is the premise the deleted `herdr-promote-shell` poll rested on. |
| Focus is shared | One focused pane per session, not per client. Navigating in Emacs moves the focus in any attached TUI too. |
| OSC | Not forwarded. herdr's VT consumes OSC 7 and OSC 133. Beware the false positive: sending the escapes inline makes the shell echo the command text, which contains the same characters. |
| cwd tracking | herdr tracks it itself, and `pane.cwd` follows a `cd` within about a second. But it publishes no event for it. A `cd` emits only `layout_updated` noise, so directory tracking has to poll, debounced off the event stream with a slow backstop timer. |
| Shell panes | ~~`pane.report_agent` makes a plain shell pane attachable, which is how adoption works.~~ True before 0.8.2; since then attachability no longer depends on it, and `pane.report_agent` only affects sidebar labelling and `agent.start` availability. |
| `pane.read` shape | Text is nested under a `read` object, not a top-level field. |
| Rename and move events are flat | They carry no nested record. `workspace_renamed` is `{workspace_id, label}`, `tab_renamed` adds `workspace_id`, the two move events send `{id, insert_index, <array of fresh records>}`, and `pane_agent_detected` is `{pane_id, workspace_id, agent?, final_status?, released?}`. Reading a `workspace`, `tab` or `pane` object out of any of them, as this package did, silently drops the event. |
| Terminal titles animate | Claude runs a spinner glyph and a second counter inside the title, so `terminal_title_stripped` changes several times a second: 662 of 662 `pane_updated` events differed in it, against 11 that differed in `agent_status`. It is a volatile field, not a stable label, and must not be treated as one when diffing panes. |
| JSON arrays | Emacs's `json-serialize` cannot distinguish a list of alists from one alist. Array parameters must be vectors or `events.subscribe` is rejected. |

### Subscribe replays the whole ring

Two earlier readings of this were wrong. The third came from reading herdr's source instead of
guessing from measurement.

`events.subscribe` does not hand you the last event of each type. It hands you the server's whole
512-event ring, drip-fed one event per subscribed type per 100ms tick. In
`src/api/subscriptions.rs` every plain event subscription starts at `last_sequence: 0`, while the
per-pane status subscription fifty lines down correctly uses `event_hub.current_sequence()`. It is
an upstream bug, and the fix is one line per match arm.

Measured on a live 0.8.2 server with the 23 subscriptions this package uses: 253 events in 5
seconds, still arriving when the probe stopped. Events carry no sequence number and no timestamp,
so a client cannot tell a replay from a live event and cannot filter it out.

The visible symptom is a second or two of dead panes in the dashboard after `M-x herdr`. The next
reconcile clears them.

Full analysis, with the source excerpts and the two wrong readings kept visible:
[`docs/protocol.md`](docs/protocol.md#the-server-replays-its-full-event-ring).

## Commands

33 curated commands cover the methods worth a keybinding. `M-x herdr-call` reaches all 91,
prompting for each parameter from the server's own schema. Nothing is out of reach and there is no
generated 91-entry menu.

Worth knowing about:

- `herdr-agent-start` starts an agent in an idle pane. The picker also offers a trailing
  `＋ new shell pane` entry that splits the current pane and starts there, so a session with no
  free pane is never a dead end.
- `herdr-worktree-create` takes a branch name to a git worktree with its own herdr workspace,
  using herdr's native worktree support.
- `herdr-pane-read` and `herdr-agent-read` put terminal output into a real Emacs buffer.
  `recent_unwrapped` undoes terminal line-wrapping, which is what makes the result greppable.
- `herdr-agent-wait` and `herdr-pane-wait-for-output` run asynchronously, so Emacs stays
  responsive. "Tell me when the dev server prints `Listening on`" is one command.
- `herdr-project` focuses or creates the herdr workspace for the current `project.el` project.
- `herdr-adopt-shell` and `herdr-release-shell` are covered above.

Terminal buffers track their pane's working directory (`herdr-term-track-directory`), so
`find-file` and `compile` from a herdr buffer start in the right place.

## Agent awareness

`herdr-modeline-mode` shows something like `herdr:2⏸1✓`. Idle agents are left out deliberately: a
count that is always on screen stops being read. The old name `herdr-agents-mode-line-mode` still
works as an obsolete alias.

Desktop notifications are off by default. `(setq herdr-notify-statuses '("blocked" "done"))` opts
in, and `alert` is used when available.

## Integrations, and agents driving herdr themselves

herdr can be told about agent lifecycle directly instead of inferring it. Without an integration,
status comes from herdr's detection heuristics, which are regexes over the terminal title, so
agents tend to sit at `idle`. With one, they report `idle`, `working` or `blocked` to the socket:

```bash
herdr integration install claude     # writes ~/.claude/hooks/herdr-agent-state.sh
herdr integration status
```

That is what makes the modeline segment, the dashboard and `herdr-agent-wait` genuinely useful
rather than approximate. Note it writes to the agent's own config.

Agents can also drive herdr themselves, via herdr's
[agent skill](https://herdr.dev/docs/agent-skill/), splitting panes, running commands, waiting on
output and starting helper agents. Everything they do shows up in Emacs, because it goes through
the same server and the same event stream. An externally issued `herdr pane split` appears in the
pickers, an external status report moves the modeline, an external close removes the pane.

One consequence of attaching being lazy: a pane an agent creates gets no buffer under
`agent-windows` on its own, since only a creation Emacs itself initiated follows the new pane and
attaches to it. An agent splitting a pane to run a build should not seize an Emacs window. It is
visible in the picker, and going to it attaches directly — every pane already accepts
`herdr terminal attach`, so there is nothing to adopt first. If the agent starts a helper agent
there, it appears in the agents list and modeline immediately, same as any other detected agent.

## Completion

Pickers are plain `completing-read` over the cache, so they inherit whatever completion stack you
already use. With `marginalia` the annotation shows agent, status, title and directory, and with
`orderless` that makes `web claude blocked` a working query. `embark-act` on a pane candidate
offers focus, read, prompt, close and zoom.

## Development

```bash
make test        # 473 tests, hermetic; no herdr required, uses a fake server
make test-live   # needs a running herdr; includes the schema drift test
make compile     # byte-compile, warnings are errors
```

Both targets run `emacs -Q -L .`, which reads no init file, so `test/herdr-deps.el` searches the
package directories of `elpaca`, `package.el` and `straight.el` for `magit-section` and
`transient`. A missing dependency is a hard error naming `EXTRA_LOAD_PATH`. Nothing skips.

Both suites run in batch, and that is a real blind spot. A batch Emacs has no frame, so it cannot
catch a modeline rendering `*invalid*`, a command splitting a window, or a transient entry nobody
added. Several faults passed a green suite and were only found by driving a real Emacs under a
PTY. When your change touches windows, buffers or the modeline, run it in a real frame as well.

`src/api/subscriptions.rs`, `src/api/event_hub.rs` and `src/api/server.rs` in
[herdrdev/herdr](https://github.com/herdrdev/herdr) answer most protocol questions faster than
probing does, and without ambiguity.

Full detail, including `EXTRA_LOAD_PATH` and the rules a change must follow:
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Documentation

| Document | Content |
|---|---|
| [Getting started](docs/getting-started.md) | Install herdr.el and do the first tasks. |
| [Commands](docs/commands.md) | Every command, and the method it calls. |
| [Configuration](docs/configuration.md) | Every user option, with its default. |
| [Troubleshooting](docs/troubleshooting.md) | Symptoms, causes and corrections. |
| [Architecture](docs/architecture.md) | The files, the data flow and the design rules. |
| [Protocol notes](docs/protocol.md) | Measured behaviour of the herdr server. |
| [Contributing](CONTRIBUTING.md) | How to build, test and send a change. |
| [Changelog](CHANGELOG.md) | What changed. |

The original design documents and implementation plans live in
[`docs/history/`](docs/history/). They record the design at their date and are not current.

## License

GPL-3.0-or-later.
