;;; herdr-term.el --- Terminal hosting for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (ghostel "0"))

;;; Commentary:

;; herdr's terminals are hosted inside Emacs, never outside it.  There
;; are two ways to do that and this file implements both behind one
;; interface, because everything else in the package is indifferent to
;; the choice.
;;
;; `session' runs the herdr TUI in a single ghostel buffer.  herdr owns
;; the layout, plain shell panes work, and it is about sixty lines.
;;
;; `agent-windows' runs one ghostel buffer per agent, each holding a
;; `herdr agent attach'.  Emacs owns the layout and herdr's own layout
;; tree goes unused, so there is no geometry to synchronise.  Agents
;; outlive Emacs because the server is a daemon.
;;
;; Measurements that informed this, taken against herdr 0.7.5:
;;
;; - Throughput is not a reason to prefer either.  A 12.2 MB pane dump
;;   reached Emacs as 17 KB under `session' and 24 KB under
;;   `agent-windows'; herdr's VT only emits visible-frame diffs, so it
;;   rate-limits by construction.
;; - `agent attach' refuses a pane with no detected agent, which is why
;;   reconciliation considers agents rather than panes.
;; - Attachment is exclusive per pane, so a second attach needs
;;   `--takeover'.  We ask first rather than stealing.
;; - The client paints nothing into a zero-sized PTY.  ghostel sizes its
;;   terminal from the displayed window, so buffers are displayed before
;;   the process starts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr-rpc)
(require 'herdr-state)

(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-mode "ghostel" ())

(defcustom herdr-terminal-backend 'session
  "How herdr's terminals are hosted inside Emacs.

`session' runs the herdr TUI in one ghostel buffer and lets herdr own
the layout.  `agent-windows' gives every agent its own ghostel buffer
and lets Emacs own the layout; plain shell panes are then not
represented, since herdr will not attach to a pane without an agent."
  :type '(choice (const :tag "One buffer running the herdr TUI" session)
                 (const :tag "One buffer per agent" agent-windows))
  :group 'herdr)

(defcustom herdr-display-action '(display-buffer-full-frame)
  "Display action used for the `session' backend's buffer.

herdr draws a 26-column sidebar next to its panes, so a narrow window
leaves it very little room.  Full frame is the default for that reason;
a side window or dedicated frame works if you would rather."
  :type 'sexp
  :group 'herdr)

