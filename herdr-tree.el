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

Set both `face\\=' and `font-lock-face\\='.  Neither alone works, and this
has been got wrong in both directions: jit-lock strips `face\\=' the first
time a line is displayed, and `font-lock-face\\=' means nothing to
redisplay when font-lock is off.  No batch test can see either failure,
since `font-lock-mode\\=' will not turn on under `noninteractive\\=';
herdr-tree-test asserts both properties are present instead.

Faces belong here, where the fields are still separate values, not in
the renderer, which sees one formatted line.  The magit faces are the
exception and stay there: this file must load without magit-section."
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
`terminal_title_stripped\\=' strips ANSI, not these.  Only these two were
measured; another agent animating a different glyph costs one redraw a
second on that pane, and adding its glyph here is the whole fix.

A list of characters, not a string: `herdr-tree--steady-title\\=' builds a
regexp character class from it through `regexp-opt-charset\\=', which is
what quotes `]\\=', `-\\=' and `^\\=' correctly.")

(defun herdr-tree--steady-title (title)
  "Return TITLE with any animated spinner glyph taken off the front.
Without this the rendered tree differs several times a second while an
agent works, so the unchanged-tree skip in `herdr-dispatch-refresh\\='
never engages and the buffer is erased and rebuilt about once a second.

A different problem from the one `herdr-state-pane-significant-fields\\='
solves: that one governs whether a reconcile counts as a change, this
one whether the RENDERED tree differs.  Fixing either alone leaves the
other.

Only a leading run, and only the glyphs plus trailing whitespace.  The
rest of a title is the agent\\='s own words."
  (replace-regexp-in-string
   (concat "\\`" (regexp-opt-charset herdr-tree-spinner-glyphs)
           "+[[:space:]]*")
   "" title))

