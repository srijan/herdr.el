;;; herdr-select.el --- Completion over herdr's session -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Pickers for panes, agents, workspaces and tabs, built on plain
;; `completing-read' over the state cache rather than any bespoke UI.
;;
;; Candidates are ids, which are short and unique but say nothing; the
;; readable part — label, agent, status, directory — is supplied as an
;; annotation.  With `marginalia' that renders as aligned columns, and
;; with `orderless' it makes "web claude blocked" a working query, since
;; completion styles match against the annotation too.
;;
;; `embark' and `consult' integration is registered only when those
;; packages are present.  Neither is a dependency.

;;; Code:

(require 'subr-x)
(require 'herdr-state)
(require 'herdr-rpc)
(require 'herdr-term)
(require 'herdr-tree)

;; The embark map below binds commands from `herdr-cmd', which requires
;; this file — so they are declared rather than required.  These used to
;; compile clean only by accident: `herdr-agents' required `herdr-cmd'
;; and happened to be byte-compiled first, which loaded it into the
;; compilation session for every later file.
(declare-function herdr-pane-focus "herdr-cmd" (&optional pane-id))
(declare-function herdr-pane-read "herdr-cmd"
                  (&optional pane-id source lines))
(declare-function herdr-pane-close "herdr-cmd" (&optional pane-id))
(declare-function herdr-agent-prompt "herdr-cmd" (text &optional target))

(declare-function project-known-project-roots "project" ())

(defun herdr-select--status-glyph (status)
  "Return a short glyph for agent STATUS."
  (pcase status
    ("working" "▶")
    ("blocked" "⏸")
    ("done" "✓")
    ("idle" "·")
    (_ " ")))

(defun herdr-select--annotate-pane (pane-id)
  "Return the annotation string for PANE-ID."
  (let ((pane (herdr-state-pane (herdr-state-current) pane-id)))
    (if (not pane)
        ""
      ;; `herdr-tree-pane-name' rather than the terminal title alone,
      ;; so a pane somebody renamed — or a plugin pane seated with its
      ;; manifest title — is findable here by the name it is known by
      ;; as well as by what it is doing.  Shared with the dispatcher
      ;; row so the two cannot disagree about what a pane is called.
      (let ((agent (alist-get 'agent pane))
            (status (alist-get 'agent_status pane))
            (title (herdr-tree-pane-name pane))
            (cwd (alist-get 'cwd pane)))
        (concat "  "
                (if agent
                    (format "%s %-8s" (herdr-select--status-glyph status) agent)
                  (format "%-10s" "shell"))
                " " (or title "")
                (if cwd (format "  %s" (abbreviate-file-name cwd)) ""))))))

(defun herdr-select--annotate-workspace (workspace-id)
  "Return the annotation string for WORKSPACE-ID."
  (let ((workspace (herdr-state-workspace (herdr-state-current) workspace-id)))
    (if workspace
        (format "  %-16s %s panes"
                (or (alist-get 'label workspace) "")
                (or (alist-get 'pane_count workspace) 0))
      "")))

(defun herdr-select--read (prompt candidates category annotator)
  "Read one of CANDIDATES with PROMPT, tagged CATEGORY and using ANNOTATOR."
  (unless candidates
    (user-error "herdr: nothing to choose from"))
  (let ((table
         (lambda (string predicate action)
           (if (eq action 'metadata)
               `(metadata (category . ,category)
                          (annotation-function . ,annotator))
             (complete-with-action action candidates string predicate)))))
    (completing-read prompt table nil t)))

(defun herdr-select-pane (&optional prompt)
  "Read a pane id, defaulting the prompt to PROMPT.
Refreshes first: a picker listing panes that no longer exist is worse
than one extra round trip, and the cache can drift."
  (herdr-state-refresh)
  (herdr-select--read (or prompt "Pane: ")
                      (herdr-state-pane-ids (herdr-state-current))
                      'herdr-pane #'herdr-select--annotate-pane))

(defun herdr-select-agent (&optional prompt)
  "Read the pane id of an agent, defaulting the prompt to PROMPT."
  (herdr-state-refresh)
  (herdr-select--read (or prompt "Agent: ")
                      (mapcar (lambda (pane) (alist-get 'pane_id pane))
                              (herdr-state-agents (herdr-state-current)))
                      'herdr-pane #'herdr-select--annotate-pane))

(defun herdr-select--place-annotation (place)
  "Return the annotation string for PLACE in `herdr-select-place\\='."
  (if (herdr-state-workspace (herdr-state-current) place)
      (herdr-select--annotate-workspace place)
    "  not open yet"))

(defun herdr-select-place (&optional prompt)
  "Read where to open a terminal: an open workspace id, or a project directory.
PROMPT overrides the default.  A directory already open as a workspace is
dropped, being in the list once already under the id the verbs act on."
  (herdr-state-refresh)
  (let* ((state (herdr-state-current))
         (workspaces (mapcar (lambda (workspace)
                               (alist-get 'workspace_id workspace))
                             (herdr-state-workspaces state)))
         (roots (when (fboundp 'project-known-project-roots)
                  (seq-remove (lambda (root)
                                (herdr-state-workspace-for-directory state root))
                              (project-known-project-roots)))))
    (herdr-select--read (or prompt "New terminal in: ")
                        (append workspaces roots)
                        'herdr-place #'herdr-select--place-annotation)))

(defun herdr-select-workspace (&optional prompt)
  "Read a workspace id, defaulting the prompt to PROMPT."
  (herdr-state-refresh)
  (herdr-select--read (or prompt "Workspace: ")
                      (mapcar (lambda (w) (alist-get 'workspace_id w))
                              (herdr-state-workspaces (herdr-state-current)))
                      'herdr-workspace #'herdr-select--annotate-workspace))

(defun herdr-select-current-target (&optional buffer)
  "Return the pane a command would act on from BUFFER, or nil.
Never prompts, so it is safe to call while rendering a menu."
  (or (herdr-term-pane-for-buffer (or buffer (current-buffer)))
      (herdr-state-focused-pane-id (herdr-state-current))))

(defun herdr-select-target-pane (&optional prompt)
  "Return the pane to act on, preferring the one you are looking at.
PROMPT is passed through to `herdr-select-pane' on the paths that prompt.

In order: a prefix argument always prompts; otherwise the pane of the
current buffer if it is a herdr terminal; otherwise the pane herdr has
focused; otherwise a prompt.

The buffer comes first because it is the more local answer.  herdr\\='s
focus is server-side and only moves when something explicitly moves it,
so acting from inside one agent\\='s buffer used to target whichever pane
you last went to — which could be a different agent entirely."
  (cond
   (current-prefix-arg (herdr-select-pane prompt))
   ((herdr-select-current-target))
   (t (herdr-select-pane prompt))))

;;; Optional integrations, registered only when the package is loaded

;; These are conveniences, not requirements: the completion tables above
;; already carry an `annotation-function', and marginalia falls back to
;; it for any category it does not know.  Registering the categories
;; only buys marginalia's column alignment.
;;
;; So every hook here is guarded by `boundp'.  These are third-party
;; variables on their own release schedules — `marginalia-annotator-registry'
;; was renamed to `marginalia-annotators', which broke startup — and a
;; cosmetic integration must never be able to do that.

(defconst herdr-select-annotators
  '((herdr-pane      herdr-select--annotate-pane)
    (herdr-workspace herdr-select--annotate-workspace))
  "Annotator per completion category, in `marginalia-annotators' order.")

(defun herdr-select--register-marginalia ()
  "Register herdr's categories with marginalia, if its API is recognised."
  (let ((registry (cond ((boundp 'marginalia-annotators) 'marginalia-annotators)
                        ;; marginalia before the 2024 rename.
                        ((boundp 'marginalia-annotator-registry)
                         'marginalia-annotator-registry))))
    (when registry
      (dolist (entry herdr-select-annotators)
        (add-to-list registry (append entry '(builtin none)))))))

(with-eval-after-load 'marginalia
  (herdr-select--register-marginalia))

(defvar herdr-select-pane-embark-map
  (let ((map (make-sparse-keymap)))
    (define-key map "f" #'herdr-pane-focus)
    (define-key map "r" #'herdr-pane-read)
    (define-key map "p" #'herdr-agent-prompt)
    (define-key map "k" #'herdr-pane-close)
    map)
  "Embark actions offered on a herdr pane candidate.")

(with-eval-after-load 'embark
  (when (boundp 'embark-keymap-alist)
    (add-to-list 'embark-keymap-alist
                 '(herdr-pane . herdr-select-pane-embark-map))))

(defun herdr-select-panes-with-buffers ()
  "Return pane ids that currently have an Emacs buffer.

Under `agent-windows' a pane not yet attached to has no buffer — every
pane is attachable, but attaching is lazy, on demand — so it is not
something a buffer switcher can switch to.  Under `session' every pane
shares the one herdr buffer, so all of them qualify."
  (seq-filter (lambda (id)
                (buffer-live-p (herdr-term-buffer-for-pane id)))
              (herdr-state-pane-ids (herdr-state-current))))

(defun herdr-select--consult-visit (pane-id)
  "Switch to PANE-ID's buffer and focus the pane in herdr."
  (when-let* ((buffer (herdr-term-buffer-for-pane pane-id)))
    (herdr-term--show buffer))
  (ignore-errors (herdr-rpc-call "pane.focus" `((pane_id . ,pane-id)))))

(defun herdr-select--consult-source ()
  "Return a `consult-buffer' source listing herdr panes that have buffers.

Listing panes with no buffer would put entries in a buffer switcher that
it cannot switch to — they appear in the list, and selecting one leaves
you where you were.  Panes without buffers stay reachable through the
transient, which attaches to any of them directly."
  `(:name "herdr pane"
    :narrow ?h
    :category herdr-pane
    :annotate ,#'herdr-select--annotate-pane
    :action ,#'herdr-select--consult-visit
    ;; Reconcile at the call site, not inside the query: the query stays
    ;; a pure function of the cache and so remains testable without a
    ;; server.
    ;;
    ;; This runs on every `consult-buffer', a path the user attributes
    ;; to buffer switching rather than to herdr — so the reconcile is
    ;; bound to the background timeout, the same guard
    ;; `herdr-server-live-p' and `herdr-term--poll-directories' use for
    ;; every other unattributed call.  A wedged server then forfeits one
    ;; refresh of the pane list instead of freezing `consult-buffer' for
    ;; the full `herdr-rpc-timeout'.
    :items ,(lambda ()
              (let ((herdr-rpc-timeout (min herdr-rpc-timeout
                                            herdr-rpc-background-timeout)))
                (herdr-state-reconcile-panes))
              (herdr-select-panes-with-buffers))))

(with-eval-after-load 'consult
  (when (boundp 'consult-buffer-sources)
    (defvar herdr-select-consult-source (herdr-select--consult-source)
      "herdr pane source for `consult-buffer'.")
    (add-to-list 'consult-buffer-sources 'herdr-select-consult-source t)))

(provide 'herdr-select)
;;; herdr-select.el ends here
