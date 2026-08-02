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
      (let ((agent (alist-get 'agent pane))
            (status (alist-get 'agent_status pane))
            (title (alist-get 'terminal_title_stripped pane))
            (cwd (alist-get 'cwd pane)))
        (concat "  "
                (if agent
                    (format "%s %-8s" (herdr-select--status-glyph status) agent)
                  (format "%-10s" "shell"))
                " " (or title "")
                (if cwd (format "  %s" (abbreviate-file-name cwd)) ""))))))

(defun herdr-select--annotate-workspace (workspace-id)
  "Return the annotation string for WORKSPACE-ID."
  (let ((workspace (seq-find (lambda (w)
                               (equal workspace-id
                                      (alist-get 'workspace_id w)))
                             (herdr-state-workspaces (herdr-state-current)))))
    (if workspace
        (format "  %-16s %s panes"
                (or (alist-get 'label workspace) "")
                (or (alist-get 'pane_count workspace) 0))
      "")))

(defun herdr-select--annotate-tab (tab-id)
  "Return the annotation string for TAB-ID."
  (let ((tab (seq-find (lambda (candidate)
                         (equal tab-id (alist-get 'tab_id candidate)))
                       (herdr-state-tabs (herdr-state-current)))))
    (if tab
        (format "  %-8s %s panes"
                (or (alist-get 'label tab) "")
                (or (alist-get 'pane_count tab) 0))
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

(defun herdr-select-workspace (&optional prompt)
  "Read a workspace id, defaulting the prompt to PROMPT."
  (herdr-state-refresh)
  (herdr-select--read (or prompt "Workspace: ")
                      (mapcar (lambda (w) (alist-get 'workspace_id w))
                              (herdr-state-workspaces (herdr-state-current)))
                      'herdr-workspace #'herdr-select--annotate-workspace))

(defun herdr-select-tab (&optional prompt)
  "Read a tab id, defaulting the prompt to PROMPT."
  (herdr-state-refresh)
  (herdr-select--read (or prompt "Tab: ")
                      (mapcar (lambda (tab) (alist-get 'tab_id tab))
                              (herdr-state-tabs (herdr-state-current)))
                      'herdr-tab #'herdr-select--annotate-tab))

(defun herdr-select-current-target (&optional buffer)
  "Return the pane a command would act on from BUFFER, or nil.
Never prompts, so it is safe to call while rendering a menu."
  (or (herdr-term-pane-for-buffer (or buffer (current-buffer)))
      (herdr-state-focused-pane-id (herdr-state-current))))

(defun herdr-select-target-pane (&optional prompt)
  "Return the pane to act on, preferring the one you are looking at.

In order: a prefix argument always prompts; otherwise the pane of the
current buffer if it is a herdr terminal; otherwise the pane herdr has
focused; otherwise a prompt.

The buffer comes first because it is the more local answer.  herdr\='s
focus is server-side and only moves when something explicitly moves it,
so acting from inside one agent\='s buffer used to target whichever pane
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
    (herdr-workspace herdr-select--annotate-workspace)
    (herdr-tab       herdr-select--annotate-tab))
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
    (define-key map "z" #'herdr-pane-zoom)
    map)
  "Embark actions offered on a herdr pane candidate.")

(with-eval-after-load 'embark
  (when (boundp 'embark-keymap-alist)
    (add-to-list 'embark-keymap-alist
                 '(herdr-pane . herdr-select-pane-embark-map))))

(defun herdr-select-panes-with-buffers ()
  "Return pane ids that currently have an Emacs buffer.

Under `agent-windows' a pane without an agent has no buffer, so it is
not something a buffer switcher can switch to.  Under `session' every
pane shares the one herdr buffer, so all of them qualify."
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
transient, which can offer to adopt them."
  `(:name "herdr pane"
    :narrow ?h
    :category herdr-pane
    :annotate ,#'herdr-select--annotate-pane
    :action ,#'herdr-select--consult-visit
    ;; Reconcile at the call site, not inside the query: the query stays
    ;; a pure function of the cache and so remains testable without a
    ;; server.
    :items ,(lambda ()
              (herdr-state-reconcile-panes)
              (herdr-select-panes-with-buffers))))

(with-eval-after-load 'consult
  (when (boundp 'consult-buffer-sources)
    (defvar herdr-select-consult-source (herdr-select--consult-source)
      "herdr pane source for `consult-buffer'.")
    (add-to-list 'consult-buffer-sources 'herdr-select-consult-source t)))

(provide 'herdr-select)
;;; herdr-select.el ends here
