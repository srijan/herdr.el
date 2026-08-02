;;; herdr-test-helper.el --- Shared fixtures for herdr tests -*- lexical-binding: t; -*-

;;; Commentary:

;; A fake herdr server, so the bulk of the suite runs with no herdr
;; installed.  It reproduces the two behaviours that actually shape the
;; client: ordinary requests get one response and then the connection is
;; closed, while `events.subscribe' is held open and streamed.

;;; Code:

(require 'json)
(require 'ert)

;; macOS caps unix socket paths near 104 bytes and the standard temp
;; directory is already long, so build paths under /tmp directly.
(defvar herdr-test--socket-counter 0)

(defun herdr-test-socket-path ()
  "Return a fresh, unused unix socket path."
  (format "/tmp/herdr-test-%d-%d.sock"
          (emacs-pid)
          (cl-incf herdr-test--socket-counter)))

(defun herdr-test-parse (string)
  "Parse STRING as herdr does: alists, lists, nil for null and false."
  (json-parse-string string
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

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
       (let* ((request (herdr-test-parse line))
              (reply (funcall responder request)))
         (when (car reply)
           (process-send-string client (car reply)))
         (unless (cdr reply)
           (ignore-errors (delete-process client))))))))

(defmacro herdr-test-with-server (responder &rest body)
  "Run BODY with `herdr-socket-path' bound to a fake server using RESPONDER."
  (declare (indent 1) (debug t))
  `(let* ((path (herdr-test-socket-path))
          (server (herdr-test-start-server path ,responder)))
     (unwind-protect
         (let ((herdr-socket-path path))
           ,@body)
       (ignore-errors (delete-process server))
       (ignore-errors (delete-file path)))))

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

(provide 'herdr-test-helper)
;;; herdr-test-helper.el ends here
