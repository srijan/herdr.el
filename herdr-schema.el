;;; herdr-schema.el --- Runtime API schema for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; herdr ships a complete JSON Schema for its socket API, loaded at
;; runtime rather than generated from.
;;
;; It buys `herdr-call' every method without a hand-written wrapper, and
;; it buys the drift test: a herdr upgrade that renames a method the
;; curated commands use surfaces as a failing test, not a runtime error.
;;
;; Held for the session, invalidated by server version.  No disk cache:
;; `herdr api schema --json' prints the schema bundled in the binary
;; without consulting the server, measured at 7ms.
;;
;; That last point is also this module's one sharp edge.  There is no
;; socket method for the schema, so it can only come from the local
;; binary, and a binary that is a different build from the running
;; server describes an API nobody is talking to.  Upgrading herdr
;; without restarting the server is the ordinary way in: the package
;; manager replaces the file, the running process keeps its loaded
;; image.  `herdr-schema-matches-server-p' is how to ask, and the
;; mismatch is said once rather than hidden.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'herdr-rpc)

(defvar herdr-schema--cache nil
  "Parsed schema, or nil when not yet loaded.")

(defvar herdr-schema--cache-version nil
  "Server version the cached schema was fetched alongside.

Not the schema's own provenance.  The schema comes from the local
binary and this is what the socket answered at the time, so the two
agree only when the binary and the server are the same build.  It is
kept because it is the cheap change detector: a `herdr update\=' that
replaces both shows up here as a different string.  See
`herdr-schema--cache-protocol\=' for what the schema actually describes.")

(defvar herdr-schema--cache-protocol nil
  "Protocol the cached schema declares, from the schema itself.")

(defvar herdr-schema--mismatch-warned nil)

;;; Loading

(defun herdr-schema-load-file (path)
  "Load and cache the schema stored at PATH.
Used by the tests to stand a captured schema up without a herdr on
`exec-path'."
  (setq herdr-schema--cache
        (with-temp-buffer
          (insert-file-contents path)
          (herdr-rpc-decode (buffer-string))))
  herdr-schema--cache)

(defun herdr-schema--fetch ()
  "Shell out to herdr for a fresh schema, bounded by `herdr-rpc-timeout'.

Not `call-process': that blocks with no way to bound it — timers do not
run while it waits — so a herdr binary that started but never exited
froze Emacs indefinitely, reachable from the interactive escape hatch
right after `herdr update', which is exactly when the binary may be
mid-restart and slow to answer.  A process plus a deadline mirrors the
bounded wait every socket RPC already uses."
  (with-temp-buffer
    (let ((proc (condition-case err
                    (make-process
                     :name "herdr-schema" :buffer (current-buffer)
                     :command (list herdr-executable "api" "schema" "--json")
                     :connection-type 'pipe :noquery t
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
                                    herdr-executable herdr-rpc-timeout))))
            ;; The exit can beat its last output; drain what came with it.
            (while (accept-process-output proc 0.01))
            (unless (zerop (process-exit-status proc))
              (signal 'herdr-error
                      (list "schema_unavailable"
                            (format "%s api schema --json exited %s"
                                    herdr-executable
                                    (process-exit-status proc)))))
            (setq herdr-schema--cache (herdr-rpc-decode (buffer-string))))
        (when (process-live-p proc)
          (delete-process proc))))))

