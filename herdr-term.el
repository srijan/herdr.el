;;; herdr-term.el --- Terminal hosting for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (ghostel "0"))

;;; Commentary:

;; herdr's terminals are hosted inside Emacs, never outside it: one
;; ghostel buffer per pane, each holding a `herdr terminal attach'.
;; Emacs owns the layout and herdr's own layout tree goes unused, so
;; there is no geometry to synchronise.  Panes outlive Emacs because the
;; server is a daemon.
;;
;; Two constraints shape the code here.  Attachment is exclusive per
;; pane, so a second attach needs `--takeover' and this asks first.  And
;; the client paints nothing into a zero-sized PTY, so a buffer must be
;; displayed before its process starts.
;;
;; Measured throughput and attach behaviour are in docs/protocol.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr-rpc)
(require 'herdr-state)
(require 'herdr-pane)

(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-mode "ghostel" ())

(defcustom herdr-display-action
  '((display-buffer-reuse-window display-buffer-same-window))
  "How herdr buffers are shown, for every path that shows one.
Starting herdr, going to a pane and attaching all route through this, so
one buffer cannot appear two ways depending on the command.  The default
reuses the current window and leaves the frame alone.

    (setq herdr-display-action \\='(display-buffer-full-frame))"
  :type 'sexp
  :group 'herdr)

(defun herdr-term--show (buffer)
  "Show BUFFER according to `herdr-display-action' and select it."
  (pop-to-buffer buffer herdr-display-action))

(defcustom herdr-server-start-timeout 15.0
  "Seconds to wait for a freshly launched herdr server to answer."
  :type 'number
  :group 'herdr)

;;; Naming and argument construction — pure, so they are testable

(defun herdr-term-buffer-name (state pane)
  "Return the wanted buffer name for PANE, read against STATE.

Not unique.  Two unnamed panes of the same kind in one workspace compute
the same name, so callers that create a buffer must uniquify first; see
`herdr-term--unique-buffer-name\\='."
  (format "*herdr: %s*" (herdr-term-pane-identity state pane)))

(defun herdr-term-pane-identity (state pane)
  "Return PANE\='s identity, with the two facts STATE holds looked up.
`herdr-pane-identity\=' takes no cache on purpose; this is the one place
that fetches what it needs from one."
  (herdr-pane-identity pane
                       (herdr-state-agent-name state (herdr-pane-id pane))
                       (herdr-state-workspace-label
                        state (herdr-pane-workspace-id pane))))

(defun herdr-term--unique-buffer-name (state pane)
  "Return a unique buffer name for PANE, from `herdr-term-buffer-name'.
Uniquify before creating, not after: `get-buffer-create\\=' on a colliding
name hands back another pane\\='s buffer rather than a fresh one."
  (generate-new-buffer-name (herdr-term-buffer-name state pane)))

(defun herdr-term--buffer-name-sans-uniquify-suffix (name)
  "Return NAME with a trailing `<N>\\=' uniquifying suffix stripped, if any.
Without this, a buffer that collided on creation compares unequal to its
own wanted name forever; see `herdr-term--rename-stale-buffers\\='."
  (if (string-match "<[0-9]+>\\'" name)
      (substring name 0 (match-beginning 0))
    name))

(defun herdr-term-buffers-to-reap (state buffers)
  "Return the buffers in BUFFERS whose pane is gone from STATE.

BUFFERS is an alist of (PANE-ID . BUFFER).  Pure: no processes are
touched and no buffer is killed here.

It used to answer a pair, the other half naming panes with no buffer.
Nothing attached from it - attaching needs a window, so it happens on
demand in `herdr-term-select-pane\=' - so the half was carried, tested
and never read."
  (let ((pane-ids (mapcar (lambda (pane) (herdr-pane-id pane))
                          (herdr-state-panes state))))
    (mapcar #'cdr
            (seq-remove (lambda (cell) (member (car cell) pane-ids))
                        buffers))))

;;; Server lifecycle

(defun herdr-server-live-p ()
  "Return non-nil when the herdr server answers a ping.

The ping is bound to `herdr-rpc-background-timeout': this is a liveness
probe, called in a loop while the server starts and once before every
start, and a healthy local server answers in milliseconds.  At the full
`herdr-rpc-timeout' a hung socket made each probe a ten-second freeze —
the startup loop alone could block for forty."
  (let ((herdr-rpc-timeout (min herdr-rpc-timeout
                                herdr-rpc-background-timeout)))
    (condition-case nil
        (progn (herdr-rpc-call "ping") t)
      (herdr-error nil))))

(defconst herdr-term-bootstrap-buffer-name "*herdr-bootstrap*"
  "Buffer for the client that brings the server up; killed once it has.")

(defun herdr-term--bootstrap-server ()
  "Start a herdr client long enough to bring the server up.

herdr has no headless start command, so the server is brought up by
running a client.  The server is a daemon and outlives it, so the buffer
is discarded once ping succeeds.

Shown while it runs: ghostel sizes its PTY from a displayed window and
paints nothing into a zero-sized one, so a bootstrap that is never shown
can hang on an unusable PTY until the timeout gives up."
  (let ((buffer (get-buffer-create herdr-term-bootstrap-buffer-name)))
    (with-current-buffer buffer (ghostel-mode))
    (herdr-term--show buffer)
    (ghostel-exec buffer herdr-executable nil)
    (unwind-protect
        ;; One liveness answer per loop pass, and none after the
        ;; deadline.  The old shape re-pinged in the `unless' after the
        ;; loop ended, so a server that missed the deadline was charged
        ;; one more full probe on top of it before the error finally
        ;; surfaced.
        (let ((deadline (+ (float-time) herdr-server-start-timeout))
              (live (herdr-server-live-p)))
          (while (and (not live) (< (float-time) deadline))
            (sit-for 0.2)
            (setq live (herdr-server-live-p)))
          (unless live
            (error "herdr server did not come up within %ss"
                   herdr-server-start-timeout)))
      (quit-windows-on buffer))
    buffer))

;;; Buffer bookkeeping

(defvar herdr-term--buffers nil
  "Alist of (PANE-ID . BUFFER), one entry per attached pane.")

(defun herdr-term--live-buffers ()
  "Return `herdr-term--buffers' with dead buffers dropped."
  (setq herdr-term--buffers
        (seq-filter (lambda (cell) (buffer-live-p (cdr cell)))
                    herdr-term--buffers)))

(defun herdr-term-select-pane (pane-id)
  "Show PANE-ID, attaching to it first if it is not attached yet.

Focus is server-side state and nothing in Emacs repaints: each pane is
its own buffer, so focusing one has no visible effect unless Emacs also
selects that buffer.

Attaching happens here rather than in reconciliation because the client
needs a window at startup, so attaching every agent up front would mean
`M-x herdr\\=' seizing a window per agent before being asked for anything.
Returns the buffer when it showed one."
  (let ((buffer (herdr-term-buffer-for-pane pane-id)))
    (unless (buffer-live-p buffer)
      (setq buffer (herdr-term--attach-if-possible pane-id)))
    (when (buffer-live-p buffer)
      (herdr-term--show buffer)
      buffer)))

(defun herdr-term--attach-if-possible (pane-id)
  "Attach to PANE-ID now, if the cache knows it."
  (let ((state (herdr-state-current)))
    (when-let* ((pane (herdr-state-pane state pane-id)))
      (herdr-term--attach state pane))))

(defun herdr-term-select-focused ()
  "Select the buffer for whichever pane herdr now considers focused.
Asks the server rather than trusting the cache, because focus may have
moved as a side effect of the command that just ran."
  (when-let* ((pane (ignore-errors
                      (alist-get 'pane_id
                                 (alist-get 'pane (herdr-rpc-call "pane.current"))))))
    (herdr-term-select-pane pane)))

(defun herdr-term-buffer-for-pane (pane-id)
  "Return the buffer showing PANE-ID, if one is attached."
  (cdr (assoc pane-id (herdr-term--live-buffers))))

(defun herdr-term-pane-for-buffer (&optional buffer)
  "Return the pane id BUFFER is showing, or nil if it is not a herdr terminal."
  (let* ((buffer (or buffer (current-buffer)))
         (id (car (rassq buffer (herdr-term--live-buffers)))))
    ;; Ignore a buffer whose pane has since gone away.
    (when (and id (herdr-state-pane (herdr-state-current) id))
      id)))

(defun herdr-term-buffer-p (&optional buffer)
  "Return non-nil if BUFFER is one of herdr\\='s terminal buffers.

Membership in the registry rather than the major mode: a herdr terminal
is a `ghostel-mode\\=' buffer like any other ghostel shell, and only herdr
knows which of them front its panes.  Unlike `herdr-term-pane-for-buffer\\='
this still answers for a buffer whose pane has gone away, which is a
buffer to clean up rather than one to protect."
  (and (rassq (or buffer (current-buffer)) (herdr-term--live-buffers)) t))

(defun herdr-term--attach (state pane)
  "Create and start a ghostel buffer attached to PANE, named from STATE.
Returns an existing buffer untouched rather than attaching twice:
attachment is exclusive per pane, so a second attach either fails or
steals the first one's terminal."
  (let* ((pane-id (herdr-pane-id pane))
         (existing (herdr-term-buffer-for-pane pane-id)))
    (if (buffer-live-p existing)
        existing
      (herdr-term--attach-1 state pane pane-id))))

(defun herdr-term--attach-1 (state pane pane-id)
  "Create and start a ghostel buffer attached to PANE, named from STATE.

Signals rather than answering nil when the client will not start: the
two ways it can fail - a pane with no `terminal_id\\=', an
`herdr-executable\\=' that will not run - are both settings to fix, and
neither improves by being retried.  Nil is left meaning what the callers
that retry already read it as: the cache does not know this pane yet.

Created under `herdr-term--unique-buffer-name\\=' rather than the
plain wanted name: that name is not guaranteed unique, and a collision
would hand this pane's client a buffer `get-buffer-create\\=' found
already live for a different pane, attaching two panes into one
terminal."
  (let* (;; Argv first, before anything exists to clean up:
         ;; `herdr-pane-attach-args' refuses a pane with no
         ;; `terminal_id', and that refusal is about the server being
         ;; too old, not about this buffer.
         (args (herdr-pane-attach-args pane nil))
         (buffer (get-buffer-create
                  (herdr-term--unique-buffer-name state pane))))
    ;; Everything from here to the registry under one cleanup.  A buffer
    ;; that exists but never reached `herdr-term--buffers' is invisible
    ;; to teardown, to the reap and to `herdr-term-buffer-p', and the
    ;; next select builds a second buffer for the same pane - so any step
    ;; that can signal has to take the buffer with it, not just the one
    ;; that signals most often.
    (condition-case err
        (progn
          (with-current-buffer buffer (ghostel-mode))
          ;; The buffer needs a window when the client starts: attaching
          ;; without displaying, or with a window that is deleted straight
          ;; afterwards, kills the client and ghostel then kills the
          ;; buffer.  Being merely hidden later is fine — a buried
          ;; terminal keeps running — so the window only has to exist, not
          ;; persist.  Shown through `herdr-display-action' like every
          ;; other path.
          (herdr-term--show buffer)
          (ghostel-exec buffer herdr-executable args)
          (herdr-term--set-directory buffer pane)
          (push (cons pane-id buffer) herdr-term--buffers))
      (error
       (kill-buffer buffer)
       (signal (car err) (cdr err))))
    buffer))

(defun herdr-term--rename-stale-buffers ()
  "Rename buffers whose pane has changed identity since they were created.

A pane that starts as a plain shell and gets an agent detected in it
keeps the same buffer, since the attachment is still valid.  Without
this its name would read `shell' forever.

Compares against the buffer's name with any uniquifying suffix removed.
Two unnamed panes of the same kind in one workspace share a wanted name,
so one of their buffers keeps a `...<2>\\=' suffix for as long as that
collision lasts — that is not staleness, and recomputing the bare
`wanted\\=' every sync and renaming toward it each time would just have
`rename-buffer\\=' hand the same suffix right back, forever, from inside
the state-change hook."
  (let ((state (herdr-state-current)))
    (dolist (cell (herdr-term--live-buffers))
      (when-let* ((pane (herdr-state-pane state (car cell)))
                  (wanted (herdr-term-buffer-name state pane))
                  ((not (equal wanted
                               (herdr-term--buffer-name-sans-uniquify-suffix
                                (buffer-name (cdr cell)))))))
        (with-current-buffer (cdr cell)
          ;; Unique suffix rather than an error if the name is taken.
          (rename-buffer wanted t))))))

(defun herdr-term--sync-buffers ()
  "Reap buffers whose pane is gone and correct stale names.

Deliberately does not attach.  Attaching requires displaying the buffer
and keeping it displayed, so attaching on every `pane_agent_detected\\='
would take a window each time an agent appears.  `herdr-term-select-pane\\='
attaches on demand instead."
  (dolist (buffer (herdr-term-buffers-to-reap (herdr-state-current)
                                             (herdr-term--live-buffers)))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (herdr-term--rename-stale-buffers)
  (herdr-term--live-buffers))

;;; Directory tracking

(defcustom herdr-term-track-directory t
  "Whether terminal buffers follow their herdr pane's working directory.

herdr consumes OSC 7 rather than forwarding it, so ghostel's own
directory tracking cannot see through it.  herdr does track cwd itself,
so `default-directory' is driven from that instead.

It has to be polled.  herdr publishes no event when a pane changes
directory: a `cd' produces only unrelated `layout_updated' traffic, so
there is nothing to subscribe to.  See `herdr-term-directory-interval'."
  :type 'boolean
  :group 'herdr)

(defcustom herdr-term-directory-interval 5.0
  "Seconds between backstop working-directory polls, or nil to disable.
Directories normally refresh off `layout_updated', debounced by
`herdr-term-directory-debounce'.  This timer only covers a change that
produces no events at all."
  :type '(choice number (const :tag "Never poll" nil))
  :group 'herdr)

(defcustom herdr-term-directory-debounce 0.4
  "Seconds to coalesce directory refreshes triggered by events.
One `cd' emits dozens of `layout_updated' events."
  :type 'number
  :group 'herdr)

(defvar herdr-term--directory-timer nil)
(defvar herdr-term--directory-debounce-timer nil)

(defvar herdr-term--poll-in-progress nil
  "Non-nil while a directory poll's RPC is in flight.
The RPC wait runs due timers, so without this the next poll fires
re-entrantly inside the previous one's wait.  Let-bound, not set, so a
signal anywhere in the poll clears it.")

(defun herdr-term--poll-directories ()
  "Refresh pane directories, then point buffers at them.
Also the one caller of `herdr-state-reconcile-workspaces': no event
reliably announces a workspace's removal, so a missed `workspace.closed'
would leave a ghost for the rest of the session."
  ;; Guarded on the stream only, not on a herdr buffer existing: pruning
  ;; panes the server no longer has matters most when no buffers are
  ;; open, because that is when the pickers are used.
  ;;
  ;; The background timeout is what keeps this survivable.  This fires on
  ;; a 5s interval whether or not the server is well, and at the full 10s
  ;; `herdr-rpc-timeout' a wedged server makes the backstop a
  ;; continuous main-thread freeze.
  (when (and (herdr-state-running-p)
             (not herdr-term--poll-in-progress))
    (let ((herdr-term--poll-in-progress t)
          (herdr-rpc-timeout (min herdr-rpc-timeout
                                  herdr-rpc-background-timeout)))
      (when (herdr-state-reconcile-panes)
        (herdr-term--sync-directories))
      (herdr-state-reconcile-workspaces))))

(defun herdr-term--schedule-directory-poll ()
  "Refresh directories shortly, coalescing bursts of events."
  (when herdr-term-track-directory
    (when herdr-term--directory-debounce-timer
      (cancel-timer herdr-term--directory-debounce-timer))
    (setq herdr-term--directory-debounce-timer
          (run-at-time herdr-term-directory-debounce nil
                       (lambda ()
                         (setq herdr-term--directory-debounce-timer nil)
                         (herdr-term--poll-directories))))))

(defun herdr-term--start-directory-timer ()
  "Begin the backstop poll for working-directory changes.
A repeating timer rather than an idle one: idle timers never fire while
something keeps Emacs busy, which is exactly when a long-running command
is changing directories."
  (when (and herdr-term-track-directory
             herdr-term-directory-interval
             (not herdr-term--directory-timer))
    (setq herdr-term--directory-timer
          (run-at-time herdr-term-directory-interval
                       herdr-term-directory-interval
                       #'herdr-term--poll-directories))))

(defun herdr-term--stop-directory-timer ()
  "Stop polling for working-directory changes."
  (dolist (timer (list herdr-term--directory-timer
                       herdr-term--directory-debounce-timer))
    (when timer (cancel-timer timer)))
  (setq herdr-term--directory-timer nil
        herdr-term--directory-debounce-timer nil))

(defun herdr-term--set-directory (buffer pane)
  "Point BUFFER's `default-directory' at PANE's working directory."
  (when-let* (((buffer-live-p buffer))
              (dir (herdr-pane-directory pane)))
    (with-current-buffer buffer
      (unless (equal default-directory dir)
        (setq default-directory dir)))))

(defun herdr-term--sync-directories ()
  "Point every terminal buffer at its pane's current directory."
  (when herdr-term-track-directory
    (let ((state (herdr-state-current)))
      (dolist (cell (herdr-term--live-buffers))
        (when-let* ((pane (herdr-state-pane state (car cell))))
          (herdr-term--set-directory (cdr cell) pane))))))

(defun herdr-term--on-state-change (_kind _data)
  "Resync terminal buffers after a cache change."
  (herdr-term--sync-buffers)
  (herdr-term--sync-directories)
  (herdr-term--schedule-directory-poll))

;;; Interface

(defun herdr-term-ensure ()
  "Make sure the terminals exist, starting the server if needed."
  (require 'ghostel)
  (let ((bootstrap (unless (herdr-server-live-p)
                     (herdr-term--bootstrap-server))))
    (add-hook 'herdr-state-change-functions #'herdr-term--on-state-change)
    (prog1
        (progn
          ;; The bootstrap client was only there to start the daemon.
          (when (buffer-live-p bootstrap) (kill-buffer bootstrap))
          (herdr-term--sync-buffers))
      (herdr-term--sync-directories)
      (herdr-term--start-directory-timer))))

(defun herdr-term-teardown ()
  "Kill the terminal buffers.  The herdr server is left running."
  (remove-hook 'herdr-state-change-functions #'herdr-term--on-state-change)
  (herdr-term--stop-directory-timer)
  (dolist (cell (herdr-term--live-buffers))
    (kill-buffer (cdr cell)))
  (setq herdr-term--buffers nil))

;;; Optional integration, registered only when project.el is loaded

;; herdr's terminals live in the project directory and answer to
;; `project-buffers', but no default clause in
;; `project-kill-buffer-conditions' matches one, so `project-kill-buffers'
;; counted them and left them behind.  Guarded like the completion
;; integrations: project.el is built in, its variables are not a
;; contract, and a convenience must never break loading.

(defun herdr-term--register-project ()
  "Teach `project-kill-buffer-conditions\\=' about herdr terminals."
  (when (boundp 'project-kill-buffer-conditions)
    (add-to-list 'project-kill-buffer-conditions #'herdr-term-buffer-p t)))

(with-eval-after-load 'project
  (herdr-term--register-project))

(provide 'herdr-term)
;;; herdr-term.el ends here
