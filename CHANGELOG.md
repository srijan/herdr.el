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
  workspaces and panes. Every command is reachable from it, and each command acts on the
  item under point. Two new files hold it: `herdr-tree.el` builds the tree as data, and
  `herdr-dispatch.el` renders the tree with `magit-section`.
- **An `Inactive` section.** The dashboard lists each `project.el` project that has no open
  workspace. Press `RET` on a row to create the workspace. The rows are dimmed and carry their
  own git worktrees. A worktree you have also opened as a project in Emacs gets no row of its
  own: it is listed under the repository it belongs to, once, instead of drawing a second copy
  of that repository's whole worktree list. A project whose directory has been deleted gets no
  row either -- project.el remembers a project until told to forget one, and nothing tells it
  when a directory goes away. Use `project-forget-zombie-projects` to drop them from project.el
  itself.
- **Worktree detail.** Each worktree row shows its branch and its directory. The branch column
  sizes itself to the widest branch in the session. A worktree you have open as a workspace of
  its own is drawn there in full -- its panes, its label, its status -- instead of as a dimmed
  row pointing at a second copy of it at the top level. The top level is one row per repository.
  A worktree hangs off its workspace directly rather than under a `worktrees (N)` heading. A
  workspace that has worktrees holds its own panes in a `main (N)` group beside them, so the two
  kinds of row are never mistaken for each other, and the count on the workspace row is its
  checkouts -- its own plus one per worktree -- with the pane count on the group that holds the
  panes:

  ```
  herdr.el (2)
    main (2)
      claude
      shell
    project-el (1)
      claude
  ```

  A workspace with no worktrees has no group: its panes hang off its own row. The group only
  ever existed to tell panes from checkouts, and where there are no checkouts beside them it
  described a plugin workspace -- the Lantern chat arrives as one -- as something it is not.

  An inactive project row gets the same treatment: a `main` row for the repository's own
  checkout, its worktrees beside it, and its own count. The row folds, so a repository of
  sixteen checkouts collapses to one line. Press `n` on any of those rows to open a terminal in
  that directory -- opening it as a workspace first if nothing is open there yet.
- **`herdr-command-map`.** A prefix keymap holding the verbs the dashboard holds, for use from
  anywhere else: `s` the status buffer, `f` go to a pane, `n` open a terminal, `k` close one,
  `w` go to a workspace, `p` the project workspace, `%` create a worktree, `g` resync. Bind it
  yourself, the way `project-prefix-map` is bound. The letters are the dashboard's letters, so
  there is one set to learn rather than two. There is no help key: `C-h` after the prefix lists
  the bindings already.
- **`herdr-dispatch-create-terminal`**, renamed from `herdr-dispatch-create-pane`. It creates a
  tab in the usual case but a whole workspace on a row whose directory has none open, so neither
  `pane` nor `tab` named it. What it always produces is a terminal, which is what the docs and
  the key table already called it, and what `herdr-new-terminal` is called.
- **`herdr-dispatch-display-action`.** The dashboard takes the frame rather than splitting a
  window. A pane row has four columns and the last two carry the news -- the pane id, and what
  the agent reports it is working on -- so half a frame cuts off the part worth reading. Taking
  the frame deletes the other windows and `q` does not bring them back, which is why this is an
  option: set it to nil for the old splitting behaviour.
- **`herdr-new-terminal`.** Opens a terminal, asking where first: an open workspace, or a
  `project.el` project with no workspace open, which is created and then opened in.
- **A test suite.** 460 hermetic tests across 15 files, and a live suite that includes a schema
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
- **The dashboard tree flattened to two levels.** Workspace and pane only; a tab no longer gets
  its own row, since herdr's own attach client, `herdr terminal attach`, now takes any pane and
  no longer needs an agent first. `n` creates a terminal as a fresh tab directly, and `t` is gone
  from the dashboard keymap; `herdr-tab-create` and the tab commands remain reachable from
  `herdr-transient-tab` for TUI users.
- **One way to make a place to run something.** The dashboard's `n` now resolves a row that names
  a directory -- a worktree, a `main` row, an inactive project -- and opens the terminal there.
  Before, it resolved to nothing, and a nil `workspace_id` makes `tab.create` fall back to
  whatever workspace the server has focused: `n` on an inactive project quietly opened a terminal
  in some other repository, with nothing on screen saying where it went. The directory row wins
  over any enclosing workspace, so a worktree inside an open repository does not land in the
  repository it sits under.
- **The dashboard no longer opens a terminal somewhere you were not pointing.** `n` on the
  `Inactive (N)` heading, or on the dashboard's own header line, resolved to no workspace, and a
  nil `workspace_id` makes `tab.create` fall back to whatever the server has focused. Both are
  now refused, the way every other verb already refused them.
- **A reported agent no longer controls whether a pane is attachable.** Every pane already is.
  `herdr-adopt-shell` and `herdr-release-shell` still work, and still put a pane in herdr's own
  agent list — the modeline count, the agent picker and notifications — but nothing needs them
  for a shell pane to get an Emacs buffer.

### Removed

- **The `pane.updated` subscription.** The event fires about 7.5 times each second and carries a
  full pane record, but it stops exactly when an agent becomes idle. Connection B now carries
  the statuses, and `herdr-state-reconcile-panes` carries the rest.
- **The `session` terminal backend.** It ran the herdr TUI in one ghostel buffer and let herdr
  own the layout. `ghostel-project`, or any shell, runs the herdr CLI just as well, and keeping
  it meant every function in `herdr-term.el` branching on which backend was in force.
  `herdr-terminal-backend` is gone with it; drop it from your configuration. Panes get one
  buffer each, which is what `agent-windows` always did.
