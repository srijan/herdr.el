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
is how `herdr-start' gets its connection."
  (let ((herdr-connections nil))
    (let ((connection (herdr-current-connection)))
      (should (herdr-connection-p connection))
      (should (equal (list connection) (herdr-connection-list)))
      ;; The same one next time, not a fresh one per call.
      (should (eq connection (herdr-current-connection))))))

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
      (should (member "BatchMode=yes" command))
      ;; A listening forward sends nothing itself, so without probes a
      ;; sleeping laptop keeps a dead ssh that every RPC waits out.
      (should (member "ServerAliveInterval=15" command)))))

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

(defmacro herdr-connection-test--answering (&rest body)
  "Run BODY with a stubbed remote answering where herdr is and its sessions."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'call-process)
              ;; BUFFER is `t' here, meaning the current one, which is
              ;; how `call-process' is called in the code under test.
              (lambda (_program _infile _buffer _display &rest args)
                (setq asked args)
                (insert "/home/u/.local/bin/herdr\n"
                        "{\"sessions\":[{\"name\":\"default\",\"socket_path\":\"/home/u/.config/herdr/herdr.sock\"},{\"name\":\"work\",\"socket_path\":\"/home/u/.local/share/herdr/work/herdr.sock\"}]}")
                0)))
     ,@body))

(ert-deftest herdr-connection-remote-reads-the-socket-off-the-far-host ()
  "The default socket path contains a `~', so expanding it here would
forward a macOS client to a `/Users/...' path on a Linux server.  The
remote binary is asked instead, which doubles as the one check that
herdr is installed there at all."
  (let ((asked nil))
    (herdr-connection-test--answering
      (let ((answer (herdr-connection--ask-remote "shadow")))
        (should (equal "/home/u/.local/bin/herdr" (car answer)))
        (should (equal "/home/u/.config/herdr/herdr.sock"
                       (herdr-connection--session-socket
                        "shadow" (cdr answer) nil)))
        ;; A named session selects its own socket, not the default one.
        (should (equal "/home/u/.local/share/herdr/work/herdr.sock"
                       (herdr-connection--session-socket
                        "shadow" (cdr answer) "work")))
        (should-error (herdr-connection--session-socket
                       "shadow" (cdr answer) "nope")
                      :type 'herdr-error))
      (should (member "shadow" asked))
      ;; The script goes over as one quoted argument.  ssh joins its
      ;; arguments into a single string that the remote login shell
      ;; re-parses, so an unquoted script loses its own `&&' to that
      ;; shell and `sh -c' is handed only the first word.  Measured: the
      ;; path line never came back.
      (let* ((script (car (last asked)))
             (plain (replace-regexp-in-string "\\\\" "" script)))
        (should (equal "command -v herdr && herdr session list --json" plain))
        ;; Quoted, whichever way this platform spells it.
        (should-not (equal script plain))))))

(ert-deftest herdr-connection-remote-resolves-the-binary-not-just-the-socket ()
  "TRAMP runs remote commands under its own `tramp-remote-path', not the
login PATH, so a herdr in `~/.local/bin' is on the PATH for
`ssh host herdr' and not on the one the terminal client gets.  Measured:
the attach failed with `/bin/sh: exec: herdr: not found\='.  An absolute
path needs no PATH at all."
  (let ((asked nil))
    (herdr-connection-test--answering
      (let ((connection (herdr-connection-remote "shadow" "shadow")))
        (should (equal "/home/u/.local/bin/herdr"
                       (herdr-connection-executable connection)))))
    (ignore asked))
  ;; A local connection keeps using the option.
  (let ((herdr-executable "herdr"))
    (should (equal "herdr" (herdr-connection-executable
                            (herdr-connection-local))))))

(ert-deftest herdr-connection-remote-reports-ssh-failing-as-ssh-failing ()
  "SSH exiting non-zero has already said why on stderr.  Repeating it is
the whole report; guessing past it is not."
  (cl-letf (((symbol-function 'call-process)
             (lambda (_program _infile buffer _display &rest _args)
               ;; Where ssh actually writes it.  DESTINATION is now
               ;; (STDOUT STDERR); stdout is the parsed channel and must
               ;; not carry diagnostics, because its first line is taken
               ;; as the path of a binary to run.
               (write-region "ssh: Could not resolve hostname shadow\n"
                             nil (cadr buffer) nil 'quiet)
               255)))
    (let ((err (should-error (herdr-connection--ask-remote "shadow")
                             :type 'herdr-error)))
      (should (equal "ssh_failed" (herdr-error-code err)))
      (should (string-match-p "Could not resolve" (herdr-error-message err))))))

(ert-deftest herdr-connection-login-noise-is-not-mistaken-for-the-binary ()
  "`command -v' answers an absolute path.  A banner, a host-key warning
