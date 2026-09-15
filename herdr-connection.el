;;; herdr-connection.el --- The connection registry and resolver -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Where the connections live and how an action finds the one it
;; belongs to.
;;
;; The struct itself is in herdr-rpc.el, with the transport that takes
;; it.  This file holds the set of them and the question every
;; interactive command asks: which server is this about?
;;
;; The answer is a function, not a variable, following
;; `eglot-current-server'.  A variable would be an ambient default, and
;; an ambient default is exactly what a second server turns into a bug:
;; work scheduled against one server landing on another because
;; something read the variable late.  The resolver is asked at the point
;; of action and its answer is carried from there.
;;
;; It is asked in a fixed order, most specific first: the connection
;; bound around an asynchronous dispatch, the buffer's own connection,
;; whatever a registered resolver makes of point, and the sole
;; connection when there is only one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'herdr-rpc)

(declare-function herdr-state-stop "herdr-state" (connection))
(declare-function herdr-state-start "herdr-state" (connection))
(declare-function herdr-state-running-p "herdr-state" (connection))

;;; The registry

(defun herdr-connection--host (path)
  "Return the host part of PATH\\='s TRAMP prefix, or nil when it is local.
The user is deliberately ignored: `/ssh:shadow:\\=' and
`/ssh:me@shadow:\\=' name the same machine, and refusing a path because
the two were spelled differently would be this package inventing a
distinction TRAMP does not make."
  (when-let* ((remote (file-remote-p (or path ""))))
    (let ((host (file-remote-p remote 'host)))
      (and host (downcase host)))))

(defun herdr-connection-file-name (connection path)
  "Return PATH, which CONNECTION\\='s server named, as a file name Emacs can use.

A remote server names paths on its own machine, so a buffer pointed at
one verbatim is pointed at a local path of the same name — usually one
that does not exist, and occasionally one that does and is not it.  The
TRAMP prefix is what makes the name mean the machine it came from."
  (when path
    (if-let* ((prefix (herdr-connection-host-directory connection)))
        (concat prefix (file-local-name path))
      path)))

(defun herdr-connection-server-path (connection path)
  "Return PATH, which Emacs named, as CONNECTION\\='s server would name it.

A server cannot use a TRAMP file name: it names a machine, and the
server already knows which machine it is on.  So the prefix is stripped
— but only once the prefix and the connection agree about the machine,
because a path from a buffer on some third host is a path on neither and
stripping it would hand the server a filename that resolves to
something arbitrary.  A local path offered to a remote server is the
same mistake the other way round.

Signals `herdr-error\\=' on a mismatch rather than guessing, since every
guess here names a real directory on the wrong machine."
  (when path
    (let ((path-host (herdr-connection--host path))
          (server-host (herdr-connection--host
                        (herdr-connection-host-directory connection))))
      (unless (equal path-host server-host)
        (signal 'herdr-error
                (list "wrong_host"
                      (format "%s is on %s; %s is on %s"
                              path (or path-host "this machine")
                              (herdr-connection-name connection)
                              (or server-host "this machine")))))
      (file-local-name (expand-file-name path)))))

