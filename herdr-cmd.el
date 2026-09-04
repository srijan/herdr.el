;;; herdr-cmd.el --- Curated herdr commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Hand-written wrappers for the methods worth a keybinding.  A
;; generated wrapper cannot know that a pane id should default to the
;; focused pane, which is most of what these are for.  Everything not
;; wrapped here stays reachable through `herdr-call'.
;;
;; `herdr-cmd-methods' records what each command calls, so the drift test
;; can check the set against the server's live schema.

;;; Code:

(require 'subr-x)
(require 'ansi-color)
(require 'herdr-rpc)
(require 'herdr-state)
(require 'herdr-select)
(require 'herdr-term)

(declare-function herdr-term-pane-name "herdr-term" (state pane))

(defconst herdr-cmd-methods
  '((herdr-pane-close            "pane.close"           "pane_id")
    (herdr-pane-rename           "pane.rename"          "pane_id" "label")
    (herdr-pane-focus            "pane.focus"           "pane_id")
    (herdr-pane-read             "pane.read"            "pane_id" "source" "lines" "format" "strip_ansi")
    (herdr-workspace-create      "workspace.create"     "cwd" "label" "focus")
    (herdr-workspace-close       "workspace.close"      "workspace_id")
    (herdr-workspace-focus       "workspace.focus"      "workspace_id")
    (herdr-workspace-rename      "workspace.rename"     "workspace_id" "label")
    (herdr-worktree-create       "worktree.create"      "branch" "base" "cwd" "focus")
    (herdr-worktree-remove       "worktree.remove"      "workspace_id" "force")
    (herdr-agent-prompt          "agent.prompt"         "target" "text"))
  "Every curated command, with the method and parameters it uses.
Each entry is (COMMAND METHOD PARAM...).  Verified against the live
schema by the drift test.")

(defun herdr-cmd--current-pane-id ()
  "Return the id of the pane herdr currently considers focused."
  (ignore-errors
    (alist-get 'pane_id (alist-get 'pane (herdr-rpc-call "pane.current")))))

(defun herdr-cmd--pane-description (pane-id)
  "Return a readable description of PANE-ID, retaining its exact id."
  (let* ((state (herdr-state-current))
         (pane (herdr-state-pane state pane-id)))
    (if pane
        (format "%s (%s)" (herdr-term-pane-name state pane) pane-id)
      pane-id)))

(defun herdr-cmd--created-pane-id (result)
  "Return the id of the pane a create-style RESULT reports.
`pane.split' answers with `pane'; `tab.create' and `workspace.create'
answer with `root_pane'.  Either shape names the pane just made."
  (alist-get 'pane_id (or (alist-get 'pane result)
                          (alist-get 'root_pane result))))

(defun herdr-cmd--follow-new-pane (pane-id)
  "Show PANE-ID, the pane a create command just made.
PANE-ID must come from the creating call's own response: herdr.el is a
paneless client, so `pane.current' answers with the server's global
focus instead.  A cache miss waits for reconciliation rather than
failing, since creation was announced on the event stream."
  (when pane-id
    (unless (herdr-term-select-pane pane-id)
      (herdr-cmd--select-pane-when-ready pane-id))))

(defun herdr-cmd--select-pane-when-ready (pane-id)
  "Select PANE-ID's buffer as soon as reconciliation has built it.
Gated on `herdr-state-generation', captured at the first attempt.  The
chain keeps no handle for `herdr-stop' to cancel, so without the gate a
stop-and-restart leaves it selecting buffers for the old session."
  (let ((generation (herdr-state-generation)))
    (letrec ((attempts 0)
             (check
              (lambda ()
                (setq attempts (1+ attempts))
                (when (= generation (herdr-state-generation))
                  (cond
                   ((herdr-term-select-pane pane-id))
                   ((< attempts 20) (run-at-time 0.25 nil check)))))))
      (run-at-time 0.25 nil check))))

(defun herdr-cmd--read-source (&optional prompt)
  "Read a `ReadSource' value, defaulting to the one worth having.
PROMPT overrides the default \"Source: \" prompt text.
`recent_unwrapped' is the useful default: it is the whole recent
scrollback with terminal line-wrapping undone, which is what makes the
result greppable."
  (completing-read (or prompt "Source: ")
                   '("recent_unwrapped" "recent" "visible" "detection")
                   nil t nil nil "recent_unwrapped"))

;;; Panes

(defun herdr-pane-close (&optional pane-id)
  "Close PANE-ID, or the pane being acted on."
  (interactive)
  (let* ((pane (or pane-id (herdr-select-target-pane "Close pane: ")))
         (description (herdr-cmd--pane-description pane)))
    (if (y-or-n-p (format "Close pane %s? " description))
        (progn
          (herdr-rpc-call "pane.close" `((pane_id . ,pane)))
          ;; Say something afterwards.  Closing reaps the pane's buffer,
          ;; so redisplay happens while the confirmation prompt is still
          ;; on screen and it otherwise sits there looking unanswered.
          (message "herdr: closed %s" description))
      (message "herdr: %s left open" description))))

(defun herdr-pane-rename (label &optional pane-id)
  "Rename PANE-ID, or the focused pane, to LABEL."
  (interactive (list (read-string "Pane label: ")))
  (herdr-rpc-call "pane.rename"
                  `((pane_id . ,(or pane-id (herdr-select-target-pane)))
                    (label . ,label))))

(defun herdr-pane-focus (&optional pane-id)
  "Focus PANE-ID, prompting when not given, and select its buffer.

Focusing is server-side and has no visible effect on its own, because
each pane is a separate Emacs buffer and nothing repaints.  Emacs is
moved to match."
  (interactive)
  (let ((pane (or pane-id (herdr-select-pane "Focus pane: "))))
    (herdr-rpc-call "pane.focus" `((pane_id . ,pane)))
    (or (herdr-term-select-pane pane)
        (herdr-cmd--select-pane-when-ready pane))
    pane))

(defun herdr-cmd--follow-focus ()
  "Show whichever pane herdr now considers focused.

Focusing a workspace lands on one of its panes, and the server decides
which, so the pane has to be asked for rather than assumed.  The cache
may not hold it yet, since the focus change arrives on the event stream,
so a miss waits for reconciliation instead of failing."
  (or (herdr-term-select-focused)
      (when-let* ((pane (herdr-cmd--current-pane-id)))
        (herdr-cmd--select-pane-when-ready pane))))

(defun herdr-cmd-read-text (result)
  "Return the terminal text carried by a read RESULT.

Both `pane.read' and `agent.read' answer with an envelope — type plus a
nested `read' object — rather than a bare text field, so the text has to
be unwrapped."
  (or (alist-get 'text (alist-get 'read result))
      (alist-get 'text result)
      ""))

(defun herdr-cmd-read-truncated-p (result)
  "Return non-nil when read RESULT reports older rows were omitted.
herdr sets `truncated' on the read envelope (or, defensively, the
top-level result) when the requested window dropped earlier terminal
rows.  JSON `false' and `null' both decode to nil, so a plain non-nil
test is enough."
  (or (alist-get 'truncated (alist-get 'read result))
      (alist-get 'truncated result)))

(defun herdr-cmd--display-read (name result)
  "Show READ RESULT in a buffer called NAME and return that buffer."
  (let ((buffer (get-buffer-create name))
        (text (herdr-cmd-read-text result))
        (truncated (herdr-cmd-read-truncated-p result)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (when truncated
          (insert (propertize "⋯ older rows omitted (read truncated) ⋯\n"
                              'face 'font-lock-comment-face)))
        (insert text)
        (ansi-color-apply-on-region (point-min) (point-max))
        (goto-char (point-max)))
      (special-mode))
    (pop-to-buffer buffer)
    buffer))

(defun herdr-pane-read (&optional pane-id source lines)
  "Read PANE-ID's output from SOURCE into a buffer, at most LINES lines."
  (interactive)
  (let* ((pane (or pane-id (herdr-select-target-pane "Read pane: ")))
         (source (or source (herdr-cmd--read-source)))
         (result (herdr-rpc-call "pane.read"
                                 `((pane_id . ,pane)
                                   (source . ,source)
                                   (lines . ,lines)
                                   (format . "ansi")
                                   (strip_ansi . :false)))))
    (herdr-cmd--display-read (format "*herdr read: %s*" pane) result)))

;;; Workspaces

(defun herdr-workspace-create (cwd &optional label)
  "Create a workspace rooted at CWD called LABEL."
  (interactive (list (read-directory-name "Workspace directory: ")))
  (herdr-cmd--follow-new-pane
   (herdr-cmd--created-pane-id
    (herdr-rpc-call "workspace.create"
                    `((cwd . ,(expand-file-name cwd))
                      (label . ,(or label (file-name-nondirectory
                                           (directory-file-name cwd))))
                      (focus . t))))))

(defun herdr-workspace-close (&optional workspace-id)
  "Close WORKSPACE-ID, prompting when not given."
  (interactive)
  (let ((workspace (or workspace-id (herdr-select-workspace "Close workspace: "))))
    (if (y-or-n-p (format "Close workspace %s? " workspace))
        (progn
          (herdr-rpc-call "workspace.close" `((workspace_id . ,workspace)))
          (message "herdr: closed workspace %s" workspace))
      (message "herdr: workspace %s left open" workspace))))

(defun herdr-workspace-focus (&optional workspace-id)
  "Focus WORKSPACE-ID, prompting when not given, and follow it in Emacs."
  (interactive)
  (herdr-rpc-call "workspace.focus"
                  `((workspace_id . ,(or workspace-id
                                         (herdr-select-workspace "Focus: ")))))
  (herdr-cmd--follow-focus))

(defun herdr-workspace-rename (label &optional workspace-id)
  "Rename WORKSPACE-ID to LABEL."
  (interactive (list (read-string "New workspace label: ")))
  (herdr-rpc-call "workspace.rename"
                  `((workspace_id . ,(or workspace-id
                                         (herdr-select-workspace "Rename: ")))
                    (label . ,label))))

;;; Worktrees

(defun herdr-worktree-create (branch &optional base)
  "Create a git worktree for BRANCH off BASE and open it as a workspace.
This is the command that pays for the package: one step from a branch
name to a worktree with its own herdr workspace."
  (interactive (list (read-string "New worktree branch: ")
                     (read-string "Base ref (optional): ")))
  (herdr-rpc-call "worktree.create"
                  `((branch . ,branch)
                    (base . ,(unless (string-empty-p (or base "")) base))
                    (cwd . ,(expand-file-name default-directory))
                    (focus . t))))

(defun herdr-worktree-remove (&optional workspace-id force)
  "Remove the worktree workspace WORKSPACE-ID, forcing when FORCE."
  (interactive)
  (let ((workspace (or workspace-id (herdr-select-workspace "Remove worktree: "))))
    (if (yes-or-no-p (format "Remove worktree workspace %s? " workspace))
        (progn
          (herdr-rpc-call "worktree.remove"
                          `((workspace_id . ,workspace)
                            (force . ,(if force t :false))))
          (message "herdr: removed worktree %s" workspace))
      (message "herdr: worktree %s kept" workspace))))

;;; Agents

(defun herdr-agent-prompt (text &optional target)
  "Send TEXT as a prompt to the agent in TARGET."
  (interactive (list (read-string "Prompt: ")))
  (herdr-rpc-call "agent.prompt"
                  `((target . ,(or target (herdr-select-agent "Prompt agent: ")))
                    (text . ,text))))

;;; Opening a place to run something

(defun herdr-cmd--workspace-label (directory)
  "Return the label a workspace created at DIRECTORY takes."
  (file-name-nondirectory (directory-file-name directory)))

(defun herdr-cmd--create-workspace-pane (directory)
  "Create a focused workspace at DIRECTORY and return its root pane\='s id.
`focus\=' rides on the create: without it the workspace is made but not
focused, and anything that then asks the server \"where am I?\" answers
with the pane the user was on before.  The reply names the new
workspace\='s root pane, so callers go there directly rather than asking."
  (herdr-cmd--created-pane-id
   (herdr-rpc-call "workspace.create"
                   `((cwd . ,(expand-file-name directory))
                     (label . ,(herdr-cmd--workspace-label directory))
                     (focus . t)))))

(defun herdr-cmd-open-workspace-for (root)
  "Focus the workspace at ROOT, creating it if absent, and go there.
Shared by `herdr-project\=', the dispatcher\='s inactive-project verb, and
RET on that row\='s `main\=' checkout.  The create half is
`herdr-cmd--create-workspace-pane\=', which `herdr-cmd-pane-in-directory\='
calls too: with nothing open at ROOT the two have nothing to differ
about."
  (if-let* ((existing (herdr-state-workspace-for-directory
                       (herdr-state-current) root)))
      (progn
        (herdr-rpc-call "workspace.focus"
                        `((workspace_id . ,(alist-get 'workspace_id existing))))
        (herdr-term-select-focused))
    (or (herdr-cmd--follow-new-pane (herdr-cmd--create-workspace-pane root))
        (herdr-term-select-focused))))

(defun herdr-cmd--new-tab-pane (&optional workspace-id cwd)
  "Create a tab and return its root pane's id.
WORKSPACE-ID nil means whatever workspace the server has focused; CWD
nil inherits the workspace directory.  One tab per agent, rather than a
split: Emacs ignores herdr's layout, but the TUI does not, and N agents
as N full-width tabs beats N slivers of one tab."
  (herdr-cmd--created-pane-id
   (herdr-rpc-call "tab.create"
                   `((workspace_id . ,workspace-id)
                     (cwd . ,cwd)
                     (focus . t)))))

(defun herdr-cmd-pane-in-directory (directory)
  "Return a pane for a new terminal in DIRECTORY, opening a workspace if needed."
  (if-let* ((open (herdr-state-workspace-for-directory
                   (herdr-state-current) directory)))
      (herdr-cmd--new-tab-pane (alist-get 'workspace_id open))
    (herdr-cmd--create-workspace-pane directory)))

(defun herdr-new-terminal (&optional place)
  "Open a terminal in PLACE, a workspace id or a directory, and go to it."
  (interactive)
  (let ((place (or place (herdr-select-place))))
    (herdr-cmd--follow-new-pane
     (if (herdr-state-workspace (herdr-state-current) place)
         (herdr-cmd--new-tab-pane place)
       (herdr-cmd-pane-in-directory place)))))

(provide 'herdr-cmd)
;;; herdr-cmd.el ends here
