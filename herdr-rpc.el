;;; herdr-rpc.el --- Socket transport for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Maintainer: Srijan Choudhary
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Transport for herdr's local socket API.
;;
;; Newline-delimited JSON over a unix domain socket, one request per
;; connection: the server writes a single response and closes.  Nothing
;; to multiplex and nothing to correlate.
;;
;; `events.subscribe' is the sole exception.  It holds the connection
;; open and streams; callers use `herdr-rpc-connect' and manage the
;; process themselves.  See `herdr-state'.

;;; Code:

(require 'subr-x)
(require 'cl-lib)

(defgroup herdr nil
  "Control the herdr terminal workspace manager."
  :group 'tools
  :prefix "herdr-")

(defun herdr-rpc--env (name)
  "Return environment variable NAME, or nil when it is unset or empty.
An exported-but-empty variable is the same fact as an unset one, and
`getenv\\=' tells them apart where nothing here wants to.  An empty
string is non-nil, so an empty HERDR_SOCKET_PATH fell straight through
`or\\=' and became a socket path with nothing in it."
  (let ((value (getenv name)))
    (unless (or (null value) (string-empty-p value)) value)))

(defconst herdr-self-socket-path (herdr-rpc--env "HERDR_SOCKET_PATH")
  "Socket of the server whose pane this Emacs is running inside, or nil.
herdr exports it into every pane it starts, along with `HERDR_ENV\\=',
`HERDR_PANE_ID\\=', `HERDR_TAB_ID\\=' and `HERDR_WORKSPACE_ID\\='.")

