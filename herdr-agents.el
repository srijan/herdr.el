;;; herdr-agents.el --- Agent status surface for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Knowing which agents are blocked or finished without going to look.
;;
;; A modeline segment that is always on, fed by `herdr-state-change-hook'
;; and doing no I/O, plus desktop notifications that are available but
;; off, because an agent changing state is not by default worth
;; interrupting for.  The buffer those used to sit beside now lives in
;; `herdr-dispatch'.

;;; Code:

(require 'subr-x)
(require 'herdr-state)
(require 'herdr-tree)

;; `herdr-agents' is the dispatcher command, and lives in
;; `herdr-dispatch', which requires magit-section.  Autoloaded rather
;; than required so the modeline segment costs nothing until the buffer
;; is actually asked for.
(declare-function herdr-agents "herdr-dispatch" ())
(autoload 'herdr-agents "herdr-dispatch" nil t)

(defcustom herdr-notify-statuses nil
  "Agent statuses that raise a desktop notification.
Nil means never.  A sensible opt-in is (\"blocked\" \"done\")."
  :type '(repeat string)
  :group 'herdr)

;;; Modeline segment

(defun herdr-agents--counts (state)
  "Return an alist of (STATUS . COUNT) for the agents in STATE.
Delegates to `herdr-tree-status-counts\\=', which the dispatcher header
reads from too, so the modeline and the dispatcher cannot disagree."
  (herdr-tree-status-counts state))

(defun herdr-agents--segment (state)
  "Return the modeline string for STATE, or an empty string.
Idle agents are omitted: a count that is always on screen stops being
read.  Only the states worth acting on appear, via
`herdr-tree-status-summary\\='."
  (let ((summary (herdr-tree-status-summary state)))
    (if (string-empty-p summary) "" (concat "herdr:" summary))))

(defvar herdr-agents-mode-line-string ""
  "Cached modeline segment, refreshed from the state change hook.")
(put 'herdr-agents-mode-line-string 'risky-local-variable t)

(defun herdr-agents--refresh-segment (&rest _)
  "Recompute the modeline segment and redisplay."
  (setq herdr-agents-mode-line-string
        (let ((text (herdr-agents--segment (herdr-state-current))))
          (if (string-empty-p text)
              ""
            (concat " "
                    (propertize text
                                'help-echo "herdr agents (mouse-1: details)"
                                'mouse-face 'mode-line-highlight
                                'local-map
                                (let ((map (make-sparse-keymap)))
                                  (define-key map [mode-line mouse-1]
                                              #'herdr-agents)
                                  map))))))
  (force-mode-line-update t))

(defun herdr-agents--ensure-global-mode-string ()
  "Make `global-mode-string' safe to append a symbol to.

A mode-line construct that is a list beginning with a symbol is read as
a conditional — (SYMBOL THEN ELSE) — not as a list of elements.  So on a
fresh Emacs, where `global-mode-string' is nil, appending our symbol
produced (herdr-agents-mode-line-string), which Emacs evaluated as a
conditional with no branches and rendered as *invalid* in every mode
line.

Leading with an empty string forces the list-of-elements reading.  This
is why Emacs's own `global-mode-string' conventionally starts with \"\"."
  (cond
   ((null global-mode-string) (setq global-mode-string '("")))
   ((not (listp global-mode-string))
    (setq global-mode-string (list "" global-mode-string)))
   ((not (equal (car global-mode-string) ""))
    (setq global-mode-string (cons "" global-mode-string)))))

;;;###autoload
(define-minor-mode herdr-agents-mode-line-mode
  "Show a count of noteworthy herdr agents in the modeline."
  :global t
  :group 'herdr
  (if herdr-agents-mode-line-mode
      (progn
        (herdr-agents--ensure-global-mode-string)
        (add-to-list 'global-mode-string
                     'herdr-agents-mode-line-string t)
        (add-hook 'herdr-state-change-hook #'herdr-agents--refresh-segment)
        (herdr-agents--refresh-segment))
    (setq global-mode-string
          (delq 'herdr-agents-mode-line-string global-mode-string))
    (remove-hook 'herdr-state-change-hook #'herdr-agents--refresh-segment)))

;;; Notifications

(defvar herdr-agents--last-status (make-hash-table :test 'equal)
  "Last seen status per pane, so only transitions notify.")

(defun herdr-agents--notify (title body)
  "Raise a desktop notification with TITLE and BODY."
  (cond
   ((fboundp 'alert) (funcall 'alert body :title title))
   ((fboundp 'notifications-notify)
    (funcall 'notifications-notify :title title :body body))
   (t (message "%s: %s" title body))))

(defun herdr-agents--maybe-notify (&rest _)
  "Notify about agents that just entered a status in `herdr-notify-statuses'."
  (when herdr-notify-statuses
    (dolist (pane (herdr-state-agents (herdr-state-current)))
      (let* ((id (alist-get 'pane_id pane))
             (status (alist-get 'agent_status pane))
             (previous (gethash id herdr-agents--last-status)))
        (unless (equal status previous)
          (puthash id status herdr-agents--last-status)
          (when (and previous (member status herdr-notify-statuses))
            (herdr-agents--notify
             (format "herdr: %s is %s" (or (alist-get 'agent pane) id) status)
             (or (alist-get 'terminal_title_stripped pane) id))))))))

(add-hook 'herdr-state-change-hook #'herdr-agents--maybe-notify)

(provide 'herdr-agents)
;;; herdr-agents.el ends here
