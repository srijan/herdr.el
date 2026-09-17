;;; herdr-term.el --- Terminal hosting for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Maintainer: Srijan Choudhary
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1") (ghostel "0"))

;;; Commentary:

;; herdr's terminals are hosted inside Emacs, never outside it: one
;; ghostel buffer per pane, each holding a `herdr terminal attach'.
;; Emacs owns the layout and herdr's own layout tree goes unused, so
;; there is no geometry to synchronise.  Panes outlive Emacs because the
;; server is a daemon.
;;
;; Two constraints shape the code here.  Attachment is exclusive per
;; pane, so a second attach is refused and `herdr-pane-takeover' is what
;; takes the terminal instead.  And the client paints nothing into a
;; zero-sized PTY, so a buffer must be displayed before its process
;; starts.
;;
;; Measured throughput and attach behaviour are in docs/protocol.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'herdr-rpc)
(require 'herdr-connection)
(require 'herdr-state)
(require 'herdr-pane)

(declare-function ghostel-exec "ghostel" (buffer program &optional args))
(declare-function ghostel-mode "ghostel" ())
(declare-function ghostel--redraw-now "ghostel" (buffer &optional force))
(declare-function ghostel-desktop-restore-buffer "ghostel-desktop"
                  (file-name buffer-name misc))
(defvar ghostel-exit-functions)
(defvar desktop-save-buffer)
(defvar desktop-buffer-mode-handlers)

(defcustom herdr-display-action
  '((display-buffer-reuse-window display-buffer-same-window))
  "How herdr buffers are shown, for every path that shows one.
Starting herdr, going to a pane and attaching all route through this, so
one buffer cannot appear two ways depending on the command.  The default
reuses the current window and leaves the frame alone.

    (setq herdr-display-action \\='(display-buffer-full-frame))"
  :type 'sexp
  :group 'herdr
  :package-version '(herdr . "0.1.0"))

(defun herdr-term--show (buffer)
  "Show BUFFER according to `herdr-display-action' and select it."
  (pop-to-buffer buffer herdr-display-action))

(defcustom herdr-server-start-timeout 15.0
  "Seconds to wait for a freshly launched herdr server to answer."
  :type 'number
  :group 'herdr
  :package-version '(herdr . "0.1.0"))

;;; Naming and argument construction — pure, so they are testable

(defun herdr-term-buffer-name (state pane)
  "Return the wanted buffer name for PANE, read against STATE.

Not unique.  Two unnamed panes of the same kind in one workspace compute
the same name, so callers that create a buffer must uniquify first; see
`herdr-term--unique-buffer-name'."
  (format "*herdr: %s*" (herdr-term-pane-identity state pane)))

(defun herdr-term-pane-identity (state pane)
  "Return PANE\\='s identity, with the two facts STATE holds looked up.
`herdr-pane-identity' takes no cache on purpose; this is the one place
that fetches what it needs from one."
  (herdr-pane-identity pane
                       (herdr-state-agent-name state (herdr-pane-id pane))
                       (herdr-state-workspace-label
                        state (herdr-pane-workspace-id pane))))

(defun herdr-term--unique-buffer-name (state pane)
  "Return a unique buffer name for PANE in STATE.
The name itself comes from `herdr-term-buffer-name'.  Uniquify before
creating, not after: `get-buffer-create' on a colliding name hands back
another pane\\='s buffer rather than a fresh one."
  (generate-new-buffer-name (herdr-term-buffer-name state pane)))

(defun herdr-term--buffer-name-sans-uniquify-suffix (name)
  "Return NAME with a trailing `<N>' uniquifying suffix stripped, if any.
Without this, a buffer that collided on creation compares unequal to its
own wanted name forever; see `herdr-term--rename-stale-buffers'."
  (replace-regexp-in-string "<[0-9]+>\\'" "" name))

(defun herdr-term-buffers-to-reap (state buffers)
  "Return the buffers in BUFFERS whose pane is gone from STATE.

BUFFERS is an alist of (PANE-ID . BUFFER).  Pure: no processes are
touched and no buffer is killed here.

It used to answer a pair, the other half naming panes with no buffer.
Nothing attached from it - attaching needs a window, so it happens on
demand in `herdr-term-select-pane' - so the half was carried, tested
and never read."
  (let ((pane-ids (mapcar (lambda (pane) (herdr-pane-id pane))
                          (herdr-state-panes state))))
    (mapcar #'cdr
            (seq-remove (lambda (cell) (member (car cell) pane-ids))
                        buffers))))

;;; Server lifecycle

(defun herdr-server-live-p (connection)
  "Return non-nil when the herdr server answers a ping.

The ping is bound to `herdr-rpc-background-timeout': this is a liveness
probe, called in a loop while the server starts and once before every
start, and a healthy local server answers in milliseconds.  At the full
`herdr-rpc-timeout' a hung socket made each probe a ten-second freeze —
the startup loop alone could block for forty."
  (let ((herdr-rpc-timeout (min herdr-rpc-timeout
                                herdr-rpc-background-timeout)))
    (condition-case nil
        (progn (herdr-rpc-call connection "ping") t)
      (herdr-error nil))))

(defun herdr-term--bootstrap-complaint (log)
  "Return what the server wrote to LOG as a phrase to append to an error."
  (let ((said (ignore-errors
                (with-temp-buffer
                  (insert-file-contents log)
                  (string-trim (buffer-string))))))
    (if (and said (not (string-empty-p said))) (format ": %s" said) "")))

(defun herdr-term--bootstrap-server (connection)
  "Start the local herdr server, detached, and wait for it to answer.

`herdr server' is how herdr starts its own daemon, but it blocks in the
foreground and has no detach flag: started as a process of ours it would
be an Emacs child and die with Emacs.  The `&' lets the shell exit at
once so the server is reparented to init instead.

Local only.  A remote connection\\='s server lives on the far host, and
starting one here would bring up a local server the tunnel does not
point at and then report success.

`call-process' returns when the shell does, so it cannot say whether
herdr started; the ping loop is the detector and LOG is what lets a
timeout say why."
  (when (herdr-connection-remote-p connection)
    (error "herdr: no server answering on %s; start it on that host"
           (herdr-connection-ssh-target connection)))
  (let ((log (make-temp-file "herdr-server-")))
    (unwind-protect
        (progn
          (call-process "sh" nil nil nil "-c"
                        (format "%s server >%s 2>&1 &"
                                (shell-quote-argument herdr-executable)
                                (shell-quote-argument log)))
          ;; One liveness answer per loop pass, and none after the
          ;; deadline.
          (let ((deadline (+ (float-time) herdr-server-start-timeout))
                (live (herdr-server-live-p connection)))
            (while (and (not live) (< (float-time) deadline))
              (sit-for 0.2)
              (setq live (herdr-server-live-p connection)))
            (unless live
              (error "herdr server did not come up within %ss%s.  \
For one that outlives Emacs: `brew services start herdr', or a systemd \
user unit running `herdr server'"
                     herdr-server-start-timeout
                     (herdr-term--bootstrap-complaint log)))))
      (delete-file log))))