(defvar herdr-connections nil
  "Alist of (NAME . CONNECTION) for every connection being followed.

In registration order, which puts the local server first: it is the one
`herdr-start\\=' makes, and the one a command with no other context
means.  Keyed by name because that is what a user types and what a
failure has to be able to name.")

(defun herdr-connection-list ()
  "Return every connection being followed, in registration order."
  (mapcar #'cdr herdr-connections))

(defun herdr-connection-named (name)
  "Return the connection called NAME, or nil."
  (cdr (assoc name herdr-connections)))

(defun herdr-connection-roots-for (connection roots)
  "Return the ROOTS that belong to CONNECTION.

A root is a path on some machine, so it belongs to the connection whose
host it is on: a purely local root to a local server, a TRAMP root to
the server on the host it names.  Asking every connection about every
root is how one server\='s projects reached another, and how two servers
holding the same path became indistinguishable."
  (let ((server (herdr-connection--host
                 (herdr-connection-host-directory connection))))
    (seq-filter (lambda (root)
                  (equal (herdr-connection--host root) server))
                roots)))

(defun herdr-connection-register (connection)
  "Add CONNECTION to the registry and return it.
Replaces any connection of the same name in place, so that reconnecting
under a name a user already knows does not leave two of them."
  (let ((name (herdr-connection-name connection)))
    (if-let* ((cell (assoc name herdr-connections)))
        (setcdr cell connection)
      (setq herdr-connections
            (append herdr-connections (list (cons name connection))))))
  connection)

(defun herdr-connection-forget (connection)
  "Drop CONNECTION from the registry."
  (setq herdr-connections
        (seq-remove (lambda (cell) (eq (cdr cell) connection))
                    herdr-connections)))

;;; The resolver

(defvar herdr-connection--dispatching nil
  "The connection an asynchronous dispatch is running under.

The one place this package rebinds a connection dynamically, following
`eglot\\='s rebind at its own dispatch site.  A callback runs in an empty
extent, so a listener it reaches — a redraw, a reap — would otherwise
resolve whatever the user last looked at.  Nothing may read it except
`herdr-current-connection\\='.")

(defvar herdr-connection-chosen nil
  "The connection a picker just answered with, for this command only.

Outranks the buffer.  A pane chosen by hand on one server means that
server even when the command was typed in a terminal buffer belonging
to another: ambient context loses to an explicit answer.  Cleared from
`post-command-hook\=', so it never survives the command that set it.")

(defun herdr-connection-choose (connection)
  "Answer CONNECTION for the rest of this command, and return it."
  (setq herdr-connection-chosen connection)
  (add-hook 'post-command-hook #'herdr-connection--unchoose)
  connection)

(defun herdr-connection--unchoose ()
  "Forget the chosen connection once its command is over."
  (setq herdr-connection-chosen nil)
  (remove-hook 'post-command-hook #'herdr-connection--unchoose))

(defvar-local herdr-buffer-connection nil
  "The connection this buffer belongs to, when it belongs to one.
Set where the buffer is created: a terminal buffer knows its pane's
server for as long as it lives, and a command typed in it means that
server whatever else is on screen.")

(defvar herdr-connection-resolvers nil
  "Functions asked which connection an action started now belongs to.

An abnormal hook, run with no arguments in the current buffer until one
answers non-nil.  The dashboard adds one that reads the object at
point, which is the case a buffer-local cannot serve: one buffer, rows
from several servers.")

(defmacro herdr-connection-with-dispatch (connection &rest body)
  "Run BODY with CONNECTION as what `herdr-current-connection\\=' answers.
For the extent of an asynchronous dispatch and nothing else."
  (declare (indent 1) (debug t))
  `(let ((herdr-connection--dispatching ,connection))
     ,@body))

(defun herdr-connection--only ()
  "Return the connection a command with no other context means.

The sole one when there is one.  When there are several and nothing
said which, the first registered — the local server — because that is
what a command typed with no herdr buffer in sight most likely means.
Asking instead is what the pickers do once they can show a server
column.

Registers a local connection when there are none, so that the
single-server path needs no setup."
  (cond
   ((null herdr-connections)
    (herdr-connection-register (herdr-connection-local)))
   (t (cdar herdr-connections))))

(defun herdr-current-connection ()
  "Return the connection an action started now belongs to.

A function rather than a variable, because the transport must never
read an ambient default: a caller that wants a connection asks for one
here and hands it over.  Interactive commands arrive from
\\[execute-extended-command] and from keybindings with no connection in
hand, so they resolve here at the point of action.

Anything deferred must not.  A retry, a repair tick, a resubscribe, a
reconnect or an async reply captures its connection when it is scheduled
and carries it to the moment it fires; resolving late is how work
scheduled against one server lands on another.

Asked most specific first: an asynchronous dispatch says which
connection it is running under, a picker says which server the thing
just chosen is on, a buffer says which server it belongs to, a
registered resolver reads point, and failing all four the sole
connection answers."
  (or herdr-connection--dispatching
      herdr-connection-chosen
      herdr-buffer-connection
      (run-hook-with-args-until-success 'herdr-connection-resolvers)
      (herdr-connection--only)))

;;; The tunnel
;;
;; `make-network-process' has no file-handler support, so a remote
;; control socket cannot be reached the way a remote terminal can.  The
;; socket is forwarded to a local one instead and the transport is
;; unchanged: it connects to a unix socket either way.

(defcustom herdr-connection-socket-directory (format "/tmp/herdr-%s" (user-uid))
  "Directory holding the local end of each forwarded remote socket.

Under `/tmp\\=' rather than `temporary-file-directory\\=': macOS caps a
unix socket path at 104 bytes and its temporary directory spends about
half of that before the file name starts.  Per-uid, because /tmp is
shared."
  :type 'directory
  :group 'herdr)

(defcustom herdr-connection-tunnel-timeout 10.0
  "Seconds to wait for a forwarded socket to answer before giving up."
  :type 'number
  :group 'herdr)

(defcustom herdr-connection-tunnel-poll 0.5
  "Seconds between attempts to reach a forwarded socket while it comes up."
  :type 'number
  :group 'herdr)

(defun herdr-connection--socket-name (name)
  "Return the file name of the local socket for the connection called NAME.

Spelled out when it is short and plain, hashed when it is not.  The
whole path has to stay well inside 104 bytes, and a name is whatever a
user typed."
  (if (string-match-p "\\`[A-Za-z0-9._-]\\{1,24\\}\\'" name)
      (format "%s.sock" name)
    (format "%s.sock" (substring (secure-hash 'sha1 name) 0 16))))

(defun herdr-connection--local-socket-path (name)
  "Return the local socket path for the remote connection called NAME."
  (expand-file-name (herdr-connection--socket-name name)
                    herdr-connection-socket-directory))

(defun herdr-connection--tunnel-command (target local remote)
  "Return the argv forwarding TARGET\\='s REMOTE socket to LOCAL.

`-N\\=' because nothing is being run: the forward is the whole point.
`ExitOnForwardFailure\\=' is asked for anyway, though it catches nothing
here — OpenSSH binds a local unix socket at setup and only dials the
remote when something connects to it, so a forward to a socket that does
not exist starts exactly like one that does.  What it does catch is the
local bind failing.

TARGET is passed through untouched, so a bare host, a `user@host\\=' and
an alias from the user\\='s SSH config all work and none of them is
parsed here."
  (list "ssh" "-N"
        "-o" "ExitOnForwardFailure=yes"
        "-o" "BatchMode=yes"
        "-L" (format "%s:%s" local remote)
        target))

(defun herdr-connection--ask-remote (target)
  "Ask TARGET where its herdr is and which sockets its sessions listen on.

Returns (EXECUTABLE . SESSIONS).  One round trip, because each one is an
SSH handshake and this runs before a user has anything to look at.

Both answers have to come from the remote host.  The socket path must,
because the default contains a `~\=' and a macOS client expanding it
locally would forward to a `/Users/...\=' path on a Linux server.  The
executable must for a different reason: TRAMP runs remote commands under
its own `tramp-remote-path\=', not the login PATH, so a herdr installed
in `~/.local/bin\=' is on the PATH for `ssh host herdr\=' and not on the
one the terminal client would get.  An absolute path needs neither.

Asking at all doubles as the explicit check that herdr is installed
there — the one diagnosis the forward can never make, because OpenSSH
dials the path it is given without inspecting what is behind it.

Signals `herdr-error\=' with a code saying which part failed."
  (with-temp-buffer
    (let ((status (call-process
                   "ssh" nil t nil "-o" "BatchMode=yes" target
                   ;; Quoted here, because ssh joins its arguments into
                   ;; one string and the remote login shell re-parses
                   ;; it: an unquoted script loses its own `&&' to that
                   ;; shell and `sh -c' is handed only the first word.
                   "sh" "-c"
                   (shell-quote-argument
                    "command -v herdr && herdr session list --json"))))
      (unless (equal 0 status)
        (signal 'herdr-error
                (list "ssh_failed"
                      (format "%s: %s" target
                              (string-trim (buffer-string))))))
      (let* ((text (string-trim (buffer-string)))
             (newline (string-search "\n" text))
             (executable (and newline (string-trim (substring text 0 newline))))
             (json (and newline (substring text (1+ newline)))))
        (unless (and executable json)
          (signal 'herdr-error
                  (list "no_herdr"
                        (format "%s did not say where its herdr is" target))))
        (cons executable
              (alist-get 'sessions
                         (ignore-errors (herdr-rpc-decode json))))))))

(defun herdr-connection--session-socket (target sessions session)
  "Return the socket path SESSION listens on, from TARGET\='s SESSIONS."
  (let* ((wanted (or session "default"))
         (found (seq-find (lambda (entry) (equal wanted (alist-get 'name entry)))
                          sessions)))
    (unless found
      (signal 'herdr-error
              (list "no_such_session"
                    (format "%s has no herdr session called %s" target wanted))))
    (or (alist-get 'socket_path found)
        (signal 'herdr-error
                (list "no_socket"
                      (format "%s's session %s reports no socket"
                              target wanted))))))

(defun herdr-connection-executable (connection)
  "Return the herdr binary CONNECTION\='s commands should run.
The absolute path resolved on a remote host, and `herdr-executable\=' for
a local one."
  (or (herdr-connection-remote-executable connection) herdr-executable))

(defun herdr-connection--remove-stale-socket (path)
  "Delete PATH when it is a socket nothing is listening on.

An `ssh\\=' killed rather than stopped leaves its end of the forward
behind, and OpenSSH refuses to bind over it.  Deleting a socket that is
still live would break a working tunnel, so this connects first: a
refused connection is a dead file, an accepted one is left alone."
  (when (file-exists-p path)
    (let ((live (ignore-errors
                  (let ((proc (make-network-process
                               :name "herdr-stale-check" :family 'local
                               :service path :noquery t :nowait nil)))
                    (delete-process proc)
                    t))))
      (unless live (ignore-errors (delete-file path))))))

(defun herdr-connection--start-tunnel (connection)
  "Start CONNECTION\\='s SSH forward and return the process.

The sentinel routes a tunnel that dies into the same reconnect the event
streams use, so there is one retry mechanism rather than two."
  (let* ((local (herdr-connection-socket-path connection))
         (target (herdr-connection-ssh-target connection)))
    (make-directory herdr-connection-socket-directory t)
    (set-file-modes herdr-connection-socket-directory #o700)
    (herdr-connection--remove-stale-socket local)
    (let ((process
           (make-process
            :name (format "herdr-tunnel-%s" (herdr-connection-name connection))
            :command (herdr-connection--tunnel-command
                      target local
                      (herdr-connection-remote-socket-path connection))
            :connection-type 'pipe :noquery t
            :buffer (generate-new-buffer
                     (format " *herdr-tunnel-%s*"
                             (herdr-connection-name connection)))
            :sentinel
            ;; Captured, not resolved: this fires whenever ssh exits,
            ;; which is long after anything is looking at it.
            (lambda (process _event)
              (unless (process-live-p process)
                (herdr-connection--tunnel-died connection))))))
      (setf (herdr-connection-tunnel connection) process)
      process)))

(defun herdr-connection--tunnel-died (connection)
  "Note that CONNECTION\\='s tunnel exited, and retry if it is still wanted.
Wanted means the session is running: `herdr-disconnect\\=' stops it first,
so a deliberate teardown reaches here with nothing left to retry."
  (setf (herdr-connection-tunnel connection) nil)
  (when (and (fboundp 'herdr-state-running-p)
             (herdr-state-running-p connection)
             (fboundp 'herdr-state--schedule-reconnect))
    (herdr-state--schedule-reconnect connection)))

(defun herdr-connection--stop-tunnel (connection)
  "Kill CONNECTION\\='s tunnel and remove the local socket it bound."
  (when-let* ((process (herdr-connection-tunnel connection)))
    (setf (herdr-connection-tunnel connection) nil)
    (when (buffer-live-p (process-buffer process))
      (kill-buffer (process-buffer process)))
    (when (process-live-p process) (delete-process process)))
  (when (herdr-connection-remote-p connection)
    (ignore-errors (delete-file (herdr-connection-socket-path connection)))))

(defun herdr-connection--await-tunnel (connection)
  "Wait until CONNECTION answers a ping through its tunnel.

The socket appearing is necessary and not sufficient: OpenSSH binds the
local end at setup and only dials the remote when something connects, so
a forward to a path with no listener produces a socket that exists and
refuses every connection.  The handshake is the only evidence the whole
path works.

Three reportable states, and no more.  `ssh\\=' exiting is SSH\\='s own
failure and it has said why on stderr.  A socket that never answers is
a socket that never answered: through the forward, a missing herdr and a
wrong socket path are the same silence, which is why the path is
resolved on the remote host before any of this.  An answer that is not a
pong is a server that is not herdr."
  (let ((deadline (+ (float-time) herdr-connection-tunnel-timeout))
        (process (herdr-connection-tunnel connection)))
    (catch 'ready
      (while (< (float-time) deadline)
        (unless (process-live-p process)
          (signal 'herdr-error
                  (list "ssh_exited"
                        (format "ssh for %s exited: %s"
                                (herdr-connection-name connection)
                                (herdr-connection--tunnel-output connection)))))
        (when (file-exists-p (herdr-connection-socket-path connection))
          (let ((pong (ignore-errors
                        (let ((herdr-rpc-timeout 2.0))
                          (herdr-rpc-call connection "ping")))))
            (when pong
              (unless (alist-get 'protocol pong)
                (signal 'herdr-error
                        (list "not_herdr"
                              (format "%s answered, but not with a herdr pong"
                                      (herdr-connection-name connection)))))
              (throw 'ready pong))))
        ;; A refused channel comes back at once, so the wait is what
        ;; paces this: without it the loop asks ten times a second and
        ;; ssh answers each with a line of its own about the failure.
        (accept-process-output nil herdr-connection-tunnel-poll))
      (signal 'herdr-error
              (list "no_answer"
                    (format "%s: the forwarded socket did not answer in %ss"
                            (herdr-connection-name connection)
                            herdr-connection-tunnel-timeout))))))

(defun herdr-connection--tunnel-output (connection)
  "Return what CONNECTION\\='s ssh said, trimmed, or a note that it said nothing."
  (let ((buffer (and (herdr-connection-tunnel connection)
                     (process-buffer (herdr-connection-tunnel connection)))))
    (if (buffer-live-p buffer)
        (let ((text (string-trim (with-current-buffer buffer (buffer-string)))))
          (if (string-empty-p text) "no output on stderr" text))
      "no output on stderr")))

;;; Lifecycle

;;;###autoload
(defun herdr-connect (name socket-path)
  "Follow the herdr server whose socket is at SOCKET-PATH, calling it NAME.

Connects on request and then keeps the connection, retrying while it is
still wanted.  Nothing connects at startup: a laptop opened in a cafe
must not slow to a stack of timeouts for servers nobody asked about."
  (interactive
   (list (read-string "Connection name: ")
         (read-file-name "herdr socket: " "~/.config/herdr/")))
  (when (string-empty-p name)
    (user-error "herdr: a connection needs a name"))
  ;; Required here rather than at the top: herdr-state.el requires this
  ;; file for the resolver, so requiring it back would be a cycle.
  (require 'herdr-state)
  (let ((connection (herdr-connection-register
                     (herdr-connection--make
                      :name name :socket-path socket-path))))
    (herdr-state-start connection)
    (message "herdr: following %s" name)
    connection))

;;;###autoload
(defun herdr-disconnect (name)
  "Stop following the connection called NAME.

Deliberate, and therefore final: the retries stop with it.  A stream
that merely drops keeps being retried, because nobody said to stop."
  (interactive
   (list (completing-read "Disconnect: " (mapcar #'car herdr-connections)
                          nil t)))
  (require 'herdr-state)
  (let ((connection (or (herdr-connection-named name)
                        (user-error "herdr: no connection called %s" name))))
    (herdr-state-stop connection)
    ;; After the stop, which clears the running flag: the tunnel's own
    ;; sentinel reads it to decide whether a dead tunnel is worth
    ;; retrying, and a deliberate teardown is not.
    (herdr-connection--stop-tunnel connection)
    (herdr-connection-forget connection)
    (message "herdr: stopped following %s" name)))

(defun herdr-connection-remote (name target &optional session)
  "Return a connection to the herdr SESSION on TARGET, calling it NAME.

Resolves the remote socket before building anything, because that is
the one question the forward itself can never answer: OpenSSH dials the
path it is given without inspecting what is behind it, so a herdr that
is not installed and a socket path that is wrong fail the forward
identically.  Asking the remote binary separates them, and says which."
  (let* ((answer (herdr-connection--ask-remote target))
         (remote (herdr-connection--session-socket
                  target (cdr answer) session)))
    (herdr-connection--make
     :name name
     :ssh-target target
     :session session
     :remote-executable (car answer)
     :remote-socket-path remote
     :socket-path (herdr-connection--local-socket-path name))))

;;;###autoload
(defun herdr-connect-remote (name target &optional session)
  "Follow the herdr server on SSH TARGET, calling the connection NAME.

SESSION names one of that host\\='s herdr sessions; nil means its
default.  The connection is not reported up until a ping answers
through the forward: the local socket appearing proves only that
OpenSSH bound it, which it does before speaking to the far host at all.

Nothing is left in the registry when any of it fails.  A half-open
connection is worse than none: it would be retried forever against a
server nobody established was there."
  (interactive
   (list (read-string "Connection name: ")
         (read-string "SSH target: ")
         (let ((session (read-string
                         (format-prompt "herdr session" "default") nil nil "")))
           (unless (string-empty-p session) session))))
  (when (string-empty-p name)
    (user-error "herdr: a connection needs a name"))
  (require 'herdr-state)
  (let ((connection (herdr-connection-remote name target session))
        (established nil))
    (unwind-protect
        (progn
          (herdr-connection--start-tunnel connection)
          (herdr-connection--await-tunnel connection)
          (herdr-connection-register connection)
          (herdr-state-start connection)
          (setq established t)
          (message "herdr: following %s on %s" name target)
          connection)
      (unless established
        (herdr-connection--stop-tunnel connection)
        (herdr-connection-forget connection)))))

(provide 'herdr-connection)
;;; herdr-connection.el ends here
