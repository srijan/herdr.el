# Getting started

This document tells you how to install herdr.el and how to do the first tasks.

## Before you start

You must have these items:

- Emacs 28.1 or a later version.
- [herdr](https://herdr.dev) 0.8.2. This version speaks protocol 20.
- The Emacs packages `ghostel` and `magit-section`. (`magit-section` requires `transient`, which
  Emacs ships from version 28.1.)

To find your herdr version, use this command:

```bash
herdr --version
```

If you have a different version of herdr, herdr.el shows a warning one time. herdr.el continues
to run. Some commands can behave incorrectly.

## Step 1: Install the Emacs packages

herdr.el is not on MELPA. Get the code with `git`:

```bash
git clone https://github.com/srijan/herdr.el ~/src/herdr.el
```

Install `ghostel` from [its repository](https://github.com/dakra/ghostel). Install
`magit-section` from MELPA or from GNU ELPA.

## Step 2: Configure Emacs

Put this form in your init file:

```elisp
(use-package herdr
  :ensure nil                          ; a local checkout, not MELPA
  :load-path "~/src/herdr.el"
  :bind (("C-x M" . herdr)
         ("C-c H" . herdr-command-map)
         :map project-prefix-map
         ("h" . herdr-project))
  :custom (herdr-terminal-backend 'session)
  :config (herdr-modeline-mode 1))
```

The `:ensure nil` line is necessary if you set `use-package-always-ensure`. Without the line,
Emacs looks for herdr on MELPA. Emacs then fails at start.

## Step 3: Start herdr

Type `M-x herdr`.

The command does these operations in sequence:

1. It starts the herdr server if the server does not run.
2. It opens the terminal buffers.
3. It connects the event stream.
4. It opens the dashboard in the buffer `*herdr-agents*`.

For one or two seconds, the dashboard can show panes that do not exist. The panes have the
status `unknown`. This is a known effect of the herdr server. The dashboard corrects itself.
For the cause, see [Protocol notes](protocol.md#the-server-replays-its-full-event-ring).

## Step 4: Read the dashboard

The dashboard shows the session as a tree. The top level is one row per repository. A workspace
with worktrees holds its own panes in a `main` group, and hangs its worktrees off itself beside
that group. A workspace with no worktrees hangs its panes off its own row.

```
herdr.el (2)                          ~/src/herdr.el/
  main (2)
    · claude    working   wS:p1       Fix the reconcile order
      shell     idle      wS:p2
  feat-dispatch (1)                   ~/src/herdr.el-worktrees/feat-dispatch/
    · claude    idle      w19:p1      Nest worktrees under their repository

example-api (1)                       ~/src/example-api/
  · shell       idle      wA:p1       npm run watch

Inactive (14)
  other-api (1)                       ~/src/other-api/
    main                              ~/src/other-api
```

Read the counts this way: a repository row counts its checkouts, its own plus one per worktree.
Where a `main` group is drawn, it counts the panes it holds. Here `herdr.el` has two checkouts —
itself and the worktree `feat-dispatch`, which is open as a workspace and so is drawn in full
rather than as a one-line pointer. `example-api` has one checkout and no worktrees, so it has no
`main` group and its pane sits directly under it.

A closed section shows the worst status inside it. A closed section therefore never hides a
blocked agent.

The `Inactive` section lists the `project.el` projects that have no open workspace. Press `RET`
on one row to create the workspace, or `n` on any checkout under it to open a terminal there.

## Step 5: Do the first tasks

| Task | Keys |
|---|---|
| Go to the pane at point | `RET` |
| Open or close a section | `TAB` |
| Create a workspace | `w` |
| Create a terminal | `n` |
| Send a prompt to the agent at point | `p` |
| Read the output of the pane at point | `r` |
| Rename the item at point | `R` |
| Close the item at point | `k` |
| Refresh the dashboard | `g` |

## Step 6: Install an agent integration

Without an integration, herdr reads the agent status from the terminal title. The heuristic is
weak. Most agents stay at the status `idle`.

With an integration, the agent reports its own status to the server. The status is then `idle`,
`working` or `blocked`.

```bash
herdr integration install claude
herdr integration status
```

The first command writes a hook file into the configuration directory of the agent. For Claude,
the file is `~/.claude/hooks/herdr-agent-state.sh`.

The integration makes the modeline and the dashboard accurate.

## Next steps

- Read [Commands](commands.md) for the full command list.
- Read [Configuration](configuration.md) to change the defaults.
- Read the `agent-windows` section of the main [README](../README.md) if you want your agents to
  stay alive when you close Emacs.
