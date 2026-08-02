;;; herdr-rpc.el --- Socket transport for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Transport for herdr's local socket API.
;;
;; The protocol is newline-delimited JSON over a unix domain socket, and
;; it is one request per connection: the server writes a single response
;; and then closes.  There is therefore no request multiplexing and no
;; response correlation to do — the connection itself is the correlation.
;; Every call opens a fresh socket, which is cheap enough that pooling
;; would only add failure modes.
;;
;; `events.subscribe' is the sole exception; it holds the connection open
;; and streams.  Callers that need it use `herdr-rpc-connect' and manage
;; the process themselves.  See `herdr-state'.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'cl-lib)

(defgroup herdr nil
  "Control the herdr terminal workspace manager."
  :group 'tools
  :prefix "herdr-")

(defcustom herdr-socket-path "~/.config/herdr/herdr.sock"
  "Path to the herdr server's unix domain socket."
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

(define-error 'herdr-error "herdr error")

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

Entries whose value is nil are dropped rather than sent as JSON null:
herdr's optional parameters want absence, and several of them reject an
explicit null.  Callers that genuinely mean false pass `:false'.  Using
a hash table also guarantees that empty params serialize as {} rather
than the null that an empty alist would produce."
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

(defun herdr-rpc-connect (name filter sentinel)
  "Open a connection to the herdr socket named NAME.
FILTER and SENTINEL are installed on the process.  Signals `herdr-error'
with code \"no_server\" when the socket is absent or refuses."
  (let ((path (expand-file-name herdr-socket-path)))
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

(defun herdr-rpc-call (method &optional params)
  "Call METHOD with PARAMS synchronously and return its result alist.
Signals `herdr-error' on a server error, an unreachable socket, or a
timeout."
  (let* ((chunks nil)
         (closed nil)
         (proc (herdr-rpc-connect
                (format "herdr-rpc-%s" method)
                (lambda (_proc chunk) (push chunk chunks))
                (lambda (_proc _event) (setq closed t)))))
    (unwind-protect
        (progn
          (process-send-string proc (herdr-rpc-encode (herdr-rpc--next-id)
                                                      method params))
          ;; The server closes after responding, so EOF is the completion
          ;; signal rather than anything we have to parse for.
          (let ((deadline (+ (float-time) herdr-rpc-timeout)))
            (while (and (not closed) (< (float-time) deadline))
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

(defun herdr-rpc-call-async (method params callback)
  "Call METHOD with PARAMS, invoking CALLBACK when the response arrives.
CALLBACK receives (RESULT ERROR).  Exactly one is non-nil; ERROR is the
server's error alist, with keys `code' and `message'.  Returns the
process, which may be deleted to abandon the call.

Used for methods that block server-side — `agent.wait' and
`pane.wait_for_output' — so that Emacs stays responsive."
  (let* ((chunks nil)
         (fired nil)
         (finish
          (lambda ()
            (unless fired
              (setq fired t)
              (let ((text (apply #'concat (nreverse chunks))))
                (condition-case err
                    (let* ((payload (herdr-rpc-decode
                                     (car (split-string text "\n" t))))
                           (server-error (alist-get 'error payload)))
                      (if server-error
                          (funcall callback nil server-error)
                        (funcall callback (alist-get 'result payload) nil)))
                  (error
                   (funcall callback nil
                            `((code . "bad_response")
                              (message . ,(error-message-string err)))))))))))
    (let ((proc (herdr-rpc-connect
                 (format "herdr-rpc-async-%s" method)
                 (lambda (_proc chunk) (push chunk chunks))
                 (lambda (_proc _event) (funcall finish)))))
      (process-send-string proc (herdr-rpc-encode (herdr-rpc--next-id)
                                                  method params))
      proc)))

(provide 'herdr-rpc)
;;; herdr-rpc.el ends here
