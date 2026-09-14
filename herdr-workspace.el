;;; herdr-workspace.el --- What a workspace is called -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A workspace answers two questions about what it is called, the same
;; two a pane answers.
;;
;; Its NAME is the label somebody chose.  It can be absent, and a
;; workspace the server labelled with an empty string has no name at
;; all - the case a plain `or' fallback never catches, because an empty
;; string is truthy in Emacs Lisp.
;;
;; Its IDENTITY is what you call it when the answer must not be empty:
;; the label, else the id.
;;
;; A leaf, like `herdr-pane': nothing here requires another herdr
;; module.  What a record cannot answer stays where the pane list is -
;; a workspace's directory is walked out of its panes by
;; `herdr-state-workspace-directory', because `WorkspaceInfo' carries no
;; cwd.

;;; Code:

(require 'subr-x)

(defun herdr-workspace--said (string)
  "Return STRING when it says something, nil when it is empty or absent.
The server sends an empty label for a workspace nobody has named, and an
empty string is a name that reads as a missing one."
  (unless (or (null string) (string-empty-p string)) string))

;;; Fields
;;
;; The wire names live here and nowhere else, so a protocol rename is
;; one file's problem.

(defun herdr-workspace-id (workspace)
  "Return WORKSPACE\\='s id."
  (alist-get 'workspace_id workspace))

(defun herdr-workspace-label (workspace)
  "Return the label somebody set on WORKSPACE, or nil.
Nil for an empty label too, which is what the server sends for a
workspace nobody has named."
  (herdr-workspace--said (alist-get 'label workspace)))

(defun herdr-workspace-pane-count (workspace)
  "Return how many panes herdr reports in WORKSPACE, or nil."
  (alist-get 'pane_count workspace))

(defun herdr-workspace-status (workspace)
  "Return the busiest agent status herdr reports for WORKSPACE, or nil."
  (alist-get 'agent_status workspace))

;;; Names

(defun herdr-workspace-name (workspace)
  "Return what WORKSPACE is called, or nil when nobody has named it.
Callers that must print something fall back to
`herdr-workspace-identity\\='."
  (herdr-workspace-label workspace))

(defun herdr-workspace-identity (workspace)
  "Return what to call WORKSPACE when the answer must not be empty.
The label, else the id.  An empty label counts as absent, so a workspace
the server labelled \"\" reads as its id rather than as nothing."
  (or (herdr-workspace-label workspace)
      (herdr-workspace-id workspace)))

(provide 'herdr-workspace)
;;; herdr-workspace.el ends here
