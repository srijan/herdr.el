# Configuration

This document lists every user option. There are eighteen. Set an option with
`M-x customize-group RET herdr RET`, or with `setq` in your init file.

herdr.el binds no key. `herdr-command-map` is a prefix keymap that you bind yourself. See
[Commands](commands.md#the-prefix-keymap).

## Connection

| Option | Default | Function |
|---|---|---|
| `herdr-socket-path` | `"~/.config/herdr/herdr.sock"` | The path to the unix socket of the server. |
| `herdr-executable` | `"herdr"` | The name of the herdr program, or the path to it. |
| `herdr-protocol-version` | `20` | The protocol version that this package targets. |
| `herdr-rpc-timeout` | `10.0` | The number of seconds to wait for a synchronous response. |
| `herdr-rpc-background-timeout` | `2.0` | The number of seconds that a background call can block Emacs. |
| `herdr-server-start-timeout` | `15.0` | The number of seconds to wait for a new server to answer. |

The two timeouts are different on purpose. A command that you start yourself can wait for
10 seconds. A timer that runs without your knowledge must not freeze the editor, so a timer
waits for 2 seconds only.

Change `herdr-protocol-version` only to stop the mismatch warning. The value does not change
what herdr.el sends.

## Terminals

| Option | Default | Function |
|---|---|---|
| `herdr-display-action` | `((display-buffer-reuse-window display-buffer-same-window))` | Where a herdr buffer appears. |
| `herdr-term-track-directory` | `t` | Whether a buffer follows the working directory of its pane. |
| `herdr-term-directory-interval` | `5.0` | The number of seconds between directory polls. `nil` stops the polls. |
| `herdr-term-directory-debounce` | `0.4` | The number of seconds to group the directory refreshes. |

herdr.el gives each pane its own buffer. Emacs controls the layout. Your panes stay alive when
you close Emacs, because the herdr server is a daemon.

Every path that shows a terminal uses `herdr-display-action`. The same buffer therefore cannot
appear in one place from one command and in another place from a different command. The dashboard
has its own option; see [The dashboard](#the-dashboard).

herdr does not send an event when the working directory changes. Directory tracking must
therefore poll. The poll runs only while herdr terminal buffers exist.

## The dashboard

| Option | Default | Function |
|---|---|---|
| `herdr-dispatch-buffer-name` | `"*herdr-agents*"` | The name of the dashboard buffer. |
| `herdr-dispatch-display-action` | `(display-buffer-full-frame)` | Where the dashboard appears. |
| `herdr-dispatch-refresh-debounce` | `0.2` | The number of seconds to group the dashboard redraws. |
| `herdr-dispatch-fold-indicators` | `nil` | The value that `magit-section-visibility-indicators` takes. |

The dashboard takes the frame. A pane row has four columns, and the last two carry the news: the
pane id, and the work that the agent reports. Half a frame cuts them off.

Taking the frame deletes your other windows. The key `q` does not bring them back. It restores
the buffer that this window held before.

For a dashboard that splits the window instead, set the option to nil:

```elisp
(setq herdr-dispatch-display-action nil)
```

The dashboard and the terminals have separate options on purpose. A terminal is a buffer that you
move between, and it must not rearrange the frame. The dashboard is a place that you go to, read,
and leave.

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

## The event stream

| Option | Default | Function |
|---|---|---|
| `herdr-state-reconnect-min` | `1.0` | The first delay, in seconds, before a retry. |
| `herdr-state-reconnect-max` | `30.0` | The longest delay, in seconds, between retries. |
| `herdr-state-settle-delay` | `0.4` | The delay, in seconds, before the first reconcile. |

herdr.el increases the reconnect delay after each failed attempt. The delay starts at the
minimum and stops at the maximum. A server that goes away therefore does not cause a loop of
connection attempts.

`herdr-state-settle-delay` sets when herdr.el first compares its cache against the server. The
comparison removes the panes that the event replay of the server creates. If you see dead panes
for more than two seconds, decrease `herdr-term-directory-interval`. That option controls the
later comparisons. See [Protocol notes](protocol.md#the-server-replays-its-full-event-ring).
