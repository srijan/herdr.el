# Commands

Each curated command wraps a server method. The command `herdr-call` reaches every method the
server has.

The list is short on purpose. A command exists here only if the dashboard or `herdr-command-map`
calls it. Anything else is an `M-x herdr-call` away.

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
| `herdr-call` | Call any server method. |
| `herdr-modeline-mode` | Show the agent counts in the modeline. |

## Connections

| Command | Function |
|---|---|
| `herdr-connect` | Follow a second server on this machine, by its socket path. |
| `herdr-connect-remote` | Follow a server on another machine, over SSH. Offers the machines saved with `herdr machine`. |
| `herdr-disconnect` | Stop following a connection, and take its SSH forward down. |

Nothing connects when Emacs starts. `herdr-start` makes the local connection when you first
ask for anything; the others are made only when you name them.

Disconnecting is deliberate and therefore final: the retries stop with it. A connection whose
stream merely drops keeps being retried, because nothing said to stop.

See [Remote servers](configuration.md#remote-servers).

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

Under `use-package`, use `:bind-keymap`. `herdr-command-map` is a keymap, not a command, so
`:bind` does not take it:

```elisp
:bind-keymap ("C-c H" . herdr-command-map)
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

`herdr-new-terminal` asks where first. It offers each open workspace by id and every `project.el`
project by path. An open project appears both ways. Selecting either choice adds a new tab to its
workspace. Selecting an unopened project creates its workspace and opens the root pane.

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
| `herdr-workspace-close` | `workspace.close` | Close a workspace, asking before closing its group. |
| `herdr-workspace-focus` | `workspace.focus` | Focus a workspace and follow it in Emacs. |
| `herdr-workspace-rename` | `workspace.rename` | Give a workspace a new label. |

A workspace has a working directory as its key. A workspace stays across a restart of the
server. herdr.el shows workspaces under both backends.

Closing a workspace that has linked worktree workspaces closes the whole group, and herdr
refuses to do it unless you say so. `herdr-workspace-close` asks a second question when that
happens; answering no leaves everything open. A workspace with no worktrees is closed by the
first answer and never asks twice.

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
| `herdr-agent-send-keys` | `agent.send_keys` | Send key presses to an agent. |
| `herdr-agent-rename` | `agent.rename` | Name an agent, or clear its name. |

`herdr-agent-prompt` sends the region when one is active, and the whole buffer under
`C-u`. With neither, it asks you to type the prompt. This is the half of prompting that Emacs
is better at than a terminal: the prompt is usually a function, a failing test or a diff that is
already on screen.

herdr refuses a prompt to an agent that is already **blocked**, answering `agent_blocked` before
sending anything, so a question waiting on screen is never answered by accident. It also refuses
a pane whose agent is not the foreground process, with `agent_not_ready` — a plain shell that was
merely *reported* as an agent is not enough.

`herdr-agent-send-keys` is what answers a blocked agent, since a prompt cannot. It takes
whitespace-separated key names — `y`, `n`, `Enter`, `esc` — and sends them as they are. `esc` is
herdr's canonical spelling for Escape, though it accepts `escape` too. From the dashboard, `a`
names the agent in its prompt: this is the one verb that answers a question somebody else is
being asked, and answering the wrong agent is the mistake worth making hard.

`herdr-agent-rename` names an agent. **A name is not a label.** The pane's label is what the pane
is *doing* and moves as the work moves; the agent's name is what you *call* it, and herdr takes one
anywhere it takes a target — `agent.get`, a prompt, a wait. In Emacs it is also what stops a buffer
name moving: `herdr-pane-identity` prefers it over everything else, so a named agent keeps
`*herdr: reviewer*` however its terminal title churns.

Clearing a name means giving an empty one. herdr requires a name to start with a lowercase letter
and to hold only lowercase letters, digits, `-` or `_`, and refuses one already in use with
`agent_name_taken`.

herdr publishes no event when an agent is renamed, so the reply is the only news of one. herdr.el
folds it into the cache itself; a name set outside Emacs appears at the next snapshot instead.

To run an agent, open a terminal with `herdr-new-terminal` and run the agent in it. herdr detects
the agent and names the pane a few seconds later. This is the mechanism the herdr TUI uses, and
it is the only one here.

An agent is reached as a pane. `herdr-pane-read` and `herdr-pane-focus` take a pane target, and
the dashboard names both on the row.

## The escape hatch

`M-x herdr-call` asks you for a method, then asks you for each parameter. It reads the parameter
names, the types and the enumerated values from the schema of the server. herdr.el therefore
needs no generated menu, and no method is out of reach.

`herdr-call` has no key. It is the surface of last resort, and the reason the curated list can
stay short.

`herdr.el` requires `herdr-call.el` explicitly. Nothing else pulls it in, and the test suite
cannot tell you so: the suite loads every file itself, so `herdr-call` answers `fboundp` either
way.
