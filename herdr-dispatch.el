;;; herdr-dispatch.el --- The herdr dispatcher buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (magit-section "3.3"))

;;; Commentary:

;; `*herdr-agents*': one buffer showing the whole session as a foldable
;; workspace/tab/pane tree, and the place every command is reachable
;; from.
;;
;; The tree itself is data, built by `herdr-tree'.  This file only
;; renders it, resolves the object under point, and hands that object to
;; the commands in `herdr-cmd' — which already take explicit ids, so no
;; command logic is duplicated here.

;;; Code:

(require 'subr-x)
(require 'magit-section)
(require 'herdr-tree)
(require 'herdr-state)

(defcustom herdr-dispatch-buffer-name "*herdr-agents*"
  "Name of the dispatcher buffer."
  :type 'string
  :group 'herdr)

(defvar herdr-dispatch--worktrees nil
  "Alist of (WORKSPACE-ID . LIST-OF-WORKTREEINFO) for expanded workspaces.
Filled lazily; see `herdr-dispatch--worktrees-for'.")

(defvar herdr-dispatch-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map "g" #'herdr-dispatch-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `herdr-dispatch-mode'.
Verbs are added in the command-surface layer; this holds only what the
buffer needs to be readable.")

(define-derived-mode herdr-dispatch-mode magit-section-mode "herdr"
  "Major mode for the herdr dispatcher."
  (setq-local revert-buffer-function
              (lambda (&rest _) (herdr-dispatch-refresh))))

(defun herdr-dispatch--insert-nodes (nodes)
  "Insert NODES, each (TYPE VALUE LINE CHILDREN), as magit sections.

`magit-insert-section\\=' takes its type as an unevaluated symbol, so the
five types are spelled out rather than passed through.  A runtime `eval\\='
would collapse these into one branch; five explicit branches byte-compile
and do not need defending."
  (dolist (node nodes)
    (let ((value (nth 1 node))
          (line (nth 2 node))
          (children (nth 3 node)))
      (pcase (nth 0 node)
        ('herdr-workspace
         (magit-insert-section (herdr-workspace value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))
        ('herdr-tab
         (magit-insert-section (herdr-tab value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))
        ('herdr-pane
         (magit-insert-section (herdr-pane value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))
        ('herdr-worktrees
         (magit-insert-section (herdr-worktrees value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))
        ('herdr-worktree
         (magit-insert-section (herdr-worktree value)
           (magit-insert-heading line)
           (herdr-dispatch--insert-nodes children)))))))

(defun herdr-dispatch--header (state)
  "Return the header line summarising STATE."
  (format "herdr   %d workspaces  %d panes  %d agents"
          (length (herdr-state-workspaces state))
          (length (herdr-state-panes state))
          (length (herdr-state-agents state))))

(defun herdr-dispatch-refresh ()
  "Redraw the dispatcher from the cache, keeping point and fold state."
  (interactive)
  (when-let* ((buffer (get-buffer herdr-dispatch-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (state (herdr-state-current)))
        ;; Point is restored by section identity rather than by line
        ;; number: a pane closing above point used to move you to a
        ;; different agent than the one you were reading.
        ;;
        ;; Fold state needs no saving here.  `magit-section-hide' and
        ;; `magit-section-show' write to `magit-section-visibility-cache'
        ;; as they go, and `magit-section-set-visibility-hook' reads it
        ;; back when each section is recreated below.
        (let ((ident (and (magit-current-section)
                          (magit-section-ident (magit-current-section)))))
          (erase-buffer)
          (magit-insert-section (herdr-root)
            (magit-insert-heading (herdr-dispatch--header state))
            (herdr-dispatch--insert-nodes
             (herdr-tree-build state herdr-dispatch--worktrees)))
          (when ident
            (when-let* ((section (magit-get-section ident)))
              (goto-char (oref section start)))))))))

(defun herdr-dispatch--refresh-hook (&rest _)
  "Refresh the dispatcher, or unhook when its buffer is gone."
  (if (get-buffer herdr-dispatch-buffer-name)
      (herdr-dispatch-refresh)
    (remove-hook 'herdr-state-change-hook #'herdr-dispatch--refresh-hook)))

;;;###autoload
(defun herdr-agents ()
  "Show the herdr dispatcher: workspaces, tabs, panes and agents."
  (interactive)
  (let ((buffer (get-buffer-create herdr-dispatch-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'herdr-dispatch-mode) (herdr-dispatch-mode))
      (add-hook 'herdr-state-change-hook #'herdr-dispatch--refresh-hook))
    (herdr-dispatch-refresh)
    (pop-to-buffer buffer)))

(provide 'herdr-dispatch)
;;; herdr-dispatch.el ends here
