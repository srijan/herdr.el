;;; herdr-schema.el --- Runtime API schema for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; herdr ships a complete JSON Schema for its socket API, which this
;; package loads at runtime rather than generating code from.
;;
;; That buys two things.  `herdr-call' can offer every method the server
;; knows about, prompting for each parameter according to its declared
;; type, without anyone hand-writing 89 wrappers.  And the drift test can
;; assert that the wrappers we *did* hand-write still name methods and
;; parameters the server recognises, so a herdr upgrade surfaces as a
;; failing test instead of a runtime error.
;;
;; The schema is held for the session and invalidated by server version.
;; There is no disk cache: `herdr api schema --json' prints the schema
;; bundled in the binary without consulting the server, measured at 7ms,
;; and nothing calls in here until you run `herdr-call' by hand.  A cache
;; saving that is a 250K file and a staleness question for no gain.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'herdr-rpc)

(defvar herdr-schema--cache nil
  "Parsed schema, or nil when not yet loaded.")

(defvar herdr-schema--cache-version nil
  "herdr version the cached schema came from.")

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
      (setq herdr-schema--cache nil))
    (unless herdr-schema--cache
      (herdr-schema--fetch)
      (setq herdr-schema--cache-version version)))
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
       ;; `herdr-rpc-decode' parses a JSON array as a Lisp list — right
       ;; for the alists nested inside an object parameter, wrong here:
       ;; `herdr-rpc-array' is what turns a list into the vector
       ;; `json-serialize' requires for an array-typed parameter, and
       ;; skipping it made every array parameter (`agent.send_keys'
       ;; `keys', for instance) fail encoding before any request went
       ;; out.
       (let ((raw (read-string (format "%s (JSON): " name))))
         (if (string-empty-p raw) nil
           (herdr-rpc-array (herdr-rpc-decode raw)))))
      (_
       (let ((raw (read-string prompt)))
         (if (string-empty-p raw) nil raw))))))

(provide 'herdr-schema)
;;; herdr-schema.el ends here
