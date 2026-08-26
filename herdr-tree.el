;;; herdr-tree.el --- Pure tree model for the herdr dispatcher -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; The dispatcher's tree, as data.  `herdr-tree-build' turns the state
;; cache into a nested list of (TYPE VALUE LINE CHILDREN); `herdr-dispatch'
;; walks that list emitting magit sections.
;;
;; Kept separate from the renderer, and loadable without magit-section.
;; The original reason was that `make test' ran under `emacs -Q -L .'
;; where magit-section was not on the load path, so a model living in
;; herdr-dispatch.el would not have been tested at all; that reason is
;; gone — test/herdr-deps.el finds the dependency and nothing skips —
;; but the separation earns its keep on its own.  Everything here is a
;; pure function of the state cache, testable by comparing values,
;; while the renderer can only be tested by inserting into a buffer and
;; reading text properties back.  Keeping the two apart is what lets
;; nearly all the logic be tested the cheap way.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'regexp-opt)
(require 'herdr-state)

(defconst herdr-tree-status-glyphs
  '(("working" . "▶") ("blocked" . "⏸") ("done" . "✓") ("idle" . "·"))
  "Glyph shown for each agent status.
The canonical set: the modeline segment and the dispatcher both read it,
so the two surfaces cannot disagree about what a status looks like.")

(defun herdr-tree-glyph (status)
  "Return the glyph for STATUS, or a space when it has none."
  (alist-get status herdr-tree-status-glyphs " " nil #'equal))

(defconst herdr-tree-status-faces
  '(("blocked" . warning) ("working" . font-lock-keyword-face)
    ("done" . success) ("idle" . shadow))
  "Face shown for each agent status.

Built-in faces rather than colours of our own, so that the dashboard
follows whatever theme is loaded instead of fighting it.  The four are
chosen for what each state asks of you: blocked wants attention and gets
the face Emacs already uses to ask for it, working is the one state that
is going somewhere, done is the good ending, and idle is the state most
lines are in most of the time and so is the one worth dimming.")

(defun herdr-tree-status-face (status)
  "Return the face for STATUS, or nil when it has none."
  (alist-get status herdr-tree-status-faces nil nil #'equal))

(defun herdr-tree--faced (text face)
  "Return TEXT carrying FACE, or TEXT unchanged when FACE is nil.

Faces are applied here, where the fields are still separate values,
rather than in the renderer, which receives one already-formatted and
column-aligned line per node and could only recover the fields from it
by guessing at offsets.  It costs the renderer nothing: `equal\\=' ignores
text properties on strings, so neither the tree tests that compare lines
nor the unchanged-tree check in `herdr-dispatch-refresh\\=' can see them.

The magit faces are the exception and stay in the renderer: herdr-tree
is loadable — and tested — without magit-section on the load path, so it
cannot name anything magit-section defines.

Both `face\\=' and `font-lock-face\\=' carry it, which is not belt and
braces: each property is invisible in exactly the situation the other
covers, and this has now been got wrong in both directions.

`face\\=' alone is erased.  `magit-section-mode\\=' sets
`font-lock-defaults\\=', so `global-font-lock-mode\\=' turns
`font-lock-mode\\=' on in the dashboard, and the first thing jit-lock does
to a region is `font-lock-default-unfontify-region\\=' — which removes
`face\\=' and leaves `font-lock-face\\=' alone.  A `face\\=' therefore lasts
until the line is first displayed, which is the whole of the time nobody
is looking at it.

`font-lock-face\\=' alone renders as nothing.  It is not a display
property at all; it is made one by the `char-property-alias-alist\\='
entry `font-lock-mode\\=' installs, so with font-lock off it means
nothing to redisplay.  That was verified after the first fix, with
`face-at-point\\=' answering nil on every line of the dashboard.

Setting both is what magit does, for this reason.  No batch test can see
either failure, because `font-lock-mode\\=' refuses to turn itself on
under `noninteractive\\=' — what a test can assert is that both
properties are present, and herdr-tree-test does."
  (if face (propertize text 'font-lock-face face 'face face) text))

(defconst herdr-tree-noteworthy-statuses '("blocked" "working" "done")
  "Statuses worth showing on a collapsed section.
Idle is omitted for the same reason the modeline omits it: a marker that
is always on screen stops being read.")

(defun herdr-tree--rollup (status)
  "Return the glyph for STATUS on a collapsed section, or an empty string."
  (if (member status herdr-tree-noteworthy-statuses)
      (herdr-tree--faced (herdr-tree-glyph status)
                         (herdr-tree-status-face status))
    ""))

(defun herdr-tree-status-counts (state)
  "Return an alist of (STATUS . COUNT) over the agent panes in STATE.
`herdr-state-agents' is the source: over the agent panes in STATE
\(panes whose `agent' field is set).  Shared by the modeline segment
and the dispatcher header so the two surfaces cannot disagree."
  (let ((counts nil))
    (dolist (pane (herdr-state-agents state))
      (let ((status (or (alist-get 'agent_status pane) "unknown")))
        (setf (alist-get status counts nil nil #'equal)
              (1+ (or (alist-get status counts nil nil #'equal) 0)))))
    counts))

(defun herdr-tree-status-summary (state)
  "Return a compact status summary for STATE, such as \"2⏸1✓\", or \"\".
Only `herdr-tree-noteworthy-statuses\\=' are shown, in that order; idle is
omitted for the same reason the modeline omits it: a marker that is
always on screen stops being read.  Empty when nothing is noteworthy."
  (let* ((counts (herdr-tree-status-counts state))
         (parts (delq nil
                      (mapcar
                       (lambda (status)
                         (when-let* ((n (alist-get status counts
                                                   nil nil #'equal)))
                           (when (> n 0)
                             (format "%d%s" n (herdr-tree-glyph status)))))
                       herdr-tree-noteworthy-statuses))))
    (if parts (string-join parts) "")))

(defun herdr-tree--agent-label (state pane)
  "Return the agent column for PANE in STATE.
A pane with no agent reads as a shell, since it has no agent lifecycle.
A name set through `agent.rename\\=' is appended to the kind."
  (if (not (alist-get 'agent pane))
      "shell"
    (let* ((kind (or (alist-get 'display_agent pane)
                     (alist-get 'agent pane)
                     "shell"))
           (name (herdr-state-agent-name state (alist-get 'pane_id pane))))
      (if name (concat kind "/" name) kind))))

(defconst herdr-tree-agent-column-min 10
  "Minimum width of the agent column.
Keeps a session of bare `claude\\=' panes, with no long `kind/name'
labels among them, from producing a cramped column.")

(defun herdr-tree--agent-column-width (state)
  "Return the agent column width for STATE.
Computed from the widest label `herdr-tree--agent-label\\=' produces over
every pane in STATE, so a long `kind/name\\=' label is never truncated by
a fixed column, and clamped to `herdr-tree-agent-column-min\\=' so a
session of short labels does not look cramped either."
  (apply #'max herdr-tree-agent-column-min
         (mapcar (lambda (pane) (length (herdr-tree--agent-label state pane)))
                 (herdr-state-panes state))))

(defconst herdr-tree-spinner-glyphs '(?◐ ?◑)
  "Characters an agent animates at the head of its terminal title.

Claude spins a half-circle glyph there while it works, and the animation
reaches `terminal_title_stripped\\=' — the stripping is of ANSI, not of
this.  Measured over one 60-second window on a working pane: 485 titles,
239 of them \"◑ Debug webmentions from fed.brid.gy\", 238 the same line
with \"◐\", and 8 with no glyph at all.

Only those two were observed, so only those two are listed.  Another
agent animating a different glyph would go unstripped, which costs a
redraw a second on that pane and nothing else; adding its glyph here is
the whole fix.  Guessing at the rest of the ◐◑◒◓ family would cost
nothing either, but it would put unmeasured characters in a constant
whose entire value is that it was measured.

A list of characters rather than a string, because
`herdr-tree--steady-title\\=' builds a regexp character class out of it and
`regexp-opt-charset\\=' is what quotes one correctly.  Interpolating a
string here directly was one `]\\=', `-\\=' or `^\\=' away from a regexp
that silently matched something else — and this is a constant whose
docstring invites editing.")

(defun herdr-tree--steady-title (title)
  "Return TITLE with any animated spinner glyph taken off the front.

The dashboard renders the title, so the animation makes the rendered
tree genuinely different on every event — several times a second while
an agent works — and the unchanged-tree skip in `herdr-dispatch-refresh\\='
therefore never engages.  That is what had the buffer being erased and
rebuilt about once a second, which destroys the section highlight and
costs the fold and point machinery a full round trip for no visible
change.

Note this is a different problem from the one
`herdr-state-pane-significant-fields\\=' solves by leaving the title out.
That governs whether a `pane.list\\=' reconcile counts as a change; this
governs whether the RENDERED tree differs, and it does, because the
spinner is in the text being drawn.  Fixing either one alone leaves the
other.

Only a leading run is stripped, and only of the glyphs themselves plus
whatever whitespace follows them: a title is otherwise the agent\\='s own
words and is not ours to edit.  Nothing is stripped from a title that
does not begin with a glyph, so the whitespace clause cannot reach a
title on its own."
  (replace-regexp-in-string
   (concat "\\`" (regexp-opt-charset herdr-tree-spinner-glyphs)
           "+[[:space:]]*")
   "" title))

(defun herdr-tree-pane-name (pane)
  "Return the name column for PANE: its label, what it is doing, or both.

A pane\\='s `label\\=' is the name somebody chose for it — `pane.rename\\='
writes one (`herdr-pane-rename\\='), and a plugin pane is seated carrying
its manifest title as one, which is how the Lantern chat comes through
as \"Lantern\".  The terminal title is what the thing running in it is
announcing, which for an agent is the task in hand.

Both, because they answer different questions and a row that dropped
either lost something real: the label alone cannot say what an agent is
working on, and the title alone cannot tell two panes running the same
agent apart.  Joined by a middle dot, the separator herdr already uses
in its own composite labels (a Lantern tab reads \"home · claude\").

Degrades to whichever exists.  A pane with no label — most of them —
reads exactly as it did before this column learned about labels, and a
title that merely repeats the label is not printed twice.

Shared with `herdr-select--annotate-pane\\=' and `herdr-notify--maybe\\=',
the way `herdr-tree-status-counts\\=' is shared with the modeline, so the
surfaces that name a pane cannot disagree about what it is called."
  (let ((label (alist-get 'label pane))
        (title (herdr-tree--steady-title
                (or (alist-get 'terminal_title_stripped pane) ""))))
    (cond
     ((or (null label) (string-empty-p label)) title)
     ((or (string-empty-p title) (equal title label)) label)
     (t (concat label " · " title)))))

(defun herdr-tree--pane-node (state pane width)
  "Return the node for PANE in STATE, its agent column WIDTH wide.

A pane row is a leaf: the renderer inserts it as ordinary content rather
than as a section heading, so the faces here are all the shape it gets.
The status governs both the glyph and the word, which makes the leading
column a colour strip you can read down without reading any of the
words."
  (let* ((id (alist-get 'pane_id pane))
         (shell (not (alist-get 'agent pane)))
         (status (if shell "" (or (alist-get 'agent_status pane) "")))
         (face (herdr-tree-status-face status)))
    (list 'herdr-pane id
          (string-trim-right
           (format (format "%%s %%-%ds %%-8s %%-8s %%s" width)
                   (if shell
                       (herdr-tree--faced "~" 'shadow)
                     (herdr-tree--faced (herdr-tree-glyph status) face))
                   (herdr-tree--agent-label state pane)
                   (herdr-tree--faced status face)
                   (herdr-tree--faced id 'shadow)
                   (herdr-tree--faced (herdr-tree-pane-name pane)
                                      'font-lock-doc-face)))
          nil)))

(defun herdr-tree--panes-in-workspace (state workspace-id width)
  "Return nodes for every pane of WORKSPACE-ID in STATE, agent column WIDTH.
Tabs are server-side layout: under `agent-windows' every pane is its own
Emacs buffer, so grouping rows by tab explained nothing and cost a level.
Listing panes directly also closes the lost-pane hole the old orphan
handling existed for — a pane whose tab the cache does not hold is just
another pane of its workspace here."
  (mapcar (lambda (pane) (herdr-tree--pane-node state pane width))
          (seq-filter (lambda (pane)
                        (equal workspace-id (alist-get 'workspace_id pane)))
                      (herdr-state-panes state))))

(defun herdr-tree-linked-worktree-p (worktree)
  "Return non-nil when WORKTREE is a linked worktree, not the main checkout.

`worktree.list\\=' answers with the repository\\='s own checkout as well as
its linked worktrees, and marks which is which in the REQUIRED
`is_linked_worktree\\=' field.  Measured against a live session, every
workspace answered with exactly one entry and that entry was itself —
workspace, branch, `is_linked_worktree\\=', `open_workspace_id\\=':

    w7  .emacs.d            main     false  \"w7\"
    wA  gmc-rearchitecture  develop  false  \"wA\"
    wJ  srijan.ch           main     false  \"wJ\"

So `open_workspace_id\\=' cannot tell the two apart — for the main
checkout it names the very workspace whose listing this is, which is why
resolving a worktree row through it still had `k\\=' removing the
workspace point was standing inside.  This field is the one that can.

Absent reads as not linked, which drops the row.  The field is required,
so absence means a reply the schema does not describe; erring towards
dropping costs a row that the workspace heading one line above already
shows, and erring the other way costs the workspace."
  (and (alist-get 'is_linked_worktree worktree) t))

(defun herdr-tree-own-workspace-p (worktree workspace-id)
  "Return non-nil when WORKTREE is WORKSPACE-ID rather than one of its worktrees.

WORKSPACE-ID is the workspace the listing containing WORKTREE was fetched
for, so an entry whose `open_workspace_id\\=' equals it is the section\\='s
own workspace — already on screen as the heading the section hangs
under, and the object a verb on the row would then destroy.

This is the same defect `herdr-tree-linked-worktree-p\\=' describes and it
survived that fix, because a repository\\='s main checkout is not the only
entry that can name the enclosing workspace.  This package\\='s own `RET\\='
makes the other one: opening a linked worktree as a workspace means the
next `worktree.list\\=' for that workspace returns its own directory as a
LINKED worktree whose `open_workspace_id\\=' is that workspace.  It then
renders inside its own worktrees section, and `k\\=' on it resolves to the
workspace the row is nested under.  Not reachable in the session the
first fix was measured against, which had no linked worktrees at all.

Neither check subsumes the other, so both are applied.  This one asks
\"is this row the workspace it is nested under?\", which is the question
the destruction turns on and which a main checkout answers yes to as
well.  `herdr-tree-linked-worktree-p\\=' asks \"is this a worktree at
all?\", and that still has to be asked separately: the listing is
fetched for the workspace\\='s pane cwd, and a pane that has been `cd\\='d
into another repository produces a reply whose main checkout names some
other workspace, or none — which this predicate would let through."
  (let ((open (alist-get 'open_workspace_id worktree)))
    (and open (equal open workspace-id))))

(defun herdr-tree--as-directory (path)
  "Return PATH as an absolute directory name, or nil when PATH is nil.

The two kinds of path this file compares do not arrive in the same
shape.  `project-known-project-roots\\=' hands back roots abbreviated and
slash-terminated (`~/workspace/repo/\\='); a `worktree.list\\=' reply names
a worktree by its full path with no trailing slash
\(`/Users/me/workspace/repo\\=').  Comparing those as strings answers no
every time, which is exactly the bug that let one repository appear
once per worktree.  This is the normalization
`herdr-state-workspace-for-directory\\=' already applies to its own
argument, spelled once here so every comparison in this file agrees."
  (and path (file-name-as-directory (expand-file-name path))))

(defun herdr-tree--main-checkout (root worktrees)
  "Return the path of the main checkout of ROOT's repository, or nil.

Read out of ROOT's own cached `worktree.list\\=' reply: the one entry
`herdr-tree-linked-worktree-p\\=' says is not a linked worktree is the
repository's main checkout, whatever ROOT itself happens to be.  For an
ordinary project that is ROOT; for a directory that is itself a linked
worktree it is the checkout the worktree hangs off, which is the fact
`herdr-tree--secondary-worktree-p\\=' needs and which nothing else in the
reply states.

Nil when ROOT has not been fetched yet, and equally when the reply
holds no main checkout at all — the caller treats both as \\='not known
to be a worktree of anything\\=', which keeps the row rather than
hiding it."
  (when-let* ((entry (assoc root worktrees)))
    (seq-some (lambda (worktree)
                (and (not (herdr-tree-linked-worktree-p worktree))
                     (alist-get 'path worktree)))
              (cdr entry))))

(defun herdr-tree--secondary-worktree-p (state root known-project-roots worktrees)
  "Return non-nil when ROOT is a linked worktree already shown elsewhere.

Opening a worktree as a project in Emacs puts it in
`project-known-project-roots\\=' alongside the repository it came from,
and both are repositories as far as `worktree.list\\=' is concerned.  Left
alone, each one drew its own `Inactive\\=' row carrying the same
`worktrees (N)\\=' section as the other: fifteen worktrees listed sixteen
times, with the fifteen rows that produced it sitting between the copies.
The primary checkout is the row worth keeping — its worktrees section
already names ROOT, one line further in — so ROOT's own row goes.

Three things must hold, and the third is what makes this safe.  ROOT
must have a main checkout that is not ROOT, which is what makes it a
worktree rather than a repository in its own right; and that checkout
must actually be on screen, either as an open workspace or as another
known root about to be drawn.  A worktree whose repository is neither
keeps its row: hiding it would remove the only mention of it in the
tree, which is worse than showing it twice.

STATE answers the open-workspace half through
`herdr-state-workspace-for-directory\\=', the same question
`herdr-tree--known-project-nodes\\=' already asks of every root."
  (let ((main (herdr-tree--as-directory
               (herdr-tree--main-checkout root worktrees))))
    (and main
         (not (equal main (herdr-tree--as-directory root)))
         (or (herdr-state-workspace-for-directory state main)
             (seq-some (lambda (other)
                         (equal main (herdr-tree--as-directory other)))
                       known-project-roots))
         t)))

(defun herdr-tree--workspace-repository (state workspace-id worktrees)
  "Return the id of the workspace WORKSPACE-ID is a linked worktree of.

Nil unless all four things hold: WORKSPACE-ID's own `worktree.list\\='
reply has been fetched, it names a main checkout, that checkout is some
directory other than WORKSPACE-ID's own, and a workspace is open there.
Anything less and the workspace has no repository on screen to sit
under, so it stays where it is.

This is `herdr-tree--secondary-worktree-p\\=' asked about an open
workspace instead of an inactive project row, and it answers with the
parent rather than with yes: the row is not dropped here, it is moved,
and the caller needs to know where to."
  (when-let* ((main (herdr-tree--as-directory
                     (herdr-tree--main-checkout workspace-id worktrees)))
              (own (herdr-tree--as-directory
                    (herdr-state-workspace-directory state workspace-id)))
              ((not (equal main own)))
              (parent (herdr-state-workspace-for-directory state main))
              (parent-id (alist-get 'workspace_id parent))
              ((not (equal parent-id workspace-id))))
    parent-id))

(defun herdr-tree--nesting (state workspaces worktrees)
  "Return an alist of (WORKSPACE-ID . PARENT-ID) for WORKSPACES that nest.

Only workspaces that actually move appear: a workspace with no
repository open elsewhere is absent, and so is one whose repository is
itself nested.

That second exclusion is a guard rather than a case anyone will meet.
A worktree's main checkout is the repository, so every worktree of one
repository names the same parent and no chain of length two can form.
Were one to form anyway — a reply naming a main checkout that is itself
a worktree — the grandchild would be spliced into a section its parent
never draws, and would vanish from the tree entirely.  Leaving it at top
level is the safe reading of a reply that cannot be trusted."
  (let ((parents (mapcar (lambda (workspace)
                           (let ((id (alist-get 'workspace_id workspace)))
                             (cons id (herdr-tree--workspace-repository
                                       state id worktrees))))
                         workspaces)))
    (seq-filter (lambda (cell)
                  (and (cdr cell)
                       (not (cdr (assoc (cdr cell) parents)))))
                parents)))

(defconst herdr-tree-worktree-column-min 20
  "Minimum width of a worktree row's branch column.
Keeps a session of short branch names from producing a cramped column.")

(defun herdr-tree--worktree-column-width (worktrees)
  "Return the worktree branch column width for WORKTREES.

Computed from the widest branch or label over every worktree in every
entry of WORKTREES — every workspace and every known project together,
the same global scope `herdr-tree--agent-column-width\\=' uses for the
agent column — so a long feature/ticket branch name in one repository's
worktree list is never truncated by a fixed column, and every
`worktrees (N)\\=' section in the tree lines up the same way regardless
of which repository it belongs to.  Clamped to
`herdr-tree-worktree-column-min\\='.

Includes each entry's own main checkout, not only the linked worktrees
`herdr-tree--worktrees-node\\=' and `herdr-tree--known-project-worktrees-node\\='
go on to filter to: widening the column for a name that never renders
costs nothing, and computing this from the pre-filter list once here is
simpler than re-deriving the same filtered set a second time."
  (apply #'max herdr-tree-worktree-column-min
         (mapcar (lambda (worktree)
                   (length (or (alist-get 'branch worktree)
                               (alist-get 'label worktree)
                               "?")))
                 (seq-mapcat #'cdr worktrees))))

(defun herdr-tree--worktree-node (worktree width)
  "Return the node for WORKTREE, which is a linked worktree.
WIDTH is the worktree branch column width, computed once in
`herdr-tree-build\\=' by `herdr-tree--worktree-column-width\\=' and threaded
down here the same way the agent column width reaches a pane row.

`herdr-tree--worktrees-node\\=' has already dropped the repository\\='s own
checkout, so `open_workspace_id\\=' here means what it appears to mean: a
worktree herdr has opened as a workspace of its own.  The workspace
itself takes this row's place when its repository is the workspace this
section hangs under — see `herdr-tree--nesting\\=' — so what reaches here
with an `open_workspace_id\\=' is a worktree whose repository is not on
screen as a workspace at all.  It is marked rather than repeated: the
workspace is drawn at top level, and a second full copy of it here would
be the duplication this nesting exists to remove.

The whole line is dimmed with `shadow\\=', the same treatment
`herdr-tree--known-project-node\\=' gives an unopened project: a worktree
is not itself running anything either, and a bright branch name next to
a dimmed directory made the two look like they belonged to different
kinds of row when they are the same kind.

The displayed path is abbreviated with `abbreviate-file-name\\=' — the
same `~/\\=' shortening a known-project row already gets for free, since
`project-known-project-roots\\=' hands those back pre-abbreviated, while
a server-reported worktree path arrives as the full absolute path and
had nothing shortening it.  VALUE stays the real, unabbreviated path:
commands need the path the server actually understands, not the one a
human reads faster."
  (let ((open (alist-get 'open_workspace_id worktree)))
    (list 'herdr-worktree (alist-get 'path worktree)
          (herdr-tree--faced
           (string-trim-right
            (format (format "%%-%ds %%-30s %%s" width)
                    (or (alist-get 'branch worktree)
                        (alist-get 'label worktree)
                        "?")
                    (abbreviate-file-name (or (alist-get 'path worktree) ""))
                    (if open (format "open as %s" open) "")))
           'shadow)
          nil)))

(defun herdr-tree--worktrees-node (workspace-id worktrees width &optional nested)
  "Return the worktrees node for WORKSPACE-ID, or nil when it has none.
WIDTH is the worktree branch column width; see `herdr-tree--worktree-node\\='.

NESTED is an alist of (WORKSPACE-ID . NODE) for the workspaces that are
worktrees of this one, built by `herdr-tree-build\\='.  A worktree row
whose `open_workspace_id\\=' is in it renders as that whole workspace —
its panes, its label, its status — in place of the dimmed pointer row,
which is what puts a worktree you are working in underneath the
repository it belongs to rather than beside it.  A row not in NESTED
renders as before.

The heading counts both kinds together, because both are worktrees of
this repository and the count answers that question rather than the
question of which ones happen to be open.

Two things are dropped, and they are different questions with the same
consequence.  `herdr-tree-linked-worktree-p\\=' drops the repository\\='s own
checkout, which is not a worktree at all.  `herdr-tree-own-workspace-p\\='
drops any entry naming WORKSPACE-ID, which is this section\\='s own
workspace however git classifies it — the heading one line above.  Each
predicate lets a case through that the other catches; see either for
which.  A row that survives both is a worktree, and is not the workspace
it is listed under.

A workspace whose repository has no other worktrees is therefore the
ordinary case rather than an unusual one, and it gets no section: what a
`worktrees (1)\\=' heading listed there was the workspace itself, already
on screen.

Nil covers three things now — \\='none were found\\=', \\='none have been
fetched yet\\=' and \\='none of what was found is a worktree other than
this workspace\\='.  A workspace with nothing to show has no section worth
drawing whichever of those it is, and the distinction between the first
two lives in the cache that builds WORKTREES rather than here."
  (when-let* ((entry (assoc workspace-id worktrees))
              (found (seq-filter
                      (lambda (worktree)
                        (and (herdr-tree-linked-worktree-p worktree)
                             (not (herdr-tree-own-workspace-p worktree
                                                              workspace-id))))
                      (cdr entry))))
    (list 'herdr-worktrees workspace-id
          (format "worktrees (%s)" (length found))
          (mapcar (lambda (worktree)
                    (or (cdr (assoc (alist-get 'open_workspace_id worktree)
                                    nested))
                        (herdr-tree--worktree-node worktree width)))
                  found))))

(defun herdr-tree--workspace-node (state workspace worktrees width worktree-width
                                         &optional nested)
  "Return the node for WORKSPACE in STATE, including WORKTREES.
WIDTH is the agent column width, computed once in `herdr-tree-build\\='
and threaded down to every pane in this workspace.  WORKTREE-WIDTH is
the worktree branch column width, threaded the same way to
`herdr-tree--worktrees-node\\='.  NESTED is passed straight through to it;
see there for what it does.

The pane count rides in parentheses on the label — `repo (3)\\=' — rather
than as a `3 panes\\=' column of its own.  That is magit's idiom for the
same thing (`Unstaged changes (1)\\='), and it is the shape that reads as
a container: a heading that owns a countable number of children, told
apart at a glance from the leaf rows that own none.  The worktrees
heading is counted the same way for the same reason.

The directory is abbreviated with `abbreviate-file-name\\=' — the `~/\\='
a known-project row already shows for free, since
`project-known-project-roots\\=' hands those back pre-abbreviated, while
`herdr-state-workspace-directory\\=' derives this one from a pane\\='s
`cwd\\=' and had nothing shortening it."
  (let* ((id (alist-get 'workspace_id workspace))
         (children (herdr-tree--panes-in-workspace state id width))
         (worktree-node (herdr-tree--worktrees-node id worktrees worktree-width
                                                    nested)))
    (list 'herdr-workspace id
          (string-trim-right
           (format "%-28s %-30s %s"
                   (format "%s (%s)"
                           (or (alist-get 'label workspace) id)
                           (or (alist-get 'pane_count workspace) 0))
                   (herdr-tree--faced
                    (abbreviate-file-name
                     (or (herdr-state-workspace-directory state id) ""))
                    'font-lock-comment-face)
                   (herdr-tree--rollup (alist-get 'agent_status workspace))))
          (if worktree-node (append children (list worktree-node)) children))))

(defun herdr-tree--known-project-worktrees-node (root worktrees width)
  "Return ROOT's worktrees node from WORKTREES, or nil when it has none.
WIDTH is the worktree branch column width; see `herdr-tree--worktree-node\\='.

Two things are dropped, as in `herdr-tree--worktrees-node\\=', but the
second question is asked by path rather than by workspace id.
`herdr-tree-linked-worktree-p\\=' drops the repository's own main
checkout.  What remains is then compared against ROOT itself, because a
directory that is a linked worktree of some other repository lists
itself among its own worktrees — flagged linked, since that is what it
is — and drawing it there put ROOT one level underneath its own
heading, described as one of its own children.

`herdr-tree-own-workspace-p\\=' is what asks the same question for an
open workspace, and it cannot be reused here: it compares
`open_workspace_id\\=', and ROOT, being unopened, has no workspace id to
compare against.  Its path is the identity ROOT does have."
  (when-let* ((entry (assoc root worktrees))
              (found (seq-filter
                      (lambda (worktree)
                        (and (herdr-tree-linked-worktree-p worktree)
                             (not (equal (herdr-tree--as-directory
                                          (alist-get 'path worktree))
                                         (herdr-tree--as-directory root)))))
                      (cdr entry))))
    (list 'herdr-worktrees root
          (format "worktrees (%s)" (length found))
          (mapcar (lambda (w) (herdr-tree--worktree-node w width)) found))))

(defun herdr-tree--known-project-node (root worktrees worktree-width)
  "Return the node for ROOT, a known project with no workspace open.
WORKTREES is threaded through to `herdr-tree--known-project-worktrees-node\\=',
the same cache `herdr-tree--workspace-node\\=' reads for an open workspace's
own worktrees section — ROOT's own repository is asked about exactly the
same way, just keyed by ROOT itself rather than a workspace id.
WORKTREE-WIDTH is the worktree branch column width, threaded the same way.

Always \"(0)\": a real workspace cannot reach zero panes and survive —
closing a workspace's last pane closes the workspace itself with it,
verified against a running server — so the count doubles as the signal
that this row is not actually open, the same way
`herdr-tree--worktree-node\\=' marks an unopened worktree with `open as
WORKSPACE-ID\\=' rather than leaving it looking identical to one that is.
Dimmed with `shadow\\=' for the same reason: nothing here is running."
  (let ((worktrees-node (herdr-tree--known-project-worktrees-node
                         root worktrees worktree-width)))
    (list 'herdr-known-project root
          (herdr-tree--faced
           (string-trim-right
            (format "%-28s %s"
                    (format "%s (0)"
                            (file-name-nondirectory (directory-file-name root)))
                    root))
           'shadow)
          (and worktrees-node (list worktrees-node)))))

(defun herdr-tree--known-project-nodes (state known-project-roots worktrees
                                              worktree-width)
  "Return nodes for KNOWN-PROJECT-ROOTS with no workspace open in STATE.

KNOWN-PROJECT-ROOTS is a plain list of directory strings — typically
`project-known-project-roots\\=', but kept as a parameter rather than read
here so this stays a pure function of its arguments, the same reason
`herdr-tree-build\\=' takes WORKTREES as a parameter instead of fetching
them itself.  WORKTREES and WORKTREE-WIDTH are passed straight through to
`herdr-tree--known-project-node\\='.

Two kinds of root are excluded.  One is any root
`herdr-state-workspace-for-directory\\=' already finds open: a project
you have open needs no second, dimmer entry for the same directory at
the bottom of its own tree.  The other is any root
`herdr-tree--secondary-worktree-p\\=' recognises as a linked worktree of
a repository already on screen — a worktree you once opened as a
project in Emacs, which project.el then remembers as a project in its
own right and which would otherwise redraw its whole repository's
worktree list beside the repository's own copy of it."
  (mapcar (lambda (root)
            (herdr-tree--known-project-node root worktrees worktree-width))
          (seq-remove (lambda (root)
                        (or (herdr-state-workspace-for-directory state root)
                            (herdr-tree--secondary-worktree-p
                             state root known-project-roots worktrees)))
                      known-project-roots)))

(defun herdr-tree--known-projects-node (state known-project-roots worktrees
                                              worktree-width)
  "Return one \"Inactive (N)\\=\" container node, or nil when there is nothing.

Wrapping every `herdr-known-project\\=' row under one foldable heading is
what removes the blank line `herdr-dispatch--insert-nodes\\=' otherwise
puts between top-level nodes: only top-level siblings get one, and inside
this container the rows are children, not siblings of the workspaces
above.  VALUE is a stable placeholder string rather than nil, because a
`nil\\=' section value reads to `herdr-dispatch--value-at-point\\=' as
`nothing found here\\=' even while point is on the heading."
  (when-let* ((nodes (herdr-tree--known-project-nodes
                      state known-project-roots worktrees worktree-width)))
    (list 'herdr-known-projects "inactive"
          (format "Inactive (%s)" (length nodes))
          nodes)))

(defun herdr-tree-build (state worktrees &optional known-project-roots)
  "Return the dispatcher tree for STATE.

Each node is the list (TYPE VALUE LINE CHILDREN).  TYPE is one of
`herdr-workspace\\=', `herdr-pane\\=', `herdr-worktrees\\=',
`herdr-worktree\\=', `herdr-known-project\\=' or `herdr-known-projects\\=';
VALUE is the id a command needs; LINE is the rendered text; CHILDREN is a
list of nodes.

WORKTREES is an alist of (ID . LIST-OF-WORKTREEINFO) for every workspace
or known-project root whose worktrees have been fetched, keyed either way
by the same id its own node uses.  An id missing from it simply gets no
worktrees section — absence of knowledge, not absence of worktrees.

A workspace that is a linked worktree of another open workspace is not a
top-level node.  It is drawn inside its repository's `worktrees (N)\\='
section, in place of the dimmed row that would otherwise point at it, so
that the top level is one row per repository and a worktree you are
working in sits under the repository it belongs to.  See
`herdr-tree--nesting\\=' for which workspaces move and
`herdr-tree--worktrees-node\\=' for what replaces their rows.

A worktree open as a workspace whose repository is only an inactive
project row keeps its top-level place, and that row keeps its `open as
WORKSPACE-ID\\=' pointer.  Nesting a workspace with running agents under a
dimmed `Inactive\\=' heading would file the thing this dashboard exists to
show under the heading for things that are not running.

KNOWN-PROJECT-ROOTS, when given, appends one \"Inactive (N)\\=\" container
after every real workspace — see `herdr-tree--known-projects-node\\=' —
holding one dimmed row per project with no workspace currently open, so
a project you are not in right now is still one keystroke from being
opened, folded away at the bottom rather than mixed in among the
workspaces actually running something.

The agent column width is computed once here, from every pane in STATE,
so it is consistent across every workspace rather than fitted separately
per tab — a session with one long label in one workspace and only short
ones in another would otherwise show two different column widths.  The
worktree branch column width is computed once the same way, from every
worktree in WORKTREES, so every `worktrees (N)\\=' section in the tree
lines up regardless of which repository it belongs to."
  (let* ((width (herdr-tree--agent-column-width state))
         (worktree-width (herdr-tree--worktree-column-width worktrees))
         (workspaces (herdr-state-workspaces state))
         (nesting (herdr-tree--nesting state workspaces worktrees))
         ;; Built before the workspaces that will hold them, and built
         ;; with no worktrees of their own: a nested workspace's own
         ;; `worktree.list' names its siblings, and those siblings are
         ;; about to be drawn beside it under the same repository.  A
         ;; section repeating them one level deeper would put every
         ;; worktree of the repository under every other one.
         (nested (mapcar
                  (lambda (workspace)
                    (cons (alist-get 'workspace_id workspace)
                          (herdr-tree--workspace-node
                           state workspace nil width worktree-width)))
                  (seq-filter (lambda (workspace)
                                (assoc (alist-get 'workspace_id workspace)
                                       nesting))
                              workspaces))))
    (append (mapcar
             (lambda (workspace)
               (let ((id (alist-get 'workspace_id workspace)))
                 (herdr-tree--workspace-node
                  state workspace worktrees width worktree-width
                  ;; Only this workspace's own children.  A worktree row
                  ;; here names a worktree of this repository, so a node
                  ;; belonging to some other repository could not match
                  ;; it anyway -- but passing the whole set would make
                  ;; that a property of the data rather than of the code.
                  (seq-filter (lambda (cell)
                                (equal id (cdr (assoc (car cell) nesting))))
                              nested))))
             (seq-remove (lambda (workspace)
                           (assoc (alist-get 'workspace_id workspace) nesting))
                         workspaces))
            (when-let* ((inactive (herdr-tree--known-projects-node
                                   state known-project-roots worktrees
                                   worktree-width)))
              (list inactive)))))

(provide 'herdr-tree)
;;; herdr-tree.el ends here
