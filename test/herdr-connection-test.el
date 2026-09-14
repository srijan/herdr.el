;;; herdr-connection-test.el --- Tests for the registry and resolver -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-connection)
(require 'herdr-state)
(require 'herdr-test-helper)

;;; The registry

(ert-deftest herdr-connection-registry-keeps-registration-order ()
  "The local server is registered first and stays first, because it is
what a command with no other context means."
  (let ((herdr-connections nil))
    (herdr-connection-register (herdr-connection--make :name "local"))
    (herdr-connection-register (herdr-connection--make :name "shadow"))
    (should (equal '("local" "shadow")
                   (mapcar #'herdr-connection-name (herdr-connection-list))))))

(ert-deftest herdr-connection-registering-a-name-again-replaces-it ()
  "Reconnecting under a name a user already knows must not leave two
connections answering to it, one of them dead."
  (let ((herdr-connections nil))
    (herdr-connection-register (herdr-connection--make :name "shadow"))
    (let ((fresh (herdr-connection-register
                  (herdr-connection--make :name "shadow"))))
      (should (= 1 (length (herdr-connection-list))))
      (should (eq fresh (herdr-connection-named "shadow"))))))

(ert-deftest herdr-connection-forget-drops-only-the-one-named ()
  (let ((herdr-connections nil))
    (let ((local (herdr-connection-register
                  (herdr-connection--make :name "local")))
          (shadow (herdr-connection-register
                   (herdr-connection--make :name "shadow"))))
      (herdr-connection-forget shadow)
      (should (equal (list local) (herdr-connection-list)))
      (should-not (herdr-connection-named "shadow")))))

;;; The resolver

(ert-deftest herdr-current-connection-registers-a-local-one-when-empty ()
  "The single-server path needs no setup: asking with nothing registered
is how `herdr-start\\=' gets its connection."
  (let ((herdr-connections nil))
    (let ((connection (herdr-current-connection)))
      (should (herdr-connection-p connection))
      (should (equal (list connection) (herdr-connection-list)))
      ;; The same one next time, not a fresh one per call.
      (should (eq connection (herdr-current-connection))))))

(ert-deftest herdr-current-connection-prefers-the-dispatching-one ()
  "An asynchronous callback runs in an empty extent, so a listener it
reaches would otherwise resolve whatever the user last looked at."
  (let* ((local (herdr-connection--make :name "local"))
         (shadow (herdr-connection--make :name "shadow"))
         (herdr-connections (list (cons "local" local)
                                  (cons "shadow" shadow))))
    (should (eq local (herdr-current-connection)))
    (herdr-connection-with-dispatch shadow
      (should (eq shadow (herdr-current-connection))))
    (should (eq local (herdr-current-connection)))))

(ert-deftest herdr-current-connection-prefers-the-buffer-over-the-registry ()
  "A command typed in a terminal buffer means that buffer's server,
whatever else is on screen."
  (let* ((local (herdr-connection--make :name "local"))
         (shadow (herdr-connection--make :name "shadow"))
         (herdr-connections (list (cons "local" local)
                                  (cons "shadow" shadow))))
    (with-temp-buffer
      (setq herdr-buffer-connection shadow)
      (should (eq shadow (herdr-current-connection))))
    (with-temp-buffer
      (should (eq local (herdr-current-connection))))))

(ert-deftest herdr-current-connection-asks-the-resolvers-before-the-registry ()
  "One buffer can hold rows from several servers, which is the case a
buffer-local cannot serve."
  (let* ((local (herdr-connection--make :name "local"))
         (shadow (herdr-connection--make :name "shadow"))
         (herdr-connections (list (cons "local" local)
                                  (cons "shadow" shadow)))
         (herdr-connection-resolvers (list (lambda () shadow))))
    (should (eq shadow (herdr-current-connection)))
    ;; A resolver that has nothing to say falls through rather than
    ;; answering nil.
    (let ((herdr-connection-resolvers (list #'ignore (lambda () shadow))))
      (should (eq shadow (herdr-current-connection))))))

(ert-deftest herdr-current-connection-dispatch-outranks-the-buffer ()
  "A reply that lands while some other herdr buffer happens to be
current belongs to the connection it was dispatched under."
  (let* ((local (herdr-connection--make :name "local"))
         (shadow (herdr-connection--make :name "shadow"))
         (herdr-connections (list (cons "local" local))))
    (with-temp-buffer
      (setq herdr-buffer-connection local)
      (herdr-connection-with-dispatch shadow
        (should (eq shadow (herdr-current-connection)))))))

;;; Connecting and disconnecting

(ert-deftest herdr-connect-registers-and-starts ()
  (let ((herdr-connections nil)
        (started nil))
    (cl-letf (((symbol-function 'herdr-state-start)
               (lambda (connection) (push connection started))))
      (let ((connection (herdr-connect "shadow" "/tmp/shadow.sock")))
        (should (equal "shadow" (herdr-connection-name connection)))
        (should (equal "/tmp/shadow.sock"
                       (herdr-connection-socket-path connection)))
        (should (eq connection (herdr-connection-named "shadow")))
        (should (equal (list connection) started))))))

(ert-deftest herdr-connect-refuses-an-empty-name ()
  "The name is how a failure says which server it was about."
  (let ((herdr-connections nil))
    (should-error (herdr-connect "" "/tmp/shadow.sock") :type 'user-error)
    (should-not herdr-connections)))

(ert-deftest herdr-disconnect-stops-the-retries ()
  "Disconnecting is deliberate and therefore final.  A stream that merely
drops keeps being retried, because nobody said to stop."
  (let* ((connection (herdr-test-connection))
         (herdr-connections (herdr-test-connections connection))
         (herdr-state-change-functions nil))
    (setf (herdr-connection-running connection) t
          (herdr-connection-reconnect-timer connection)
          (run-at-time 3600 nil #'ignore))
    (herdr-disconnect (herdr-connection-name connection))
    (should-not (herdr-connection-running connection))
    (should-not (herdr-connection-reconnect-timer connection))
    (should-not (herdr-connection-list))))

(ert-deftest herdr-disconnect-names-a-connection-that-is-not-there ()
  (let ((herdr-connections nil))
    (should-error (herdr-disconnect "nobody") :type 'user-error)))

(ert-deftest herdr-a-dropped-stream-keeps-retrying ()
  "The other half of the same contract: a drop schedules a reconnect and
the session stays running, because nothing said to stop."
  (let* ((connection (herdr-test-connection))
         (herdr-connections (herdr-test-connections connection)))
    (setf (herdr-connection-running connection) t)
    (unwind-protect
        (progn
          (herdr-state--schedule-reconnect connection)
          (should (herdr-connection-reconnect-timer connection))
          (should (herdr-connection-running connection))
          (should (herdr-connection-named (herdr-connection-name connection))))
      (when (herdr-connection-reconnect-timer connection)
        (cancel-timer (herdr-connection-reconnect-timer connection))))))

(provide 'herdr-connection-test)
;;; herdr-connection-test.el ends here