or anything a remote shell echoes does not -- and the first line of the
answer is exec\\='d on that host, so taking one would run whatever the
noise named."
  (cl-letf (((symbol-function 'call-process)
             (lambda (_program _infile _buffer _display &rest _args)
               (insert "Welcome to shadow. Unauthorized access prohibited.\n"
                       "{\"sessions\":[]}")
               0)))
    (let ((err (should-error (herdr-connection--ask-remote "shadow")
                             :type 'herdr-error)))
      (should (equal "no_herdr" (herdr-error-code err))))))

(ert-deftest herdr-connection-an-unparseable-answer-says-so ()
  "Swallowing the decode left SESSIONS nil, and the caller then reported
a session that does not exist -- a cause inferred rather than observed."
  (cl-letf (((symbol-function 'call-process)
             (lambda (_program _infile _buffer _display &rest _args)
               (insert "/usr/bin/herdr\n" "{not json at all")
               0)))
    (let ((err (should-error (herdr-connection--ask-remote "shadow")
                             :type 'herdr-error)))
      (should (equal "bad_answer" (herdr-error-code err))))))

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

;;; Paths cross a machine boundary in both directions

(ert-deftest herdr-connection-file-name-names-the-machine-a-path-is-on ()
  "A remote server names paths on its own machine.  Pointing a buffer at
one verbatim points it at a local path of the same name — usually one
that does not exist, occasionally one that does and is not it."
  (let ((local (herdr-connection--make :name "local"))
        (remote (herdr-connection--make :name "shadow" :ssh-target "shadow")))
    (should (equal "/srv/app/" (herdr-connection-file-name local "/srv/app/")))
    (should (equal "/ssh:shadow:/srv/app/"
                   (herdr-connection-file-name remote "/srv/app/")))
    ;; Already remote: not doubled.
    (should (equal "/ssh:shadow:/srv/app/"
                   (herdr-connection-file-name remote "/ssh:shadow:/srv/app/")))
    (should-not (herdr-connection-file-name remote nil))))

(ert-deftest herdr-connection-server-path-strips-what-a-server-cannot-use ()
  "A server cannot use a TRAMP file name: it names a machine, and the
server already knows which machine it is on."
  (let ((local (herdr-connection--make :name "local"))
        (remote (herdr-connection--make :name "shadow" :ssh-target "shadow")))
    (should (equal "/srv/app/" (herdr-connection-server-path local "/srv/app/")))
    (should (equal "/srv/app/"
                   (herdr-connection-server-path remote "/ssh:shadow:/srv/app/")))
    ;; The user part is not a distinction TRAMP makes, so it is not one
    ;; this makes either.
    (should (equal "/srv/app/"
                   (herdr-connection-server-path
                    (herdr-connection--make :name "s" :ssh-target "me@shadow")
                    "/ssh:shadow:/srv/app/")))))

(ert-deftest herdr-connection-server-path-refuses-a-path-on-another-machine ()
  "Every guess here names a real directory on the wrong machine, so there
is no safe default: a local path offered to a remote server and a remote
path offered to a local one are the same mistake in two directions."
  (let ((local (herdr-connection--make :name "local"))
        (remote (herdr-connection--make :name "shadow" :ssh-target "shadow")))
    (let ((err (should-error (herdr-connection-server-path
                              local "/ssh:elsewhere:/srv/app/")
                             :type 'herdr-error)))
      (should (equal "wrong_host" (herdr-error-code err))))
    (should-error (herdr-connection-server-path remote "/srv/app/")
                  :type 'herdr-error)
    (should-error (herdr-connection-server-path
                   remote "/ssh:elsewhere:/srv/app/")
                  :type 'herdr-error)))

(ert-deftest herdr-cmd-creating-from-a-tramp-buffer-sends-a-server-path ()
  "`expand-file-name' on a TRAMP `default-directory' produces
`/ssh:host:/path', and handing the server that is handing it a filename
it cannot open."
  (let* ((remote (herdr-connection--make :name "shadow" :ssh-target "shadow"))
         (herdr-connections (herdr-test-connections remote))
         (sent nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (_connection _method params) (setq sent params) nil))
              ((symbol-function 'herdr-cmd--follow-new-pane) #'ignore)
              ((symbol-function 'herdr-cmd--created-pane-id) #'ignore))
      (herdr-workspace-create "/ssh:shadow:/srv/app/")
      (should (equal "/srv/app/" (alist-get 'cwd sent)))
      (should-not (file-remote-p (alist-get 'cwd sent))))))

(defmacro herdr-connection-test--catalog (output status &rest body)
  "Run BODY with `herdr machine list --json' printing OUTPUT and exiting STATUS."
  (declare (indent 2) (debug t))
  `(cl-letf (((symbol-function 'call-process)
              (lambda (_program _infile _buffer _display &rest args)
                (should (equal '("machine" "list" "--json") args))
                (insert ,output)
                ,status)))
     ,@body))

(ert-deftest herdr-connection-catalog-offers-the-enabled-machines ()
  "Disabled is a state herdr keeps for a reason.  A catalog is a source
of suggestions, and a machine its owner switched off is not one."
  (herdr-connection-test--catalog
      (concat "[{\"id\":\"p1\",\"label\":\"shadow\",\"target\":\"shadow\","
              "\"session\":null,\"enabled\":true},"
              "{\"id\":\"p2\",\"label\":\"build\",\"target\":\"u@build\","
              "\"session\":\"work\",\"enabled\":true},"
              "{\"id\":\"p3\",\"label\":\"old\",\"target\":\"old\","
              "\"session\":null,\"enabled\":false}]")
      0
    (let ((machines (herdr-connection-machines)))
      (should (equal '("shadow" "build") (mapcar #'herdr-machine-label machines)))
      (should (equal '("p1" "p2") (mapcar #'herdr-machine-id machines)))
      (should (equal '("shadow" "u@build") (mapcar #'herdr-machine-target machines)))
      ;; A machine that names no session means that host's default.
      (should-not (herdr-machine-session (nth 0 machines)))
      (should (equal "work" (herdr-machine-session (nth 1 machines)))))))

(ert-deftest herdr-connection-catalog-absent-is-not-a-failure ()
  "A herdr with no `machine' subcommand, a catalog that will not parse
and an empty one are the same answer, because every caller falls back to
being told a target directly."
  ;; No subcommand: non-zero exit, usage on the buffer.
  (herdr-connection-test--catalog "usage: herdr machine\n" 2
    (should-not (herdr-connection-machines)))
  ;; Unreadable.
  (herdr-connection-test--catalog "not json at all" 0
    (should-not (herdr-connection-machines)))
  ;; Empty.
  (herdr-connection-test--catalog "[]" 0
    (should-not (herdr-connection-machines)))
  ;; And a record with no target is not a machine anything can be done
  ;; with, whatever else it carries.
  (herdr-connection-test--catalog "[{\"id\":\"p1\",\"label\":\"x\"}]" 0
    (should-not (herdr-connection-machines))))

(ert-deftest herdr-connection-catalog-reads-and-never-writes ()
  "herdr owns the catalog.  This package offers what it holds and adds
nothing to it, so there is no second place a machine can be described."
  (herdr-connection-test--catalog "[]" 0
    (herdr-connection-machines))
  ;; `list' is the only `herdr machine' subcommand the package runs.  The
  ;; search is for "machine" followed by another string literal -- an
  ;; argument list -- so that the word used as a display noun, which the
  ;; dashboard header counts with, is not mistaken for an invocation.
  (dolist (file (directory-files default-directory t "\\`herdr.*\\.el\\'"))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (re-search-forward "\"machine\"[ \t\n]+\"\\([a-z-]+\\)\"" nil t)
        (should (equal "list" (match-string 1)))))))

(ert-deftest herdr-connection-a-renamed-machine-keeps-its-connection ()
  "A profile keeps its id through a rename.  Reconnecting to a renamed
machine must answer with the connection already being followed, under
its new name, rather than dig a second tunnel to the same server."
  (let* ((following (herdr-connection--make
                     :name "shadow" :ssh-target "shadow" :machine-id "p1"))
         (herdr-connections (list (cons "shadow" following))))
    (should (eq following (herdr-connection-for-machine "p1")))
    (cl-letf (((symbol-function 'herdr-connection--open-remote)
               (lambda (&rest _) (error "herdr: dug a second tunnel"))))
      (should (eq following (herdr-connect-remote "build-box" "shadow" nil "p1"))))
    (should (equal "build-box" (herdr-connection-name following)))
    ;; Registered under the new name and no longer under the old one.
    (should (eq following (herdr-connection-named "build-box")))
    (should-not (herdr-connection-named "shadow"))
    (should (equal 1 (length herdr-connections)))))

(ert-deftest herdr-connection-an-unsaved-machine-is-no-harder-to-reach ()
  "The catalog is a shortcut, never a gate.  Anything typed that is not
one of its labels is read as a target and asked about in full."
  (let ((prompts nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt &rest _) (push prompt prompts) "elsewhere"))
              ((symbol-function 'read-string)
               (lambda (prompt &optional initial &rest _)
                 (push prompt prompts)
                 (or initial ""))))
      (herdr-connection-test--catalog
          "[{\"id\":\"p1\",\"label\":\"shadow\",\"target\":\"shadow\"}]" 0
        (should (equal '("elsewhere" "elsewhere" nil nil)
                       (herdr-connection--read-remote)))))
    ;; The target typed at the machine prompt is not asked for again.
    (should-not (member "SSH target: " prompts))
    (should (member "Connection name: " prompts))))

(ert-deftest herdr-connection-registering-a-name-retires-the-one-it-displaces ()
  "Replacing the registry cell alone left the old connection running --
its streams, its timers and its tunnel -- and reachable by nothing,
`herdr-disconnect\=' included."
  (let* ((old (herdr-connection--make :name "shadow" :socket-path "/tmp/a.sock"))
         (new (herdr-connection--make :name "shadow" :socket-path "/tmp/b.sock"))
         (herdr-connections (list (cons "shadow" old)))
         (stopped nil))
    (cl-letf (((symbol-function 'herdr-state-stop)
               (lambda (connection) (push connection stopped))))
      (herdr-connection-register new))
    (should (equal (list old) stopped))
    (should (eq new (herdr-connection-named "shadow")))
    (should (equal 1 (length herdr-connections)))))

(ert-deftest herdr-connection-re-registering-the-same-struct-does-not-stop-it ()
  "The rename path re-registers the connection it is renaming."
  (let* ((connection (herdr-connection--make :name "shadow"))
         (herdr-connections (list (cons "shadow" connection)))
         (stopped nil))
    (cl-letf (((symbol-function 'herdr-state-stop)
               (lambda (c) (push c stopped))))
      (herdr-connection-register connection))
    (should-not stopped)))

(ert-deftest herdr-connection-a-failed-local-connect-leaves-no-entry ()
  "`herdr-connect-remote\=' promises the registry holds nothing when any of
it fails; the local entry point registered before the fallible call."
  (let ((herdr-connections nil))
    (cl-letf (((symbol-function 'herdr-state-start)
               (lambda (_connection) (error "herdr: no server"))))
      (should-error (herdr-connect "broken" "/tmp/definitely-absent.sock")))
    (should-not (herdr-connection-named "broken"))
    (should-not herdr-connections)))

(ert-deftest herdr-connection-two-accounts-on-one-host-are-two-machines ()
  "They have different home directories and different herdr sockets, so a
path from one is not a path on the other -- but an unqualified path
still matches, which is the leniency TRAMP itself has."
  (let ((alice (herdr-connection--make :name "alice" :ssh-target "alice@shadow"))
        (bob (herdr-connection--make :name "bob" :ssh-target "bob@shadow")))
    (should-error (herdr-connection-server-path
                   bob "/ssh:alice@shadow:/home/alice/src/")
                  :type 'herdr-error)
    (should (equal "/home/bob/src/"
                   (herdr-connection-server-path
                    bob "/ssh:bob@shadow:/home/bob/src/")))
    ;; A target that names no user still matches either account.
    (should (equal "/srv/x/"
                   (herdr-connection-server-path alice "/ssh:shadow:/srv/x/")))
    ;; And roots go only to the account whose host AND user they name.
    (should (equal '("/ssh:alice@shadow:/home/alice/p/")
                   (herdr-connection-roots-for
                    alice '("/ssh:alice@shadow:/home/alice/p/"
                            "/ssh:bob@shadow:/home/bob/p/"))))))

(ert-deftest herdr-connection-a-choice-survives-a-confirmation-prompt ()
  "`post-command-hook\= ' runs for the commands inside a recursive edit too,
so a command that picked a target and then asked `y-or-n-p\=' lost its
answer between the two.  Measured in a real frame: the close went to the
local server after picking a pane on the remote one."
  (let* ((one (herdr-connection--make :name "one"))
         (two (herdr-connection--make :name "two"))
         (herdr-connections (list (cons "one" one) (cons "two" two)))
         (herdr-connection-chosen nil))
    (herdr-connection-choose two)
    ;; What the hook does while a minibuffer is open.
    (cl-letf (((symbol-function 'minibuffer-depth) (lambda () 1)))
      (herdr-connection--unchoose))
    (should (eq two (herdr-current-connection)))
    ;; And what it does once the command is actually over.
    (cl-letf (((symbol-function 'minibuffer-depth) (lambda () 0)))
      (herdr-connection--unchoose))
    (should (eq one (herdr-current-connection)))))

(ert-deftest herdr-connection-a-remote-reconnect-restarts-its-tunnel ()
  "A remote connection reaches its server through the forward, so
reopening a socket whose `ssh\=' has exited retries a path that cannot
answer -- forever, with backoff, looking like it is trying."
  (let ((connection (herdr-connection--make :name "shadow"
                                            :ssh-target "shadow"))
        (started nil))
    (cl-letf (((symbol-function 'herdr-connection--start-tunnel)
               (lambda (c) (push c started) nil))
              ((symbol-function 'herdr-connection--await-tunnel) #'ignore))
      (herdr-connection-ensure-tunnel connection))
    (should (equal (list connection) started))))

(provide 'herdr-connection-test)
;;; herdr-connection-test.el ends here
