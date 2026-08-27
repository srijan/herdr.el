# Commands

herdr.el has 33 curated commands. Each curated command wraps one server method. The command
`herdr-call` reaches all 91 methods of the server.

Every command that acts on a pane uses this rule to find its target:

1. If the current buffer is a herdr terminal, the command uses the pane of that buffer.
2. If the current buffer is not a herdr terminal, the command uses the pane that herdr focuses.
3. If you give a prefix argument (`C-u`), the command asks you for the target.

The transient menu shows the target before you act. The target is therefore never a guess.

## Entry points

| Command | Function |
|---|---|
| `herdr` | Start herdr and open the dashboard. |
| `herdr-start` | Start the server, the terminals and the event stream. |
| `herdr-stop` | Stop the event stream and remove the Emacs buffers. The server continues. |
| `herdr-project` | Focus the workspace of the current project, or create it. |
| `herdr-agents` | Open the dashboard. |
| `herdr-transient` | Open the menu without the start sequence. |
| `herdr-call` | Call any of the 91 server methods. |
| `herdr-modeline-mode` | Show the agent counts in the modeline. |

`herdr-stop` does not stop your agents. The herdr server is a daemon, and the agents belong to
the server.

`herdr-transient` does not run the start sequence. From a cold Emacs, the menu therefore opens
with an empty cache. Run `herdr` first to make sure that the start sequence runs.

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
| `%` | `herdr-transient-worktree` |
| `g` | `herdr-state-resync` |
| `?` | `herdr-transient` |

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
| `herdr-pane-split-right` | `pane.split` | Split the target pane to the right. |
| `herdr-pane-split-down` | `pane.split` | Split the target pane downward. |
| `herdr-pane-close` | `pane.close` | Close the target pane. |
| `herdr-pane-zoom` | `pane.zoom` | Zoom the target pane, or remove the zoom. |
| `herdr-pane-resize` | `pane.resize` | Resize the split around the target pane. |
| `herdr-pane-swap` | `pane.swap` | Exchange the target pane with a neighbour. |
| `herdr-pane-rename` | `pane.rename` | Give the target pane a new label. |
| `herdr-pane-focus` | `pane.focus` | Focus the pane and select its buffer. |
| `herdr-pane-read` | `pane.read` | Put the output of the pane into a buffer. |
| `herdr-pane-send-text` | `pane.send_text` | Send text to the pane without a newline. |
| `herdr-pane-run` | `pane.send_text` | Run a command in the pane. |
| `herdr-pane-wait-for-output` | `pane.wait_for_output` | Wait for a pattern in the output. |

`herdr-pane-read` accepts a source. The source `recent_unwrapped` removes the line wrapping of
the terminal. Use that source when you want to search the result.

`herdr-pane-wait-for-output` does not block Emacs. The command reports when the pattern appears.
Use it for a task such as "tell me when the development server prints `Listening on`".

## Tabs

| Command | Method | Function |
|---|---|---|
| `herdr-tab-create` | `tab.create` | Create a tab. |
| `herdr-tab-close` | `tab.close` | Close a tab. |
| `herdr-tab-focus` | `tab.focus` | Focus a tab and follow it in Emacs. |
| `herdr-tab-rename` | `tab.rename` | Give a tab a new label. |

The `agent-windows` backend hides the tab commands. A tab has one visual form only, which is the
tab bar of the TUI. Where nothing shows a tab, herdr.el offers nothing that is tab shaped. The
command `herdr-call` still reaches the four methods.

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
| `herdr-worktree-list` | `worktree.list` | List the git worktrees for the current directory. |
| `herdr-worktree-create` | `worktree.create` | Create a worktree and open it as a workspace. |
| `herdr-worktree-open` | `worktree.open` | Open an existing worktree as a workspace. |
| `herdr-worktree-remove` | `worktree.remove` | Remove a worktree workspace. |

herdr has native support for git worktrees. `herdr-worktree-create` therefore takes a branch
name and gives you a worktree with its own workspace.

The method `worktree.list` needs a directory inside a repository that is already open. The
server cannot find a repository that has no open workspace.

## Agents

| Command | Method | Function |
|---|---|---|
| `herdr-agent-prompt` | `agent.prompt` | Send a prompt to an agent. |
| `herdr-agent-read` | `agent.read` | Put the output of an agent into a buffer. |
| `herdr-agent-wait` | `agent.wait` | Report when an agent reaches a status. |
| `herdr-agent-focus` | `agent.focus` | Focus an agent and select its buffer. |
| `herdr-agent-explain` | `agent.explain` | Show how herdr detected the agent. |

There is no command for `agent.start`. To run an agent, open a terminal with
`herdr-new-terminal` and run the agent in it. herdr detects the agent and names the pane a few
seconds later. This is the mechanism the herdr TUI uses, and it is now the only one here.

`herdr-agent-wait` does not block Emacs.

## Shells and notifications

| Command | Method | Function |
|---|---|---|
| `herdr-adopt-shell` | `pane.report_agent` | Obsolete. Name an agent on a plain shell pane, so herdr watches it. |
| `herdr-release-shell` | `pane.release_agent` | Obsolete. Undo that. |
| `herdr-notification-show` | `notification.show` | Show a notification on the herdr side. |

The first two are obsolete: every pane is attachable, and herdr names the agent in a pane on its
own. Naming one by hand still puts a long-running shell in herdr's sidebar and modeline; see
[Troubleshooting](troubleshooting.md#a-pane-is-labelled-shell-but-is-running-an-agent) for the
label it can leave behind.

## The escape hatch

`M-x herdr-call` asks you for a method, then asks you for each parameter. It reads the parameter
names, the types and the enumerated values from the schema of the server. herdr.el therefore
needs no generated menu of 91 entries, and no method is out of reach.

The transient menu has `herdr-call` on the key `:`. magit puts its own raw command on the same
key.
