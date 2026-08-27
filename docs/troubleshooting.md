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

**Symptom.** Emacs reports that it cannot find `magit-section` or `ghostel`.

**Cause.** One dependency is missing.

**Correction.** Install `magit-section` 3.3 or a later version. Install `ghostel` from its
repository.

No file here names `transient`, but `magit-section` requires one and asks for a recent version.
Emacs ships a `transient` from 28.1, which is enough unless `magit-section` says otherwise at
load time.

## Emacs looks for herdr on MELPA

**Symptom.** Emacs fails at start, and the message names MELPA.

**Cause.** You set `use-package-always-ensure`, and your `use-package` form has no
`:ensure nil` line.

**Correction.** Add `:ensure nil` to the form. herdr.el is not on MELPA.

## The dashboard took the whole frame

**Symptom.** `M-x herdr` deletes your other windows. The key `q` does not bring them back.

**Cause.** `herdr-dispatch-display-action` defaults to `(display-buffer-full-frame)`. A pane row
has four columns, and the last two carry the news. Half a frame cuts them off.

**Correction.** For the splitting behaviour, set the option to nil:

```elisp
(setq herdr-dispatch-display-action nil)
```

`q` restores the buffer that this window held before. It cannot restore a window that was
deleted.

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

## A pane is labelled `shell` but is running an agent

herdr names the agent in a pane on its own, a few seconds after it starts.

One case never corrects itself: a pane that had an agent *reported* on it while something was
already running in it. The report comes from a `pane.report_agent` call, or from an older version
of herdr.el that reported one automatically.

The label then stays put indefinitely. Measured on two panes, hours apart: `agent.explain`
answered `claude` for both, with a matched detection rule and a live session id, while the pane
record went on carrying the reported `shell`.

Releasing the report does not hand the pane to detection either. A released pane sat at no agent
at all for 25 seconds. `agent.explain` then refused it outright:

```
herdr error: "agent_not_found", "agent target wA:p1 not found"
```

That method runs only against panes herdr already counts as agents, so the report was the reason
detection ran on the pane at all.

**Kill the pane and start the agent again.** A fresh pane gets its agent named correctly with no
report involved. Releasing the report alone leaves the pane with no name rather than the right
one.

Nothing in herdr.el reports an agent on its own, so this state comes from the herdr CLI or from a
`pane.report_agent` you made yourself through `herdr-call`.

## `make test` fails and names `EXTRA_LOAD_PATH`

**Symptom.** The build stops with an error that names `EXTRA_LOAD_PATH`.

**Cause.** The test target found no `magit-section`. The target runs `emacs -Q`, which reads no
init file.

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
