;;; herdr-test-helper.el --- Shared fixtures for herdr tests -*- lexical-binding: t; -*-

;;; Commentary:

;; A fake herdr server, so the bulk of the suite runs with no herdr
;; installed.  It reproduces the two behaviours that actually shape the
;; client: ordinary requests get one response and then the connection is
;; closed, while `events.subscribe' is held open and streamed.

;;; Code:

(require 'ert)
(require 'cl-lib)
;; The connection struct and its `setf' expanders have to exist before
;; `herdr-test-with-state' expands, or the seeds compile to a call to a
;; setter function that was never defined.
(require 'herdr-rpc)
(require 'herdr-state)
(require 'herdr-connection)
(require 'herdr-select)

;; `herdr-self-pane-id' and `herdr-self-socket-path' are read from the
;; environment when the package loads, and herdr exports both into every
;; pane it starts.  A suite run from inside a herdr pane would otherwise
;; disagree with one run outside it - and it did: with HERDR_PANE_ID set
;; to a pane id the fixtures use, `herdr-term-select-pane' refused to
;; attach and a test that had nothing to do with any of this failed.
;; Neutralised here so every test states its own self-pane or has none.
(setq herdr-self-pane-id nil
      herdr-self-socket-path nil)

;; macOS caps unix socket paths near 104 bytes and the standard temp
;; directory is already long, so build paths under /tmp directly.
(defvar herdr-test--socket-counter 0)

(defvar herdr-test--connection-counter 0
  "Counter behind the names `herdr-test-connection\=' hands out.
Distinct names, because the registry is keyed by name and two test
connections sharing one would replace each other.")

(defun herdr-test-socket-path ()
  "Return a fresh, unused unix socket path."
  (format "/tmp/herdr-test-%d-%d.sock"
          (emacs-pid)
          (cl-incf herdr-test--socket-counter)))

(defun herdr-test-start-server (path responder)
  "Listen on PATH, answering with RESPONDER.
RESPONDER is called with each decoded request alist and must return a
cons (PAYLOAD . KEEP-OPEN).  PAYLOAD is written verbatim, so it may hold
several newline-delimited lines.  When KEEP-OPEN is nil the client
connection is closed afterwards, which is what produces the EOF the
real server sends after every non-subscription request."
  (make-network-process
   :name "herdr-test-server" :server t :family 'local
   :service path :coding 'utf-8-unix :noquery t
   :filter
   (lambda (client chunk)
     (dolist (line (split-string chunk "\n" t "[ \t\r]+"))
       (let* ((request (herdr-rpc-decode line))
              (reply (funcall responder request)))
         (when (car reply)
           (process-send-string client (car reply)))
         (unless (cdr reply)
           (ignore-errors (delete-process client))))))))

(defmacro herdr-test-with-server (responder &rest body)
  "Run BODY talking to a fake server using RESPONDER.
Points the current connection at the fake socket as well as binding
`herdr-socket-path', because the transport reads its socket from the
connection it is handed and not from the variable."
  (declare (indent 1) (debug t))
  `(let* ((path (herdr-test-socket-path))
          (server (herdr-test-start-server path ,responder))
          ;; The connection already in scope, pointed at the fake socket
          ;; rather than replaced: a test that seeded a cache means to
          ;; keep it, and binding a fresh connection would drop it.
          (connection (herdr-current-connection))
          (previous (herdr-connection-socket-path connection)))
     (unwind-protect
         (let ((herdr-socket-path path))
           (setf (herdr-connection-socket-path connection) path)
           ,@body)
       (setf (herdr-connection-socket-path connection) previous)
       (ignore-errors (delete-process server))
       (ignore-errors (delete-file path)))))

