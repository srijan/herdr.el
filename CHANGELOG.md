# Changelog

This file records the changes that matter to a user of herdr.el.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version numbers
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

This entry covers the whole divergence from
[eddof13/herdr.el](https://github.com/eddof13/herdr.el). It holds 82 commits. It adds about
12,900 lines and removes about 970.

### Added

- **A dashboard.** The buffer `*herdr-agents*` now shows the session as a foldable tree of
  workspaces, tabs and panes. Every command is reachable from it, and each command acts on the
  item under point. Two new files hold it: `herdr-tree.el` builds the tree as data, and
  `herdr-dispatch.el` renders the tree with `magit-section`.
- **An `Inactive` section.** The dashboard lists each `project.el` project that has no open
  workspace. Press `RET` on a row to create the workspace. The rows are dimmed and carry their
  own git worktrees.
- **Worktree detail.** Each worktree row shows its branch and its directory. The branch column
  sizes itself to the widest branch in the session.
- **`herdr-menu`.** The command runs the same start sequence as `herdr` but ends on the compact
  menu. Use it from inside a terminal buffer, where a full-window dashboard is the wrong result.
- **A test suite.** 473 hermetic tests across 16 files, and a live suite that includes a schema
  drift test.
- **Dependency resolution for the build.** `test/herdr-deps.el` finds `magit-section` and
  `transient` in the directories of `elpaca`, `package.el` and `straight.el`. A missing
  dependency is now a hard error that names `EXTRA_LOAD_PATH`.

### Changed

- **herdr 0.8.2 and protocol 20.** Upstream targets protocol 19.
- **`magit-section` 3.3 is now a hard dependency.** The dashboard is built on it.
- **The modeline moved to `herdr-modeline.el`.** The command is now `herdr-modeline-mode`. The
  old name `herdr-agents-mode-line-mode` still works as an obsolete alias.
- **Workspaces and tabs are now reconciled against the server.** Before, only panes were. Ghost
  workspaces therefore collected for the life of a session. The new functions are
  `herdr-state-reconcile-workspaces` and `herdr-state-reconcile-tabs`.
- **A directory renders with `~/`.** The abbreviation is for display only. A command still uses
  the real path.
- **`herdr-state-workspace-for-directory` is now public.** Both `herdr-project` and the
  `Inactive` section use it.

### Removed

- **The `pane.updated` subscription.** The event fires about 7.5 times each second and carries a
  full pane record, but it stops exactly when an agent becomes idle. Connection B now carries
  the statuses, and `herdr-state-reconcile-panes` carries the rest.
- **`herdr-promote-shell`, and the poll behind it.** The command rested on a belief that a
  reported agent outranks detection. That belief was false. The poll called `agent.explain` on
  every adopted shell at every directory poll: 936 calls in one session, which was three
  quarters of all the traffic that herdr.el sent, to force a relabel that herdr already did.

### Fixed

- **A slow server no longer freezes Emacs.** Every synchronous call on a timer now binds
  `herdr-rpc-timeout` to `herdr-rpc-background-timeout`, which is 2 seconds.
- **A busy server no longer makes the dashboard flicker.** Redraws now group inside
  `herdr-dispatch-refresh-debounce`.
- **A wedged server is now noticed** instead of leaving the editor to wait.
- **Rename and move events are no longer dropped.** These events carry no nested record.
  herdr.el read a `workspace`, `tab` or `pane` object out of them, so the events did nothing.
- **A repository no longer lists its own checkout as a worktree.**
- **A worktree row that is the workspace above it is now refused.**
- **A closed workspace now drops its cached worktree listing.**
- **A working agent no longer loses the section highlight.**
- **Every dashboard face is now written under both face properties.** One property alone left
  some rows unstyled.
- **An unparseable directory name no longer outranks every version** in the dependency search.
- **The dependency search now takes the newest copy** when it finds more than one.

### Documentation

- A new `docs/` directory holds a getting-started guide, a command reference, a configuration
  reference, an architecture note, protocol notes and a troubleshooting guide.
- The original design documents and implementation plans moved to `docs/history/`. They record
  the design at their date and are not current documentation.
- The README states the relationship to upstream, and it corrects several facts that the code
  had already corrected.
