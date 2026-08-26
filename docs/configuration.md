# Configuration

This document lists every user option. Set an option with `M-x customize-group RET herdr RET`,
or with `setq` in your init file.

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
| `herdr-terminal-backend` | `session` | How Emacs hosts the herdr terminals. |
| `herdr-display-action` | `((display-buffer-reuse-window display-buffer-same-window))` | Where a herdr buffer appears. |
| `herdr-term-track-directory` | `t` | Whether a buffer follows the working directory of its pane. |
| `herdr-term-directory-interval` | `5.0` | The number of seconds between directory polls. `nil` stops the polls. |
| `herdr-term-directory-debounce` | `0.4` | The number of seconds to group the directory refreshes. |

`herdr-terminal-backend` takes one of two values:

- `session` gives you one buffer that runs the herdr TUI. herdr controls the layout.
- `agent-windows` gives you one buffer for each agent. Emacs controls the layout. Your agents
  stay alive when you close Emacs.

Every path that shows a herdr buffer uses `herdr-display-action`. The same buffer therefore
cannot appear in one place from one command and in another place from a different command.

The herdr TUI needs width for its sidebar. The sidebar is 26 columns. Under the `session`
backend, you can prefer `'(display-buffer-full-frame)`. That value deletes your other windows.

herdr does not send an event when the working directory changes. Directory tracking must
therefore poll. The poll runs only while herdr terminal buffers exist.

## The dashboard

| Option | Default | Function |
|---|---|---|
| `herdr-dispatch-buffer-name` | `"*herdr-agents*"` | The name of the dashboard buffer. |
| `herdr-dispatch-refresh-debounce` | `0.2` | The number of seconds to group the dashboard redraws. |
| `herdr-dispatch-fold-indicators` | `nil` | The value that `magit-section-visibility-indicators` takes. |

The dashboard redraws from the cache, not from the server. A redraw therefore costs no socket
traffic. The debounce stops a busy agent from causing many redraws each second.

## Agents and shells

| Option | Default | Function |
|---|---|---|
| `herdr-adopt-created-shells` | `t` | Obsolete no-op, kept so an old config does not error. |
| `herdr-shell-agent-name` | `"shell"` | The agent name that `herdr-adopt-shell` reports. |
| `herdr-agent-kinds` | 22 names | The agent kinds that the pickers offer. |
| `herdr-notify-statuses` | `nil` | The agent statuses that raise a desktop notification. |

Since herdr 0.8.2, every pane is attachable, so `herdr-adopt-created-shells` does nothing;
`herdr terminal attach` no longer refuses a plain shell pane. `M-x herdr-adopt-shell` still has a
use: it reports `herdr-shell-agent-name` on a pane so herdr itself watches it, which puts the pane
in the modeline count, the agent picker and notifications like any other agent-reporting pane.
`M-x herdr-release-shell` undoes the report.

To get desktop notifications, set the statuses that you want:

```elisp
(setq herdr-notify-statuses '("blocked" "done"))
```

herdr.el uses the `alert` package when the package is present.

The default value of `herdr-agent-kinds` holds these names: `pi`, `claude`, `codex`, `gemini`,
`cursor`, `devin`, `agy`, `cline`, `omp`, `mastracode`, `opencode`, `copilot`, `kimi`, `kiro`,
`droid`, `amp`, `grok`, `hermes`, `kilo`, `qodercli`, `qwen` and `maki`.

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
