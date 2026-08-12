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

(defconst herdr-tree-noteworthy-statuses '("blocked" "working" "done")
  "Statuses worth showing on a collapsed section.
Idle is omitted for the same reason the modeline omits it: a marker that
is always on screen stops being read.")

(defun herdr-tree--rollup (status)
  "Return the glyph for STATUS on a collapsed section, or an empty string."
  (if (member status herdr-tree-noteworthy-statuses)
      (herdr-tree-glyph status)
    ""))

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

(defun herdr-tree--pane-node (state pane)
  "Return the node for PANE in STATE."
  (let ((id (alist-get 'pane_id pane))
        (shell (herdr-state-shell-pane-p pane)))
    (list 'herdr-pane id
          (string-trim-right
           (format "%s %-14s %-8s %-8s %s"
                   (if shell "~" (herdr-tree-glyph
                                  (alist-get 'agent_status pane)))
                   (herdr-tree--agent-label state pane)
                   (if shell "" (or (alist-get 'agent_status pane) ""))
                   id
                   (or (alist-get 'terminal_title_stripped pane) "")))
          nil)))

(defun herdr-tree--panes-in-tab (state tab-id)
  "Return the nodes for every pane of TAB-ID in STATE."
  (mapcar (lambda (pane) (herdr-tree--pane-node state pane))
          (seq-filter (lambda (pane)
                        (equal tab-id (alist-get 'tab_id pane)))
                      (herdr-state-panes state))))

(defun herdr-tree--tab-node (state tab)
  "Return the node for TAB in STATE."
  (let ((id (alist-get 'tab_id tab)))
    (list 'herdr-tab id
          (string-trim-right
           (format "%-24s %s %s"
                   (or (alist-get 'label tab) id)
                   (format "%s panes" (or (alist-get 'pane_count tab) 0))
                   (herdr-tree--rollup (alist-get 'agent_status tab))))
          (herdr-tree--panes-in-tab state id))))

(defun herdr-tree--tabs-in-workspace (state workspace-id)
  "Return TABs of WORKSPACE-ID in STATE, in cache order."
  (seq-filter (lambda (tab)
                (equal workspace-id (alist-get 'workspace_id tab)))
              (herdr-state-tabs state)))

(defun herdr-tree--worktree-node (worktree)
  "Return the node for WORKTREE.
A worktree already open as a workspace is shown above as that workspace,
so it is marked rather than repeated."
  (let ((open (alist-get 'open_workspace_id worktree)))
    (list 'herdr-worktree (alist-get 'path worktree)
          (string-trim-right
           (format "%-24s %s"
                   (or (alist-get 'branch worktree)
                       (alist-get 'label worktree)
                       "?")
                   (if open (format "open as %s" open) "")))
          nil)))

(defun herdr-tree--worktrees-node (workspace-id worktrees)
  "Return the worktrees node for WORKSPACE-ID, or nil when it has none to
show.

Nil covers both \\='none were found\\=' and \\='none have been fetched yet\\=':
a workspace with zero worktrees has no section worth drawing either way.
The distinction between the two lives in the cache that builds WORKTREES,
not here."
  (when-let* ((entry (assoc workspace-id worktrees))
              (found (cdr entry)))
    (list 'herdr-worktrees workspace-id
          (format "worktrees %s" (length found))
          (mapcar #'herdr-tree--worktree-node found))))

(defun herdr-tree--workspace-node (state workspace worktrees)
  "Return the node for WORKSPACE in STATE, including WORKTREES."
  (let* ((id (alist-get 'workspace_id workspace))
         (tabs (herdr-tree--tabs-in-workspace state id))
         ;; One tab is not structure.  Unnamed tabs are labelled by
         ;; number, so keeping the level would indent every pane behind a
         ;; heading that reads "1".
         (children (if (= (length tabs) 1)
                       (herdr-tree--panes-in-tab
                        state (alist-get 'tab_id (car tabs)))
                     (mapcar (lambda (tab) (herdr-tree--tab-node state tab))
                             tabs)))
         (worktree-node (herdr-tree--worktrees-node id worktrees)))
    (list 'herdr-workspace id
          (string-trim-right
           (format "%-24s %-28s %s %s"
                   (or (alist-get 'label workspace) id)
                   (or (herdr-state-workspace-directory state id) "")
                   (format "%s panes" (or (alist-get 'pane_count workspace) 0))
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
of worktrees."
  (mapcar (lambda (workspace)
            (herdr-tree--workspace-node state workspace worktrees))
          (herdr-state-workspaces state)))

(provide 'herdr-tree)
;;; herdr-tree.el ends here