(defun herdr-test-wait-for (predicate &optional seconds)
  "Pump the event loop until PREDICATE answers non-nil, or SECONDS elapse.
Returns what PREDICATE answered, so a caller can `should' it directly.

The repair and the settle are asynchronous: their requests go out and
their replies arrive through process filters.  A test that asserts on
the line after starting one is asserting that nothing has happened yet,
which is true and useless."
  (let ((deadline (+ (float-time) (or seconds 5)))
        (value nil))
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    value))

(defun herdr-test-ok (request result)
  "Build a success line for REQUEST carrying RESULT."
  (concat (json-serialize `((id . ,(alist-get 'id request))
                            (result . ,result)))
          "\n"))

(defun herdr-test-err (request code message)
  "Build an error line for REQUEST with CODE and MESSAGE."
  (concat (json-serialize `((id . ,(alist-get 'id request))
                            (error . ((code . ,code) (message . ,message)))))
          "\n"))

(defun herdr-schema-load-file (connection path)
  "Cache the schema stored at PATH as CONNECTION\\='s, needing no herdr binary."
  (setf (herdr-connection-schema connection)
        (with-temp-buffer
          (insert-file-contents path)
          (herdr-rpc-decode (buffer-string)))))

(defmacro herdr-test-with-state (seeds &rest body)
  "Run BODY with the sole connection seeded from SEEDS.
SEEDS is a plist of connection slots, so a test that used to bind
`herdr-state--running\=' and friends seeds them here instead: the session
state lives in the connection now, and a global is exactly what this
removes."
  (declare (indent 1) (debug t))
  `(let ((herdr-connections (herdr-test-connections (herdr-test-connection))))
     ,@(let ((rest seeds) forms)
         (while rest
           (let ((slot (pop rest)) (value (pop rest)))
             (push `(setf (,(intern (format "herdr-connection-%s"
                                            (substring (symbol-name slot) 1)))
                           (herdr-current-connection))
                          ,value)
                   forms)))
         (nreverse forms))
     ,@body))

(defun herdr-test-term-buffers (cells &optional connection)
  "Return a terminal registry for CELLS on CONNECTION.
CELLS is an alist of (PANE-ID . BUFFER), the shape the registry had
before ids needed a server.  Keys each by the connection\='s token and
tells each buffer which connection it belongs to, which is what
attaching does."
  (let ((connection (or connection (herdr-current-connection))))
    (mapcar (lambda (cell)
              (when (buffer-live-p (cdr cell))
                (with-current-buffer (cdr cell)
                  (setq herdr-buffer-connection connection)))
              (cons (cons (herdr-connection-token connection) (car cell))
                    (cdr cell)))
            cells)))

(defun herdr-test-connections (connection)
  "Return a registry holding CONNECTION alone.
What a test binds `herdr-connections\=' to when it wants one connection
and wants every resolution to reach it."
  (list (cons (herdr-connection-name connection) connection)))

(defun herdr-test-connection (&optional cache)
  "Return a fresh connection whose session cache is CACHE.
The drop-in for what used to be a `herdr-state--current' binding: the
cache lives in the connection now, so a test seeds one rather than a
global.

Inherits the socket of whatever connection is already current, so
seeding inside `herdr-test-with-server' still talks to the fake server
rather than silently reaching for the real one."
  (let ((connection (herdr-connection-local))
        (name (format "test-%d" (cl-incf herdr-test--connection-counter))))
    (setf (herdr-connection-name connection) name)
    (setf (herdr-connection-socket-path connection)
          (herdr-connection-socket-path (herdr-current-connection)))
    (setf (herdr-connection-cache connection) (or cache (herdr-state-empty)))
    connection))

(define-advice ert-run-test (:around (run test) herdr-forget-the-last-pick)
  "Run TEST through RUN with nothing left behind by the test before it.

What a picker leaves — the rows it offered and the connection it chose —
belongs to the command that picked.  `herdr-connection-choose' clears
the choice from `post-command-hook', which batch Emacs never runs, so
without this one test\='s pick answers the next test\='s question."
  (let ((herdr-connection-chosen nil)
        (herdr-select--rows nil))
    (funcall run test)))

(provide 'herdr-test-helper)
;;; herdr-test-helper.el ends here
