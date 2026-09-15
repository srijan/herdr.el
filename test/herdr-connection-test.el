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

;;; The tunnel

(ert-deftest herdr-connection-tunnel-command-passes-the-target-through ()
  "A bare host, a `user@host' and an SSH config alias are all just the
target: parsing one here would be this package inventing a grammar SSH
already has."
  (dolist (target '("shadow" "srijan@192.0.2.10" "work-box"))
    (let ((command (herdr-connection--tunnel-command
                    target "/tmp/local.sock" "/home/u/.config/herdr/herdr.sock")))
      (should (equal "ssh" (car command)))
      (should (equal target (car (last command))))
      (should (member "-N" command))
      (should (member "/tmp/local.sock:/home/u/.config/herdr/herdr.sock"
                      command))
      ;; Non-interactive, or a forward that needs a password hangs a
      ;; command nobody is watching.
      (should (member "BatchMode=yes" command)))))

(ert-deftest herdr-connection-socket-path-stays-inside-the-platform-limit ()
  "macOS caps `sun_path' at 104 bytes, which is the tighter of the two
platforms.  A name is whatever a user typed, so a long one is hashed
rather than spelled out."
  (let ((herdr-connection-socket-directory "/tmp/herdr-501"))
    (should (equal "/tmp/herdr-501/shadow.sock"
                   (herdr-connection--local-socket-path "shadow")))
    (let* ((long (make-string 200 ?x))
           (path (herdr-connection--local-socket-path long)))
      (should (< (string-bytes path) 104))
      (should-not (string-match-p "xxxx" path))
      ;; Still one socket per connection: two long names do not collide.
      (should-not (equal path (herdr-connection--local-socket-path
                               (concat long "y")))))
    ;; A name with a slash in it cannot become a directory separator.
    (should-not (string-match-p "a/b"
                                (herdr-connection--local-socket-path "a/b")))))

(ert-deftest herdr-connection-remote-reads-the-socket-off-the-far-host ()
  "The default socket path contains a `~', so expanding it here would
forward a macOS client to a `/Users/...' path on a Linux server.  The
remote binary is asked instead, which doubles as the one check that
herdr is installed there at all."
  (let ((asked nil))
    (cl-letf (((symbol-function 'call-process)
               ;; BUFFER is `t' here, meaning the current one, which is
               ;; how `call-process' is called in the code under test.
               (lambda (_program _infile _buffer _display &rest args)
                 (setq asked args)
                 (progn
                   (insert "{\"sessions\":[{\"name\":\"default\",\"socket_path\":\"/home/u/.config/herdr/herdr.sock\"},{\"name\":\"work\",\"socket_path\":\"/home/u/.local/share/herdr/work/herdr.sock\"}]}"))
                 0)))
      (should (equal "/home/u/.config/herdr/herdr.sock"
                     (herdr-connection--remote-socket-path "shadow" nil)))
      (should (member "shadow" asked))
      (should (member "--json" asked))
      ;; A named session selects its own socket, not the default one.
      (should (equal "/home/u/.local/share/herdr/work/herdr.sock"
                     (herdr-connection--remote-socket-path "shadow" "work")))
      (should-error (herdr-connection--remote-socket-path "shadow" "nope")
                    :type 'herdr-error))))

(ert-deftest herdr-connection-remote-reports-ssh-failing-as-ssh-failing ()
  "SSH exiting non-zero has already said why on stderr.  Repeating it is
the whole report; guessing past it is not."
  (cl-letf (((symbol-function 'call-process)
             (lambda (_program _infile _buffer _display &rest _args)
               (insert "ssh: Could not resolve hostname shadow\n")
               255)))
    (let ((err (should-error (herdr-connection--remote-socket-path "shadow" nil)
                             :type 'herdr-error)))
      (should (equal "ssh_failed" (herdr-error-code err)))
      (should (string-match-p "Could not resolve" (herdr-error-message err))))))

(ert-deftest herdr-connection-a-forward-with-nothing-behind-it-says-so ()
  "OpenSSH binds the local socket at setup and only dials the remote when
something connects, so a forward to a path with no listener produces a
socket that exists and refuses every connection.  The socket appearing
is necessary and not sufficient, and the handshake is the only evidence
the whole path works.

Through the forward alone, a missing herdr and a wrong socket path are
the same silence.  That is why the path is resolved on the far host
first, and why nothing here tries to tell them apart."
  (let* ((path (herdr-test-socket-path))
         (connection (herdr-connection--make
                      :name "silent" :ssh-target "shadow"
                      :socket-path path))
         (herdr-connection-tunnel-timeout 0.4))
    (unwind-protect
        (progn
          ;; Stands in for ssh: alive, and the socket exists because
          ;; something bound it.  Nothing answers.
          (setf (herdr-connection-tunnel connection)
                (make-process :name "herdr-test-fake-ssh"
                              :command (list "sleep" "30") :noquery t))
          (let ((server (herdr-test-start-server path (lambda (_req) (cons nil t)))))
            (unwind-protect
                (let ((err (should-error (herdr-connection--await-tunnel connection)
                                         :type 'herdr-error)))
                  (should (equal "no_answer" (herdr-error-code err))))
              (ignore-errors (delete-process server)))))
      (herdr-connection--stop-tunnel connection)
      (ignore-errors (delete-file path)))))

(ert-deftest herdr-connection-an-ssh-that-exits-is-not-a-silent-socket ()
  "The other reportable state.  Reported as SSH's own failure, with what
it said, rather than waiting out a timeout for a socket that will never
exist."
  (let* ((connection (herdr-connection--make
                      :name "gone" :ssh-target "shadow"
                      :socket-path "/tmp/herdr-test-never-bound.sock"))
         (herdr-connection-tunnel-timeout 5.0))
    (setf (herdr-connection-tunnel connection)
          (make-process :name "herdr-test-fake-ssh"
                        :command (list "false") :noquery t
                        :buffer (generate-new-buffer " *fake-ssh*")))
    (unwind-protect
        (progn
          (herdr-test-wait-for
           (lambda () (not (process-live-p (herdr-connection-tunnel connection)))))
          (let ((err (should-error (herdr-connection--await-tunnel connection)
                                   :type 'herdr-error)))
            (should (equal "ssh_exited" (herdr-error-code err)))))
      (herdr-connection--stop-tunnel connection))))

(ert-deftest herdr-connection-a-live-socket-is-not-treated-as-stale ()
  "An `ssh' killed rather than stopped leaves its end of the forward
behind and OpenSSH refuses to bind over it, so a stale file has to go.
Deleting one that is still live would break a working tunnel, so the
check connects rather than trusting the file's existence."
  (let* ((path (herdr-test-socket-path))
         (server (herdr-test-start-server path (lambda (_req) (cons nil t)))))
    (unwind-protect
        (progn
          (herdr-connection--remove-stale-socket path)
          (should (file-exists-p path)))
      (ignore-errors (delete-process server)))
    ;; With the listener gone the same file is stale, and goes.
    (should (file-exists-p path))
    (herdr-connection--remove-stale-socket path)
    (should-not (file-exists-p path))))

(ert-deftest herdr-connection-a-dead-tunnel-retries-while-it-is-wanted ()
  "One retry mechanism, not two: the tunnel's sentinel routes into the
same reconnect a dropped event stream takes."
  (let ((connection (herdr-test-connection)))
    (setf (herdr-connection-running connection) t
          (herdr-connection-ssh-target connection) "shadow")
    (unwind-protect
        (progn
          (herdr-connection--tunnel-died connection)
          (should (herdr-connection-reconnect-timer connection))
          (should-not (herdr-connection-tunnel connection)))
      (when (herdr-connection-reconnect-timer connection)
        (cancel-timer (herdr-connection-reconnect-timer connection))))))

(ert-deftest herdr-connection-a-deliberate-teardown-retries-nothing ()
  "`herdr-disconnect' stops the session before it kills the tunnel, so the
sentinel finds nothing left to want."
  (let ((connection (herdr-test-connection)))
    (setf (herdr-connection-running connection) nil
          (herdr-connection-ssh-target connection) "shadow")
    (herdr-connection--tunnel-died connection)
    (should-not (herdr-connection-reconnect-timer connection))))

(ert-deftest herdr-disconnect-kills-the-tunnel-and-its-socket ()
  (let* ((path (herdr-test-socket-path))
         (connection (herdr-connection--make
                      :name "shadow" :ssh-target "shadow" :socket-path path))
         (herdr-connections (herdr-test-connections connection))
         (herdr-state-change-functions nil)
         (process (make-process :name "herdr-test-fake-ssh"
                                :command (list "sleep" "30") :noquery t)))
    (setf (herdr-connection-tunnel connection) process)
    (with-temp-file path (insert ""))
    (herdr-disconnect "shadow")
    (should-not (process-live-p process))
    (should-not (file-exists-p path))
    (should-not (herdr-connection-tunnel connection))
    (should-not (herdr-connection-list))))

(provide 'herdr-connection-test)
;;; herdr-connection-test.el ends here
