# herdr.el

Drive [herdr](https://herdr.dev), a terminal workspace manager for AI coding agents, from Emacs,
with herdr's terminals hosted **inside** Emacs via [ghostel](https://github.com/dakra/ghostel).

No second terminal application sits in the loop. Commands go over herdr's unix socket. A live
event stream keeps a cache of the session, and that cache feeds a foldable dashboard, a modeline
segment and completion pickers.

## This is a fork

Upstream is [eddof13/herdr.el](https://github.com/eddof13/herdr.el). This copy has diverged far
enough that a rebase onto it is no longer realistic. Treat upstream as a source of ideas and
protocol news, not as a branch to merge.

## The dashboard

`M-x herdr`, or `C-c H s`, opens `*herdr-agents*`. It draws the whole session as a foldable tree
of repositories, their checkouts and their panes. Every command is reachable from it.

```
herdr   3 workspaces  5 panes  2▶1✓

example-api (1)              ~/src/example-api/
  · shell       idle      w4:p1   npm run watch
  ✓ claude      done      w4:p5   Add the pagination endpoint

herdr.el (2)                 ~/src/herdr.el/
  main (1)
    ▶ claude    working   w7:p1   Fix the reconcile order
  feat-dispatch (1)          ~/src/herdr.el-worktrees/feat-dispatch/ ▶
    ▶ claude    working   w9:p1   Nest worktrees under their repository

Inactive (24)
```

The dashboard opens in the selected window and leaves your other windows alone. `q` restores the
buffer that window held before.

| Key | Action |
| --- | --- |
| `RET` | go to the thing at point. A worktree that is not open yet opens as a workspace |
| `TAB` | fold |
| `w` / `n` / `%` | create workspace / terminal / worktree |
| `p` | prompt the agent at point |
| `r` | read the pane at point into a buffer |
| `R` | rename the thing at point |
| `k` | close or remove the thing at point |
| `g` | refresh from the cache |
| `q` | quit the window |

Every verb acts on the most specific thing under point.

Some rows name a directory rather than a workspace: a worktree, a `main` row, an inactive
project. `n` on one of those opens the terminal in that directory. If nothing is open there, it
opens the directory as a workspace first.

A heading is not a target. `TAB` folds it. Every other verb refuses it rather than acting on what
it encloses.

`n` is the only way to make a place to run something. herdr's own TUI works the same way. A new
tab opens a shell, the agent is whatever you run in that shell, and herdr names it by detection a
few seconds later.

A folded section still shows the worst status inside it. Folding never hides a blocked agent.

### The shape of the tree

The top level is one row per repository.

Look at `herdr.el` in the tree above. It has a worktree, so its own panes sit in a `main` group,
and the worktree hangs off the repository row beside that group. The two kinds of row cannot be
confused for each other.

A worktree you have open as a workspace is drawn inside the repository it came from, panes and
all. It gets no second row at the top level. A worktree that is not open is a dimmed one-line row
in the same place.

The `main` group appears only where there are worktrees. `example-api` has none, so its panes
hang off its own row. Every workspace herdr opens for a plugin has that shape too. The Lantern
chat arrives as a workspace of one pane and reads as exactly that.

The count on a repository row is its checkouts: its own, plus one for each worktree. Where a
`main` group is drawn, the pane count sits on the group.

### Inactive projects

Below the live workspaces sits one foldable `Inactive (N)` heading. It lists every `project.el`
project with no herdr workspace open. Each row is dimmed, folds, and carries the repository's
checkouts underneath: a `main` row for its own, then one for each worktree.

```
Inactive (24)
  example-api (16)           ~/src/example-api/
    main                     ~/src/example-api
    release-1.4              ~/src/example-api-worktrees/release-1.4
    …
```

`RET` on the project row creates its workspace. `n` on any row under it opens a terminal in that
directory. A worktree you have not touched in a week is two keystrokes from having a shell in it.

Two kinds of row are left out. A worktree you have also opened as a project in Emacs gets no row
of its own, because it is already listed under the repository it belongs to. A project whose
directory has been deleted gets no row either. `project.el` remembers a project until something
tells it to forget one, and nothing tells it when a directory goes away. Run
`project-forget-zombie-projects` to drop those.

This list comes from `project-known-project-roots`, not from herdr. A herdr workspace closes when
its last pane closes, so the server knows nothing about a project you are not working in right
now. Reading `project.el` is what makes the dashboard a place to start work from.

Directories render with `~/` in place of the home path. The abbreviation is display only. The row
still carries the real path for the commands that act on it.

## One prefix key

`herdr-command-map` is a prefix keymap. It holds the same verbs as the dashboard, for use from
anywhere else. Bind it yourself, to whichever key is spare in your configuration:

```elisp
(define-key global-map (kbd "C-c H") herdr-command-map)
```

| Key | Action |
| --- | --- |
| `s` | open the dashboard, running the start sequence first |
| `f` | pick a shell or agent and go to it |
| `n` | open a terminal, picking the workspace or project first |
| `k` | pick a shell or agent and close it |
| `w` | pick a workspace and go to it |
| `p` | the workspace for the current project, created if absent |
| `%` | create a git worktree |
| `g` | resync the cache |

The letters are the dashboard's letters, so there is one set to learn. `n` opens a terminal and
`k` closes one here exactly as they do on a dashboard row. Only the target differs: a picker
here, point there.

There is no help key. `C-h` after the prefix lists these bindings, and `C-h m` in
`*herdr-agents*` describes that buffer's.

## Two surfaces

The dashboard is where you act on something you can see. `herdr-command-map` is where you act on
something you cannot, by naming it in a picker. That is the whole interface.

A short list of curated commands covers what those two call. `M-x herdr-call` reaches every other
server method. It prompts for each parameter from the server's own schema, so nothing the server
can do is out of reach and no menu has to be generated.

A command acts on the pane of the buffer you are in, if that buffer is a herdr terminal.
Otherwise it acts on the pane herdr has focused. `C-u` on any command prompts instead.

Tabs are not modelled. A tab's only visual form is the TUI's tab bar, and nothing here draws one,
so nothing tab-shaped is offered. `herdr-call` reaches the `tab.*` methods if you want them.

Workspaces are modelled. They are keyed by working directory, they survive a server restart, they
group the dashboard, and they back `herdr-project`. Going to one shows that workspace's active
pane in the current window.

## Requirements

- Emacs 28.1+
- [herdr](https://herdr.dev) 0.8.2 (protocol 20)
- `ghostel`, `magit-section`

Optional, used when present and never required: `marginalia`, `embark`, `consult`, `alert`.

The dashboard is built on `magit-section`. No file here names `transient`, but `magit-section`
requires one, and Emacs has shipped one since 28.1, so it loads anyway.

## Install

```elisp
(use-package herdr
  :ensure nil                          ; local checkout, not on MELPA
  :load-path "~/src/herdr.el"
  :bind (:map project-prefix-map
         ("h" . herdr-project))
  :bind-keymap ("C-c H" . herdr-command-map)
  :config (herdr-modeline-mode 1))
```

`herdr-command-map` is a keymap, not a command. It needs `:bind-keymap`. `:bind` does not work.

`:ensure nil` matters if you set `use-package-always-ensure`. Without it Emacs tries MELPA and
fails at startup.

`M-x herdr` starts the server if it is not running, brings up the terminals, connects the event
stream, and opens the dashboard.

## How terminals are hosted

One ghostel buffer for each pane, each running `herdr terminal attach`. Emacs owns the layout.
herdr's own layout tree goes unused, so there is no geometry to keep in sync.

`herdr-display-action` controls placement. Every path that shows a terminal goes through it, so
one buffer cannot appear one way from one command and another way from the next. It defaults to
reusing the current window and leaving your splits alone.

A buffer takes the name the pane is best known by. First choice is a name set through
`agent.rename`. Then the pane's own label, which is how a plugin pane arrives already named.
Otherwise `KIND@WORKSPACE`. An unnamed Claude in the `web` workspace reads as
`*herdr: claude@web*`, and a plain shell as `*herdr: shell@web*`.

Attaching is lazy and nothing splits. `M-x herdr` takes no windows and opens no buffers. A pane
attaches the first time you go to it, in the current window. Splitting stays yours: `C-x 2`,
`C-x 3`, `display-buffer-alist`.

The attach client needs a window when it starts, so attaching every agent up front would take a
window for each agent before you asked for anything. Once started, the client survives being
buried, so you can switch away freely.

Agents survive Emacs exiting, because the herdr server is a daemon. Quit Emacs, restart,
`M-x herdr`, and every agent is still there and reattached. A plain ghostel shell cannot do that.
It is a child of Emacs and dies with it.

Since herdr 0.8.2, `herdr terminal attach` takes any pane, agent or plain shell alike. A shell
pane gets a buffer the same way an agent pane does, on first visit. Before you attach to one it
stays reachable through `pane.read`, `pane.send_text` and `pane.wait_for_output`, each an
`M-x herdr-call` away. For ordinary interactive shells outside herdr, use `ghostel-project`.

## What a pane is

"Pane" here always means a herdr pane: a PTY and shell process owned by the herdr daemon, with an
id like `w2:p1`. It is not a ghostel buffer and not an Emacs window. The daemon forks the shell.
Emacs only asks it to. That is why a pane outlives Emacs.

A ghostel buffer is a view onto a pane, created the moment you attach to it.

A pane you create from Emacs is shown immediately. Creation follows the new pane and attaches to
it, the same as going to any other pane.

herdr names the agent in a pane itself. Open a terminal pane, start Claude in it, and the row
reads `claude` a few seconds later. Nothing needs reporting.

`pane.report_agent` can name an agent on a pane by hand. That puts a long-running shell, a build
for example, in herdr's own sidebar and modeline, and it survives an Emacs restart because the
report is server-side state. Naming an agent on a pane that is already running one leaves a label
that never corrects itself. See
[Troubleshooting](docs/troubleshooting.md#a-pane-is-labelled-shell-but-is-running-an-agent).

## What we measured

herdr's socket API is mostly undocumented, so the design here rests on behaviour probed from a
live server, and since 0.8.2 on herdr's own source at
[herdrdev/herdr](https://github.com/herdrdev/herdr).

Some early findings were wrong. `docs/protocol.md` keeps each wrong one visible with a
strikethrough beside its correction. Deleting a wrong finding only means the next reader derives
it again from the same weak evidence, which is how four of them survived as long as they did.

The finding that bites first: `events.subscribe` replays the server's whole 512-event ring to
every new subscriber, one event per subscribed type per 100ms tick. Events carry no sequence
number and no timestamp, so a client cannot tell a replay from a live event. The dashboard shows
a second or two of dead panes after `M-x herdr`, until the next reconcile clears them.

Everything measured, with the source excerpts and the wrong readings kept visible, is in
[`docs/protocol.md`](docs/protocol.md).

## Commands

Worth knowing about:

- `herdr-new-terminal` opens a terminal, asking where first. It offers every `project.el` project
  by path, including open projects, and each open workspace by id. An open target gets a new tab.
  An unopened project gets a workspace and its root pane.
- `herdr-worktree-create` takes a branch name and gives you a git worktree with its own herdr
  workspace, using herdr's native worktree support.
- `herdr-pane-read` puts terminal output into a real Emacs buffer. The `recent_unwrapped` source
  undoes terminal line-wrapping, which is what makes the result greppable.
- `herdr-project` focuses the herdr workspace for the current `project.el` project, or creates it.

Terminal buffers track their pane's working directory, controlled by
`herdr-term-track-directory`. `find-file` and `compile` from a herdr buffer start in the right
place.

## Agent awareness

`herdr-modeline-mode` shows something like `herdr:2⏸1✓`. Idle agents are left out on purpose. A
count that is always on screen stops being read.

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

That is what makes the modeline and the dashboard accurate rather than approximate. Note that it
writes to the agent's own configuration directory.

Agents can also drive herdr themselves, through herdr's
[agent skill](https://herdr.dev/docs/agent-skill/): splitting panes, running commands, waiting on
output, starting helper agents. Everything they do shows up in Emacs, because it goes through the
same server and the same event stream. A `herdr pane split` run outside Emacs appears in the
pickers, an external status report moves the modeline, an external close removes the pane.

Attaching is lazy, so a pane an agent creates gets no buffer on its own. Only a creation Emacs
started follows the new pane and attaches to it. An agent splitting a pane to run a build should
not seize an Emacs window. The pane is visible in the picker, and going to it attaches directly.
If the agent starts a helper agent there, it appears in the agents list and the modeline at once,
the same as any other detected agent.

## Completion

Pickers are plain `completing-read` over the cache, so they inherit whatever completion stack you
already use. A pane candidate is the whole row - id, agent, status, name and directory - rather
than an id annotated with the rest, because `completing-read` matches the candidate and never the
annotation. With `orderless` that makes `web claude blocked` a working query. `embark-act` on a
pane candidate offers focus, read, prompt and close.

## Development

```bash
make test        # hermetic; no herdr required, uses a fake server
make test-live   # needs a running herdr; includes the schema drift test
make compile     # byte-compile, warnings are errors
```

Both targets run `emacs -Q -L .`, which reads no init file. `test/herdr-deps.el` therefore
searches the package directories of `elpaca`, `package.el` and `straight.el` for `magit-section`
and what it needs. A missing dependency is a hard error naming `EXTRA_LOAD_PATH`. Nothing skips.

Both suites run in batch, and that is a real blind spot. A batch Emacs has no frame. It cannot
catch a modeline rendering `*invalid*`, a command splitting a window, or a `require` that nothing
pulls in any more. Several faults passed a green suite and were found only by driving a real
Emacs under a PTY. When your change touches windows, buffers or the modeline, run it in a real
frame as well.

`src/api/subscriptions.rs`, `src/api/event_hub.rs` and `src/api/server.rs` in
[herdrdev/herdr](https://github.com/herdrdev/herdr) answer most protocol questions faster than
probing does, and without ambiguity.

For `EXTRA_LOAD_PATH` and the rules a change must follow, see
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

The original design documents and implementation plans live in
[`docs/history/`](docs/history/). They record the design at their date and are not current.

## License

GPL-3.0-or-later.