(defun herdr-schema--server-version ()
  "Return the running server's version string, or nil if unreachable."
  (ignore-errors (alist-get 'version (herdr-rpc-call "ping"))))

(defun herdr-schema--server-protocol ()
  "Return the running server's protocol number, or nil if unreachable."
  (ignore-errors (alist-get 'protocol (herdr-rpc-call "ping"))))

(defun herdr-schema-protocol ()
  "Return the protocol the loaded schema declares.
This is the binary's answer, not the server's."
  (alist-get 'protocol (or herdr-schema--cache (herdr-schema))))

(defun herdr-schema-matches-server-p ()
  "Return non-nil when the loaded schema describes the running server.

There is no socket method for the schema, so it can only come from the
local `herdr\=' binary.  When that binary is a different build from the
running server the schema describes an API nobody is talking to, and
every check made against it answers the wrong question.

An unreachable server is not a mismatch.  `herdr-call\=' reads the
schema with no server running, and reporting that as a disagreement
would warn on every one of those."
  (let ((server (herdr-schema--server-protocol))
        (schema (herdr-schema-protocol)))
    (or (null server) (null schema) (equal server schema))))

(defun herdr-schema--warn-on-mismatch ()
  "Say once when the schema and the server describe different APIs."
  (unless (or herdr-schema--mismatch-warned (herdr-schema-matches-server-p))
    (setq herdr-schema--mismatch-warned t)
    (message
     "herdr.el: %s speaks protocol %s but the running server speaks %s; \
schema-driven prompts and drift checks describe the binary, not the server"
     herdr-executable (herdr-schema-protocol) (herdr-schema--server-protocol))))

(defun herdr-schema ()
  "Return the herdr API schema, fetching it if needed.
The schema is held for as long as the server reports the version it
was captured from: `herdr update' mid-session drops it, so the drift
test cannot check yesterday's schema and report no drift."
  (let ((version (herdr-schema--server-version)))
    (when (and herdr-schema--cache
               herdr-schema--cache-version
               version
               (not (equal version herdr-schema--cache-version)))
      (setq herdr-schema--cache nil)
      (setq herdr-schema--mismatch-warned nil))
    (unless herdr-schema--cache
      (herdr-schema--fetch)
      (setq herdr-schema--cache-version version)
      (setq herdr-schema--cache-protocol
            (alist-get 'protocol herdr-schema--cache))))
  (herdr-schema--warn-on-mismatch)
  herdr-schema--cache)

;;; Navigation

(defun herdr-schema--request ()
  "Return the request sub-schema."
  (alist-get 'request (alist-get 'schemas (or herdr-schema--cache
                                              (herdr-schema)))))

(defun herdr-schema--defs ()
  "Return the request schema's definitions table."
  (alist-get '$defs (herdr-schema--request)))

(defun herdr-schema-resolve (node)
  "Resolve NODE if it is a $ref or a nullable anyOf wrapper.
Returns NODE unchanged when there is nothing to resolve."
  (cond
   ((null node) nil)
   ((alist-get '$ref node)
    (let* ((ref (alist-get '$ref node))
           (name (car (last (split-string ref "/")))))
      (alist-get (intern name) (herdr-schema--defs))))
   ((alist-get 'anyOf node)
    ;; Nullable parameters are expressed as anyOf [<real thing>, null].
    (let ((real (seq-find (lambda (branch)
                            (not (equal (alist-get 'type branch) "null")))
                          (alist-get 'anyOf node))))
      (if real (herdr-schema-resolve real) node)))
   (t node)))

(defun herdr-schema--entry (method)
  "Return the oneOf entry describing METHOD, or nil."
  (seq-find (lambda (entry)
              (equal method
                     (alist-get 'const
                                (alist-get 'method
                                           (alist-get 'properties entry)))))
            (alist-get 'oneOf (herdr-schema--request))))

(defun herdr-schema-methods ()
  "Return every method name the server declares, as strings."
  (mapcar (lambda (entry)
            (alist-get 'const
                       (alist-get 'method (alist-get 'properties entry))))
          (alist-get 'oneOf (herdr-schema--request))))

(defun herdr-schema--params-def (method)
  "Return the resolved params definition for METHOD."
  (when-let* ((entry (herdr-schema--entry method))
              (params (alist-get 'params (alist-get 'properties entry))))
    (herdr-schema-resolve params)))

(defun herdr-schema-params (method)
  "Return METHOD's parameters as an alist of (NAME . SCHEMA).
NAME is a string.  SCHEMA is unresolved; use `herdr-schema-resolve'."
  (mapcar (lambda (cell) (cons (symbol-name (car cell)) (cdr cell)))
          (alist-get 'properties (herdr-schema--params-def method))))

(defun herdr-schema-required (method)
  "Return METHOD's required parameter names, as strings."
  (alist-get 'required (herdr-schema--params-def method)))

(defun herdr-schema-param (method name)
  "Return the resolved schema for METHOD's parameter NAME."
  (herdr-schema-resolve
   (cdr (assoc name (herdr-schema-params method)))))

(defun herdr-schema-enum (method name)
  "Return the permitted values for METHOD's parameter NAME, or nil."
  (alist-get 'enum (herdr-schema-param method name)))

(defun herdr-schema-param-type (method name)
  "Return a symbol describing the type of METHOD's parameter NAME.
One of `enum', `string', `boolean', `integer', `number', `object',
`array', or nil when the parameter is unknown."
  (let* ((schema (herdr-schema-param method name))
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
  (pcase type
    ("string" 'string)
    ("boolean" 'boolean)
    ("integer" 'integer)
    ("number" 'number)
    ("object" 'object)
    ("array" 'array)
    (_ nil)))

;;; Prompting

(defun herdr-schema-read-param (method name)
  "Prompt for METHOD's parameter NAME according to its declared type.
Returns a value ready to hand to `herdr-rpc-call', or nil to omit it."
  (let* ((required (member name (herdr-schema-required method)))
         (prompt (format "%s%s: " name (if required "" " (optional)"))))
    (pcase (herdr-schema-param-type method name)
      ('enum
       (let ((choice (completing-read prompt (herdr-schema-enum method name)
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
       ;; `herdr-rpc-decode' gives a list, which an array-typed
       ;; parameter cannot be: it must go through `herdr-rpc-array' or
       ;; `json-serialize' fails before the request goes out.
       (let ((raw (read-string (format "%s (JSON): " name))))
         (if (string-empty-p raw) nil
           (herdr-rpc-array (herdr-rpc-decode raw)))))
      (_
       (let ((raw (read-string prompt)))
         (if (string-empty-p raw) nil raw))))))

(provide 'herdr-schema)
;;; herdr-schema.el ends here