(defcustom herdr-server-start-timeout 15.0
  "Seconds to wait for a freshly launched herdr server to answer."
  :type 'number
  :group 'herdr)

(defconst herdr-term-session-buffer-name "*herdr*"
  "Buffer that hosts the herdr TUI under the `session' backend.")

;;; Naming and argument construction — pure, so they are testable

(defun herdr-term-agent-buffer-name (pane)
  "Return the buffer name for PANE under the `agent-windows' backend."
  (format "*herdr: %s %s*"
          (or (alist-get 'agent pane) "agent")
          (alist-get 'pane_id pane)))

(defun herdr-term-attach-args (pane-id takeover)
  "Return argv tail for attaching to PANE-ID, stealing it when TAKEOVER."
  (append (list "agent" "attach" pane-id)
          (when takeover '("--takeover"))))

(defun herdr-term-session-args ()
  "Return argv tail for the session client, which takes no arguments."
  nil)

(defun herdr-term-reconcile (state buffers)
  "Compare STATE against BUFFERS and return (TO-CREATE . TO-REAP).

BUFFERS is an alist of (PANE-ID . BUFFER).  TO-CREATE holds pane alists
that have an agent but no buffer; TO-REAP holds buffers whose pane is
gone or has lost its agent.  Pure: no processes are touched."
  (let* ((agents (herdr-state-agents state))
         (agent-ids (mapcar (lambda (pane) (alist-get 'pane_id pane)) agents))
         (have-ids (mapcar #'car buffers)))
    (cons
     (seq-remove (lambda (pane)
                   (member (alist-get 'pane_id pane) have-ids))
                 agents)
     (mapcar #'cdr
             (seq-remove (lambda (cell) (member (car cell) agent-ids))
                         buffers)))))

;;; Server lifecycle

(defun herdr-server-live-p ()
  "Return non-nil when the herdr server answers a ping."
  (condition-case nil
      (progn (herdr-rpc-call "ping") t)
    (herdr-error nil)))

(defun herdr-term--bootstrap-server ()
  "Start a herdr client long enough to bring the server up.

herdr has no headless start command, so the server is brought up by
running a client.  Under `session' that client is the UI and stays.
Under `agent-windows' it is only a bootstrap: the server is a daemon
and outlives it, so the buffer is discarded once ping succeeds."
  (let ((buffer (get-buffer-create herdr-term-session-buffer-name)))
    (with-current-buffer buffer (ghostel-mode))
    (display-buffer buffer herdr-display-action)
    (ghostel-exec buffer herdr-executable (herdr-term-session-args))
    (let ((deadline (+ (float-time) herdr-server-start-timeout)))
      (while (and (< (float-time) deadline) (not (herdr-server-live-p)))
        (sit-for 0.2)))
    (unless (herdr-server-live-p)
      (error "herdr server did not come up within %ss"
             herdr-server-start-timeout))
    buffer))

;;; Buffer bookkeeping

(defvar herdr-term--agent-buffers nil
  "Alist of (PANE-ID . BUFFER) for the `agent-windows' backend.")

(defun herdr-term--live-agent-buffers ()
  "Return `herdr-term--agent-buffers' with dead buffers dropped."
  (setq herdr-term--agent-buffers
        (seq-filter (lambda (cell) (buffer-live-p (cdr cell)))
                    herdr-term--agent-buffers)))

(defun herdr-term-buffer-for-pane (pane-id)
  "Return the buffer showing PANE-ID, if this backend has one."
  (pcase herdr-terminal-backend
    ('session (get-buffer herdr-term-session-buffer-name))
    ('agent-windows (cdr (assoc pane-id (herdr-term--live-agent-buffers))))))

(defun herdr-term--attach (pane)
  "Create and start a ghostel buffer attached to PANE."
  (let* ((pane-id (alist-get 'pane_id pane))
         (buffer (get-buffer-create (herdr-term-agent-buffer-name pane))))
    (with-current-buffer buffer (ghostel-mode))
    ;; Display before starting: ghostel sizes the PTY from the window,
    ;; and herdr paints nothing into a zero-sized terminal.
    (display-buffer buffer)
    (condition-case err
        (ghostel-exec buffer herdr-executable
                      (herdr-term-attach-args pane-id nil))
      (error
       (if (and (y-or-n-p
                 (format "Attaching to %s failed (%s).  Take it over? "
                         pane-id (error-message-string err))))
           (ghostel-exec buffer herdr-executable
                         (herdr-term-attach-args pane-id t))
         (kill-buffer buffer)
         (setq buffer nil))))
    (when buffer
      (push (cons pane-id buffer) herdr-term--agent-buffers))
    buffer))

(defun herdr-term--sync-agent-windows ()
  "Bring the set of agent buffers in line with the cache."
  (let* ((plan (herdr-term-reconcile (herdr-state-current)
                                     (herdr-term--live-agent-buffers))))
    (dolist (pane (car plan))
      (herdr-term--attach pane))
    (dolist (buffer (cdr plan))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (herdr-term--live-agent-buffers)))

(defun herdr-term--on-state-change (_kind _data)
  "Resync agent buffers after a cache change."
  (when (eq herdr-terminal-backend 'agent-windows)
    (herdr-term--sync-agent-windows)))

;;; Interface

(defun herdr-term-ensure ()
  "Make sure this backend's terminals exist, starting the server if needed."
  (require 'ghostel)
  (let ((bootstrap (unless (herdr-server-live-p)
                     (herdr-term--bootstrap-server))))
    (pcase herdr-terminal-backend
      ('session
       (or bootstrap
           (let ((buffer (get-buffer herdr-term-session-buffer-name)))
             (if (buffer-live-p buffer)
                 buffer
               (herdr-term--bootstrap-server)))))
      ('agent-windows
       ;; The bootstrap client was only there to start the daemon.
       (when (buffer-live-p bootstrap) (kill-buffer bootstrap))
       (add-hook 'herdr-state-change-hook #'herdr-term--on-state-change)
       (herdr-term--sync-agent-windows)))))

(defun herdr-term-display ()
  "Show this backend's primary buffer."
  (pcase herdr-terminal-backend
    ('session
     (when-let* ((buffer (get-buffer herdr-term-session-buffer-name)))
       (display-buffer buffer herdr-display-action)))
    ('agent-windows
     (when-let* ((cell (car (herdr-term--live-agent-buffers))))
       (display-buffer (cdr cell))))))

(defun herdr-term-teardown ()
  "Kill this backend's buffers.  The herdr server is left running."
  (remove-hook 'herdr-state-change-hook #'herdr-term--on-state-change)
  (pcase herdr-terminal-backend
    ('session
     (when-let* ((buffer (get-buffer herdr-term-session-buffer-name)))
       (kill-buffer buffer)))
    ('agent-windows
     (dolist (cell (herdr-term--live-agent-buffers))
       (kill-buffer (cdr cell)))
     (setq herdr-term--agent-buffers nil))))

(provide 'herdr-term)
;;; herdr-term.el ends here
