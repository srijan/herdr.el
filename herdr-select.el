;;; herdr-select.el --- Completion over herdr's session -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Pickers for panes, agents and workspaces, on plain `completing-read'
;; over the state cache.
;;
;; A pane or workspace candidate is the whole readable row - id, then
;; what you know it by - rather than an id with the rest hung off an
;; annotation.  `completing-read' matches the candidate and never the
;; annotation, so a name that lives only in an annotation is a name you
;; cannot type to find what it names.  With the row itself as the
;; candidate, "web claude blocked" is a working query under `orderless'.
;;
;; `embark' and `consult' integration registers only when those packages
;; are present.  Neither is a dependency.

;;; Code:

(require 'subr-x)
(require 'herdr-state)
(require 'herdr-rpc)
(require 'herdr-term)
(require 'herdr-tree)

;; The embark map below binds commands from `herdr-cmd', which requires
;; this file, so they are declared rather than required.
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

(defun herdr-select--pane-candidate (pane-id)
  "Return the completion candidate for PANE-ID.

The id leads, so it stays as searchable as it was and two panes sharing
a name stay two candidates.  What follows is the annotation, moved into
the candidate so it can be matched against."
  (concat pane-id (herdr-select--annotate-pane pane-id)))

(defun herdr-select-row-id (candidate)
  "Return the id CANDIDATE names, pane or workspace.
A picker row leads with the id; the consult source, embark and the
dispatcher hand over a bare id.  Both reduce here."
  (car (split-string candidate)))

(defun herdr-select--read-row (prompt ids candidate category)
  "Read one of IDS with PROMPT, offering each as the row CANDIDATE builds.
CATEGORY tags the completion table."
  (herdr-select-row-id
   (herdr-select--read prompt (mapcar candidate ids)
                       ;; No annotator: the row is the candidate now, and
                       ;; annotating it again would print it twice.
                       category #'ignore)))

(defun herdr-select-pane (&optional prompt)
  "Read a pane id, defaulting the prompt to PROMPT.
Refreshes first: a picker listing panes that no longer exist is worse
than one extra round trip, and the cache can drift."
  (herdr-state-refresh)
  (herdr-select--read-row (or prompt "Pane: ")
                          (herdr-state-pane-ids (herdr-state-current))
                          #'herdr-select--pane-candidate 'herdr-pane))

(defun herdr-select-agent (&optional prompt)
  "Read the pane id of an agent, defaulting the prompt to PROMPT."
  (herdr-state-refresh)
  (herdr-select--read-row (or prompt "Agent: ")
                          (mapcar (lambda (pane) (alist-get 'pane_id pane))
                                  (herdr-state-agents (herdr-state-current)))
                          #'herdr-select--pane-candidate 'herdr-pane))

(defun herdr-select--place-annotation (place)
  "Return the annotation string for PLACE in `herdr-select-place\\='."
  (let* ((state (herdr-state-current))
         (workspace (or (herdr-state-workspace state place)
                        (herdr-state-workspace-for-directory state place))))
    (if workspace
        (herdr-select--annotate-workspace
         (alist-get 'workspace_id workspace))
      "  not open yet")))

(defun herdr-select-place (&optional prompt)
  "Read where to open a terminal: an open workspace id, or a project directory.
PROMPT overrides the default.  Known projects stay in the list when open so
completion can match their paths instead of only their opaque workspace ids."
  (herdr-state-refresh)
  (let* ((state (herdr-state-current))
         (workspaces (mapcar (lambda (workspace)
                               (alist-get 'workspace_id workspace))
                             (herdr-state-workspaces state)))
         (roots (when (fboundp 'project-known-project-roots)
                  (project-known-project-roots))))
    (herdr-select--read (or prompt "New terminal in: ")
                        (append workspaces roots)
                        'herdr-place #'herdr-select--place-annotation)))

(defun herdr-select--workspace-candidate (workspace-id)
  "Return the completion candidate for WORKSPACE-ID.
Built like a pane row, for the same reason: the label and the pane count
are what you know a workspace by, and completion matches only what is in
the candidate."
  (concat workspace-id (herdr-select--annotate-workspace workspace-id)))

(defun herdr-select-workspace (&optional prompt)
  "Read a workspace id, defaulting the prompt to PROMPT."
  (herdr-state-refresh)
  (herdr-select--read-row (or prompt "Workspace: ")
                          (mapcar (lambda (w) (alist-get 'workspace_id w))
                                  (herdr-state-workspaces
                                   (herdr-state-current)))
                          #'herdr-select--workspace-candidate
                          'herdr-workspace))

(defun herdr-select-current-target (&optional buffer)
  "Return the pane a command would act on from BUFFER, or nil.
Never prompts, so it is safe to call while rendering a menu."
  (or (herdr-term-pane-for-buffer (or buffer (current-buffer)))
      (herdr-state-focused-pane-id (herdr-state-current))))

(defun herdr-select-target-pane (&optional prompt)
  "Return the pane to act on, preferring the one you are looking at.
PROMPT is passed through to `herdr-select-pane' on the paths that prompt.

In order: a prefix argument always prompts, then the pane of the current
buffer if it is a herdr terminal, then the pane herdr has focused, then
a prompt.  The buffer comes first because herdr\\='s focus is server-side
and moves only when something moves it."
  (cond
   (current-prefix-arg (herdr-select-pane prompt))
   ((herdr-select-current-target))
   (t (herdr-select-pane prompt))))

;;; Optional integrations, registered only when the package is loaded

;; Cosmetic only: the completion tables already carry an
;; `annotation-function', and this just buys marginalia's column
;; alignment.  Every hook is `boundp'-guarded because these are
;; third-party variables that get renamed, and a cosmetic integration
;; must never be able to break startup.

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

(defun herdr-select--embark-pane-target (type target)
  "Reduce embark TARGET of TYPE to the pane id it names.
Every action on `herdr-select-pane-embark-map' takes an id, and a picker
candidate is a whole row."
  (cons type (herdr-select-row-id target)))

(with-eval-after-load 'embark
  (when (boundp 'embark-keymap-alist)
    (add-to-list 'embark-keymap-alist
                 '(herdr-pane . herdr-select-pane-embark-map)))
  (when (boundp 'embark-transformer-alist)
    (add-to-list 'embark-transformer-alist
                 '(herdr-pane . herdr-select--embark-pane-target))))

(defun herdr-select-panes-with-buffers ()
  "Return pane ids that currently have an Emacs buffer.

Every pane is attachable, but attaching is lazy, so a pane you have not
visited has no buffer and a buffer switcher cannot switch to it."
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

Listing panes with no buffer would put entries in a buffer switcher
that cannot switch to them: they appear, and selecting one leaves you
where you were.  Those panes stay reachable from the dashboard and from
`herdr-pane-focus', which attach on the way."
  `(:name "herdr pane"
    :narrow ?h
    :category herdr-pane
    :annotate ,#'herdr-select--annotate-pane
    :action ,#'herdr-select--consult-visit
    ;; Reconcile at the call site, so the query stays a pure function of
    ;; the cache and testable without a server.  Bound to the background
    ;; timeout: this runs on every `consult-buffer', which nobody
    ;; attributes to herdr, so a wedged server must forfeit a refresh
    ;; rather than freeze buffer switching.
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
