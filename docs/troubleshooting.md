# Troubleshooting

Each section names a symptom. Read the cause, then do the correction.

## The dashboard shows panes that do not exist

**Symptom.** For one or two seconds after `M-x herdr`, the dashboard shows extra rows. The rows
read `shell` and `unknown`. The rows then disappear.

**Cause.** The herdr server replays its full event ring to each new subscriber. The replay
creates panes that closed long ago.

**Correction.** None is necessary. The next reconcile removes the rows. To make the correction
faster, decrease `herdr-term-directory-interval` from 5.0 seconds.

For the full explanation, see
[Protocol notes](protocol.md#the-server-replays-its-full-event-ring).

## Emacs cannot reach the server

**Symptom.** A command reports `cannot reach herdr socket`.

**Cause.** The server does not run, or the socket is at a different path.

**Correction.**

1. Check the server: `herdr status server`.
2. Check the socket path: `ls ~/.config/herdr/herdr.sock`.
3. If your socket is elsewhere, set `herdr-socket-path`.
4. Start the server with `M-x herdr-start`.

## Emacs warns about the protocol version

**Symptom.** The echo area shows `server speaks protocol N, this package targets 20`.

**Cause.** Your herdr version is not 0.8.2.

**Correction.** herdr.el continues to run, and the warning appears one time only. Some commands
can behave incorrectly. Either install herdr 0.8.2, or set `herdr-protocol-version` to your
version to stop the warning. The option changes the warning only. It does not change what
herdr.el sends.

To find the methods that drifted, run `make test-live`. The drift test names each broken
command.

## Emacs fails at start with `Cannot open load file`

**Symptom.** Emacs reports that it cannot find `magit-section`, `transient` or `ghostel`.

**Cause.** One dependency is missing. `magit-section` is the dependency that people forget,
because upstream herdr.el does not need it.

**Correction.** Install `magit-section` 3.3 or a later version. Install `transient` 0.4 or a
later version. Install `ghostel` from its repository.

## Emacs looks for herdr on MELPA

**Symptom.** Emacs fails at start, and the message names MELPA.

**Cause.** You set `use-package-always-ensure`, and your `use-package` form has no
`:ensure nil` line.

**Correction.** Add `:ensure nil` to the form. herdr.el is not on MELPA.

## The mouse does not work in the TUI

**Symptom.** Under the `session` backend, a click does nothing.

**Cause.** You run Emacs in a terminal, with `emacs -nw`. A TTY frame has no mouse events to
send.

**Correction.** Choose one of these three:

- Use a graphical Emacs.
- Drive the TUI from the keyboard, with its `ctrl+b` prefix.
- Set `herdr-terminal-backend` to `agent-windows`. That backend needs no TUI.

## A plain shell pane has no buffer

**Symptom.** Under the `agent-windows` backend, a shell pane appears in the dashboard but has no
Emacs buffer.

**Cause.** The command `herdr agent attach` refuses a pane that has no agent.

**Correction.** Run `M-x herdr-adopt-shell` on the pane. Adoption reports an agent named `shell`,
which is the only condition that `agent attach` tests. Use `M-x herdr-release-shell` to undo it.

A pane that an agent creates is never adopted for you. That rule stops an agent from taking an
Emacs window for a build.

## The TUI has too little width

**Symptom.** The sidebar of the TUI is cut off, or the layout looks wrong.

**Cause.** The TUI sidebar needs 26 columns. The default display action reuses the current
window.

**Correction.** Set `herdr-display-action` to `'(display-buffer-full-frame)`. That value deletes
your other windows. A side window is the other option.

## Every agent shows the status `idle`

**Symptom.** The modeline shows no counts. The dashboard shows `idle` for an agent that works.

**Cause.** You have no agent integration. Without one, herdr reads the status from the terminal
title with a regular expression. The heuristic is weak.

**Correction.**

```bash
herdr integration install claude
herdr integration status
```

The first command writes a hook file into the configuration directory of the agent.

## `make test` fails and names `EXTRA_LOAD_PATH`

**Symptom.** The build stops with an error that names `EXTRA_LOAD_PATH`.

**Cause.** The test target found no `magit-section` or no `transient`. The targets run
`emacs -Q`, which reads no init file.

**Correction.** Point the variable at your package directories:

```bash
B=~/.emacs.d/var/elpaca/builds   # change for your package manager
DEPS="$B/magit-section $B/compat $B/dash $B/llama $B/transient $B/cond-let"

make test EXTRA_LOAD_PATH="$DEPS"
```

Nothing skips. The suite runs in full, or it stops and tells you why.

## The modeline shows `*invalid*`

**Symptom.** The modeline shows `*invalid*` in place of the herdr segment.

**Cause.** The segment returned a value that Emacs cannot render.

**Correction.** Report the fault. Note that the test suite cannot catch this. Both suites run in
batch, and a batch Emacs has no frame. See [Contributing](../CONTRIBUTING.md).
