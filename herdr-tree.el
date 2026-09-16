;;; herdr-tree.el --- Pure tree model for the herdr dispatcher -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Maintainer: Srijan Choudhary
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The dispatcher's tree, as data.  `herdr-tree-build' turns the state
;; cache into a nested list of (TYPE VALUE LINE CHILDREN); `herdr-dispatch'
;; walks that list emitting magit sections.
;;
;; Kept separate from the renderer, and loadable without magit-section:
;; everything here is a pure function of the state cache, testable by
;; comparing values, while the renderer can only be tested by inserting
;; into a buffer and reading text properties back.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'regexp-opt)
(require 'herdr-state)
(require 'herdr-pane)
(require 'herdr-workspace)
(require 'herdr-worktree)

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
      (let ((status (or (herdr-state-pane-status state pane) "unknown")))
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
  (if (not (herdr-pane-agent pane))
      "shell"
    (let* ((kind (or (herdr-pane-display-agent pane)
                     (herdr-pane-agent pane)
                     "shell"))
           (name (herdr-state-agent-name state (herdr-pane-id pane))))
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

(defun herdr-tree--pane-node (state pane width)
  "Return the node for PANE in STATE, its agent column WIDTH wide.

A pane row is a leaf: the renderer inserts it as ordinary content rather
than as a section heading, so the faces here are all the shape it gets.
The status governs both the glyph and the word, which makes the leading
column a colour strip you can read down without reading any of the
words."
  (let* ((id (herdr-pane-id pane))
         (shell (not (herdr-pane-agent pane)))
         (status (if shell "" (or (herdr-state-pane-status state pane) "")))
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
                   (herdr-tree--faced (herdr-pane-name pane)
                                      'font-lock-doc-face)))
          nil)))

(defun herdr-tree--panes-in-workspace (state workspace-id width)
  "Return nodes for every pane of WORKSPACE-ID in STATE, agent column WIDTH.
Tabs are server-side layout.  Every pane is its own Emacs buffer here,
so grouping rows by tab would explain nothing and cost a level."
  (mapcar (lambda (pane) (herdr-tree--pane-node state pane width))
          (seq-filter (lambda (pane)
                        (equal workspace-id (herdr-pane-workspace-id pane)))
                      (herdr-state-panes state))))

(defun herdr-tree-own-workspace-p (worktree workspace-id)
  "Return non-nil when WORKTREE is WORKSPACE-ID rather than one of its worktrees.
An entry whose open workspace is WORKSPACE-ID is the section\\='s own
workspace: already on screen as the heading above, and the object a verb
on the row would destroy.  A linked worktree opened as a workspace comes
back in its own listing exactly this way.

Bare ids on both sides, which is sound because every caller compares
a record against the workspace of the listing it came from, on one
connection.

Apply this AND `herdr-worktree-linked-p\\='.  Neither subsumes the other.
This asks \"is this row the workspace it is nested under?\"; that asks
\"is this a worktree at all?\", which still matters because a pane `cd\\='d
into another repository yields a listing whose main checkout names some
other workspace, or none."
  (let ((open (herdr-worktree-open-workspace-id worktree)))
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

(defun herdr-tree--workspace-repository (state workspace-id worktrees)
  "Return the id of the workspace WORKSPACE-ID is a linked worktree of.

Nil unless all four things hold: WORKSPACE-ID's own `worktree.list\\='
reply has been fetched, it names a main checkout, that checkout is some
directory other than WORKSPACE-ID's own, and STATE has one open there.
Anything less and the workspace has no repository on screen to sit
under, so it stays where it is.

It answers with the parent rather than with yes: the row is not dropped
here, it is moved, and the caller needs to know where to."
  (when-let* ((main (herdr-tree--as-directory
                     (herdr-worktree-listing-repo-root
                      (cdr (assoc workspace-id worktrees)))))
              (own (herdr-tree--as-directory
                    (herdr-state-workspace-directory state workspace-id)))
              ((not (equal main own)))
              (parent (herdr-state-workspace-for-directory state main))
              (parent-id (herdr-workspace-id parent))
              ((not (equal parent-id workspace-id))))
    parent-id))

(defun herdr-tree--nesting (state workspaces worktrees)
  "Return an alist of (WORKSPACE-ID . PARENT-ID) for WORKSPACES that nest.

Only workspaces that actually move appear: a workspace with no
repository open elsewhere in STATE is absent, and so is one whose
repository is itself nested.

That second exclusion is a guard rather than a case anyone will meet.
A worktree's main checkout is the repository, so every worktree of one
repository names the same parent and no chain of length two can form.
Were one to form anyway — a reply naming a main checkout that is itself
a worktree — the grandchild would be spliced into a section its parent
never draws, and would vanish from the tree entirely.  Leaving it at top
level is the safe reading of a reply that cannot be trusted."
  (let ((parents (mapcar (lambda (workspace)
                           (let ((id (herdr-workspace-id workspace)))
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
entry of WORKTREES — the same global scope
`herdr-tree--agent-column-width\\=' uses for the agent column — so a long
feature/ticket branch name in one repository's worktree list is never
truncated by a fixed column, and every `worktrees (N)\\=' section in the
tree lines up the same way regardless of which repository it belongs to.
Clamped to `herdr-tree-worktree-column-min\\='.

Includes each entry's own main checkout, not only the linked worktrees
`herdr-tree--worktree-nodes\\=' goes on to filter to: widening the column
for a name that never renders costs nothing, and computing this from the
pre-filter list once here is simpler than re-deriving the same filtered
set a second time."
  (apply #'max herdr-tree-worktree-column-min
         (mapcar (lambda (worktree)
                   (length (herdr-worktree-name worktree)))
                 (seq-mapcat (lambda (entry)
                               (herdr-worktree-listing-worktrees (cdr entry)))
                             worktrees))))

(defun herdr-tree--worktree-node (worktree width)
  "Return the node for WORKTREE, which is a linked worktree.
WIDTH is the branch column width, computed once in `herdr-tree-build\\='.

A row reaching here with an `open_workspace_id\\=' is a worktree whose
repository is not on screen as a workspace: where it is,
`herdr-tree--nesting\\=' has already put the workspace in this row's
place.  So it is marked, not repeated.

Abbreviate the displayed path only.  VALUE stays the real path, because
commands send it to the server."
  (let ((open (herdr-worktree-open-workspace-id worktree)))
    (list 'herdr-worktree (herdr-worktree-path worktree)
          (herdr-tree--faced
           (string-trim-right
            (format (format "%%-%ds %%-30s %%s" width)
                    (herdr-worktree-name worktree)
                    (abbreviate-file-name (or (herdr-worktree-path worktree) ""))
                    (if open (format "open as %s" open) "")))
           'shadow)
          nil)))

(defun herdr-tree--worktree-nodes (workspace-id worktrees width &optional nested)
  "Return a node per worktree of WORKSPACE-ID, or nil when it has none.
WORKTREES holds the cached `worktree.list\\=' reply per workspace, and
WIDTH is the worktree branch column width.

NESTED is an alist of (WORKSPACE-ID . NODE) for the workspaces that are
worktrees of this one, built by `herdr-tree-build\\='.  A worktree row
whose `open_workspace_id\\=' is in it renders as that whole workspace in
place of the dimmed pointer row, which is what puts a worktree you are
working in underneath its repository rather than beside it.

Two predicates drop rows, and neither subsumes the other:
`herdr-worktree-linked-p\\=' drops the repository\\='s own checkout,
`herdr-tree-own-workspace-p\\=' drops any entry naming WORKSPACE-ID.  A
row surviving both is a worktree and is not the workspace it sits under.

A list, not a `worktrees (N)\\=' container: the nodes hang off the
workspace beside its `main (N)\\=' group.  Once a worktree could be a
whole workspace, that extra level put a running agent three deep."
  (when-let* ((entry (assoc workspace-id worktrees))
              (found (seq-filter
                      (lambda (worktree)
                        (and (herdr-worktree-linked-p worktree)
                             (not (herdr-tree-own-workspace-p worktree
                                                              workspace-id))))
                      (herdr-worktree-listing-worktrees (cdr entry)))))
    (mapcar (lambda (worktree)
              (or (cdr (assoc (herdr-worktree-open-workspace-id worktree) nested))
                  (herdr-tree--worktree-node worktree width)))
            found)))

(defun herdr-tree--worktrees-node (workspace-id nodes)
  "Return the foldable `worktrees (N)\\=' heading over WORKSPACE-ID\\='s NODES.

One heading rather than a run of sibling rows.  The run was affordable
only while a `main (N)\\=' tab group sat beside it; with that level gone a
container costs no extra depth, and it is what lets a repository with a
dozen checkouts stay one line until asked.  Collapsed by default through
`magit-section-initial-visibility-alist\\='."
  (list 'herdr-worktrees workspace-id
        (format "worktrees (%s)" (length nodes))
        nodes))

(defun herdr-tree--workspace-branch (workspace-id worktrees)
  "Return the branch WORKSPACE-ID\\='s own checkout is on, or nil.

Only a `worktree.list\\=' reply carries a branch — no snapshot field does —
so this is nil until WORKTREES holds that reply, and stays nil for a
workspace whose directory is not a git repository.  The entry naming
WORKSPACE-ID as its open workspace is that workspace\\='s own checkout."
  (when-let* ((listing (cdr (assoc workspace-id worktrees))))
    (seq-some (lambda (worktree)
                (and (herdr-tree-own-workspace-p worktree workspace-id)
                     (herdr-worktree-branch worktree)))
              (herdr-worktree-listing-worktrees listing))))

(defun herdr-tree--workspace-node (state workspace worktrees width worktree-width
                                         &optional nested)
  "Return the node for WORKSPACE in STATE, including WORKTREES.
WIDTH and WORKTREE-WIDTH are the agent and branch column widths,
computed once in `herdr-tree-build\\='.  NESTED passes through to
`herdr-tree--worktree-nodes\\='.

The row names the workspace, the branch its own checkout is on and its
directory — what herdr\\='s own sidebar shows for a workspace.  Panes hang
directly off it; its other checkouts sit under one foldable
`worktrees (N)\\=' heading.

There is no tab level.  `main\\=' on this screen is a branch, and it used
to also be the name of a tab group two rows above it, which is the one
collision worth removing before any other.

The directory goes through `abbreviate-file-name\\='."
  (let* ((id (herdr-workspace-id workspace))
         (panes (herdr-tree--panes-in-workspace state id width))
         (worktree-nodes (herdr-tree--worktree-nodes id worktrees
                                                     worktree-width nested)))
    (list 'herdr-workspace id
          (string-trim-right
           (format (format "%%-28s %%-%ds %%-30s %%s" worktree-width)
                   (herdr-workspace-identity workspace)
                   (or (herdr-tree--workspace-branch id worktrees) "")
                   (herdr-tree--faced
                    (abbreviate-file-name
                     (or (herdr-state-workspace-directory state id) ""))
                    'font-lock-comment-face)
                   (herdr-tree--rollup (herdr-workspace-status workspace))))
          (if worktree-nodes
              (append panes
                      (list (herdr-tree--worktrees-node id worktree-nodes)))
            panes))))

(defun herdr-tree-build (state worktrees)
  "Return the dispatcher tree for STATE.

Each node is the list (TYPE VALUE LINE CHILDREN).  TYPE is one of
`herdr-workspace\\=', `herdr-pane\\=', `herdr-worktree\\=' or
`herdr-worktrees\\=';
VALUE is the id a command needs; LINE is the rendered text; CHILDREN is a
list of nodes.

WORKTREES is an alist of (ID . LIST-OF-WORKTREEINFO), keyed by workspace
id.  A missing id gets no worktrees section: that
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
                    (cons (herdr-workspace-id workspace)
                          (herdr-tree--workspace-node
                           state workspace nil width worktree-width)))
                  (seq-filter (lambda (workspace)
                                (assoc (herdr-workspace-id workspace)
                                       nesting))
                              workspaces))))
    (append (mapcar
             (lambda (workspace)
               (let ((id (herdr-workspace-id workspace)))
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
                           (assoc (herdr-workspace-id workspace) nesting))
                         workspaces)))))

(defconst herdr-tree-queue-sections
  '(("blocked" . "BLOCKED") ("done" . "READY")
    ("working" . "WORKING") ("idle" . "IDLE")
    ("unknown" . "UNKNOWN"))
  "Agent statuses as the queue heads them, worst-first.

herdr\\='s own words where it has one and the queue\\='s where it reads
better.  `done\\=' is headed READY because that is what it means: herdr
says `idle\\=' and `done\\=' both mean ready for input and uses its seen
state to tell them apart, so `done\\=' is work finished that nobody has
looked at yet.  `unknown\\=' keeps a heading of its own rather than
joining IDLE — herdr says it does not prove completion, so it must not
read as nothing to do.")

(defun herdr-tree--queue-row (state pane machine width)
  "Return the queue row for PANE in STATE, its agent column WIDTH wide.

A `herdr-pane\\=' node like any other, so every verb already aimed at a
pane row works here with no arm of its own.

MACHINE, when given, is the name of the machine the pane is on, carried
as a text property rather than shown: a queue is sorted by attention and
not by machine, so a row has no machine heading above it to be read off.
A name rather than a connection, because a section outlives the redraws
around it and a reconnect replaces the struct."
  (let* ((id (herdr-pane-id pane))
         (status (or (herdr-state-pane-status state pane) "unknown"))
         (face (herdr-tree-status-face status))
         (name (herdr-pane-name pane))
         (line (string-trim-right
                (format (format "%%s %%-%ds %%-34s %%s" width)
                        (herdr-tree--faced (herdr-tree-glyph status) face)
                        (herdr-tree--agent-label state pane)
                        (if (string-empty-p name) id name)
                        (herdr-tree--faced
                         (or (herdr-state-workspace-label
                              state (herdr-pane-workspace-id pane))
                             (herdr-pane-workspace-id pane) "")
                         'font-lock-comment-face)))))
    (list 'herdr-pane id
          (if machine (propertize line 'herdr-machine machine) line)
          nil)))

(defun herdr-tree-queue-nodes (entries)
  "Return the attention queue over ENTRIES, one (MACHINE-NAME . STATE) each.

One section per status that has agents in it, worst first, and inside a
section the highest `state_change_seq\\=' first — the most recent news at
the top of the group that wants you most.  That counter is the only
ordering a pane record carries; no field says when a change happened.

MACHINE-NAME is nil when only one machine is connected, which keeps a
single-machine queue free of a name that says nothing.

Pure: the panes come from the states handed in, so the queue is built
and asserted without a buffer or a server."
  (let ((width (apply #'max herdr-tree-agent-column-min
                      (mapcar (lambda (entry)
                                (herdr-tree--agent-column-width (cdr entry)))
                              entries))))
    (delq nil
          (mapcar
           (lambda (section)
             (let* ((status (car section))
                    (rows (sort
                           (seq-mapcat
                            (lambda (entry)
                              (mapcar
                               (lambda (pane) (cons (car entry) pane))
                               (seq-filter
                                (lambda (pane)
                                  (equal status
                                         (or (herdr-state-pane-status
                                              (cdr entry) pane)
                                             "unknown")))
                                (herdr-state-agents (cdr entry)))))
                            entries)
                           (lambda (a b)
                             (> (or (herdr-pane-state-change-seq (cdr a)) 0)
                                (or (herdr-pane-state-change-seq (cdr b)) 0))))))
               (when rows
                 (list 'herdr-queue status
                       (format "%s (%s)" (cdr section) (length rows))
                       (mapcar
                        (lambda (row)
                          (herdr-tree--queue-row
                           (cdr (assoc (car row) entries)) (cdr row)
                           (car row) width))
                        rows)))))
           herdr-tree-queue-sections))))

(defface herdr-tree-machine
  '((t :inherit magit-section-heading))
  "Face for the row naming a machine, drawn only when there are several."
  :group 'herdr)

(defface herdr-tree-machine-down
  '((t :inherit shadow))
  "Face for the row naming a machine that is not being followed."
  :group 'herdr)

(defun herdr-tree-machine-node (name reachable children)
  "Return the node holding CHILDREN, the tree of the machine called NAME.

A machine, which is herdr\\='s own word for it: `herdr machine\\=' is the
catalog these names come from, and the TUI heads this level `machines\\='.
The connection is how the package reaches one; the machine is the thing
reached, and the row names the thing.

Drawn only when more than one is connected, so that nobody following one
sees a level that says nothing.

A machine that REACHABLE reports as down is drawn as itself, dimmed and
labelled, rather than left out.  An empty dashboard and an unreachable
machine are different facts, and a row that disappears when a laptop
sleeps tells you the wrong one."
  (list 'herdr-machine name
        (herdr-tree--faced
         (if reachable
             (format "%s (%d)" name (length children))
           (format "%s  not connected" name))
         (if reachable 'herdr-tree-machine 'herdr-tree-machine-down))
        children))

(provide 'herdr-tree)
;;; herdr-tree.el ends here