- **The tab cache.** The `tabs` and `focused-tab-id` slots, `herdr-state-tabs`,
  `herdr-state-reconcile-tabs`, its `tab.list` round trip on every poll, the five `tab.*` event
  subscriptions and their merge and move handling. Nothing outside `herdr-state.el` ever read a
  tab record: the dashboard flattened tabs away and the tab commands are gone, so this was 43
  lines maintained for no reader. Creating a tab still works -- `tab.create` answers with its
  root pane, which is all the caller wants -- and a closing tab reaches you as `pane.closed`.
- **The dashboard's `f`.** It focused server-side and deliberately did not move Emacs, which
  means something only when a second client is watching: the herdr TUI in a real terminal,
  repainting to the newly focused pane. Every pane is its own Emacs buffer here, and `RET` makes
  the same call and takes you there.
- **`herdr-state-attachable`.** An identity function over `herdr-state-panes` with one caller.
  It said something while attaching was conditional; since herdr 0.8.2 it does not.
- **`transient` from `Package-Requires`.** The dashboard's `c` create menu was the last
  transient prefix in the package. It offered the same three verbs as `w`, `n` and `%` directly,
  plus three arguments: `--directory` and `--label` only skipped a prompt, and `--label` skipped
  one that was never asked, since herdr names a workspace after its directory. The third,
  `--base`, was the one capability -- a worktree off something other than the current HEAD -- and
  it is the second prompt of `herdr-dispatch-create-worktree` now, where RET is the answer for
  the ordinary case.

  Declared, not needed: `magit-section` requires `transient` itself, and Emacs has shipped one
  since 28.1, so it loads in any session that draws the dashboard. What changed is that no file
  here names it. Nothing changes at install time.
- **Twenty-eight commands and the transient menu.** A command now exists only if the dashboard or
  `herdr-command-map` calls it, which leaves eleven. Gone: `herdr-transient` and its six
  sub-menus; the TUI layout commands `herdr-pane-split-right`/`-down`, `-zoom`, `-resize` and
  `-swap`, which move nothing under `agent-windows` because Emacs owns the layout there; the four
  `herdr-tab-*` commands, already hidden under that backend since a tab's only visual form is the
  TUI's tab bar; the scripting commands `herdr-pane-run`, `-send-text`, `-wait-for-output` and
  `herdr-agent-wait`, which the herdr CLI and the agent skill both cover; `herdr-agent-read` and
  `herdr-agent-focus`, the same calls as their pane equivalents with a different target type;
  `herdr-agent-explain`, `herdr-notification-show`, `herdr-worktree-list` and
  `herdr-worktree-open`; and the adoption pair `herdr-adopt-shell`/`herdr-release-shell` with
  `herdr-adopt-created-shells` and `herdr-shell-agent-name`, obsolete since herdr 0.8.2.

  None of it became unreachable. `M-x herdr-call` prompts its way to all 91 methods from the
  server's own schema, and that is what makes deleting a wrapper safe rather than lossy -- the
  reason `herdr-call.el` and `herdr-schema.el` stayed while so much around them went.
- **`agent.start`, and everything that served it.** Gone: the command `herdr-agent-start`, the
  dashboard's `a` key and its `herdr-dispatch-create-agent` verb, the create menu's agent entry
  and `--kind` argument, the option `herdr-agent-kinds`, and the picker
  `herdr-select-available-shell` with its `＋ new terminal` entry. herdr's own TUI has one
  mechanism -- a new tab opens a shell, and the agent is whatever you run in it, which herdr
  names by detection a few seconds later. This package carried a second, differently shaped door
  to the same place: one that demanded a kind and a name up front and could only take a pane with
  no agent on it. `herdr-call` still reaches `agent.start` if you want it.
- **`herdr-menu`.** Its whole value was guaranteeing the start sequence before the compact menu.
  `herdr-command-map`'s `s` runs the start sequence and `?` reaches the menu, so a second entry
  point whose content was "the same thing but ending elsewhere" is duplication the prefix exists
  to remove.
- **`herdr-promote-shell`, and the poll behind it.** herdr relabels a pane on its own when an
  agent starts in it, so both existed to force a relabel that already happens. The poll called
  `agent.explain` on every reported shell at every directory poll: 936 calls in one session, three
  quarters of all the traffic that herdr.el sent. The one case that does not relabel itself is a
  report applied to a pane where an agent was already running -- see the troubleshooting guide.
  Kill the pane and start the agent again.

### Fixed

- **Closing a pane no longer throws point to the end of the dashboard.**
  `herdr-dispatch--position-restore` answered nil when point's section was one the
  redraw no longer builds, and the caller skipped its `goto-char` — leaving point wherever
  `erase-buffer` and the inserts had put it. Point now falls back to the nearest surviving
  ancestor, so closing a pane leaves you on its workspace. Both halves of the restore are
  fixed, the buffer's point and each window's.

  Closing a workspace's *last* pane closes the workspace too, so there is no surviving
  ancestor but the root — whose start is the header line, at the top of the buffer. The walk
  stops short of the root and uses the saved buffer position instead, which lands on whatever
  took the dead row's place.

  Separators are handled at the other end, when the position is saved. The blank line between
  two top-level rows belongs to the root section, so restoring it went to the root's start —
  the header. Parking point between two workspaces and letting any redraw fire therefore sent
  it to the top, with nothing closing and nothing dying; redraws fire on their own, since the
  header carries a status summary. A separator now saves the nearest row instead, which has an
  identity to restore and survives the row above it changing width. The header line itself is
  the root legitimately and stays where it is.

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
