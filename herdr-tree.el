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
;; Kept separate from the renderer for one concrete reason: `make test'
;; runs under `emacs -Q -L .', where magit-section is not on the load
;; path.  A model that the hermetic suite cannot reach is a model that
;; does not get tested, and nearly all the logic worth testing is here.

;;; Code:

(require 'seq)
(require 'subr-x)
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
  "Return an alist of (STATUS . COUNT) over the real agents in STATE.
Real agents only: `herdr-state-agents\\=' excludes adopted shells, which
have no status lifecycle worth counting.  Shared by the modeline segment
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
Adopted shells are marked rather than named, since they have no agent
lifecycle.  A name set through `agent.rename\\=' is appended to the kind."
  (if (herdr-state-shell-pane-p pane)
      "shell*"
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

(defun herdr-tree--pane-node (state pane width)
  "Return the node for PANE in STATE, its agent column WIDTH wide.

A pane row is a leaf: the renderer inserts it as ordinary content rather
than as a section heading, so the faces here are all the shape it gets.
The status governs both the glyph and the word, which makes the leading
column a colour strip you can read down without reading any of the
words."
  (let* ((id (alist-get 'pane_id pane))
         (shell (herdr-state-shell-pane-p pane))
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
                   (herdr-tree--faced
                    (or (alist-get 'terminal_title_stripped pane) "")
                    'font-lock-doc-face)))
          nil)))

(defun herdr-tree--panes-in-tab (state tab-id width)
  "Return the nodes for every pane of TAB-ID in STATE, agent column WIDTH wide."
  (mapcar (lambda (pane) (herdr-tree--pane-node state pane width))
          (seq-filter (lambda (pane)
                        (equal tab-id (alist-get 'tab_id pane)))
                      (herdr-state-panes state))))

(defun herdr-tree--orphan-panes-in-workspace (state workspace-id width)
  "Return nodes for WORKSPACE-ID\\='s panes whose tab is not in STATE.

Panes are drawn under their tab, so a pane naming a tab the cache does
not hold would otherwise be drawn nowhere at all: the workspace heading
would go on counting it while no row existed to read, prompt or close it.

That state is reachable rather than theoretical — a `tab_created\\=' event
carrying no `tab\\=' payload is dropped, and a resync races the events
around it — and losing a pane is the one failure the flat listing this
tree replaced could not have.  Showing them directly under the workspace
keeps every pane reachable no matter what the tab cache knows."
  (let ((known (mapcar (lambda (tab) (alist-get 'tab_id tab))
                       (herdr-state-tabs state))))
    (mapcar (lambda (pane) (herdr-tree--pane-node state pane width))
            (seq-filter (lambda (pane)
                          (and (equal workspace-id
                                      (alist-get 'workspace_id pane))
                               (not (member (alist-get 'tab_id pane) known))))
                        (herdr-state-panes state)))))

(defun herdr-tree--tab-node (state tab width)
  "Return the node for TAB in STATE, its pane column WIDTH wide."
  (let ((id (alist-get 'tab_id tab)))
    (list 'herdr-tab id
          (string-trim-right
           (format "%-28s %s"
                   (format "%s (%s)"
                           (or (alist-get 'label tab) id)
                           (or (alist-get 'pane_count tab) 0))
                   (herdr-tree--rollup (alist-get 'agent_status tab))))
          (herdr-tree--panes-in-tab state id width))))

(defun herdr-tree--tabs-in-workspace (state workspace-id)
  "Return TABs of WORKSPACE-ID in STATE, in cache order."
  (seq-filter (lambda (tab)
                (equal workspace-id (alist-get 'workspace_id tab)))
              (herdr-state-tabs state)))

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

(defun herdr-tree--worktree-node (worktree)
  "Return the node for WORKTREE.
A worktree already open as a workspace is shown above as that workspace,
so it is marked rather than repeated."
  (let ((open (alist-get 'open_workspace_id worktree)))
    (list 'herdr-worktree (alist-get 'path worktree)
          (string-trim-right
           (format "%-28s %s"
                   (or (alist-get 'branch worktree)
                       (alist-get 'label worktree)
                       "?")
                   (if open
                       (herdr-tree--faced (format "open as %s" open) 'shadow)
                     "")))
          nil)))

(defun herdr-tree--worktrees-node (workspace-id worktrees)
  "Return the worktrees node for WORKSPACE-ID, or nil when it has none.

Only the linked worktrees; see `herdr-tree-linked-worktree-p\\=' for what
the other kind is and what listing it cost.  A workspace whose repository
has no linked worktrees at all is therefore the ordinary case rather than
an unusual one, and it gets no section: what a `worktrees (1)\\=' heading
listed there was the workspace itself, one line above and already on
screen.

Nil covers three things now — \\='none were found\\=', \\='none have been
fetched yet\\=' and \\='none of what was found is a worktree of its own\\='.
A workspace with nothing to show has no section worth drawing whichever
of those it is, and the distinction between the first two lives in the
cache that builds WORKTREES rather than here."
  (when-let* ((entry (assoc workspace-id worktrees))
              (found (seq-filter #'herdr-tree-linked-worktree-p (cdr entry))))
    (list 'herdr-worktrees workspace-id
          (format "worktrees (%s)" (length found))
          (mapcar #'herdr-tree--worktree-node found))))

(defun herdr-tree--workspace-node (state workspace worktrees width)
  "Return the node for WORKSPACE in STATE, including WORKTREES.
WIDTH is the agent column width, computed once in `herdr-tree-build\\='
and threaded down to every pane in this workspace.

The pane count rides in parentheses on the label — `repo (3)\\=' — rather
than as a `3 panes\\=' column of its own.  That is magit's idiom for the
same thing (`Unstaged changes (1)\\='), and it is the shape that reads as
a container: a heading that owns a countable number of children, told
apart at a glance from the leaf rows that own none.  The tab and
worktrees headings are counted the same way for the same reason."
  (let* ((id (alist-get 'workspace_id workspace))
         (tabs (herdr-tree--tabs-in-workspace state id))
         ;; One tab is not structure.  Unnamed tabs are labelled by
         ;; number, so keeping the level would indent every pane behind a
         ;; heading that reads "1".
         ;; Panes whose tab the cache does not hold sit alongside the tab
         ;; nodes rather than being dropped with the tab they name.
         (children (append (if (= (length tabs) 1)
                               (herdr-tree--panes-in-tab
                                state (alist-get 'tab_id (car tabs)) width)
                             (mapcar (lambda (tab)
                                       (herdr-tree--tab-node state tab width))
                                     tabs))
                           (herdr-tree--orphan-panes-in-workspace state id width)))
         (worktree-node (herdr-tree--worktrees-node id worktrees)))
    (list 'herdr-workspace id
          (string-trim-right
           (format "%-28s %-30s %s"
                   (format "%s (%s)"
                           (or (alist-get 'label workspace) id)
                           (or (alist-get 'pane_count workspace) 0))
                   (herdr-tree--faced
                    (or (herdr-state-workspace-directory state id) "")
                    'font-lock-comment-face)
                   (herdr-tree--rollup (alist-get 'agent_status workspace))))
          (if worktree-node (append children (list worktree-node)) children))))

(defun herdr-tree-build (state worktrees)
  "Return the dispatcher tree for STATE.

Each node is the list (TYPE VALUE LINE CHILDREN).  TYPE is one of
`herdr-workspace\\=', `herdr-tab\\=', `herdr-pane\\=', `herdr-worktrees\\=' or
`herdr-worktree\\='; VALUE is the id a command needs; LINE is the rendered
text; CHILDREN is a list of nodes.

WORKTREES is an alist of (WORKSPACE-ID . LIST-OF-WORKTREEINFO) for the
workspaces whose worktrees have been fetched.  A workspace missing from
it simply gets no worktrees section — absence of knowledge, not absence
of worktrees.

The agent column width is computed once here, from every pane in STATE,
so it is consistent across every workspace rather than fitted separately
per tab — a session with one long label in one workspace and only short
ones in another would otherwise show two different column widths."
  (let ((width (herdr-tree--agent-column-width state)))
    (mapcar (lambda (workspace)
              (herdr-tree--workspace-node state workspace worktrees width))
            (herdr-state-workspaces state))))

(provide 'herdr-tree)
;;; herdr-tree.el ends here
