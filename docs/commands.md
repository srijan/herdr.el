# Commands

herdr.el has 11 curated commands. Each curated command wraps one server method. The command
`herdr-call` reaches all 91 methods of the server.

The list is short on purpose. A command exists here only if the dashboard or `herdr-command-map`
calls it. Everything else was deleted, because `herdr-call` reaches it. See
[What was removed](#what-was-removed).

Every command that acts on a pane uses this rule to find its target:

1. If the current buffer is a herdr terminal, the command uses the pane of that buffer.
2. If the current buffer is not a herdr terminal, the command uses the pane that herdr focuses.
3. If you give a prefix argument (`C-u`), the command asks you for the target.

The dashboard shows the target on the row you act from. The target is therefore never a guess.

## Entry points

| Command | Function |
|---|---|
| `herdr` | Start herdr and open the dashboard. |
| `herdr-start` | Start the server, the terminals and the event stream. |
| `herdr-stop` | Stop the event stream and remove the Emacs buffers. The server continues. |
| `herdr-project` | Focus the workspace of the current project, or create it. |
| `herdr-agents` | Open the dashboard. |
| `herdr-call` | Call any of the 91 server methods. |
| `herdr-modeline-mode` | Show the agent counts in the modeline. |

`herdr-stop` does not stop your agents. The herdr server is a daemon, and the agents belong to
the server.

`herdr-agents` does not run the start sequence. From a cold Emacs, the dashboard therefore opens
with an empty cache. Run `herdr` instead. The key `C-c H s` runs `herdr` for this reason.

## The prefix keymap

`herdr-command-map` holds the verbs the dashboard holds, for use from anywhere else. Bind it
yourself:

```elisp
(define-key global-map (kbd "C-c H") herdr-command-map)
```

| Key | Command |
|---|---|
| `s` | `herdr` |
| `f` | `herdr-pane-focus` |
| `n` | `herdr-new-terminal` |
| `k` | `herdr-pane-close` |
| `w` | `herdr-workspace-focus` |
| `p` | `herdr-project` |
| `%` | `herdr-worktree-create` |
| `g` | `herdr-state-resync` |

The letters are the letters the dashboard uses. The target comes from a picker here, and from
point in the dashboard.

## Terminals

| Command | Method | Function |
|---|---|---|
| `herdr-new-terminal` | `tab.create`, `workspace.create` | Open a terminal in a workspace or a directory. |

`herdr-new-terminal` asks where first. It offers each open workspace by id, and each `project.el`
project with no workspace open by path. A workspace gets a new tab. A directory is opened as a
workspace, and the terminal is that workspace's root pane.

A worktree appears in the list only when project.el knows it as a project. The command does not
ask the server for worktrees, because `worktree.list` needs a directory inside a repository that
is already open. To open a terminal in a worktree the server knows about, press `n` on its row in
the dashboard.

This is the one way to make a place to run something. To run an agent, run the agent in the
terminal. See [Agents](#agents).

## Panes

| Command | Method | Function |
|---|---|---|
| `herdr-pane-close` | `pane.close` | Close the target pane. |
| `herdr-pane-rename` | `pane.rename` | Give the target pane a new label. |
| `herdr-pane-focus` | `pane.focus` | Focus the pane and select its buffer. |
| `herdr-pane-read` | `pane.read` | Put the output of the pane into a buffer. |

`herdr-pane-read` accepts a source. The source `recent_unwrapped` removes the line wrapping of
the terminal. Use that source when you want to search the result.

## Workspaces

| Command | Method | Function |
|---|---|---|
| `herdr-workspace-create` | `workspace.create` | Create a workspace at a directory. |
| `herdr-workspace-close` | `workspace.close` | Close a workspace. |
| `herdr-workspace-focus` | `workspace.focus` | Focus a workspace and follow it in Emacs. |
| `herdr-workspace-rename` | `workspace.rename` | Give a workspace a new label. |

A workspace has a working directory as its key. A workspace stays across a restart of the
server. herdr.el shows workspaces under both backends.

## Worktrees

| Command | Method | Function |
|---|---|---|
| `herdr-worktree-create` | `worktree.create` | Create a worktree and open it as a workspace. |
| `herdr-worktree-remove` | `worktree.remove` | Remove a worktree workspace. |

herdr has native support for git worktrees. `herdr-worktree-create` therefore takes a branch
name and gives you a worktree with its own workspace.

The method `worktree.list` needs a directory inside a repository that is already open. The
server cannot find a repository that has no open workspace.

## Agents

| Command | Method | Function |
|---|---|---|
| `herdr-agent-prompt` | `agent.prompt` | Send a prompt to an agent. |

There is no command for `agent.start`. To run an agent, open a terminal with
`herdr-new-terminal` and run the agent in it. herdr detects the agent and names the pane a few
seconds later. This is the mechanism the herdr TUI uses, and it is now the only one here.

There is no command to read or focus an agent by name either. `herdr-pane-read` and
`herdr-pane-focus` are the same calls with a pane as the target, and the dashboard names both on
the row.

## What was removed

Twenty-eight commands and the transient menu were deleted. A command survives only if the
dashboard or `herdr-command-map` calls it.

| Removed | Reason |
|---|---|
| `herdr-transient` and its six sub-menus, `herdr-menu` | A third surface over commands the dashboard and the prefix keymap already reach. |
| The dashboard's `c` create menu | The same three verbs as `w`, `n` and `%`, plus three arguments. Two of them only skipped a prompt. The third is the base ref of a worktree, which is a prompt now. |
| `herdr-pane-split-right`, `herdr-pane-split-down`, `herdr-pane-zoom`, `herdr-pane-resize`, `herdr-pane-swap` | Layout of the TUI. The `agent-windows` backend gives the layout to Emacs. These commands then move nothing that you see. |
| `herdr-tab-create`, `herdr-tab-close`, `herdr-tab-focus`, `herdr-tab-rename` | A tab has one visual form only, which is the tab bar of the TUI. The `agent-windows` backend already hid these commands. |
| `herdr-pane-run`, `herdr-pane-send-text`, `herdr-pane-wait-for-output`, `herdr-agent-wait` | Scripting of the session. The herdr CLI and the agent skill both do this already. |
| `herdr-agent-read`, `herdr-agent-focus` | The same call as the pane command, with a different type of target. |
| `herdr-agent-explain` | A debugging aid for the detection of agents. |
| `herdr-worktree-list`, `herdr-worktree-open` | The dashboard gets its own worktrees. `RET` on a worktree row opens it. |
| `herdr-notification-show` | A notification on the herdr side, which nothing here needs. |
| `herdr-adopt-shell`, `herdr-release-shell` | Obsolete since herdr 0.8.2, when every pane became attachable. |

Nothing is out of reach. `M-x herdr-call` still calls each of these methods. It asks you for each
parameter from the schema of the server.

## The escape hatch

`M-x herdr-call` asks you for a method, then asks you for each parameter. It reads the parameter
names, the types and the enumerated values from the schema of the server. herdr.el therefore
needs no generated menu of 91 entries, and no method is out of reach.

`herdr-call` has no key. It is the surface of last resort, and it grew more necessary as the
curated list got shorter: each of the 28 removed commands is one `M-x herdr-call` away.
