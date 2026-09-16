;;; herdr-schema.el --- Runtime API schema for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Maintainer: Srijan Choudhary
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; herdr ships a complete JSON Schema for its socket API, loaded at
;; runtime rather than generated from.
;;
;; It buys `herdr-call' every method without a hand-written wrapper, and
;; it buys the drift test: a herdr upgrade that renames a method the
;; curated commands use surfaces as a failing test, not a runtime error.
;;
;; Held per connection, invalidated by server version.  No disk cache:
;; `herdr api schema --json' prints the schema bundled in the binary
;; without consulting the server, measured at 7ms.
;;
;; That last point is also this module's one sharp edge.  There is no
;; socket method for the schema, so it can only come from a binary, and
;; a binary that is a different build from the running server describes
;; an API nobody is talking to.  Upgrading herdr without restarting the
;; server is the ordinary way in: the package manager replaces the
;; file, the running process keeps its loaded image.
;; `herdr-schema-matches-server-p' is how to ask, and the mismatch is
;; said once per connection rather than hidden.
;;
;; A remote server's binary is on the remote host, which is why the
;; cache belongs to the connection and the fetch runs under its
;; `default-directory' rather than the local one.

;;; Code:

(require 'subr-x)
(require 'herdr-rpc)
(require 'herdr-connection)

(defun herdr-schema--fetch (connection)
  "Shell out to herdr for CONNECTION's schema, bounded by `herdr-rpc-timeout'.

Run on the connection's own host: a remote server's schema cannot come
from the local binary at all, so `default-directory' is the host's and
`:file-handler' is what lets `make-process' follow it.  The socket the
control plane uses is forwarded; this is not, because a schema is a
question for the machine the server runs on.

Not `call-process': that blocks with no way to bound it — timers do not
run while it waits — so a herdr binary that started but never exited
froze Emacs indefinitely, reachable from the interactive escape hatch
right after `herdr update', which is exactly when the binary may be
mid-restart and slow to answer.  A process plus a deadline mirrors the
bounded wait every socket RPC already uses."
  (with-temp-buffer
    (let* ((default-directory (or (herdr-connection-host-directory connection)
                                  default-directory))
           (executable (herdr-connection-executable connection))
           (proc (condition-case err
                     (make-process
                      :name "herdr-schema" :buffer (current-buffer)
                      :command (list executable "api" "schema" "--json")
                      :connection-type 'pipe :noquery t
                      :file-handler t
                      :sentinel #'ignore)
                   (error
                    (signal 'herdr-error
                            (list "schema_unavailable"
                                  (error-message-string err)))))))
      (unwind-protect
          (progn
            (let ((deadline (+ (float-time) herdr-rpc-timeout)))
              (while (and (process-live-p proc) (< (float-time) deadline))
                (accept-process-output proc 0.05)))
            (when (process-live-p proc)
              (signal 'herdr-error
                      (list "schema_unavailable"
                            (format "%s api schema --json gave no answer in %ss"
                                    executable herdr-rpc-timeout))))
            ;; The exit can beat its last output; drain what came with it.
            (while (accept-process-output proc 0.01))
            (unless (zerop (process-exit-status proc))
              (signal 'herdr-error
                      (list "schema_unavailable"
                            (format "%s api schema --json exited %s"
                                    executable
                                    (process-exit-status proc)))))
            (setf (herdr-connection-schema connection)
                  (herdr-rpc-decode (buffer-string))))
        (when (process-live-p proc)
          (delete-process proc))))))

(defun herdr-schema--pong (connection)
  "Return CONNECTION\\='s answer to a ping, or nil if unreachable."
  (ignore-errors (herdr-rpc-call connection "ping")))

(defun herdr-schema-protocol (connection)
  "Return the protocol CONNECTION\\='s loaded schema declares.
This is the binary's answer, not the server's."
  (alist-get 'protocol (or (herdr-connection-schema connection)
                           (herdr-schema connection))))

(defun herdr-schema-matches-server-p (connection &optional pong)
  "Return non-nil when the loaded schema describes CONNECTION\\='s server.
PONG is the server\\='s ping answer, asked for when not given.

There is no socket method for the schema, so it can only come from a
`herdr' binary.  When that binary is a different build from the running
server the schema describes an API nobody is talking to, and every check
made against it answers the wrong question.

An unreachable server is not a mismatch.  `herdr-call' reads the
schema with no server running, and reporting that as a disagreement
would warn on every one of those."
  (let ((server (alist-get 'protocol (or pong (herdr-schema--pong connection))))
        (schema (herdr-schema-protocol connection)))
    (or (null server) (null schema) (equal server schema))))

(defun herdr-schema--warn-on-mismatch (connection pong)
  "Say once when the schema and CONNECTION\\='s ping answer PONG disagree.
A nil PONG is an unreachable server, which is not a disagreement."
  (unless (or (herdr-connection-schema-mismatch-warned connection)
              (null pong)
              (herdr-schema-matches-server-p connection pong))
    (setf (herdr-connection-schema-mismatch-warned connection) t)
    (message
     "herdr.el: %s's %s speaks protocol %s but its server speaks %s; \
schema-driven prompts and drift checks describe the binary, not the server"
     (herdr-connection-name connection)
     (herdr-connection-executable connection)
     (herdr-schema-protocol connection)
     (alist-get 'protocol pong))))

(defun herdr-schema (connection)
  "Return CONNECTION\\='s API schema, fetching it if needed.
The schema is held for as long as the server reports the version it
was captured from: `herdr update' mid-session drops it, so the drift
test cannot check yesterday's schema and report no drift.

Per connection, not per package: two servers have two binaries and two
schemas, and one cache cannot hold both."
  (let* ((pong (herdr-schema--pong connection))
         (version (alist-get 'version pong)))
    (when (and (herdr-connection-schema connection)
               (herdr-connection-schema-version connection)
               version
               (not (equal version
                           (herdr-connection-schema-version connection))))
      (setf (herdr-connection-schema connection) nil)
      (setf (herdr-connection-schema-mismatch-warned connection) nil))
    (unless (herdr-connection-schema connection)
      (herdr-schema--fetch connection)
      (setf (herdr-connection-schema-version connection) version))
    (herdr-schema--warn-on-mismatch connection pong))
  (herdr-connection-schema connection))

;;; Navigation

(defun herdr-schema--request (connection)
  "Return CONNECTION's request sub-schema."
  (alist-get 'request
             (alist-get 'schemas (or (herdr-connection-schema connection)
                                     (herdr-schema connection)))))

(defun herdr-schema--defs (connection)
  "Return CONNECTION's request schema definitions table."
  (alist-get '$defs (herdr-schema--request connection)))

(defun herdr-schema-resolve (connection node)
  "Resolve NODE against CONNECTION's schema if it is a $ref or anyOf wrapper.
Returns NODE unchanged when there is nothing to resolve."
  (cond
   ((null node) nil)
   ((alist-get '$ref node)
    (let* ((ref (alist-get '$ref node))
           (name (car (last (split-string ref "/")))))
      (alist-get (intern name) (herdr-schema--defs connection))))
   ((alist-get 'anyOf node)
    ;; Nullable parameters are expressed as anyOf [<real thing>, null].
    (let ((real (seq-find (lambda (branch)
                            (not (equal (alist-get 'type branch) "null")))
                          (alist-get 'anyOf node))))
      (if real (herdr-schema-resolve connection real) node)))
   (t node)))

(defun herdr-schema--entry (connection method)
  "Return the oneOf entry describing METHOD, or nil."
  (seq-find (lambda (entry)
              (equal method
                     (alist-get 'const
                                (alist-get 'method
                                           (alist-get 'properties entry)))))
            (alist-get 'oneOf (herdr-schema--request connection))))

(defun herdr-schema-methods (connection)
  "Return every method CONNECTION's server declares, as strings."
  (mapcar (lambda (entry)
            (alist-get 'const
                       (alist-get 'method (alist-get 'properties entry))))
          (alist-get 'oneOf (herdr-schema--request connection))))

(defun herdr-schema--params-def (connection method)
  "Return the resolved params definition for METHOD."
  (when-let* ((entry (herdr-schema--entry connection method))
              (params (alist-get 'params (alist-get 'properties entry))))
    (herdr-schema-resolve connection params)))

(defun herdr-schema-params (connection method)
  "Return METHOD's parameters as an alist of (NAME . SCHEMA).
NAME is a string.  SCHEMA is unresolved; use `herdr-schema-resolve'."
  (mapcar (lambda (cell) (cons (symbol-name (car cell)) (cdr cell)))
          (alist-get 'properties (herdr-schema--params-def connection method))))

(defun herdr-schema-required (connection method)
  "Return METHOD's required parameter names, as strings."
  (alist-get 'required (herdr-schema--params-def connection method)))

(defun herdr-schema-param (connection method name)
  "Return the resolved schema for METHOD's parameter NAME."
  (herdr-schema-resolve
   connection (cdr (assoc name (herdr-schema-params connection method)))))

(defun herdr-schema-enum (connection method name)
  "Return the permitted values for METHOD's parameter NAME, or nil."
  (alist-get 'enum (herdr-schema-param connection method name)))

(defun herdr-schema-param-type (connection method name)
  "Return a symbol describing the type of METHOD's parameter NAME.
One of `enum', `string', `boolean', `integer', `number', `object',
`array', or nil when the parameter is unknown."
  (let* ((schema (herdr-schema-param connection method name))
         (type (alist-get 'type schema)))
    (cond
     ((null schema) nil)
     ((alist-get 'enum schema) 'enum)
     ;; Nullable scalars arrive as ("integer" "null").
     ((consp type)
      (herdr-schema--type-symbol
       (seq-find (lambda (candidate) (not (equal candidate "null"))) type)))
     (t (herdr-schema--type-symbol type)))))

(defun herdr-schema--type-symbol (type)
  "Map JSON Schema TYPE to a symbol this package uses."
  (and (member type '("string" "boolean" "integer" "number" "object" "array"))
       (intern type)))

;;; Prompting

(defun herdr-schema-read-param (connection method name)
  "Prompt for METHOD's parameter NAME according to its declared type.
Returns a value ready to hand to `herdr-rpc-call', or nil to omit it."
  (let* ((required (member name (herdr-schema-required connection method)))
         (prompt (format "%s%s: " name (if required "" " (optional)"))))
    (pcase (herdr-schema-param-type connection method name)
      ('enum
       (let ((choice (completing-read
                      prompt (herdr-schema-enum connection method name)
                      nil t)))
         (if (string-empty-p choice) nil choice)))
      ('boolean
       (if (y-or-n-p (format "%s? " name)) t :false))
      ((or 'integer 'number)
       (let ((raw (read-string prompt)))
         (if (string-empty-p raw) nil (string-to-number raw))))
      ('object
       (let ((raw (read-string (format "%s (JSON): " name))))
         (if (string-empty-p raw) nil (herdr-rpc-decode raw))))
      ('array
       ;; `herdr-rpc-decode' gives a list; `json-serialize' needs a
       ;; vector to tell an array from an alist.
       (let ((raw (read-string (format "%s (JSON): " name))))
         (if (string-empty-p raw) nil
           (vconcat (herdr-rpc-decode raw)))))
      (_
       (let ((raw (read-string prompt)))
         (if (string-empty-p raw) nil raw))))))

(provide 'herdr-schema)
;;; herdr-schema.el ends here
