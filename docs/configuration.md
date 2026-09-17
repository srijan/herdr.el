# Configuration

This document lists every user option. Set an option with `M-x customize-group RET herdr RET`,
or with `setq` in your init file.

herdr.el binds no key. `herdr-command-map` is a prefix keymap that you bind yourself. See
[Commands](commands.md#the-prefix-keymap).

## Connection

| Option | Default | Function |
|---|---|---|
| `herdr-socket-path` | `$HERDR_SOCKET_PATH`, else `"~/.config/herdr/herdr.sock"` | The path to the unix socket of the server. |
| `herdr-executable` | `"herdr"` | The name of the herdr program, or the path to it. |
| `herdr-protocol-version` | `22` | The protocol version that this package targets. |
| `herdr-rpc-timeout` | `10.0` | The number of seconds to wait for a synchronous response. |
| `herdr-rpc-background-timeout` | `2.0` | The number of seconds that a background call can block Emacs. |
| `herdr-server-start-timeout` | `15.0` | The number of seconds to wait for a new server to answer. |

The two timeouts are different on purpose. A command that you start yourself can wait for
10 seconds. A timer that runs without your knowledge must not freeze the editor, so a timer
waits for 2 seconds only.

Change `herdr-protocol-version` only to stop the mismatch warning. The value does not change
what herdr.el sends.

### An Emacs started inside a herdr pane

herdr exports `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`,
`HERDR_SOCKET_PATH` and `HERDR_BIN_PATH` into every pane it starts. An Emacs launched from one
inherits them, and herdr.el reads two.

`herdr-socket-path` defaults to `HERDR_SOCKET_PATH`, so an Emacs started inside a
`herdr --session work` pane talks to that session. The literal default is the *default* session's
socket, which for a named session is the wrong server — one that may not be running, and that
holds none of the panes on screen. Set the option yourself to override this.

`HERDR_PANE_ID` names the pane Emacs is running in. Going to that pane is refused, because
attaching to it points a terminal buffer at the terminal drawing the buffer. The id is only
believed for the server `HERDR_SOCKET_PATH` names: ids are per-server counters, so the same
`w1:p1` exists on every machine you follow.

An Emacs started any other way — from a desktop launcher, as a daemon — has none of these, and
nothing above applies. An exported-but-empty variable counts as absent.

## Remote servers

A remote server is a herdr server on another machine, reached over SSH. Connect to one with
`M-x herdr-connect-remote` and stop following it with `M-x herdr-disconnect`.

If you have saved machines with `herdr machine add`, the command offers them by label and
takes the target and the session from the catalog. Anything you type that is not one of those
labels is read as an SSH target and asked about in full, so a machine nobody saved is no
harder to reach than it was. With no saved machines the command asks for a target, a name and
optionally a herdr session on that host.

| Option | Default | Function |
|---|---|---|
| `herdr-connection-socket-directory` | `"/tmp/herdr-<uid>"` | Where the local end of each forwarded socket is bound. |
| `herdr-connection-tunnel-timeout` | `10.0` | The number of seconds to wait for a forwarded socket to answer. |

Nothing connects when Emacs starts. A connection is made when you ask for one and then kept,
retried while you still want it, and stopped when you disconnect.

The SSH target is passed to `ssh` untouched, so a bare host, a `user@host` and an alias from
your SSH config all work. Two accounts on one machine are two connections like any others:
they have different home directories, so herdr puts their sockets in different places and
they may be running different versions of herdr.

### How it reaches the server

herdr's control socket is a unix socket, and Emacs cannot open one on another machine. So the
remote socket is forwarded to a local one with `ssh -N -L`, and the rest of herdr.el is
unchanged: it opens a unix socket either way.

The remote path is read off the remote host, by running `herdr session list --json` there. It
is not guessed from `herdr-socket-path`: that default contains a `~`, and expanding it here
would send a macOS client looking for a `/Users/...` path on a Linux server. Running that
command is also the only check that herdr is installed on the far host at all — the forward
itself cannot tell, because `ssh` dials the path it is given without looking at what is
behind it.

Terminals do not use the tunnel. A remote pane's terminal buffer gets a TRAMP
`default-directory`, and the terminal client runs on the remote host, which is how it reaches
a pane that is running there.

The path to herdr on the remote host is resolved at the same time, with `command -v herdr`,
and the terminal client is run by that absolute path. `herdr-executable` is not used for a
remote connection: TRAMP runs remote commands under `tramp-remote-path` rather than your
login PATH, so a herdr installed in `~/.local/bin` is found by `ssh host herdr` and not by
the terminal client. An absolute path needs no PATH at all.

### When it does not work

A connection is reported up only once a ping answers through the forward. The local socket
appearing proves only that `ssh` bound it, which it does before speaking to the far host at
all. Each of these is something herdr.el observed, and it does not guess past them:

| What you see | What it means |
|---|---|
| `ssh_failed`, with what `ssh` printed | SSH did not connect. Its own message is the diagnosis. |
| `no_herdr` | SSH connected and the far host did not say where its herdr is. Usually herdr is not installed there. |
| `bad_answer` | The far host answered and its answer would not parse. |
| `no_such_session` | That host runs herdr, and has no session by that name. |
| `ssh_exited` | The forward's `ssh` exited while the connection was being made. |
| `no_answer` | The forward is up and the socket did not answer. Usually no herdr server is running on that host. |
| `not_herdr` | Something answered on that socket and it was not a herdr server. |

`wrong_host` is a different class: it means a path was about to cross to the wrong machine, and
herdr.el refused rather than guess. Two accounts on one host count as two machines, because they
have different home directories and different herdr sockets.

On a host with SELinux enforcing — Fedora and RHEL by default — `sshd` is refused access to a
socket in `~/.config`, which is where herdr puts it. The connection then reports `no_answer`
and `ssh` logs `channel N: open failed: connect failed`. Relabelling the socket lets it
through:

```sh
chcon -t user_tmp_t ~/.config/herdr/herdr.sock
```

That does not survive the socket being recreated, so it is a workaround rather than a fix.

### Saved machines

`herdr machine` is herdr's own catalog of SSH machines, holding a label, a target, an optional
session and an enabled flag:

```sh
herdr machine add shadow --label shadow --remote-session work
herdr machine list --json
```

herdr.el reads it and never writes it. A disabled machine is not offered. A herdr with no
`machine` subcommand, a catalog that will not parse and an empty one are all the same answer,
and you name a target directly as before.

The catalog is client-side and per-machine: the socket API has no `machine` method, and each
machine keeps its own server and its own socket, so following several servers still means
several connections. Your laptop's machine list is not the list on the machines it reaches.

A profile keeps its id when you rename it. Reconnecting to a renamed machine answers with the
connection already being followed, under its new name, rather than opening a second tunnel to
the same server.

### What changes once there are two

Following one server looks exactly as it did. A second one changes three surfaces, and only
while it is connected:

- The dashboard grows an outer level, one row per server, named and foldable. A server that is
  down keeps its row, dimmed, rather than disappearing.
- Pickers offer every server's panes, workspaces and projects at once, each row ending in
  `@name`. That name is part of the candidate, so it can be typed: `claude shadow` narrows to
  the agents on `shadow`.
- The modeline counts across every connection.

Choosing a row says which server the command means, even when you typed it in a terminal
buffer belonging to another one. Where nothing was chosen and nothing on screen says, a
command means the local server.

Known projects belong to the machine their path is on. A plain path is asked of local servers
only, and a TRAMP path of the server on the host it names, so one machine's project list never
reaches another and two machines holding the same path stay distinguishable.

A server that has gone quiet costs a picker its own rows' freshness and nothing else: its
last-known rows are still offered, the other servers are still asked, and nothing waits on it
longer than `herdr-rpc-background-timeout`.

## Terminals

| Option | Default | Function |
|---|---|---|
| `herdr-display-action` | `((display-buffer-reuse-window display-buffer-same-window))` | Where a herdr buffer appears. |
| `herdr-term-track-directory` | `t` | Whether a buffer follows the working directory of its pane. |
| `herdr-term-directory-debounce` | `0.4` | The number of seconds to group the directory refreshes. |

herdr.el gives each pane its own buffer. Emacs controls the layout. Your panes stay alive when
you close Emacs, because the herdr server is a daemon.

Every path that shows a terminal uses `herdr-display-action`. The same buffer therefore cannot
appear in one place from one command and in another place from a different command. The dashboard
has its own option; see [The dashboard](#the-dashboard).

herdr does not send an event when the working directory changes. A directory therefore reaches
the cache only when herdr.el asks for one. Two things pace those asks. `herdr-state-repair-interval`
is the backstop, and it runs whether or not a terminal buffer exists; see
[The event stream](#the-event-stream). With `herdr-term-track-directory` on, a burst of events also
nudges one, grouped by `herdr-term-directory-debounce`, so a `cd` shows up at the debounce interval
rather than at the backstop's.

### Restoring terminals with desktop.el

With `desktop-save-mode` on, the terminals you had open come back attached. A pane outlives the
Emacs that was showing it, so the buffer is rebuilt by reattaching to the same pane rather than by
starting anything: the scrollback is the server's and is still there.

There is nothing to configure. herdr writes `(herdr NAME PANE-ID)` into the desktop file for each of
its buffers, where NAME is the connection's, and reads it back on restore.

Two things it will not do. A pane that has closed since the desktop was written is skipped with a
message rather than recreated — the pane is the thing, and it is gone. And a restore never starts a
server: it connects to one that is already answering and otherwise skips, because a desktop is read
at startup as well as by hand, and an unattended restore should neither launch a daemon nor block on
a socket nobody is listening to. Run `M-x herdr` afterwards and attach as usual.

A remote connection is restored only if it is already registered. Rebuilding one needs its ssh
target, which the name alone does not carry.

herdr answers for every `ghostel-mode` buffer during a restore, not only its own — desktop keys
handlers by major mode and takes the first match. Buffers that are not herdr's are handed straight
to `ghostel-desktop-restore-buffer`, which is what would have run otherwise.

## The dashboard

| Option | Default | Function |
|---|---|---|
| `herdr-dispatch-buffer-name` | `"*herdr-agents*"` | The name of the dashboard buffer. |
| `herdr-dispatch-display-action` | `(display-buffer-same-window)` | Where the dashboard appears. |
| `herdr-dispatch-refresh-debounce` | `0.2` | The number of seconds to group the dashboard redraws. |

The dashboard reuses the selected window, so it preserves the rest of the frame. The key `q`
restores the buffer that window held before.

To give the dashboard the whole frame instead:

```elisp
(setq herdr-dispatch-display-action '(display-buffer-full-frame))
```

The dashboard and the terminals have separate options on purpose. A terminal is a buffer that you
move between. The dashboard is a place that you go to, read, and leave. Both reuse the selected
window by default, but you can place them independently.

The dashboard redraws from the cache, not from the server. A redraw therefore costs no socket
traffic. The debounce stops a busy agent from causing many redraws each second.

## Agents and shells

| Option | Default | Function |
|---|---|---|
| `herdr-notify-statuses` | `nil` | The agent statuses that raise a desktop notification. |

Every pane is attachable since herdr 0.8.2: `herdr terminal attach` does not refuse a plain shell
pane. To name an agent on a pane by hand, call `pane.report_agent` through `M-x herdr-call`.

To get desktop notifications, set the statuses that you want:

```elisp
(setq herdr-notify-statuses '("blocked" "done"))
```

herdr.el uses the `alert` package when the package is present.

`"done"` is worth having here and is the one status the server never sends: it means an agent
finished and you have not looked at it yet, which herdr.el works out for itself.

These are herdr.el's own notifications, and they do not come from the server. herdr has a notifier
of its own under `[ui.toast]` in `config.toml` — `off`, `inside herdr`, `via terminal` or
`via system` in its settings screen — but every one of those needs a herdr TUI attached: with none,
`notification.show` answers `no_foreground_client` and nothing is delivered whichever mode is set.
So for the usual herdr.el session, where the terminals are Emacs buffers and no TUI is running,
`herdr-notify-statuses` is the only thing that can notify you.

If you do keep a TUI attached and turn `[ui.toast]` on, set one or the other rather than both, or
each finished agent notifies you twice.

## The event stream

| Option | Default | Function |
|---|---|---|
| `herdr-state-reconnect-min` | `1.0` | The first delay, in seconds, before a retry. |
| `herdr-state-reconnect-max` | `30.0` | The longest delay, in seconds, between retries. |
| `herdr-state-settle-delay` | `0.4` | The delay, in seconds, before the first reconcile. |
| `herdr-state-repair-interval` | `5.0` | The number of seconds between later reconciles. `nil` stops them. |

herdr.el increases the reconnect delay after each failed attempt. The delay starts at the
minimum and stops at the maximum. A server that goes away therefore does not cause a loop of
connection attempts.

`herdr-state-settle-delay` sets when herdr.el first compares its cache against the server. That
comparison is what closes the gap between the startup snapshot and the subscribe, and on a herdr
older than 0.9.0 it is also what removes the panes the event replay creates. If you see dead
panes for more than two seconds, decrease `herdr-state-repair-interval`, which controls the
later comparisons. See
[Protocol notes](protocol.md#the-server-replayed-its-full-event-ring-until-090).

`herdr-state-repair-interval` replaces `herdr-term-directory-interval`, which is gone. The
repair belongs to the cache, so turning off `herdr-term-track-directory` no longer stops it.
A failed repair is also how herdr.el notices that the socket stopped answering, which is what
schedules a reconnect.
