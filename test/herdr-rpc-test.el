;;; herdr-rpc-test.el --- Tests for herdr-rpc -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-test-helper)
(require 'herdr-rpc)

(ert-deftest herdr-rpc-encode-empty-params-is-an-object ()
  "Empty params must serialize as {} — nil would become null and be rejected."
  (let ((json (herdr-rpc-encode "1" "ping" nil)))
    (should (string-suffix-p "\n" json))
    (should (string-match-p "\"params\":{}" json))
    (should (string-match-p "\"method\":\"ping\"" json))))

(ert-deftest herdr-rpc-encode-drops-nil-valued-params ()
  "Optional params left nil must be omitted, not sent as null."
  (let ((json (herdr-rpc-encode "1" "pane.split"
                                '((direction . "right") (cwd . nil)))))
    (should (string-match-p "\"direction\":\"right\"" json))
    (should-not (string-match-p "cwd" json))))

(ert-deftest herdr-rpc-encode-keeps-explicit-false ()
  "`:false' must survive as JSON false; only nil means absent."
  (let ((json (herdr-rpc-encode "1" "pane.split"
                                '((direction . "right") (focus . :false)))))
    (should (string-match-p "\"focus\":false" json))))

(ert-deftest herdr-rpc-call-returns-parsed-result ()
  (herdr-test-with-server
      (lambda (req)
        (cons (herdr-test-ok req '((type . "pong") (protocol . 17))) nil))
    (let ((result (herdr-rpc-call "ping")))
      (should (equal (alist-get 'type result) "pong"))
      (should (equal (alist-get 'protocol result) 17)))))

(ert-deftest herdr-rpc-call-passes-params-through ()
  (let (seen)
    (herdr-test-with-server
        (lambda (req)
          (setq seen req)
          (cons (herdr-test-ok req '((type . "ok"))) nil))
      (herdr-rpc-call "pane.close" '((pane_id . "w1:p3")))
      (should (equal (alist-get 'method seen) "pane.close"))
      (should (equal (alist-get 'pane_id (alist-get 'params seen)) "w1:p3")))))

(ert-deftest herdr-rpc-call-signals-herdr-error-with-code ()
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-err req "not_found" "pane not found") nil))
    (let ((err (should-error (herdr-rpc-call "pane.get" '((pane_id . "nope")))
                             :type 'herdr-error)))
      (should (equal (herdr-error-code err) "not_found"))
      (should (string-match-p "pane not found" (herdr-error-message err))))))

(ert-deftest herdr-rpc-call-without-server-signals-no-server ()
  (let ((herdr-socket-path "/tmp/herdr-test-definitely-absent.sock"))
    (let ((err (should-error (herdr-rpc-call "ping") :type 'herdr-error)))
      (should (equal (herdr-error-code err) "no_server")))))

(ert-deftest herdr-rpc-call-async-invokes-callback-with-result ()
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
    (let (got-result got-error done)
      (herdr-rpc-call-async "ping" nil
                            (lambda (result err)
                              (setq got-result result got-error err done t)))
      (let ((deadline (+ (float-time) 5)))
        (while (and (not done) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should done)
      (should-not got-error)
      (should (equal (alist-get 'type got-result) "ok")))))

(ert-deftest herdr-rpc-call-async-reports-error-to-callback ()
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-err req "invalid_request" "bad") nil))
    (let (got-error done)
      (herdr-rpc-call-async "pane.split" nil
                            (lambda (_result err) (setq got-error err done t)))
      (let ((deadline (+ (float-time) 5)))
        (while (and (not done) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should done)
      (should (equal (alist-get 'code got-error) "invalid_request")))))

(ert-deftest herdr-rpc-call-async-with-nil-timeout-is-unaffected ()
  "Passing TIMEOUT explicitly as nil must behave exactly like omitting it.
This is the regression the whole feature has to preserve: the two
existing callers of `herdr-rpc-call-async' block server-side by design
and pass nothing here, so nil must remain \"wait indefinitely\"."
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
    (let (got-result got-error done)
      (herdr-rpc-call-async "ping" nil
                            (lambda (result err)
                              (setq got-result result got-error err done t))
                            nil)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not done) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should done)
      (should-not got-error)
      (should (equal (alist-get 'type got-result) "ok")))))

(defvar herdr-rpc-test--timer-cancellations nil
  "Timers `cancel-timer' has been asked to cancel, recorded by a spy.")

(defun herdr-rpc-test--note-cancel (&rest args)
  "Record that `cancel-timer' ran, ignoring ARGS."
  (push args herdr-rpc-test--timer-cancellations))

(ert-deftest herdr-rpc-call-async-normal-reply-cancels-the-timer ()
  "A reply that beats TIMEOUT must retire the timer, not merely outrun it.

Counting callback invocations cannot tell a cancelled timer from one left
armed and quietly guarded away later — the `fired' flag absorbs either
outcome and the public contract looks identical.  Spying on
`cancel-timer' catches the missing call directly, which is what makes
this the test that would fail if the cancellation were deleted."
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
    (let ((herdr-rpc-test--timer-cancellations nil)
          done)
      (advice-add 'cancel-timer :before #'herdr-rpc-test--note-cancel)
      (unwind-protect
          (progn
            (herdr-rpc-call-async "ping" nil
                                  (lambda (&rest _) (setq done t))
                                  30)
            (let ((deadline (+ (float-time) 5)))
              (while (and (not done) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should done)
            (should herdr-rpc-test--timer-cancellations))
        (advice-remove 'cancel-timer #'herdr-rpc-test--note-cancel)))))

(ert-deftest herdr-rpc-call-async-normal-reply-never-later-reports-a-timeout ()
  "A reply that lands must be the only word CALLBACK ever gets.
Waits past TIMEOUT after a normal reply and re-checks the callback's
recorded arguments: a stray, uncancelled timer firing later would
overwrite `got-error' with a timeout — this is the observable half of
\"cancels the timer and does not later fire a timeout\"."
  (herdr-test-with-server
      (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
    (let (calls got-result got-error)
      (herdr-rpc-call-async "ping" nil
                            (lambda (result err)
                              (setq calls (1+ (or calls 0)))
                              (setq got-result result got-error err))
                            0.2)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not calls) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should (equal 1 calls))
      ;; Outlast the timer that would have fired at 0.2s.
      (let ((deadline (+ (float-time) 0.6)))
        (while (< (float-time) deadline)
          (accept-process-output nil 0.05)))
      (should (equal 1 calls))
      (should-not got-error)
      (should (equal (alist-get 'type got-result) "ok")))))

(ert-deftest herdr-rpc-call-async-times-out-when-the-server-never-answers ()
  "A server that accepts and never answers must not dangle forever.

`(nil . t)' from the fake server's responder is what produces that server:
it accepts the connection and holds it open, writing nothing back.
Without a TIMEOUT this would hang for the life of the Emacs session,
which is the bug this whole feature exists to close."
  (herdr-test-with-server (lambda (_req) (cons nil t))
    (let (calls got-error)
      (herdr-rpc-call-async "agent.wait" nil
                            (lambda (_result err)
                              (setq calls (1+ (or calls 0)))
                              (setq got-error err))
                            0.2)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not calls) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should (equal 1 calls))
      (should (equal "timeout" (alist-get 'code got-error))))))

(ert-deftest herdr-rpc-call-async-a-late-sentinel-does-not-double-fire ()
  "Deleting the process on timeout can wake its own sentinel — that must
not be a second callback.

The timeout path deletes the process to abandon the connection, and
`delete-process' is exactly what can make the sentinel run.  This test
outlasts that by a full second beyond the timeout firing, so a sentinel
that ran around the guard rather than through it — the mistake the task
brief calls out by name — would show up as a second, later call."
  (herdr-test-with-server (lambda (_req) (cons nil t))
    (let (calls got-error)
      (herdr-rpc-call-async "agent.wait" nil
                            (lambda (_result err)
                              (setq calls (1+ (or calls 0)))
                              (setq got-error err))
                            0.2)
      (let ((deadline (+ (float-time) 5)))
        (while (and (not calls) (< (float-time) deadline))
          (accept-process-output nil 0.05)))
      (should (equal 1 calls))
      (let ((deadline (+ (float-time) 1)))
        (while (< (float-time) deadline)
          (accept-process-output nil 0.05)))
      (should (equal 1 calls))
      (should (equal "timeout" (alist-get 'code got-error))))))

(ert-deftest herdr-rpc-array-serializes-as-a-json-array ()
  "A list of alists is ambiguous to `json-serialize'; vectors are not."
  (let ((json (herdr-rpc-encode
               "1" "events.subscribe"
               `((subscriptions . ,(herdr-rpc-array
                                    (list '((type . "pane.created"))
                                          '((type . "pane.closed")))))))))
    (should (string-match-p
             "\"subscriptions\":\\[{\"type\":\"pane.created\"},{\"type\":\"pane.closed\"}\\]"
             json))))

(ert-deftest herdr-rpc-encode-rejects-raw-list-of-alists ()
  "Guard the mistake this replaced: a bare list of alists must not encode."
  (should-error
   (herdr-rpc-encode "1" "events.subscribe"
                     '((subscriptions . (((type . "a")) ((type . "b"))))))))

(provide 'herdr-rpc-test)
;;; herdr-rpc-test.el ends here
