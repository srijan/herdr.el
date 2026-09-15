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
;; This record was the one left reading its fields raw, in two modules,
;; and the field that mattered was the one naming a workspace: a bare id
;; from whichever server answered the listing.
;;
;; The listing is what a row is resolved through, so the id has to be
;; read somewhere that can say whose it is.  `herdr-worktree-open-workspace'
;; is that place: it pairs the id with the connection the listing came
;; from, which is what a lookup across two servers has to compare.

;;; Code:

(require 'subr-x)
(require 'herdr-rpc)

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
  "Return the bare id of the workspace WORKTREE is open as, or nil.

Bare, and therefore only meaningful alongside the connection whose
listing this record came from.  Use `herdr-worktree-open-workspace\\='
wherever the answer is compared against a workspace, and this one only
where the id is being shown or sent back to the server that issued it."
  (alist-get 'open_workspace_id worktree))

(defun herdr-worktree-open-workspace (connection worktree)
  "Return (TOKEN . WORKSPACE-ID) for the workspace WORKTREE is open as.

Nil when it is open as nothing.  CONNECTION is the one whose listing
WORKTREE came from, and pairing it with the id is what stops two servers
that each issued a `w1\\=' being read as one workspace.  The token, not
the struct, per KTD2: the struct is mutable and `equal\\=' on one compares
fields, so a pair holding it would stop matching the moment a cache slot
changed."
  (when-let* ((id (herdr-worktree-open-workspace-id worktree)))
    (cons (herdr-connection-token connection) id)))

(defun herdr-worktree-open-as-p (connection worktree workspace)
  "Return non-nil when WORKTREE is open as WORKSPACE on CONNECTION.

WORKSPACE is a (TOKEN . WORKSPACE-ID) pair, as
`herdr-worktree-open-workspace\\=' returns and
`herdr-workspace-qualified\\=' builds.  Comparing bare ids here is the
defect this exists to prevent: a worktree on one server open as `w1\\='
would read as the `w1\\=' of whichever server the caller was looking at."
  (let ((open (herdr-worktree-open-workspace connection worktree)))
    (and open workspace (equal open workspace))))

(defun herdr-workspace-qualified (connection workspace-id)
  "Return (TOKEN . WORKSPACE-ID) for WORKSPACE-ID on CONNECTION.
The other side of `herdr-worktree-open-workspace\\=': what a caller
holding a bare id turns it into before comparing."
  (when workspace-id
    (cons (herdr-connection-token connection) workspace-id)))

(provide 'herdr-worktree)
;;; herdr-worktree.el ends here
