# Domain language

The words this codebase uses, and what each one means here. `docs/architecture.md` says which
file does what; this says what the things are called. Keep both honest.

## The things herdr manages

**Pane** — one terminal. The unit everything else is made of. herdr owns the process; Emacs
fronts it with a ghostel buffer, and that buffer is an attachment, not the pane itself. Killing
the buffer leaves the pane running.

**Workspace** — a set of panes rooted at a working directory. Keyed by that directory, survives a
server restart, and closes when its last pane closes. Groups the dashboard.

**Worktree** — a git worktree, which may or may not have a workspace open in it. herdr reports
them per workspace; a repository's own checkout is a worktree too, drawn as the `main` row.

**Agent** — a coding assistant running in a pane. Not a separate object: a pane with an `agent`
field. It has a status (`working`, `blocked`, `done`, `idle`) and may have a name someone set
with `agent.rename`.

**Session** — everything the server currently knows, cached in `herdr-state`. Every surface draws
from the cache and never from the socket, so a redraw costs no traffic.

**Dispatcher** — the `*herdr-agents*` buffer. The dashboard, and the only place with a keymap of
its own.

**Place** — where a new terminal may go: an open workspace, or a known project root that has no
workspace yet. Only `herdr-new-terminal` uses the word.

## What a pane is called

Two questions, two answers, and conflating them is what made a picker row and its own
confirmation speak different languages.

**Name** — what a pane is *doing*: the label somebody chose for it, and the title the thing
inside announces, joined by a middle dot. It moves as the work moves, and it is empty for a
shell nobody has named that is announcing nothing. The dashboard row, the pickers, the notifier
and the confirmations all show this.

**Identity** — what you *call* a pane: the `agent.rename` name, else its label, else
`kind@workspace`, else the bare kind. Never empty, and it does not move while you look at it,
which is why buffer names are built from it and why prompts fall back to it when the name is
empty.

Both live in `herdr-pane.el`, which is also the only file that reads a pane record's fields —
`pane_id`, `terminal_id`, `display_agent` and the rest are wire names, and a rename of one is
that file's problem alone. A test asserts it. Neither name takes a cache: the two facts identity cannot read off the
pane record — the rename and the workspace's label — are passed in by whoever has one.
