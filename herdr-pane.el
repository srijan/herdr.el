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

(require 'seq)
(require 'subr-x)
(require 'regexp-opt)

;;; Fields
;;
;; The wire names live here and nowhere else.  Most of these are one
;; line; the point is not what they compute but that a protocol rename
;; is one file's problem, which it was not when six files read the
;; record themselves.

(defun herdr-pane-id (pane)
  "Return PANE\\='s id."
  (alist-get 'pane_id pane))

(defun herdr-pane-workspace-id (pane)
  "Return the id of the workspace PANE belongs to, or nil."
  (alist-get 'workspace_id pane))

(defun herdr-pane-tab-id (pane)
  "Return the id of the tab PANE sits in, or nil."
  (alist-get 'tab_id pane))

(defun herdr-pane-label (pane)
  "Return the label somebody set on PANE, or nil."
  (alist-get 'label pane))

(defun herdr-pane-title (pane)
  "Return PANE\\='s terminal title with ANSI already stripped, or nil.
Still carries an animated spinner; `herdr-pane-steady-title\\=' is what
takes that off."
  (alist-get 'terminal_title_stripped pane))

(defun herdr-pane-status (pane)
  "Return the agent status herdr reports for PANE, or nil.
One of \"working\", \"blocked\", \"done\", \"idle\" - or nil for a pane with
no agent in it."
  (alist-get 'agent_status pane))

(defun herdr-pane-agent (pane)
  "Return the agent detected in PANE, or nil.
The detected kind, not the one to show: `display_agent\\=' outranks this
for display but does not decide whether a pane has an agent at all."
  (alist-get 'agent pane))

(defun herdr-pane-agent-p (pane)
  "Return non-nil when PANE has an agent in it."
  (and (herdr-pane-agent pane) t))

(defun herdr-pane-display-agent (pane)
  "Return the agent kind to show for PANE, or nil.
`display_agent\\=' is what the server wants shown - a plugin pane seated
with a manifest name has one - and it falls back to the detected agent."
  (or (alist-get 'display_agent pane)
      (alist-get 'agent pane)))

(defun herdr-pane-directory (pane)
  "Return PANE\\='s working directory as a directory name, or nil.

herdr tracks cwd itself and republishes it as panes change directory,
which is what makes this possible: it consumes OSC 7 rather than
forwarding it, so a terminal buffer fronting a herdr pane has no other
way to know where it is.

`foreground_cwd\\=' is the fallback: a pane that has not reported a cwd of
its own may still say where its foreground process is."
  (when-let* ((dir (or (alist-get 'cwd pane)
                       (alist-get 'foreground_cwd pane))))
    (when (file-directory-p dir)
      (file-name-as-directory dir))))

(defun herdr-pane-cwd (pane)
  "Return the cwd PANE reports, unchecked, or nil.
`herdr-pane-directory\\=' is the one to use when the answer must name a
directory that exists; this is the raw field, for showing."
  (alist-get 'cwd pane))

(defun herdr-pane-terminal-id (pane)
  "Return the raw terminal stream id for PANE, signalling when absent.
`herdr terminal attach\\=' wants this rather than the pane id, and only
the pane record knows it."
  (or (alist-get 'terminal_id pane)
      (user-error "herdr: pane %s has no terminal_id; herdr 0.8.2+ required"
                  (herdr-pane-id pane))))

(defun herdr-pane-attach-args (pane takeover)
  "Return the argv tail for attaching to PANE, stealing it when TAKEOVER."
  (append (list "terminal" "attach" (herdr-pane-terminal-id pane))
          (when takeover '("--takeover"))))

(defconst herdr-pane-significant-fields
  '(agent agent_status cwd foreground_cwd workspace_id tab_id label)
  "Pane fields worth reacting to when reconciling against `pane.list\\='.

Excludes the volatile ones: revision, scroll and the terminal title.
The title especially, however stable it looks - an agent animates a
spinner and a second counter inside it, so it changes several times a
second and every poll would declare a change.  `label\\=' is included
because only a person or a plugin sets it.

A record differing only in excluded fields is still refreshed, silently,
without running the change hook; see `herdr-state-reconcile-panes\\='.

`revision\\=' is not a staleness guard.  herdr bumps it for presentation
metadata only, never for `agent_status\\=' (0.8.2, terminal/state.rs), so
it cannot order status updates.")

(defun herdr-pane-differs-p (known fresh)
  "Return non-nil when FRESH differs from KNOWN in a field worth noticing."
  (seq-some (lambda (field)
              (not (equal (alist-get field known) (alist-get field fresh))))
            herdr-pane-significant-fields))


;;; Names

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
  (let ((label (herdr-pane-label pane))
        (title (herdr-pane-steady-title (or (herdr-pane-title pane) ""))))
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
  (let ((label (herdr-pane-label pane))
        (kind (or (herdr-pane-display-agent pane) "shell"))
        (workspace (or workspace-label (herdr-pane-workspace-id pane))))
    (or rename label
        (if workspace (format "%s@%s" kind workspace) kind))))

(provide 'herdr-pane)
;;; herdr-pane.el ends here
