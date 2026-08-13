# herdr.el

Drive [herdr](https://herdr.dev) — a terminal workspace manager for AI coding agents — from
Emacs, with herdr's terminals hosted **inside** Emacs via
[ghostel](https://github.com/dakra/ghostel).

There is no second terminal application in the loop. Commands go over herdr's unix socket, a live
event stream keeps a cache of the session, and that cache feeds a
[transient](https://github.com/magit/transient) menu, a modeline segment, an agent status buffer,
and completion pickers.

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

**Tabs are hidden entirely under `agent-windows`.** A tab is a grouping inside a workspace whose
only visual form is the TUI's tab bar, so where nothing renders a tab, nothing tab-shaped is
offered — `herdr-call` still reaches the methods if you want them.
Workspaces are *not* hidden: they are keyed by cwd, persist across restarts, group the agents
buffer, and back `herdr-project`. Going to one shows that workspace's active pane — one buffer,
in the current window, not all of them.

**Targeting.** Commands act on the pane of the buffer you are in, if that is a herdr terminal;
otherwise on the pane herdr has focused. `C-u` on any command prompts instead. The header names
the pane that will be acted on, so it is never a guess.

**Key scheme.** A lowercase noun jumps to that kind of thing; the same letter uppercased opens
its menu. Inside a menu, verbs are constant: `c` create, `f` focus, `r` read, `R` rename, `k`
close/remove, `l` list. `?` and `C-h` are left to transient's own help, so status is `s`.
Worktrees are on `%` and the raw-method escape hatch on `:`, matching where magit puts those two
ideas. Asserted by tests, not just by review.

## Requirements

- Emacs 28.1+
- [herdr](https://herdr.dev) 0.8.0 (protocol 19)
- `ghostel`, `transient`

Optional, used when present, never required: `marginalia`, `embark`, `consult`, `alert`.

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
  :config (herdr-agents-mode-line-mode 1))
```

`:ensure nil` matters if you set `use-package-always-ensure` — without it Emacs tries MELPA and fails at startup.

`M-x herdr` starts the server if it is not running, brings up the terminals, connects the event
stream, and opens the dispatcher.

## Terminal backends

Both are supported. Set `herdr-terminal-backend`.

### `session` (default)

One ghostel buffer, `*herdr*`, running the herdr TUI. herdr owns the layout. Plain shell panes
work normally. About sixty lines of glue and nothing to go wrong.

`herdr-display-action` controls placement, and every path that shows a herdr buffer goes through
it — starting herdr, going to a pane, attaching — so the same buffer cannot appear one way from
`M-x herdr` and another from Go to.

It defaults to reusing the current window and leaving your splits alone. herdr's TUI wants width
for its 26-column sidebar, so under `session` you may prefer
`'(display-buffer-full-frame)` — which does delete your other windows — or a side window.

The TUI is mouse-first — click panes, drag borders, right-click menus. ghostel forwards those
clicks, but only under **GUI Emacs**: a TTY frame (`emacs -nw`) has no mouse events to forward, so
there drive the TUI by keyboard (its `ctrl+b` prefix) or use `agent-windows`, which is
keyboard-first and needs no TUI at all.

### `agent-windows`

One ghostel buffer per agent — `*herdr: claude w1:p1*` — each running `herdr agent attach`.
Emacs owns the layout; herdr's own layout tree goes unused, so there is no geometry to keep in
sync.

**Attaching is lazy, and nothing splits.** `M-x herdr` takes no windows and opens no buffers; a
pane is attached the first time you go to it, in the current window. Splitting stays yours —
`C-x 2`, `C-x 3`, `display-buffer-alist`.

Laziness is not only politeness: the attach client needs a window when it starts, so attaching
every agent up front would mean taking a window per agent before you had asked for anything. Once
started it survives being buried, so you can switch away freely.

The reason to want it: **agents survive Emacs exiting**, because the herdr server is a daemon.
Quit Emacs, restart, `M-x herdr`, and every agent is still there and reattached. A plain ghostel
shell cannot do that — it is a child of Emacs and dies with it.

The cost: `herdr agent attach` refuses a pane with no detected agent, so plain shell panes get no
buffer by default. They stay reachable through `pane.read`, `pane.send_text`,
`pane.wait_for_output` and the menu, and `ghostel-project` covers ordinary interactive shells.

### Adopting a shell

"Pane" here always means a **herdr pane** — a PTY and shell process owned by the herdr daemon,
with an id like `w2:p1`. It is not a ghostel buffer and not an Emacs window. The daemon forks the
shell; Emacs only ever asks it to. That is why a pane outlives Emacs, and why adoption happens
*before* any buffer exists — a ghostel buffer is what you get after adopting, not the thing being
adopted.

herdr panes you create *from Emacs* — split, new tab, new workspace — are adopted automatically,
so they get buffers like anything else. That is `herdr-adopt-created-shells`, on by default. The
rule is about provenance: panes appearing from anywhere else, including ones an agent creates for
itself, are never claimed behind your back.

Provenance is judged once, when the command runs; there is no lasting record that Emacs created a
pane. The adoption it produces *is* lasting, though, because the reported agent is server-side
state — so an adopted pane is still adopted after you restart Emacs.

`M-x herdr-adopt-shell` does the same for any pane you point it at, by reporting an agent named
`herdr-shell-agent-name` (default `shell`) — which is the only thing `agent attach` checks. Use it
for a pane you want to watch in Emacs *and* keep running across an Emacs restart, such as a long
build.

Adopted shells get buffers but are **not** treated as agents: they stay out of the modeline count,
the agent picker and notifications, since a shell has no lifecycle. They show as `shell*` with a
`~` glyph in `*herdr-agents*`.

**Adoption does not suppress herdr's own agent detection.** Reporting and detection operate
independently in 0.8.0, and detection wins: start Claude inside a pane adopted as `shell` and
herdr relabels it `claude` a few seconds later, of its own accord. Nothing is needed from you,
and nothing is needed from herdr.el.

This is worth stating plainly because the opposite was believed here for a long time, and the
code carried a poll to compensate for it — `agent.explain` on every adopted shell on every
directory poll, 936 calls in one session and three quarters of all the RPC traffic herdr.el
made, to force a relabelling that herdr was already doing. There was a `herdr-promote-shell`
command to trigger it by hand; both are gone.

The visible cost is one row in herdr's own sidebar, in its agents section, labelled `shell`. That
section's membership rule is simply "has a reported agent", and herdr's sidebar does not list
non-agent panes at all — so there is no "plain shell" row for it to be instead.
`M-x herdr-release-shell` reverses it completely.

## What was measured

The design rests on behaviour probed from a live herdr 0.8.0 rather than from documentation.
Recorded here because most of it is not written down anywhere else.

Some of it was probed against an older herdr and later turned out to be wrong. Those rows are
**corrected in place rather than removed**, with the superseded claim still visible — deleting
one only means the next reader re-derives it from the same weak evidence, which is exactly how
four of them survived as long as they did.

| Behaviour | Finding |
|---|---|
| RPC connections | **One request per connection.** The server writes one response, then closes. No multiplexing, no id correlation. |
| `events.subscribe` | The one long-lived call. Acks `subscription_started`, then streams. |
| **Subscribe replays one event per type** | Not history. `events.subscribe` answers with the **last retained event of each subscribed type** and nothing older: 8 events in ~4 ms across all 24 global types, and exactly **1** when subscribing to `pane.updated` alone in a window that carried 662 of them. ~~Subscribing to an idle server returned 54 past events; a real startup produced about 150.~~ That earlier count was measured wrong, and the 0.4s "wait for quiet, then announce once" window built on it swallowed **533 events over 54 seconds** of a real timeline — the modeline and dashboard frozen for a minute after every connect. Every event now reaches listeners as it lands. |
| **`pane_updated` is output-coupled** | It does **not** coalesce (~~3 per-pane events produced only 1 `pane_updated`~~). It fires about **7.5/s** carrying a full `PaneInfo`, `agent_status` included — but it is tied to title and output, so it stops firing exactly when an agent goes **idle**, which is the transition worth knowing about. Lag from the per-pane event reporting idle to the global stream reflecting it: **6.18s and 31.79s**. Hence the second connection carrying per-pane `pane.agent_status_changed`, which has no global form. |
| Throughput | Not a concern for either backend. A **12.2 MB** pane dump reached Emacs as **17 KB** (`session`) / **24 KB** (`agent-windows`), completing in 0.2s. herdr's VT only emits visible-frame diffs. |
| `agent attach` | Streams one pane full-screen; coexists with a session client; **exclusive per pane**; still refuses a pane with no agent in 0.8.0 (`agent_not_found`), which is what keeps adoption necessary. |
| Attach needs a window | The client needs a window when it starts and dies if that window is *deleted*; being merely hidden is fine, so a buried terminal keeps running with its scrollback. A zero-sized PTY renders nothing. |
| **Retention leaves ghosts** | The retained `pane.created` is for whatever pane was made last, so subscribing resurrects it even if it closed minutes ago — verified. It folds away only because retained events arrive in **subscription-list order**, not chronological order, and `pane.created` is listed before `pane.closed`. Nothing in the protocol guarantees that, so the pane set is reconciled against `pane.list` once after connecting and on a poll thereafter. |
| **Detection outranks adoption** | Reporting an agent does **not** suppress detection; herdr's own docs now say the two operate independently. Measured: a pane reported as `shell` was relabelled `claude` by herdr about **3s** after Claude started in it, over the reported label, unasked. ~~`pane.report_agent` takes lifecycle authority, so an adopted pane keeps its label.~~ That was true of an older herdr and is the premise the deleted `herdr-promote-shell` poll rested on. |
| Focus is shared | One focused pane per session, not per client. Navigating in Emacs moves the focus in any attached TUI too. |
| OSC | **Not** forwarded — herdr's VT consumes OSC 7 and OSC 133. Beware the false positive: sending the escapes inline makes the shell echo the command text, which contains the same characters. |
| cwd tracking | herdr tracks it **itself** — `pane.cwd` follows a `cd` within about a second. But it publishes **no event** for it: a `cd` emits only `layout_updated` noise, so directory tracking has to poll (debounced off the event stream, with a slow backstop timer). |
| Shell panes | `pane.report_agent` makes a plain shell pane attachable, which is how adoption works. |
| `pane.read` shape | Text is nested under a `read` object, not a top-level field. |
| Rename and move events are flat | They carry **no nested record**. `workspace_renamed` is `{workspace_id, label}`; `tab_renamed` adds `workspace_id`; the two move events send `{id, insert_index, <array of fresh records>}`; `pane_agent_detected` is `{pane_id, workspace_id, agent?, final_status?, released?}`. Reading a `workspace`/`tab`/`pane` object out of any of them — as this package did — silently drops the event. |
| Terminal titles animate | Claude runs a spinner glyph and a second counter inside the title, so `terminal_title_stripped` changes several times a second: **662 of 662** `pane_updated` events differed in it, against 11 that differed in `agent_status`. It is a volatile field, not a stable label, and must not be treated as one when diffing panes. |
| JSON arrays | Emacs's `json-serialize` cannot distinguish a list of alists from one alist. Array parameters must be vectors or `events.subscribe` is rejected. |

## Commands

33 curated commands cover the methods worth a keybinding; `M-x herdr-call` reaches all
**89**, prompting for each parameter from the server's own schema. Nothing is out of reach and
there is no generated 89-entry menu.

Worth knowing about:

- **`herdr-agent-start`** — starts an agent in an idle pane. The picker also offers a trailing
  **＋ new shell pane** entry that splits the current pane and starts there, so a session with no
  free pane is never a dead end.
- **`herdr-worktree-create`** — herdr has native git-worktree support, so one command takes a
  branch name to a worktree with its own herdr workspace.
- **`herdr-pane-read`** / **`herdr-agent-read`** — terminal output into a real Emacs buffer.
  `recent_unwrapped` undoes terminal line-wrapping, which is what makes the result greppable.
- **`herdr-agent-wait`** and **`herdr-pane-wait-for-output`** — asynchronous, so Emacs stays
  responsive. "Tell me when the dev server prints `Listening on`" is one command.
- **`herdr-project`** — focus or create the herdr workspace for the current `project.el` project.
- **`herdr-adopt-shell`** / **`herdr-release-shell`** — see Adopting a shell, above.

Terminal buffers track their pane's working directory (`herdr-term-track-directory`), so
`find-file` and `compile` from a herdr buffer start in the right place.

## The dispatcher

`M-x herdr` (or `C-c H`) opens `*herdr-agents*`: the whole session as a foldable
workspace → tab → pane tree, and the place every command is reachable from.

`M-x herdr-menu` does the same startup as `herdr` — bringing up the server, terminals and event
stream — but ends on `herdr-transient`'s compact menu instead of the dashboard. Reach for `herdr`
when you want to survey the whole session; reach for `herdr-menu` when you are inside an agent's
terminal buffer and popping open a full-window dashboard would be the wrong move.

| Key | Action |
| --- | --- |
| `RET` | go to the thing at point |
| `TAB` | fold; fetches a workspace's worktrees on first open |
| `c` | create menu, with its parent taken from point |
| `w` / `t` / `n` / `a` / `%` | create workspace / tab / pane / agent / worktree directly |
| `p` | prompt the agent at point |
| `r` | read the pane at point into a buffer |
| `f` | focus the thing at point server-side, without moving Emacs |
| `R` | rename the thing at point |
| `k` | close or remove the thing at point |
| `g` | refresh from the cache |
| `q` | quit the window |
| `?` | open `herdr-transient` |

Workspaces with a single tab omit the tab level, since an unnamed tab is labelled by
number and adds nothing. A collapsed section still shows the worst status inside it,
so folding never hides a blocked agent.

`herdr-transient` is unchanged. The package binds no global key for it: it is reached by
`M-x herdr-menu`, `M-x herdr-transient` or by `?` in the dispatcher, and the transient goes
back the other way with `l`. Bind it yourself if you want it on a key. Calling
`herdr-transient` directly skips the startup `herdr` and `herdr-menu` perform, so from a
cold Emacs it opens with no state cache behind it; `herdr-menu` is the entry point that
guarantees the startup has run.

## Agent awareness

- **Modeline** — `herdr-agents-mode-line-mode` shows e.g. `herdr:2⏸1✓`. Idle agents are omitted
  deliberately: a count that is always on screen stops being read.
- **Desktop notifications** — off by default. `(setq herdr-notify-statuses '("blocked" "done"))`
  to opt in. Uses `alert` when available.

## Integrations, and agents driving herdr themselves

herdr can be told about agent lifecycle directly instead of inferring it. Without an integration,
status comes from herdr's *detection heuristics* — regexes over the terminal title — so agents
tend to sit at `idle`. With one, they report `idle` / `working` / `blocked` to the socket:

```bash
herdr integration install claude     # writes ~/.claude/hooks/herdr-agent-state.sh
herdr integration status
```

That is what makes the modeline segment, `*herdr-agents*` and `herdr-agent-wait` genuinely useful
rather than approximate. Note it writes to the agent's own config.

Agents can also drive herdr themselves, via herdr's [agent skill](https://herdr.dev/docs/agent-skill/)
— splitting panes, running commands, waiting on output, starting helper agents. **Everything they
do shows up in Emacs**, because it goes through the same server and the same event stream: an
externally issued `herdr pane split` appears in the pickers, an external status report moves the
modeline, an external close removes the pane.

One consequence of the provenance rule: a pane an *agent* creates gets no buffer under
`agent-windows`, since auto-adoption covers only panes herdr.el created — an agent splitting a
pane to run a build should not seize an Emacs window. It is visible in the picker, and going to it
offers to adopt. If the agent starts a *helper agent* there, it becomes attachable and appears in
the agents list and modeline immediately.

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

### `EXTRA_LOAD_PATH`, and what bare `make test` leaves out

Bare `make test` and `make compile` run against `emacs -Q -L .`, which has no third-party
packages on its load path. That is deliberate — it keeps both targets meaningful on a
checkout with nothing installed — but it means neither one covers the dispatcher:

- **`make test`** skips every test whose dependency is missing, currently ~60 of 250,
  including the whole `herdr-dispatch` suite. The skips are reported, not hidden, but a
  green bare run says nothing about `herdr-dispatch.el`.
- **`make compile`** drops `herdr-dispatch.el` from its file list entirely, since
  byte-compiling it without `magit-section` would only fail on the `require`. So the
  largest file in the package never meets `byte-compile-error-on-warn` on a bare run.

Point `EXTRA_LOAD_PATH` at the dependencies to run and compile everything. It takes a
space-separated list of directories, and with `straight`, `elpaca` or any other manager
they are wherever that manager builds packages:

```bash
B=~/.emacs.d/var/elpaca/builds   # adjust to your package manager
DEPS="$B/magit-section $B/compat $B/dash $B/llama $B/transient $B/cond-let"

make test    EXTRA_LOAD_PATH="$DEPS"   # 250 tests, 0 skipped
make compile EXTRA_LOAD_PATH="$DEPS"   # all 12 files, warnings are errors
```

All six directories are needed: `magit-section` is the dispatcher's own dependency, and
`compat`, `dash`, `llama`, `transient` and `cond-let` are what it and `transient` pull in
behind it. **Run this form before sending a change** — the bare targets will not tell you
that you broke the dispatcher.

`make test-live` includes a drift test that checks every curated command's method and parameters
against the running server's schema. herdr is young and its API will move; when it does, that test
names the broken command instead of leaving it to fail in front of you. The round-trip test
asserts the session is left exactly as it was found.

**Both suites run in batch, and that is a real blind spot.** A batch Emacs has no frame, so it
cannot catch a mode line rendering `*invalid*`, a command splitting a window, or a transient
entry that was never added. Several bugs got through a green suite and were only found by driving
a real Emacs under a PTY. When changing anything that touches windows, buffers or the mode line,
run it in a real frame as well.

## Design notes

Full design and rationale: [`docs/superpowers/specs/2026-08-01-herdr-el-design.md`](docs/superpowers/specs/2026-08-01-herdr-el-design.md).

## License

GPL-3.0-or-later.