(defun herdr-tree-pane-name (pane)
  "Return the name column for PANE: its label, what it is doing, or both.
The label is what somebody chose to call the pane; the terminal title is
what the thing inside it announces.  Both are shown, joined by a middle
dot, because the label alone cannot say what an agent is working on and
the title alone cannot tell two panes running the same agent apart.

Degrades to whichever exists, and does not print a title that merely
repeats the label.

Shared with `herdr-select--annotate-pane\\=' and `herdr-notify--maybe\\=',
so the surfaces that name a pane cannot disagree."
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
Tabs are server-side layout.  Every pane is its own Emacs buffer here,
so grouping rows by tab would explain nothing and cost a level."
  (mapcar (lambda (pane) (herdr-tree--pane-node state pane width))
          (seq-filter (lambda (pane)
                        (equal workspace-id (alist-get 'workspace_id pane)))
                      (herdr-state-panes state))))

(defun herdr-tree-linked-worktree-p (worktree)
  "Return non-nil when WORKTREE is a linked worktree, not the main checkout.
`is_linked_worktree\\=' is the only field that can tell them apart.  For a
main checkout `open_workspace_id\\=' names the very workspace whose
listing this is, which is how `k\\=' came to remove the workspace point
was standing in.

Absent reads as not linked, which drops the row.  The field is required,
so absence means a reply the schema does not describe: dropping costs a
row the heading above already shows, keeping costs the workspace."
  (and (alist-get 'is_linked_worktree worktree) t))

(defun herdr-tree-own-workspace-p (worktree workspace-id)
  "Return non-nil when WORKTREE is WORKSPACE-ID rather than one of its worktrees.
An entry whose `open_workspace_id\\=' is WORKSPACE-ID is the section\\='s own
workspace: already on screen as the heading above, and the object a verb
on the row would destroy.  A linked worktree opened as a workspace comes
back in its own listing exactly this way.

Apply this AND `herdr-tree-linked-worktree-p\\='.  Neither subsumes the
other.  This asks \"is this row the workspace it is nested under?\"; that
asks \"is this a worktree at all?\", which still matters because a pane
`cd\\='d into another repository yields a listing whose main checkout
names some other workspace, or none."
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
A worktree opened as a project in Emacs lands in
`project-known-project-roots\\=' beside its own repository, and each then
draws the same worktree list as the other.

Two conditions, and the second is what makes dropping ROOT safe: its
main checkout must not be ROOT, and that checkout must be on screen,
either as an open workspace or as another known root about to be drawn.
A worktree whose repository is neither keeps its row, because hiding it
would remove its only mention in the tree."
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
`herdr-tree--worktree-nodes\\=' and `herdr-tree--known-project-worktree-nodes\\='
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
WIDTH is the branch column width, computed once in `herdr-tree-build\\='.

A row reaching here with an `open_workspace_id\\=' is a worktree whose
repository is not on screen as a workspace: where it is,
`herdr-tree--nesting\\=' has already put the workspace in this row's
place.  So it is marked, not repeated.

Abbreviate the displayed path only.  VALUE stays the real path, because
commands send it to the server."
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

(defun herdr-tree--worktree-nodes (workspace-id worktrees width &optional nested)
  "Return a node per worktree of WORKSPACE-ID, or nil when it has none.
WIDTH is the worktree branch column width.

NESTED is an alist of (WORKSPACE-ID . NODE) for the workspaces that are
worktrees of this one, built by `herdr-tree-build\\='.  A worktree row
whose `open_workspace_id\\=' is in it renders as that whole workspace in
place of the dimmed pointer row, which is what puts a worktree you are
working in underneath its repository rather than beside it.

Two predicates drop rows, and neither subsumes the other:
`herdr-tree-linked-worktree-p\\=' drops the repository\\='s own checkout,
`herdr-tree-own-workspace-p\\=' drops any entry naming WORKSPACE-ID.  A
row surviving both is a worktree and is not the workspace it sits under.

A list, not a `worktrees (N)\\=' container: the nodes hang off the
workspace beside its `main (N)\\=' group.  Once a worktree could be a
whole workspace, that extra level put a running agent three deep."
  (when-let* ((entry (assoc workspace-id worktrees))
              (found (seq-filter
                      (lambda (worktree)
                        (and (herdr-tree-linked-worktree-p worktree)
                             (not (herdr-tree-own-workspace-p worktree
                                                              workspace-id))))
                      (cdr entry))))
    (mapcar (lambda (worktree)
              (or (cdr (assoc (alist-get 'open_workspace_id worktree) nested))
                  (herdr-tree--worktree-node worktree width)))
            found)))

(defun herdr-tree--main-node (workspace-id panes)
  "Return the `main (N)\\=' node holding PANES, the panes of WORKSPACE-ID.
Drawn only for a workspace that has worktrees, where it is what tells
this repository\\='s own panes from the checkouts beside them.  `main\\=' is
git\\='s word for the checkout the worktrees hang off."
  (list 'herdr-panes workspace-id
        (format "main (%s)" (length panes))
        panes))

(defun herdr-tree--workspace-node (state workspace worktrees width worktree-width
                                         &optional nested)
  "Return the node for WORKSPACE in STATE, including WORKTREES.
WIDTH and WORKTREE-WIDTH are the agent and branch column widths,
computed once in `herdr-tree-build\\='.  NESTED passes through to
`herdr-tree--worktree-nodes\\='.

A workspace with worktrees holds its own panes in a `main (N)\\=' group
and its worktrees beside it:

    herdr.el (3)
      main (2)
        claude
        shell
      project-el (1)
        claude

With no worktrees there is no group and the panes hang off the workspace
row, which is the ordinary case and the shape a plugin workspace needs.

The count in parentheses is checkouts, not panes: its own plus one per
worktree.  The pane count sits on `main (N)\\=' where that group is drawn.

The directory goes through `abbreviate-file-name\\=', which a
known-project row gets for free because `project-known-project-roots\\='
hands those back pre-abbreviated."
  (let* ((id (alist-get 'workspace_id workspace))
         (panes (herdr-tree--panes-in-workspace state id width))
         (worktree-nodes (herdr-tree--worktree-nodes id worktrees
                                                     worktree-width nested)))
    (list 'herdr-workspace id
          (string-trim-right
           (format "%-28s %-30s %s"
                   (format "%s (%s)"
                           (or (alist-get 'label workspace) id)
                           (1+ (length worktree-nodes)))
                   (herdr-tree--faced
                    (abbreviate-file-name
                     (or (herdr-state-workspace-directory state id) ""))
                    'font-lock-comment-face)
                   (herdr-tree--rollup (alist-get 'agent_status workspace))))
          ;; The `main (N)' group only where there are worktrees to tell
          ;; the panes apart from; see `herdr-tree--main-node'.
          (if worktree-nodes
              (cons (herdr-tree--main-node id panes) worktree-nodes)
            panes))))

(defun herdr-tree--main-checkout-node (root worktrees width)
  "Return the `main\\=' row for ROOT, or nil when ROOT is not a checkout.
Without it the repository\\='s own checkout is the one directory in an
inactive listing with no row to act on, and it is the likeliest wanted.

Named `main\\=', not by its branch: a repository\\='s branch may be called
anything and the row makes no claim about it.

Nil unless the reply\\='s main checkout is ROOT itself, so a ROOT that is
someone else\\='s worktree does not draw their checkout as its child."
  (when-let* ((main (herdr-tree--main-checkout root worktrees))
              ((equal (herdr-tree--as-directory main)
                      (herdr-tree--as-directory root))))
    (herdr-tree--worktree-node `((path . ,main) (branch . "main")) width)))

(defun herdr-tree--known-project-worktree-nodes (root worktrees width)
  "Return a node per worktree of ROOT in WORKTREES, or nil when it has none.
WIDTH is the worktree branch column width; see `herdr-tree--worktree-node\\='.

The repository\\='s own checkout leads the list as a `main\\=' row, so a
repository with no worktrees is one row rather than nothing: that row is
where \\[herdr-dispatch-create-terminal] is aimed.  Nil means the reply
has not landed, which is the one case where drawing nothing is right.

Two rows are dropped.  `herdr-tree-linked-worktree-p\\=' drops the main
checkout.  What remains is compared against ROOT by path, because a
directory that is someone else\\='s worktree lists itself among its own,
and drawing that row put ROOT underneath itself.

`herdr-tree-own-workspace-p\\=' cannot be reused for that second question:
it compares `open_workspace_id\\=', and an unopened ROOT has none."
  (when-let* ((entry (assoc root worktrees)))
    (let ((rows (mapcar (lambda (worktree)
                          (herdr-tree--worktree-node worktree width))
                        (seq-filter
                         (lambda (worktree)
                           (and (herdr-tree-linked-worktree-p worktree)
                                (not (equal (herdr-tree--as-directory
                                             (alist-get 'path worktree))
                                            (herdr-tree--as-directory root)))))
                         (cdr entry))))
          (main (herdr-tree--main-checkout-node root worktrees width)))
      (if main (cons main rows) rows))))

(defun herdr-tree--known-project-node (root worktrees worktree-width)
  "Return the node for ROOT, a known project with no workspace open.
WORKTREES is threaded through to `herdr-tree--known-project-worktree-nodes\\=',
the same cache `herdr-tree--workspace-node\\=' reads for an open workspace's
own worktrees section — ROOT's own repository is asked about exactly the
same way, just keyed by ROOT itself rather than a workspace id.
WORKTREE-WIDTH is the worktree branch column width, threaded the same way.

The count is the repository's checkouts, the same number an open
workspace's row carries and counted the same way: its own checkout plus
one per worktree.  It used to be a constant \"(0)\" — a real workspace
cannot reach zero panes and survive, so a zero pane count was itself the
signal that this row is not open — but a number that is always the same
is a number nobody reads, and the row says \"not running\" twice over
without it: it is dimmed with `shadow\\=', and `herdr-tree--worktree-node\\='
marks an unopened worktree with `open as WORKSPACE-ID\\=' the same way.

Zero still happens and still means something, just something else: no
checkouts are known.  Either the reply has not landed yet, or the
directory is not a git repository at all."
  (let ((worktree-nodes (herdr-tree--known-project-worktree-nodes
                         root worktrees worktree-width)))
    (list 'herdr-known-project root
          (herdr-tree--faced
           (string-trim-right
            (format "%-28s %s"
                    (format "%s (%s)"
                            (file-name-nondirectory (directory-file-name root))
                            (length worktree-nodes))
                    root))
           'shadow)
          worktree-nodes)))

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
`herdr-workspace\\=', `herdr-pane\\=', `herdr-panes\\=',
`herdr-worktree\\=', `herdr-known-project\\=' or `herdr-known-projects\\=';
VALUE is the id a command needs; LINE is the rendered text; CHILDREN is a
list of nodes.

WORKTREES is an alist of (ID . LIST-OF-WORKTREEINFO), keyed by workspace
id or known-project root.  A missing id gets no worktrees section: that
is absence of knowledge, not absence of worktrees.

A workspace that is a linked worktree of another OPEN workspace is not a
top-level node.  It is drawn inside its repository, in place of the
dimmed row that would point at it, so the top level is one row per
repository.  See `herdr-tree--nesting\\='.  A worktree whose repository is
only an inactive row keeps its top-level place: nesting running agents
under the `Inactive\\=' heading would file them under things that are not.

KNOWN-PROJECT-ROOTS, when given, appends the \"Inactive (N)\\=\" container.

Both column widths are computed here, once, from every pane and every
worktree in the whole tree.  Fitting them per workspace gives adjacent
sections different widths."
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
