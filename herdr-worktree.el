;;; herdr-worktree.el --- What a worktree record says -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A `WorktreeInfo' answers where it is, what branch it holds, and
;; whether herdr has it open as a workspace.
;;
;; A leaf, like `herdr-pane' and `herdr-workspace': the wire names live
;; here and nowhere else, so a protocol rename is one file's problem.
;;
;; `open_workspace_id' is a bare id, meaningful only beside the
;; connection whose listing the record came from.  Every comparison in
;; the package is made within one connection's listings, so it is
;; compared bare; see `herdr-tree-own-workspace-p'.

;;; Code:

(require 'subr-x)

;;; Fields

(defun herdr-worktree-path (worktree)
  "Return WORKTREE\\='s path on its server\\='s filesystem."
  (alist-get 'path worktree))

(defun herdr-worktree-branch (worktree)
  "Return the branch WORKTREE holds, or nil."
  (alist-get 'branch worktree))

(defun herdr-worktree-label (worktree)
  "Return WORKTREE\\='s label, or nil."
  (alist-get 'label worktree))

(defun herdr-worktree-name (worktree)
  "Return what to call WORKTREE: its branch, else its label, else \"?\".
Never empty, because it is a column."
  (or (herdr-worktree-branch worktree)
      (herdr-worktree-label worktree)
      "?"))

(defun herdr-worktree-linked-p (worktree)
  "Return non-nil when WORKTREE is a linked worktree, not the main checkout.
`is_linked_worktree\\=' is the only field that can tell them apart.

Absent reads as not linked.  The field is required, so absence means a
reply the schema does not describe: treating it as the main checkout
costs a row, treating it as linked costs whatever a verb on that row
would do to the repository."
  (and (alist-get 'is_linked_worktree worktree) t))

(defun herdr-worktree-open-workspace-id (worktree)
  "Return the id of the workspace WORKTREE is open as, or nil."
  (alist-get 'open_workspace_id worktree))

(provide 'herdr-worktree)
;;; herdr-worktree.el ends here