;;; Buffer bookkeeping

(defvar herdr-term--buffers nil
  "Alist of ((TOKEN . PANE-ID) . BUFFER), one entry per attached pane.

Keyed by the connection\\='s token and not by the connection itself, per
KTD2: the struct is mutable and `equal' on a struct compares fields, so
a key holding one would stop matching the moment a process or a cache
slot changed under it.  A bare pane id will not do either — ids are
per-server counters, and two machines may each hold a `w1:p1'.")

(defun herdr-term--key (connection pane-id)
  "Return the registry key for PANE-ID on CONNECTION."
  (cons (herdr-connection-token connection) pane-id))

(defun herdr-term--live-buffers ()
  "Return `herdr-term--buffers' with dead buffers dropped."
  (setq herdr-term--buffers
        (seq-filter (lambda (cell) (buffer-live-p (cdr cell)))
                    herdr-term--buffers)))

(defun herdr-term--buffers-for (connection)
  "Return CONNECTION\\='s attached buffers, as an alist of (PANE-ID . BUFFER).
Without the token, so that the pure helpers and the callers that walk
one server\\='s panes see the shape they had before there were two."
  (let ((token (herdr-connection-token connection)))
    (mapcan (lambda (cell)
              (when (equal token (caar cell))
                (list (cons (cdar cell) (cdr cell)))))
            (herdr-term--live-buffers))))

(defun herdr-term-select-pane (connection pane-id)
  "Show PANE-ID, attaching to it first if it is not attached yet.

Focus is server-side state and nothing in Emacs repaints: each pane is
its own buffer, so focusing one has no visible effect unless Emacs also
selects that buffer.

Attaching happens here rather than in reconciliation because the client
needs a window at startup, so attaching every agent up front would mean
`M-x herdr' seizing a window per agent before being asked for anything.
Returns the buffer when it showed one.

Refuses the pane this Emacs is running in.  Attaching to it points a
terminal buffer at the terminal that is drawing the buffer, and the
frame renders itself inside itself until something gives.  The refusal
is a message rather than an error: going to where you already are is a
misunderstanding, not a failure, and the dashboard row is a reasonable
thing to have pressed RET on."
  (when (herdr-self-pane-p connection pane-id)
    (user-error "herdr: %s is the pane this Emacs is running in" pane-id))
  (let ((buffer (herdr-term-buffer-for-pane connection pane-id)))
    (unless (buffer-live-p buffer)
      (setq buffer (herdr-term--attach-if-possible connection pane-id)))
    (when (buffer-live-p buffer)
      (herdr-term--show buffer)
      buffer)))

(defun herdr-term--attach-if-possible (connection pane-id &optional takeover)
  "Attach to CONNECTION\\='s PANE-ID now, if its cache knows it.
With TAKEOVER, take the terminal from whatever client holds it."
  (let ((state (herdr-state-current connection)))
    (when-let* ((pane (herdr-state-pane state pane-id)))
      (herdr-term--attach connection state pane takeover))))

(defun herdr-term-select-focused (&optional connection)
  "Select the buffer for whichever pane CONNECTION now considers focused.
Asks the server rather than trusting the cache, because focus may have
moved as a side effect of the command that just ran."
  (let ((connection (or connection (herdr-current-connection))))
    (when-let* ((pane (ignore-errors
                        (alist-get 'pane_id
                                   (alist-get 'pane
                                              (herdr-rpc-call
                                               connection "pane.current"))))))
      (herdr-term-select-pane connection pane))))

(defun herdr-term-buffer-for-pane (connection pane-id)
  "Return the buffer showing CONNECTION\\='s PANE-ID, if one is attached."
  (cdr (assoc (herdr-term--key connection pane-id)
              (herdr-term--live-buffers))))

(defun herdr-term-pane-for-buffer (&optional buffer)
  "Return the pane id BUFFER is showing, or nil if it is not a herdr terminal.
The pane is checked against the buffer\\='s own connection, which the
buffer has carried since it was attached: checking it against whichever
connection is current would retire a live buffer the moment another
server\\='s cache did not happen to know its id."
  (let* ((buffer (or buffer (current-buffer)))
         (key (car (rassq buffer (herdr-term--live-buffers))))
         (connection (and key (buffer-local-value 'herdr-buffer-connection
                                                  buffer))))
    ;; Ignore a buffer whose pane has since gone away.
    (when (and key connection
               (herdr-state-pane (herdr-state-current connection) (cdr key)))
      (cdr key))))

(defun herdr-term-buffer-p (&optional buffer)
  "Return non-nil if BUFFER is one of herdr\\='s terminal buffers.

Membership in the registry rather than the major mode: a herdr terminal
is a `ghostel-mode' buffer like any other ghostel shell, and only herdr
knows which of them front its panes.  Unlike `herdr-term-pane-for-buffer'
this still answers for a buffer whose pane has gone away, which is a
buffer to clean up rather than one to protect."
  (and (rassq (or buffer (current-buffer)) (herdr-term--live-buffers)) t))

(defconst herdr-term-attach-refused "already has an attached client"
  "What herdr leaves in the terminal when the pane is held elsewhere.")

(defun herdr-term--squeezed (text)
  "Return TEXT with every space, tab and newline taken out.
The buffer is a terminal grid: herdr's 130-character refusal hard-wraps
mid-word below that width, so both sides are compared squeezed."
  (replace-regexp-in-string "[ \t\n\r]+" "" text))

(defun herdr-term--client-ended (buffer _event)
  "Say why herdr's client for BUFFER stopped, when herdr said why.

The status cannot answer it.  Measured against 0.9.0: refused, taken
over, and the pane closing under a healthy attach all exit 1, so the
reason is only in the text herdr leaves behind.

Reports rather than offers.  A prompt here runs inside ghostel's exit
path, and anything that blocks while ghostel holds the terminal is how
Emacs wedges in redraw; `herdr-pane-takeover' is the offer, on a key."
  (when-let* ((pane-id (herdr-term-pane-for-buffer buffer)))
    ;; ghostel materializes rows on a coalescing timer, so herdr's last
    ;; line can still be pending and the tail read empty.  Reliable here
    ;; because a redraw only stays pending for a buffer with no render
    ;; window, and an attaching buffer always has one.
    (when (fboundp 'ghostel--redraw-now)
      (ghostel--redraw-now buffer))
    (with-current-buffer buffer
      (let ((tail (herdr-term--squeezed
                   (buffer-substring-no-properties
                    (max (point-min) (- (point-max) 2000)) (point-max)))))
        (when (string-search (herdr-term--squeezed herdr-term-attach-refused) tail)
          (message "herdr: %s is attached elsewhere; %s takes it over"
                   pane-id
                   (substitute-command-keys "\\[herdr-pane-takeover]")))))))

(defun herdr-term-desktop-save (_desktop-dirname)
  "Return this herdr terminal as desktop data: (herdr NAME PANE-ID).

Only herdr's own buffers get this: `ghostel-mode' sets
`desktop-save-buffer' to ghostel's saver and `herdr-term--attach-1'
overrides it afterwards, so every other ghostel buffer saves as before.

The connection is named rather than written out.  A connection is a
live socket and a process; the name is what the user typed, what the
registry is keyed by, and the only part of it that means anything in a
later Emacs."
  (list 'herdr
        (herdr-connection-name herdr-buffer-connection)
        (herdr-term-pane-for-buffer (current-buffer))))

(defun herdr-term--desktop-connection (name)
  "Return the connection called NAME, connecting first when it is not up.

Connects only to a server that is already running, and only the local
one.  A desktop is read at startup as well as by hand, and an
unattended restore must not start a server - nor block on one that is
not there, which is what a connect to a dead socket costs.

A remote connection cannot be rebuilt from a name alone: it needs its
ssh target, which is not ours to guess.  One that is already registered
is used; one that is not is skipped."
  (or (herdr-connection-named name)
      (when (equal name (herdr-connection-name (herdr-connection-local)))
        (let ((candidate (herdr-connection-local)))
          (when (herdr-server-live-p candidate)
            (herdr-connect name herdr-socket-path))))))

(defun herdr-term--desktop-reattach (name pane-id buffer-name)
  "Reattach to PANE-ID on the connection called NAME, for BUFFER-NAME.

Answers nil rather than signalling when it cannot: desktop reports a
handler that signals as a buffer it could not load, and a pane that has
since closed is not a failure worth that."
  (if-let* ((connection (herdr-term--desktop-connection name)))
      (or (herdr-term--attach-if-possible connection pane-id)
          (progn
            (message "herdr: %s is gone on %s; not restoring %s"
                     pane-id name buffer-name)
            nil))
    (message "herdr: no herdr server called %s; not restoring %s"
             name buffer-name)
    nil))

;;;###autoload
(defun herdr-term-desktop-restore (file-name buffer-name misc)
  "Restore a ghostel buffer from desktop data MISC.

herdr's own buffers are reattached to their pane, which is the whole
point: a pane outlives the Emacs that was showing it, so the terminal
can be picked up exactly where it was left.  ghostel's own handler
declines them - it will not re-run an exec'd command unattended, and
`herdr terminal attach' is one - so herdr has to answer for them.

Every other ghostel buffer is handed straight to ghostel.  This handler
sits in front of ghostel's for the whole mode, so declining to pass
those on would break shells that have nothing to do with herdr.

FILE-NAME and BUFFER-NAME are desktop's; MISC is what
`herdr-term-desktop-save' or `ghostel-desktop-save-buffer' wrote."
  (if (eq 'herdr (car-safe misc))
      (herdr-term--desktop-reattach (nth 1 misc) (nth 2 misc) buffer-name)
    (ghostel-desktop-restore-buffer file-name buffer-name misc)))

;; Autoloaded, because a desktop is read before anything has called a
;; herdr command.  `use-package' defers this package, `desktop-read' runs
;; from `emacs-startup-hook', and a registration that waits for
;; herdr-term.el to load is therefore never there when it is needed:
;; ghostel's handler answers instead and skips every herdr buffer.  The
;; autoloads file is loaded at init, so this form is.
;;
;; After ghostel, deliberately.  Both entries key on `ghostel-mode' and
;; desktop takes the first `assq' match, so herdr has to be the one added
;; last.  Either order of loading gets there: with ghostel already
;; loaded the body runs now, and otherwise it runs when `desktop-load-file'
;; loads ghostel for the mode, which desktop does before it looks the
;; handler up.
;;;###autoload
(with-eval-after-load 'ghostel
  (add-to-list 'desktop-buffer-mode-handlers
               '(ghostel-mode . herdr-term-desktop-restore)))

(defun herdr-term--attach (connection state pane &optional takeover)
  "Create and start a ghostel buffer attached to PANE, named from STATE.
Returns an existing buffer untouched rather than attaching twice:
attachment is exclusive per pane, so a second attach either fails or
steals the first one's terminal.  Exclusive per pane per server: the
same id on another connection is another pane and gets its own buffer."
  (let* ((pane-id (herdr-pane-id pane))
         (existing (herdr-term-buffer-for-pane connection pane-id)))
    (if (buffer-live-p existing)
        existing
      (herdr-term--attach-1 connection state pane pane-id takeover))))

(defun herdr-term--attach-1 (connection state pane pane-id &optional takeover)
  "Create and start a ghostel buffer attached to PANE, named from STATE.

Signals rather than answering nil when the client will not start: the
two ways it can fail - a pane with no `terminal_id', an
`herdr-executable' that will not run - are both settings to fix, and
neither improves by being retried.  Nil is left meaning what the callers
that retry already read it as: the cache does not know this pane yet.

Created under `herdr-term--unique-buffer-name' rather than the
plain wanted name: that name is not guaranteed unique, and a collision
would hand this pane's client a buffer `get-buffer-create' found
already live for a different pane, attaching two panes into one
terminal."
  (let* (;; Argv first, before anything exists to clean up:
         ;; `herdr-pane-attach-args' refuses a pane with no
         ;; `terminal_id', and that refusal is about the server being
         ;; too old, not about this buffer.
         (args (herdr-pane-attach-args
                pane takeover (herdr-connection-session connection)))
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
          (with-current-buffer buffer
            (ghostel-mode)
            ;; Before anything can go wrong: a buffer that reaches the
            ;; registry without its connection answers commands typed in
            ;; it against whichever server is current.
            (setq herdr-buffer-connection connection)
            ;; Buffer-local: `ghostel-exit-functions' is global, and only
            ;; herdr's own buffers have a herdr message to read.
            (add-hook 'ghostel-exit-functions #'herdr-term--client-ended nil t)
            ;; After `ghostel-mode', which sets its own saver.
            (setq-local desktop-save-buffer #'herdr-term-desktop-save)
            ;; And before the client starts, because `ghostel-exec' reads
            ;; `default-directory' to decide which machine to spawn the
            ;; pty on.  The host is the floor: a remote pane whose cwd
            ;; says nothing must still spawn on its own machine, not
            ;; here.
            (when-let* ((host (herdr-connection-host-directory connection)))
              (setq default-directory host)))
          ;; The buffer needs a window when the client starts: attaching
          ;; without displaying, or with a window that is deleted straight
          ;; afterwards, kills the client and ghostel then kills the
          ;; buffer.  Being merely hidden later is fine — a buried
          ;; terminal keeps running — so the window only has to exist, not
          ;; persist.  Shown through `herdr-display-action' like every
          ;; other path.
          (herdr-term--show buffer)
          ;; Before the exec, not after: the directory is what tells
          ;; ghostel where to run, and setting it afterwards told it
          ;; nothing and ran the client here.
          (herdr-term--set-directory connection buffer pane)
          ;; The connection's own binary: TRAMP runs remote commands
          ;; under its own PATH, not the login one, so a bare name that
          ;; resolves for `ssh host herdr' does not resolve here.
          (ghostel-exec buffer (herdr-connection-executable connection) args)
          (push (cons (herdr-term--key connection pane-id) buffer)
                herdr-term--buffers))
      (error
       (kill-buffer buffer)
       (signal (car err) (cdr err))))
    buffer))

(defun herdr-term--rename-stale-buffers (connection)
  "Rename buffers whose pane has changed identity since they were created.

A pane that starts as a plain shell and gets an agent detected in it
keeps the same buffer, since the attachment is still valid.  Without
this its name would read `shell' forever.

Compares against the buffer's name with any uniquifying suffix removed.
Two unnamed panes of the same kind in one workspace share a wanted name,
so one of their buffers keeps a `...<2>' suffix for as long as that
collision lasts — that is not staleness, and recomputing the bare
`wanted' every sync and renaming toward it each time would just have
`rename-buffer' hand the same suffix right back, forever, from inside
the state-change hook."
  (let ((state (herdr-state-current connection)))
    (dolist (cell (herdr-term--buffers-for connection))
      (when-let* ((pane (herdr-state-pane state (car cell)))
                  (wanted (herdr-term-buffer-name state pane))
                  ((not (equal wanted
                               (herdr-term--buffer-name-sans-uniquify-suffix
                                (buffer-name (cdr cell)))))))
        (with-current-buffer (cdr cell)
          ;; Unique suffix rather than an error if the name is taken.
          (rename-buffer wanted t))))))

(defun herdr-term--sync-buffers (connection)
  "Reap CONNECTION\\='s buffers whose pane is gone and correct stale names.

Scoped to the connection that changed.  Reaping against every registered
buffer would have one server\\='s cache retire another server\\='s
terminals, which is what stopping a connection used to do.

Deliberately does not attach.  Attaching requires displaying the buffer
and keeping it displayed, so attaching on every `pane_agent_detected'
would take a window each time an agent appears.  `herdr-term-select-pane'
attaches on demand instead."
  (dolist (buffer (herdr-term-buffers-to-reap
                   (herdr-state-current connection)
                   (herdr-term--buffers-for connection)))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (herdr-term--rename-stale-buffers connection)
  (herdr-term--live-buffers))

;;; Directory tracking

(defcustom herdr-term-track-directory t
  "Whether terminal buffers follow their herdr pane's working directory.

herdr consumes OSC 7 rather than forwarding it, so ghostel's own
directory tracking cannot see through it.  herdr does track cwd itself,
so `default-directory' is driven from that instead.

It has to be asked for.  herdr publishes no event when a pane changes
directory: a `cd' produces only unrelated `layout_updated' traffic, so
there is nothing to subscribe to.  A directory therefore reaches the
cache only through a repair; see `herdr-state-repair'."
  :type 'boolean
  :group 'herdr
  :package-version '(herdr . "0.1.0"))

(defcustom herdr-term-directory-debounce 0.4
  "Seconds to coalesce directory refreshes triggered by events.
One `cd' emits dozens of `layout_updated' events."
  :type 'number
  :group 'herdr
  :package-version '(herdr . "0.1.0"))

(defvar herdr-term--directory-debounce-timers nil
  "Alist of (TOKEN . TIMER) for the pending directory refreshes.
One timer per connection, keyed like `herdr-term--buffers'.  A single
global timer meant a chatty server cancelled a quiet one\\='s pending
repair every time it fired, so the quiet server\\='s terminals kept a
directory that had already changed.")

(defun herdr-term--schedule-directory-refresh (connection)
  "Repair CONNECTION\\='s cache shortly, coalescing bursts of events.
The repair is what reads the new directory; the change hook it runs
then points the buffers at it.

The connection is the one that notified, carried into the timer rather
than read when it fires: a timer callback runs in an empty extent."
  (when herdr-term-track-directory
    (let ((token (herdr-connection-token connection)))
      (when-let* ((pending (alist-get token herdr-term--directory-debounce-timers)))
        (cancel-timer pending))
      (setf (alist-get token herdr-term--directory-debounce-timers)
            (run-at-time herdr-term-directory-debounce nil
                         (lambda ()
                           (setf (alist-get token
                                            herdr-term--directory-debounce-timers)
                                 nil)
                           (herdr-state-repair connection)))))))

(defun herdr-term--cancel-directory-debounce (&optional connection)
  "Cancel CONNECTION\\='s pending debounced refresh, or every one."
  (dolist (cell herdr-term--directory-debounce-timers)
    (when (and (cdr cell)
               (or (null connection)
                   (equal (car cell) (herdr-connection-token connection))))
      (cancel-timer (cdr cell))
      (when connection (setcdr cell nil))))
  (unless connection (setq herdr-term--directory-debounce-timers nil)))

(defun herdr-term--set-directory (connection buffer pane)
  "Point BUFFER\\='s `default-directory' at PANE\\='s working directory.

The pane\\='s directory is a path on CONNECTION\\='s own machine, so for a
remote server it is given the TRAMP prefix that says so.  Assigning it
verbatim would strip the buffer\\='s remoteness and silently retarget it
at a local path of the same name."
  (when-let* (((buffer-live-p buffer))
              (dir (herdr-connection-file-name
                    connection (herdr-pane-directory-name pane)))
              ;; Checked only where checking is cheap and means
              ;; anything.  A remote path would cost a stat over TRAMP
              ;; per pane per poll to ask a question the server has
              ;; already answered about its own machine.
              ((or (file-remote-p dir) (file-directory-p dir))))
    (with-current-buffer buffer
      (unless (equal default-directory dir)
        (setq default-directory dir)))))

(defun herdr-term--sync-directories (connection)
  "Point CONNECTION\\='s terminal buffers at their panes' current directories."
  (when herdr-term-track-directory
    (let ((state (herdr-state-current connection)))
      (dolist (cell (herdr-term--buffers-for connection))
        (when-let* ((pane (herdr-state-pane state (car cell))))
          (herdr-term--set-directory connection (cdr cell) pane))))))

(defun herdr-term--on-state-change (connection kind _data)
  "Resync CONNECTION\\='s terminal buffers after its cache changed.
Nudges a repair for every KIND but \"reconcile\", which is a repair
reporting what it just changed: nudging another one there pays two round
trips to be told nothing moved."
  (herdr-term--sync-buffers connection)
  (herdr-term--sync-directories connection)
  (unless (equal kind "reconcile")
    (herdr-term--schedule-directory-refresh connection)))

;;; Interface

(defun herdr-term-ensure (connection)
  "Make sure CONNECTION\\='s terminals exist, starting its server if needed."
  (require 'ghostel)
  (unless (herdr-server-live-p connection)
    (herdr-term--bootstrap-server connection))
  (add-hook 'herdr-state-change-functions #'herdr-term--on-state-change)
  (prog1 (herdr-term--sync-buffers connection)
    (herdr-term--sync-directories connection)))

(defun herdr-term-teardown (&optional connection)
  "Kill CONNECTION\\='s terminal buffers, or every one when CONNECTION is nil.
The herdr server is left running.

The hook comes off only when nothing is left for it to serve: one
function serves every connection, so removing it because one stopped
would leave the others' buffers unreaped."
  (herdr-term--cancel-directory-debounce connection)
  (dolist (cell (if connection
                    (herdr-term--buffers-for connection)
                  (herdr-term--live-buffers)))
    (kill-buffer (cdr cell)))
  (if connection
      (let ((token (herdr-connection-token connection)))
        (setq herdr-term--buffers
              (seq-remove (lambda (cell) (equal token (caar cell)))
                          (herdr-term--live-buffers))))
    (setq herdr-term--buffers nil))
  (unless (herdr-term--live-buffers)
    (remove-hook 'herdr-state-change-functions
                 #'herdr-term--on-state-change)))

;;; Optional integration, registered only when project.el is loaded

;; herdr's terminals live in the project directory and answer to
;; `project-buffers', but no default clause in
;; `project-kill-buffer-conditions' matches one, so `project-kill-buffers'
;; counted them and left them behind.  Guarded like the completion
;; integrations: project.el is built in, its variables are not a
;; contract, and a convenience must never break loading.

(defun herdr-term--register-project ()
  "Teach `project-kill-buffer-conditions' about herdr terminals."
  (when (boundp 'project-kill-buffer-conditions)
    (add-to-list 'project-kill-buffer-conditions #'herdr-term-buffer-p t)))

(with-eval-after-load 'project
  (herdr-term--register-project))

(provide 'herdr-term)
;;; herdr-term.el ends here