(defconst herdr-self-pane-id (herdr-rpc--env "HERDR_PANE_ID")
  "The herdr pane this Emacs is running inside, or nil.

Set for an Emacs started from a herdr pane and absent for one started
any other way, which is why everything reading it degrades to doing
nothing rather than to guessing.  Meaningful only against the server at
`herdr-self-socket-path\\=': ids are per-server counters, so this names a
pane on that server and some unrelated pane on every other.")

(defcustom herdr-socket-path (or herdr-self-socket-path
                                 "~/.config/herdr/herdr.sock")
  "Path to the herdr server's unix domain socket.

Defaults to the socket of the session this Emacs was started from when
there is one.  The literal path is the default session\\='s, so an Emacs
started inside a `herdr --session work\\=' pane used to talk to the
default session instead of the one around it - a server that may not be
running, and that holds none of the panes on screen."
  :type 'file
  :group 'herdr)

(defcustom herdr-executable "herdr"
  "Name of, or path to, the herdr executable."
  :type 'string
  :group 'herdr)

(defcustom herdr-rpc-timeout 10.0
  "Seconds to wait for a synchronous RPC response."
  :type 'number
  :group 'herdr)

(defcustom herdr-rpc-background-timeout 2.0
  "Seconds a background RPC gets before it forfeits its answer.
Asynchronous callers pass it as their deadline; the few synchronous
ones a timer or a keystroke can reach bind `herdr-rpc-timeout\\=' down to
it.  A server too slow to answer forfeits that refresh, not the UI."
  :type 'number
  :group 'herdr)

(define-error 'herdr-error "herdr error")

;;; The connection
;;
;; A connection is a value the package passes around, the shape
;; `jsonrpc.el' and `eglot.el' settled on: the transport takes it as an
;; argument and never reads an ambient default.

(defvar herdr-connection--tokens 0
  "Counter behind `herdr-connection-token'.")

(cl-defstruct (herdr-connection (:constructor herdr-connection--make)
                                (:copier nil))
  "One herdr server this package follows.

TOKEN is allocated once and never written again.  The struct is mutable
and `equal' on a struct compares fields, so a key holding the struct
itself would stop matching the moment a process or a cache slot changed
under it; a composite key holds the token instead."
  (token (cl-incf herdr-connection--tokens))
  name
  socket-path
  ssh-target
  ;; The path on the far host that SOCKET-PATH forwards to, and the
  ;; named session it belongs to.  Resolved on that host, never by
  ;; expanding a local default.
  remote-socket-path
  session
  ;; The herdr binary on that host, resolved there.  Nil means the
  ;; local `herdr-executable'.
  remote-executable
  ;; The opaque id of the saved machine this came from, when it came
  ;; from one.  Kept because a profile's label is what a user renames
  ;; and its id is what herdr keeps: a renamed profile has to be
  ;; recognised as the connection already being followed, not as a new
  ;; one under a new name.
  machine-id
  tunnel
  ;; Session cache and its two event streams, per KTD6.
  (cache nil) (global-process nil) (pane-process nil) (pane-stream-ids nil)
  (reconnect-timer nil) (reconnect-delay nil) (resubscribe-timer nil)
  (settle-timer nil) (repair-timer nil) (repairing nil)
  (generation 0) (running nil)
  ;; Worktree cache, reached only through its interface.
  (worktrees nil) (worktrees-pending nil) (worktrees-unanswered nil)
  (worktrees-generation 0)
  ;; Handshake and schema, one answer per server rather than per package.
  (protocol-warned nil) (schema nil) (schema-version nil)
  (schema-mismatch-warned nil))

(defun herdr-connection-local ()
  "Return a connection to the local server at `herdr-socket-path'."
  (herdr-connection--make :name "local" :socket-path herdr-socket-path))

(defun herdr-connection-remote-p (connection)
  "Return non-nil when CONNECTION reaches its server over SSH."
  (and (herdr-connection-ssh-target connection) t))

(defun herdr-self-pane-p (connection pane-id)
  "Return non-nil when PANE-ID on CONNECTION is the pane hosting this Emacs.

Both halves are required.  A bare id match is not enough: ids are
per-server counters, so the `w1:p1\\=' this Emacs sits in and the `w1:p1\\='
on a machine it follows are different panes with the same name.  The
socket is what tells the two servers apart, and a remote connection
reaches its server through a forward bound somewhere else entirely, so
it can never be the one that started us."
  (and herdr-self-pane-id
       herdr-self-socket-path
       (equal pane-id herdr-self-pane-id)
       (not (herdr-connection-remote-p connection))
       (equal (expand-file-name (herdr-connection-socket-path connection))
              (expand-file-name herdr-self-socket-path))))

(defun herdr-connection-host-directory (connection)
  "Return a `default-directory\\=' for running herdr on CONNECTION\\='s host.
A TRAMP path for a remote server, so that `make-process\\=' with
`:file-handler\\=' runs the binary that belongs to that server rather
than the local one.  Nil for a local server, meaning leave
`default-directory\\=' alone."
  (when-let* ((target (herdr-connection-ssh-target connection)))
    (format "/ssh:%s:" target)))

(defun herdr-error-code (err)
  "Return the herdr error code carried by ERR, as a string."
  (nth 1 err))

(defun herdr-error-message (err)
  "Return the human-readable message carried by ERR."
  (nth 2 err))

(defun herdr-rpc--signal (code message)
  "Signal a `herdr-error' with CODE and MESSAGE."
  (signal 'herdr-error (list code message)))

(defvar herdr-rpc--id 0
  "Counter behind `herdr-rpc--next-id'.")

(defun herdr-rpc--next-id ()
  "Return a fresh request id."
  (format "emacs-%d" (cl-incf herdr-rpc--id)))

(defun herdr-rpc--params-object (params)
  "Convert PARAMS, an alist, into a hash table suitable for serializing.
Nil values are dropped rather than sent as null, which several optional
parameters reject; pass `:false' to mean false.  A hash table, so empty
params serialize as {} rather than null."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (cell params)
      (when (cdr cell)
        (puthash (symbol-name (car cell)) (cdr cell) table)))
    table))

(defun herdr-rpc-encode (id method params)
  "Encode a request with ID, METHOD and PARAMS as one NDJSON line."
  (concat (json-serialize
           `((id . ,id)
             (method . ,method)
             (params . ,(herdr-rpc--params-object params))))
          "\n"))

(defun herdr-rpc-decode (line)
  "Parse LINE into an alist, the way herdr's payloads are shaped."
  (json-parse-string line
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun herdr-rpc-connect (connection name filter sentinel)
  "Open a socket to CONNECTION\\='s server, as a process named NAME.
FILTER and SENTINEL are installed on the process.  Signals `herdr-error'
with code \"no_server\" when the socket is absent or refuses.

CONNECTION comes first so a caller that forgets it gets a wrong-type
error rather than a call against whichever server was ambient."
  (let ((path (expand-file-name (herdr-connection-socket-path connection))))
    (condition-case err
        (make-network-process
         :name name :family 'local :service path
         :coding 'utf-8-unix :noquery t
         :filter filter :sentinel sentinel)
      (file-error
       (herdr-rpc--signal
        "no_server"
        (format "cannot reach herdr socket %s: %s"
                path (error-message-string err)))))))

(defun herdr-rpc--result (payload)
  "Return the result in PAYLOAD, or signal the error it carries."
  (let ((err (alist-get 'error payload)))
    (if err
        (herdr-rpc--signal (alist-get 'code err) (alist-get 'message err))
      (alist-get 'result payload))))

(defun herdr-rpc-call (connection method &optional params)
  "Call METHOD with PARAMS on CONNECTION and return its result alist.
Signals `herdr-error' on a server error, an unreachable socket, or a
timeout."
  (let* ((chunks nil)
         (closed nil)
         (proc (herdr-rpc-connect
                connection
                (format "herdr-rpc-%s" method)
                (lambda (_proc chunk) (push chunk chunks))
                (lambda (_proc _event) (setq closed t)))))
    (unwind-protect
        (progn
          (process-send-string proc (herdr-rpc-encode (herdr-rpc--next-id)
                                                      method params))
          ;; A full line is the completion signal.  The EOF the server
          ;; sends after responding is only a fallback: waiting on EOF
          ;; alone livelocks when close sentinels are starved under
          ;; nested timer handlers.
          (let ((deadline (+ (float-time) herdr-rpc-timeout)))
            (while (and (not closed)
                        (not (and chunks (string-search "\n" (car chunks))))
                        (< (float-time) deadline))
              (accept-process-output proc 0.05)))
          (let ((text (apply #'concat (nreverse chunks))))
            (when (string-empty-p (string-trim text))
              (herdr-rpc--signal
               (if closed "empty_response" "timeout")
               (format "no response from herdr for %s" method)))
            (herdr-rpc--result
             (herdr-rpc-decode (car (split-string text "\n" t))))))
      (when (process-live-p proc)
        (delete-process proc)))))

(defun herdr-rpc-call-async (connection method params callback &optional timeout)
  "Call METHOD with PARAMS on CONNECTION, invoking CALLBACK on the response.
CALLBACK receives (RESULT ERROR), exactly one of them non-nil, and is
called exactly once.  Returns the process, which may be deleted to
abandon the call.  Nil TIMEOUT waits indefinitely.

Every path fires CALLBACK through the same `fired' guard, including a
`process-send-string' failure.  Letting that one escape as a signal
instead leaves an armed TIMEOUT free to deliver a second callback."
  (let* ((chunks nil)
         (fired nil)
         (timer nil)
         (fire
          (lambda (result error)
            (unless fired
              (setq fired t)
              (when timer
                (cancel-timer timer)
                (setq timer nil))
              (funcall callback result error))))
         (finish
          (lambda ()
            (let ((text (apply #'concat (nreverse chunks))))
              (condition-case err
                  (let* ((payload (herdr-rpc-decode
                                   (car (split-string text "\n" t))))
                         (server-error (alist-get 'error payload)))
                    (if server-error
                        (funcall fire nil server-error)
                      (funcall fire (alist-get 'result payload) nil)))
                (error
                 (funcall fire nil
                          `((code . "bad_response")
                            (message . ,(error-message-string err))))))))))
    (let ((proc (herdr-rpc-connect
                 connection
                 (format "herdr-rpc-async-%s" method)
                 (lambda (_proc chunk) (push chunk chunks))
                 (lambda (_proc _event) (funcall finish)))))
      (when timeout
        (setq timer
              (run-at-time
               timeout nil
               (lambda ()
                 (setq timer nil)
                 (funcall fire nil
                          `((code . "timeout")
                            (message . ,(format "no response from herdr for %s within %ss"
                                                method timeout))))
                 (when (process-live-p proc)
                   (delete-process proc))))))
      (condition-case err
          (process-send-string proc (herdr-rpc-encode (herdr-rpc--next-id)
                                                      method params))
        (error
         (funcall fire nil
                  `((code . "send_failed")
                    (message . ,(error-message-string err))))
         (when (process-live-p proc)
           (delete-process proc))))
      proc)))

(provide 'herdr-rpc)
;;; herdr-rpc.el ends here
