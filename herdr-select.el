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
  "Read a pane id, defaulting the prompt to PROMPT."
  (herdr-select--read (or prompt "Pane: ")
                      (herdr-state-pane-ids (herdr-state-current))
                      'herdr-pane #'herdr-select--annotate-pane))

(defun herdr-select-agent (&optional prompt)
  "Read the pane id of an agent, defaulting the prompt to PROMPT."
  (herdr-select--read (or prompt "Agent: ")
                      (mapcar (lambda (pane) (alist-get 'pane_id pane))
                              (herdr-state-agents (herdr-state-current)))
                      'herdr-pane #'herdr-select--annotate-pane))

(defun herdr-select-workspace (&optional prompt)
  "Read a workspace id, defaulting the prompt to PROMPT."
  (herdr-select--read (or prompt "Workspace: ")
                      (mapcar (lambda (w) (alist-get 'workspace_id w))
                              (herdr-state-workspaces (herdr-state-current)))
                      'herdr-workspace #'herdr-select--annotate-workspace))

(defun herdr-select-tab (&optional prompt)
  "Read a tab id, defaulting the prompt to PROMPT."
  (herdr-select--read (or prompt "Tab: ")
                      (mapcar (lambda (tab) (alist-get 'tab_id tab))
                              (herdr-state-tabs (herdr-state-current)))
                      'herdr-tab #'herdr-select--annotate-tab))

(defun herdr-select-target-pane (&optional prompt)
  "Return the pane to act on: the focused one, or a prompted choice.
With a prefix argument, always prompt."
  (if current-prefix-arg
      (herdr-select-pane prompt)
    (or (herdr-state-focused-pane-id (herdr-state-current))
        (herdr-select-pane prompt))))

;;; Optional integrations, registered only when the package is loaded

(with-eval-after-load 'marginalia
  (with-no-warnings
    (add-to-list 'marginalia-annotator-registry
                 '(herdr-pane herdr-select--annotate-pane builtin none))
    (add-to-list 'marginalia-annotator-registry
                 '(herdr-workspace herdr-select--annotate-workspace
                                   builtin none))
    (add-to-list 'marginalia-annotator-registry
                 '(herdr-tab herdr-select--annotate-tab builtin none))))

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
  (with-no-warnings
    (add-to-list 'embark-keymap-alist
                 '(herdr-pane . herdr-select-pane-embark-map))))

(provide 'herdr-select)
;;; herdr-select.el ends here
