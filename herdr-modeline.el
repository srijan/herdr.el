;;; herdr-modeline.el --- Modeline segment and notifications for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Knowing which agents are blocked or finished without going to look.
;;
;; A modeline segment that is always on, fed by `herdr-state-change-functions'
;; and doing no I/O, plus desktop notifications that are available but
;; off, because an agent changing state is not by default worth
;; interrupting for.
;;
;; This was herdr-agents.el, which by the end named neither of the things
;; in it: the buffer it was written for moved to `herdr-dispatch' when the
;; dispatcher landed, and the command `herdr-agents' moved with it.  Two
;; unrelated things then shared one prefix, so `herdr-agents--refresh-segment'
;; read as internal to the command it has nothing to do with.  The modeline
;; half is `herdr-modeline-', the notification half `herdr-notify-' — which
;; is what the one public name here, `herdr-notify-statuses', already used.

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

(defun herdr-modeline--counts (state)
  "Return an alist of (STATUS . COUNT) for the agents in STATE.
Delegates to `herdr-tree-status-counts\\=', which the dispatcher header
reads from too, so the modeline and the dispatcher cannot disagree."
  (herdr-tree-status-counts state))

(defun herdr-modeline--segment (state)
  "Return the modeline string for STATE, or an empty string.
Idle agents are omitted: a count that is always on screen stops being
read.  Only the states worth acting on appear, via
`herdr-tree-status-summary\\='."
  (let ((summary (herdr-tree-status-summary state)))
    (if (string-empty-p summary) "" (concat "herdr:" summary))))

(defvar herdr-modeline-string ""
  "Cached modeline segment, refreshed from the state change hook.")
(put 'herdr-modeline-string 'risky-local-variable t)

(defvar herdr-modeline--text ""
  "The bare text behind `herdr-modeline-string', written beside it.
What lets a refresh recognize that it is about to render the text
already on screen.  The two are only ever assigned together, so
comparing against this is comparing against the displayed segment.")

(defvar herdr-modeline--map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'herdr-agents)
    map)
  "Click map for the segment, built once rather than per refresh.")

(defun herdr-modeline--refresh (&rest _)
  "Recompute the modeline segment, and redisplay only if it changed.

The change hook fires for every event, and most events do not move the
counts this segment shows.  When `pane.updated\\=' was still subscribed
that meant about 7.5 firings a second per busy agent, each rebuilding
the string and calling `force-mode-line-update' across every frame — a
redisplay of every mode line in Emacs several times a second for text
that almost never differed: the flicker.  The subscription is gone, but
the guard stays: bursts still happen (replays, reconciles, status
refreshes), and only a changed count is worth a redisplay."
  (let ((text (herdr-modeline--segment (herdr-state-current))))
    (unless (equal text herdr-modeline--text)
      (setq herdr-modeline--text text)
      (setq herdr-modeline-string
            (if (string-empty-p text)
                ""
              (concat " "
                      (propertize text
                                  'help-echo "herdr agents (mouse-1: details)"
                                  'mouse-face 'mode-line-highlight
                                  'local-map herdr-modeline--map))))
      (force-mode-line-update t))))

(defun herdr-modeline--ensure-global-mode-string ()
  "Make `global-mode-string' safe to append a symbol to.

A mode-line construct that is a list beginning with a symbol is read as
a conditional — (SYMBOL THEN ELSE) — not as a list of elements.  So on a
fresh Emacs, where `global-mode-string' is nil, appending our symbol
produced (herdr-modeline-string), which Emacs evaluated as a
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
(define-minor-mode herdr-modeline-mode
  "Show a count of noteworthy herdr agents in the modeline."
  :global t
  :group 'herdr
  (if herdr-modeline-mode
      (progn
        (herdr-modeline--ensure-global-mode-string)
        (add-to-list 'global-mode-string
                     'herdr-modeline-string t)
        (add-hook 'herdr-state-change-functions #'herdr-modeline--refresh)
        (herdr-modeline--refresh))
    (setq global-mode-string
          (delq 'herdr-modeline-string global-mode-string))
    (remove-hook 'herdr-state-change-functions #'herdr-modeline--refresh)))

;;; Notifications

(defvar herdr-notify--last-status (make-hash-table :test 'equal)
  "Last seen status per pane, so only transitions notify.")

(defun herdr-notify--send (title body)
  "Raise a desktop notification with TITLE and BODY."
  (cond
   ((fboundp 'alert) (funcall 'alert body :title title))
   ((fboundp 'notifications-notify)
    (funcall 'notifications-notify :title title :body body))
   (t (message "%s: %s" title body))))

(defun herdr-notify--maybe (&rest _)
  "Notify about agents that just entered a status in `herdr-notify-statuses'."
  (when herdr-notify-statuses
    (dolist (pane (herdr-state-agents (herdr-state-current)))
      (let* ((id (alist-get 'pane_id pane))
             (status (alist-get 'agent_status pane))
             (previous (gethash id herdr-notify--last-status)))
        (unless (equal status previous)
          (puthash id status herdr-notify--last-status)
          (when (and previous (member status herdr-notify-statuses))
            (herdr-notify--send
             (format "herdr: %s is %s" (or (alist-get 'agent pane) id) status)
             ;; `herdr-tree-pane-name', not the bare title: the
             ;; notification names the agent kind, which does not tell
             ;; two Claudes apart, and a labelled pane says which one
             ;; this is before it says what it was doing.
             (let ((name (herdr-tree-pane-name pane)))
               (if (string-empty-p name) id name)))))))))

(add-hook 'herdr-state-change-functions #'herdr-notify--maybe)

(provide 'herdr-modeline)
;;; herdr-modeline.el ends here
