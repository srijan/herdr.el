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
(require 'seq)
(require 'magit-section)
(require 'herdr-tree)
(require 'herdr-state)
(require 'herdr-rpc)
(require 'herdr-cmd)

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
    (define-key map (kbd "RET") #'herdr-dispatch-visit)
    (define-key map "p" #'herdr-dispatch-prompt)
    (define-key map "r" #'herdr-dispatch-read)
    (define-key map "f" #'herdr-dispatch-focus)
    (define-key map "R" #'herdr-dispatch-rename)
    (define-key map "k" #'herdr-dispatch-close)
    (define-key map (kbd "TAB") #'herdr-dispatch-toggle)
    map)
  "Keymap for `herdr-dispatch-mode'.
Lowercase letters are the read-only verbs; each acts on whatever the
line under point names, so no key needs a target of its own.")

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

;;; The object at point

(defun herdr-dispatch--value-at-point (type)
  "Return the value of the nearest enclosing section of TYPE, or nil.
Walks up rather than down: a verb invoked on a pane line inside a
workspace should reach the workspace too."
  (let ((section (magit-current-section))
        (found nil))
    (while (and section (not found))
      (when (eq type (oref section type))
        (setq found (oref section value)))
      (setq section (oref section parent)))
    found))

(defun herdr-dispatch--require (type what)
  "Return the nearest enclosing TYPE value, or signal that WHAT is needed."
  (or (herdr-dispatch--value-at-point type)
      (user-error "herdr: point is not on %s" what)))

(defun herdr-dispatch--protect (fn)
  "Call FN, reporting a `herdr-error\\=' rather than letting it escape.

A stale cache is the usual cause — the pane closed while you were
looking at it — so `not_found\\=' reconciles and redraws before reporting.
Seeing a correct tree alongside the message is the difference between
\"that pane is gone\" and an opaque failure."
  (condition-case err
      (funcall fn)
    (herdr-error
     (let ((code (herdr-error-code err)))
       (when (equal code "not_found")
         (herdr-state-reconcile-panes)
         (herdr-dispatch-refresh))
       (message "herdr: %s%s" (herdr-error-message err)
                (if (equal code "no_server")
                    " (M-x herdr-start)"
                  (format " [%s]" code)))))))

(defmacro herdr-dispatch-defverb (name args docstring &rest body)
  "Define NAME as an interactive command taking ARGS, running BODY.
BODY is wrapped in `herdr-dispatch--protect\\=', so a server error is
reported rather than raised.  DOCSTRING documents the command."
  (declare (indent 3) (doc-string 3))
  `(defun ,name ,args
     ,docstring
     (interactive)
     (herdr-dispatch--protect (lambda () ,@body))))

;;; Worktrees

(defun herdr-dispatch--worktrees-for (workspace-id)
  "Return WORKSPACE-ID\\='s git worktrees, fetching them once.

Fetched on first expand rather than on every draw: `worktree.list\\=' is a
blocking round trip and there is one per workspace, so drawing them
eagerly would put N synchronous calls in the refresh path."
  (if-let* ((entry (assoc workspace-id herdr-dispatch--worktrees)))
      (cdr entry)
    (let* ((dir (herdr-state-workspace-directory (herdr-state-current)
                                                  workspace-id))
           (found (when dir
                    (alist-get 'worktrees
                               (herdr-rpc-call "worktree.list"
                                               `((cwd . ,dir)))))))
      (push (cons workspace-id found) herdr-dispatch--worktrees)
      found)))

(defun herdr-dispatch--invalidate-worktrees (kind _data)
  "Drop the worktree cache when KIND changed the set of worktrees.
Also unhooks from `herdr-state-change-hook\\=' once the dispatcher's buffer
is gone, matching `herdr-dispatch--refresh-hook\\='.  Whole-cache rather
than per-workspace: the events carry a worktree, not the workspace whose
listing it belongs to, and the refetch is one call per expanded
workspace."
  (when (member kind '("worktree_created" "worktree_opened"
                       "worktree_removed"))
    (setq herdr-dispatch--worktrees nil))
  (unless (get-buffer herdr-dispatch-buffer-name)
    (remove-hook 'herdr-state-change-hook #'herdr-dispatch--invalidate-worktrees)))

(herdr-dispatch-defverb herdr-dispatch-toggle ()
  "Fold or unfold the section at point, fetching worktrees on first open."
  (when-let* ((workspace (herdr-dispatch--value-at-point 'herdr-workspace))
              ((not (assoc workspace herdr-dispatch--worktrees))))
    (herdr-dispatch--worktrees-for workspace)
    (herdr-dispatch-refresh))
  (call-interactively #'magit-section-toggle))

(herdr-dispatch-defverb herdr-dispatch-open-worktree ()
  "Open the worktree at point as a workspace.

Calls `worktree.open\\=' directly rather than through `herdr-worktree-open\\=',
which derives its `cwd\\=' from the calling buffer's `default-directory\\=' —
here that would be `*herdr-agents*\\=', not the worktree's own workspace,
so the request would resolve against whatever directory the dispatcher
buffer happened to hold rather than the workspace at point."
  (let* ((path (herdr-dispatch--require 'herdr-worktree "a worktree"))
         (workspace (herdr-dispatch--require 'herdr-workspace "a workspace"))
         (worktree (seq-find (lambda (candidate)
                               (equal path (alist-get 'path candidate)))
                             (apply #'append
                                    (mapcar #'cdr herdr-dispatch--worktrees)))))
    (if-let* ((open (alist-get 'open_workspace_id worktree)))
        (herdr-workspace-focus open)
      (let ((dir (herdr-state-workspace-directory (herdr-state-current)
                                                   workspace)))
        (herdr-rpc-call "worktree.open"
                        `((branch . ,(alist-get 'branch worktree))
                          (cwd . ,dir)
                          (focus . t)))))))

;;; The read-only verbs

(herdr-dispatch-defverb herdr-dispatch-visit ()
  "Go to the thing at point.
A pane is focused and its buffer shown; a tab or workspace is focused
and then followed to whichever pane herdr lands on, which is the
server\\='s choice rather than ours."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-focus (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-worktree)
    (herdr-dispatch-open-worktree))
   ((herdr-dispatch--value-at-point 'herdr-tab)
    (herdr-tab-focus (herdr-dispatch--value-at-point 'herdr-tab)))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-focus (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point"))))

(herdr-dispatch-defverb herdr-dispatch-prompt ()
  "Prompt the agent at point."
  (let ((pane (herdr-dispatch--require 'herdr-pane "an agent")))
    (herdr-agent-prompt (read-string "Prompt: ") pane)))

(herdr-dispatch-defverb herdr-dispatch-read ()
  "Read the pane at point into a buffer."
  (herdr-pane-read (herdr-dispatch--require 'herdr-pane "a pane")
                   "recent_unwrapped"))

(herdr-dispatch-defverb herdr-dispatch-focus ()
  "Focus the thing at point server-side, without moving Emacs."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-rpc-call "pane.focus"
                    `((pane_id . ,(herdr-dispatch--value-at-point 'herdr-pane)))))
   ((herdr-dispatch--value-at-point 'herdr-tab)
    (herdr-rpc-call "tab.focus"
                    `((tab_id . ,(herdr-dispatch--value-at-point 'herdr-tab)))))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-rpc-call "workspace.focus"
                    `((workspace_id . ,(herdr-dispatch--value-at-point
                                        'herdr-workspace)))))
   (t (user-error "herdr: nothing at point"))))

;;; The mutating verbs

(herdr-dispatch-defverb herdr-dispatch-rename ()
  "Rename the thing at point.
Most specific section wins: a pane line inside a workspace renames the
pane, which is the thing you are looking at, rather than its tab or
workspace."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-rename (read-string "Pane label: ")
                       (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-tab)
    (herdr-tab-rename (read-string "Tab label: ")
                      (herdr-dispatch--value-at-point 'herdr-tab)))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-rename (read-string "Workspace label: ")
                            (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point to rename"))))

(herdr-dispatch-defverb herdr-dispatch-close ()
  "Close or remove the thing at point.
The underlying commands — `herdr-pane-close\\=', `herdr-workspace-close\\='
and `herdr-worktree-remove\\=' — already prompt for confirmation, so this
adds no second prompt.  `herdr-tab-close\\=' does not prompt; that
asymmetry is left as it is rather than fixed here."
  (cond
   ((herdr-dispatch--value-at-point 'herdr-worktree)
    (herdr-worktree-remove (herdr-dispatch--value-at-point 'herdr-workspace)))
   ((herdr-dispatch--value-at-point 'herdr-pane)
    (herdr-pane-close (herdr-dispatch--value-at-point 'herdr-pane)))
   ((herdr-dispatch--value-at-point 'herdr-tab)
    (herdr-tab-close (herdr-dispatch--value-at-point 'herdr-tab)))
   ((herdr-dispatch--value-at-point 'herdr-workspace)
    (herdr-workspace-close (herdr-dispatch--value-at-point 'herdr-workspace)))
   (t (user-error "herdr: nothing at point to close"))))

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
      (add-hook 'herdr-state-change-hook #'herdr-dispatch--refresh-hook)
      (add-hook 'herdr-state-change-hook #'herdr-dispatch--invalidate-worktrees))
    (herdr-dispatch-refresh)
    (pop-to-buffer buffer)))

(provide 'herdr-dispatch)
;;; herdr-dispatch.el ends here
