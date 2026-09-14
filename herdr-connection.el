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
(require 'herdr-rpc)

(declare-function herdr-state-stop "herdr-state" (connection))
(declare-function herdr-state-start "herdr-state" (connection))
(declare-function herdr-state-running-p "herdr-state" (connection))

;;; The registry

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
connection it is running under, a buffer says which server it belongs
to, a registered resolver reads point, and failing all three the sole
connection answers."
  (or herdr-connection--dispatching
      herdr-buffer-connection
      (run-hook-with-args-until-success 'herdr-connection-resolvers)
      (herdr-connection--only)))

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
    (herdr-connection-forget connection)
    (message "herdr: stopped following %s" name)))

(provide 'herdr-connection)
;;; herdr-connection.el ends here
