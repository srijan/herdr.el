# Getting started

This document tells you how to install herdr.el and how to do the first tasks.

## Before you start

You must have these items:

- Emacs 28.1 or a later version.
- [herdr](https://herdr.dev) 0.9.0. This version speaks protocol 22.
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
  :bind (:map project-prefix-map
         ("h" . herdr-project))
  :bind-keymap ("C-c H" . herdr-command-map)
  :config (herdr-modeline-mode 1))
```

The `:ensure nil` line is necessary if you set `use-package-always-ensure`. Without the line,
Emacs looks for herdr on MELPA. Emacs then fails at start.

`herdr-command-map` is a keymap, not a command. Use `:bind-keymap` for it, not `:bind`.
`C-c H` is an example. Choose a key that is free in your configuration.

herdr.el binds no key of its own. One prefix reaches every entry point, `C-c H s` included.

## Step 3: Start herdr

Type `M-x herdr`.

The command does these operations in sequence:

1. It starts the herdr server if the server does not run.
2. It opens the terminal buffers.
3. It connects the event stream.
4. It opens the dashboard in the buffer `*herdr-agents*`.

On a herdr older than 0.9.0, the dashboard can show panes that do not exist for one or two
seconds. The panes have the status `unknown`, and the dashboard corrects itself. herdr 0.9.0
removed the cause. For the explanation, see
[Protocol notes](protocol.md#the-server-replayed-its-full-event-ring-until-090).

## Step 4: Read the dashboard

The dashboard shows the session as a tree. Each workspace row names the workspace, the branch its
own checkout is on, and its directory — the three things herdr's own sidebar shows. Its panes hang
directly off it.

```
herdr.el        main                  ~/src/herdr.el/
  · claude      working   wS:p1       Fix the reconcile order
    shell       idle      wS:p2
  feat-dispatch feat/nest             ~/src/herdr.el-worktrees/feat-dispatch/
    · claude    idle      w19:p1      Nest worktrees under their repository
  ▸ worktrees (2)

example-api     main                  ~/src/example-api/
  · shell       idle      wA:p1       npm run watch
```

A repository's other checkouts sit under one `worktrees (N)` heading, folded until you press `TAB`
on it. A worktree that is open as a workspace is drawn in full in that list rather than as a
one-line pointer, which is why `feat-dispatch` shows its pane above.

The branch comes from herdr's `worktree.list`, the only reply that carries one, so it is blank
until that answer lands and for a directory that is not a git repository.

A closed section shows the worst status inside it. A closed section therefore never hides a
blocked agent.

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
| Create a git worktree | `%` |
| Refresh the dashboard | `g` |
| Leave the dashboard | `q` |

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

## Step 7: Connect a second machine, if you have one

herdr.el follows more than one server at once. A second server can be on another machine,
reached over SSH:

```
M-x herdr-connect-remote RET shadow RET RET RET
```

The first answer is a saved machine or an SSH target, the second names the connection, and the
third is a herdr session on that host — leave it empty for its default session. If you have
saved machines with `herdr machine add`, the first prompt offers them and fills in the rest.
`M-x herdr-disconnect` stops following it again, and takes the SSH forward down with it.

With a second server connected, the dashboard grows a row per server, pickers end each row with
`@name`, and the modeline counts across both. With one it all looks exactly as it did.

That host needs herdr installed and a server running on it. If nothing is running there the
connection reports `no_answer`, because the tunnel cannot tell an absent server from a wrong
path. See [Remote servers](configuration.md#remote-servers) for what each failure means, and
for the SELinux relabelling that Fedora and RHEL need.

## Next steps

- The same letters work outside the dashboard, under the prefix `C-c H`. There the target comes
  from a picker instead of from point. `C-h` after the prefix lists them.
- Read [Commands](commands.md) for the full command list.
- Read [Configuration](configuration.md) to change the defaults.
- Read the terminal-hosting section of the main [README](../README.md). Agents stay alive when you
  close Emacs, because the herdr server is a daemon.
