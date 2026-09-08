;;; herdr-pane.el --- What a pane is called -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A pane answers two different questions about what it is called, and
;; they used to be two functions of the same name in two files named
;; after surfaces rather than after the question.
;;
;; Its NAME is what it is doing: the label somebody chose, and the title
;; the thing inside announces.  It moves as work moves, it can be empty,
;; and it is what the dashboard, the pickers, the notifier and the
;; confirmations show.
;;
;; Its IDENTITY is what you call it when the answer must not move under
;; you.  It is never empty, and it is what a buffer name is built from -
;; a buffer named after a terminal title would be renamed on every
;; command.
;;
;; A leaf: nothing here requires another herdr module.  What identity
;; cannot read off the record - the name `agent.rename' set, the label
;; of the pane's workspace - arrives as an argument, so both names are
;; pure functions of what they are handed and neither needs a cache to
;; test.

;;; Code:

(require 'subr-x)
(require 'regexp-opt)

(defconst herdr-pane-spinner-glyphs '(?◐ ?◑)
  "Characters an agent animates at the head of its terminal title.
`terminal_title_stripped\\=' strips ANSI, not these.  Only these two were
measured; another agent animating a different glyph costs one redraw a
second on that pane, and adding its glyph here is the whole fix.

A list of characters, not a string: `herdr-pane-steady-title\\=' builds a
regexp character class from it through `regexp-opt-charset\\=', which is
what quotes `]\\=', `-\\=' and `^\\=' correctly.")

(defun herdr-pane-steady-title (title)
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
   (concat "\\`" (regexp-opt-charset herdr-pane-spinner-glyphs)
           "+[[:space:]]*")
   "" title))

(defun herdr-pane-name (pane)
  "Return what PANE is doing: its label, its title, or both.
The label is what somebody chose to call the pane; the terminal title is
what the thing inside it announces.  Both are shown, joined by a middle
dot, because the label alone cannot say what an agent is working on and
the title alone cannot tell two panes running the same agent apart.

Degrades to whichever exists, and does not print a title that merely
repeats the label.  Empty when the pane has neither, which is why
callers that must print something fall back to `herdr-pane-identity\\='."
  (let ((label (alist-get 'label pane))
        (title (herdr-pane-steady-title
                (or (alist-get 'terminal_title_stripped pane) ""))))
    (cond
     ((or (null label) (string-empty-p label)) title)
     ((or (string-empty-p title) (equal title label)) label)
     (t (concat label " · " title)))))

(defun herdr-pane-identity (pane &optional rename workspace-label)
  "Return what to call PANE when the answer must not move under you.
In order: RENAME, the name `agent.rename\\=' set; then the pane\\='s own
`label\\='; then KIND@WORKSPACE; then a bare KIND.

RENAME and WORKSPACE-LABEL are the two facts this cannot read off PANE,
and callers that have a cache pass them in.  Without WORKSPACE-LABEL the
workspace half falls back to the id PANE carries, so a workspace the
cache has not caught up with still tells two panes apart rather than
collapsing them onto one name.

Not unique.  Two unnamed panes of the same kind in one workspace have
the same identity, so callers that name a buffer with it must uniquify."
  (let ((label (alist-get 'label pane))
        (kind (or (alist-get 'display_agent pane)
                  (alist-get 'agent pane)
                  "shell"))
        (workspace (or workspace-label (alist-get 'workspace_id pane))))
    (or rename label
        (if workspace (format "%s@%s" kind workspace) kind))))

(provide 'herdr-pane)
;;; herdr-pane.el ends here
