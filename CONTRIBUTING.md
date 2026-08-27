# Contributing

Thank you for your interest in herdr.el. This document tells you how to build the package, how
to test it, and how to send a change.

## Before you start

Read [`docs/architecture.md`](docs/architecture.md). It gives the file map, the data flow and the
rules that a change must follow.

Read [`docs/protocol.md`](docs/protocol.md) if your change touches the socket API. It records
behaviour of the server that the herdr documentation does not state.

## Build and test

```bash
make compile     # byte-compile. A warning stops the build.
make test        # 466 tests. No herdr server is necessary.
make test-live   # more tests. A herdr server is necessary.
```

`make test` is hermetic. It uses a fake server, so it needs no herdr and touches no machine
state. Every test must stay hermetic. If your test can read a file, an environment variable or a
project list, stub that source.

`make test-live` runs against a real server. It includes a drift test. The drift test compares
each curated command against the schema of the server, and names the command that broke. The
round-trip test leaves the session exactly as it found it.

## Dependencies and `EXTRA_LOAD_PATH`

Both targets run `emacs -Q -L .`. That command starts no package system and reads no init file,
so `magit-section` is absent from the load path.

Each target therefore loads `test/herdr-deps.el` first. That file searches the package
directories of `elpaca`, `package.el` and `straight.el`, and puts the dependencies on the load
path. A missing `magit-section` is a hard error, and the error names `EXTRA_LOAD_PATH`.

Nothing skips. `make test` runs the whole suite or stops and tells you why. `make compile`
compiles every source file, including `herdr-dispatch.el`.

To test against a specific checkout, set the variable. It goes on the load path first, and it
wins:

```bash
B=~/.emacs.d/var/elpaca/builds   # change for your package manager
DEPS="$B/magit-section $B/compat $B/dash $B/llama $B/transient $B/cond-let"

make test    EXTRA_LOAD_PATH="$DEPS"
make compile EXTRA_LOAD_PATH="$DEPS"
```

`magit-section` is the one dependency that herdr names. `compat`, `dash`, `llama`, `cond-let` and
`transient` are what it needs. Emacs ships a `transient` from version 28.1, so its absence cannot
stop the build; it is searched for because `magit-section` asks for a recent one.

## The blind spot of the test suite

Both suites run in batch. A batch Emacs has no frame. The suites therefore cannot catch these
faults:

- A modeline that renders `*invalid*`.
- A command that splits a window.
- A `require` that nothing pulls in any more. Every file is loaded by the suite itself, so a
  function that is only reachable through a deleted file still answers `fboundp`.

Several faults passed a green suite. A person found them by driving a real Emacs under a PTY.

**When your change touches a window, a buffer or the modeline, run it in a real frame as well.**
A green suite is not enough.

## Rules for the code

- Emacs 28.1 is the floor. Do not use a function that arrived in Emacs 29.
- A warning stops the build. Declare each external function with `declare-function`, and each
  external variable with `defvar`.
- Every file starts with `-*- lexical-binding: t; -*-`. Every file ends with `(provide 'FEATURE)`
  and a `;;; FILE ends here` line.
- A synchronous call on a timer must bind `herdr-rpc-timeout` to `herdr-rpc-background-timeout`.
  A slow server must never freeze the editor.
- Put new logic in `herdr-tree.el`, not in `herdr-dispatch.el`. The pure half needs no socket and
  no display to test.

## Test-driven work

Write the test first. The test must fail for the right reason before you write the code.

A new command needs three tests at least:

1. The command sends the correct method and the correct parameters.
2. The command finds its target under each of the three targeting rules.
3. The command refuses a target that it cannot act on.

## Documentation

Update the documentation in the same change as the code.

- A new user option goes in [`docs/configuration.md`](docs/configuration.md).
- A new command goes in [`docs/commands.md`](docs/commands.md).
- A new fact about the server goes in [`docs/protocol.md`](docs/protocol.md).
- A new symptom goes in [`docs/troubleshooting.md`](docs/troubleshooting.md).

Write the documentation in Simplified Technical English. Keep sentences short. Use the active
voice. Use one word for one meaning, and keep that word through the document.

When you correct a fact in `docs/protocol.md`, keep the old fact visible with a strikethrough.
A deleted wrong fact returns, because the next reader derives it again from the same weak
evidence.

## Commits and pull requests

- Write a subject line that names the outcome. Do not list the files.
- Keep one logical change in one commit.
- Run `make compile`, `make test` and `make test-live` before you open a pull request. State the
  result in the description.
- Say what you ran in a real frame, and what you did not.

## Relationship to upstream

Upstream is [eddof13/herdr.el](https://github.com/eddof13/herdr.el). This repository is a fork
that has diverged by about 15,400 lines added and 2,600 removed, over 123 commits. A rebase onto
upstream is no longer realistic.

Send a change here. If the change also suits upstream, say so, and we can carry it over.

## Reporting a fault

Include these items:

1. Your Emacs version, from `M-x emacs-version`.
2. Your herdr version, from `herdr --version`.
3. The values of `herdr-display-action` and `herdr-dispatch-display-action`.
4. The exact message, or a screenshot of the dashboard.
5. Whether the fault survives a reconcile. Press `g`, then wait five seconds.

Item 5 separates a real fault from the replay effect that
[Protocol notes](docs/protocol.md#the-server-replays-its-full-event-ring) describes.
