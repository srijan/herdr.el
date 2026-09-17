;;; herdr-term-test.el --- Tests for herdr terminal backends -*- lexical-binding: t; -*-

;;; Commentary:

;; Reconciliation is the whole of the buffer bookkeeping's
;; correctness: which agents need a buffer, and which buffers outlived
;; their pane.  It is a pure function so it can be tested without
;; ghostel, a PTY, or a server.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-term)
(require 'herdr-test-helper)

(defun herdr-term-test--state (&rest panes)
  (herdr-state-from-snapshot `((panes . ,panes))))

(defun herdr-term-test--pane (id &optional agent)
  `((pane_id . ,id) (agent . ,agent) (agent_status . "idle")
    (workspace_id . "w1") (terminal_title_stripped . ,(or agent "shell"))))

(ert-deftest herdr-term-reaps-buffers-whose-pane-is-gone ()
  (let ((state (herdr-term-test--state
                (herdr-term-test--pane "w1:p1" "claude"))))
    (should (equal '(:buf9)
                   (herdr-term-buffers-to-reap state '(("w1:p1" . :buf1)
                                                       ("w1:p9" . :buf9)))))))

(ert-deftest herdr-term-reaps-only-when-the-pane-is-gone ()
  "A pane losing its agent keeps its buffer; only a closed pane is reaped."
  (let ((state (herdr-term-test--state (herdr-term-test--pane "w1:p1"))))
    (should (equal '(:buf9)
                   (herdr-term-buffers-to-reap state '(("w1:p1" . :buf1)
                                                       ("w1:p9" . :buf9)))))))

(ert-deftest herdr-term-reaps-nothing-when-nothing-changed ()
  (let ((state (herdr-term-test--state
                (herdr-term-test--pane "w1:p1" "claude"))))
    (should (null (herdr-term-buffers-to-reap state '(("w1:p1" . :buf1)))))))

;;; Buffer naming: name first, workspace fallback

(ert-deftest herdr-term-buffer-name-prefers-the-agent-name ()
  "A name set through `agent.rename' is used verbatim, kind and workspace
notwithstanding — it is the one thing someone chose to call this pane."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w7") (label . ".emacs.d"))))
                   (panes . (((pane_id . "w7:p5") (agent . "claude")
                              (workspace_id . "w7"))))
                   (agents . (((pane_id . "w7:p5") (agent . "claude")
                               (name . "emacs-herdr")))))))
         (pane (herdr-state-pane state "w7:p5")))
    (should (equal "*herdr: emacs-herdr*"
                   (herdr-term-buffer-name state pane)))))

(ert-deftest herdr-term-buffer-name-uses-the-pane-label ()
  "A pane carrying a `label' — what `pane.rename' writes, and what a
plugin pane is seated with — is named by it rather than by KIND@WORKSPACE.
This is how the Lantern chat reads as `*herdr: Lantern*'."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w16")
                                   (label . "lantern"))))
                   (panes . (((pane_id . "w16:p2") (agent . "claude")
                              (label . "Lantern")
                              (workspace_id . "w16")))))))
         (pane (herdr-state-pane state "w16:p2")))
    (should (equal "*herdr: Lantern*"
                   (herdr-term-buffer-name state pane)))))

(ert-deftest herdr-term-buffer-name-prefers-the-agent-name-over-the-label ()
  "`agent.rename' outranks `pane.rename'.  Below it rather than above so
nobody who renames agents today sees their buffers change."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w16") (label . "lantern"))))
                   (panes . (((pane_id . "w16:p2") (agent . "claude")
                              (label . "Lantern") (workspace_id . "w16"))))
                   (agents . (((pane_id . "w16:p2") (agent . "claude")
                               (name . "lantern-chat")))))))
         (pane (herdr-state-pane state "w16:p2")))
    (should (equal "*herdr: lantern-chat*"
                   (herdr-term-buffer-name state pane)))))

(ert-deftest herdr-term-buffer-name-falls-back-to-kind-at-workspace ()
  "An unnamed agent reads as KIND@WORKSPACE, not an opaque pane id."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "wG") (label . "srijan.ch"))))
                   (panes . (((pane_id . "wG:p3") (agent . "claude")
                              (workspace_id . "wG")))))))
         (pane (herdr-state-pane state "wG:p3")))
    (should (equal "*herdr: claude@srijan.ch*"
                   (herdr-term-buffer-name state pane)))))

(ert-deftest herdr-term-buffer-name-reads-a-plain-shell-naturally ()
  "A plain pane carries no `agent' field at all — `herdr terminal attach'
needs no detected agent — so the kind fallback of `shell' is what makes
it read as `shell@WORKSPACE' rather than `agent@WORKSPACE'."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w7") (label . ".emacs.d"))))
                   (panes . (((pane_id . "w7:p9")
                              (workspace_id . "w7")))))))
         (pane (herdr-state-pane state "w7:p9")))
    (should (equal "*herdr: shell@.emacs.d*"
                   (herdr-term-buffer-name state pane)))))

(ert-deftest herdr-term-buffer-name-falls-back-to-the-workspace-id ()
  "A workspace missing from STATE altogether — so its label is unknowable
— still yields a readable name, not a bare `KIND@'."
  (let* ((state (herdr-state-from-snapshot
                 '((panes . (((pane_id . "w9:p1") (agent . "claude")
                              (workspace_id . "w9")))))))
         (pane (herdr-state-pane state "w9:p1")))
    (should (equal "*herdr: claude@w9*"
                   (herdr-term-buffer-name state pane)))))

(ert-deftest herdr-term-buffer-name-has-a-sensible-floor ()
  "Neither a kind nor a workspace must not produce `*herdr: @*'."
  (should (equal "*herdr: shell*"
                 (herdr-term-buffer-name
                  (herdr-state-empty) '((pane_id . "p1"))))))

(ert-deftest herdr-term-buffer-name-collides-for-two-unnamed-siblings ()
  "This collision is the point, not a bug in this function: two unnamed
same-kind panes in one workspace are expected to compute the same wanted
name here.  Uniquifying it is `herdr-term--attach-1's job, tested below,
not this pure naming function's."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w7") (label . ".emacs.d"))))
                   (panes . (((pane_id . "w7:p2") (agent . "claude")
                              (workspace_id . "w7"))
                             ((pane_id . "w7:p5") (agent . "claude")
                              (workspace_id . "w7")))))))
         (one (herdr-state-pane state "w7:p2"))
         (two (herdr-state-pane state "w7:p5")))
    (should (equal (herdr-term-buffer-name state one)
                   (herdr-term-buffer-name state two)))))

(ert-deftest herdr-term-unique-buffer-name-avoids-a-collision ()
  "The hazard: `get-buffer-create' on a colliding wanted name returns a
different pane's existing buffer.  `herdr-term--unique-buffer-name'
is what `herdr-term--attach-1' creates buffers under instead, precisely
to make that impossible."
  (let* ((existing (generate-new-buffer "*herdr: claude@.emacs.d*"))
         (state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w7") (label . ".emacs.d"))))
                   (panes . (((pane_id . "w7:p5") (agent . "claude")
                              (workspace_id . "w7")))))))
         (pane (herdr-state-pane state "w7:p5")))
    (unwind-protect
        (let* ((name (herdr-term--unique-buffer-name state pane))
               (created (get-buffer-create name)))
          (unwind-protect
              (progn
                (should-not (equal "*herdr: claude@.emacs.d*" name))
                (should-not (eq existing created)))
            (kill-buffer created)))
      (kill-buffer existing))))


;;; Attaching, which nothing used to test

(defmacro herdr-term-test--attaching (exec &rest body)
  "Run BODY with `ghostel-exec' bound to EXEC and no ghostel loaded.
`ghostel-mode' and the display call are stubbed too: the first needs the
package, the second a window, and neither is what these assert."
  (declare (indent 1) (debug t))
  `(let ((herdr-term--buffers nil))
     (cl-letf (((symbol-function 'ghostel-exec) ,exec)
               ((symbol-function 'ghostel-mode) #'ignore)
               ((symbol-function 'herdr-term--show) #'ignore))
       ,@body)))

(ert-deftest herdr-term-attach-registers-the-buffer-it-started ()
  "The registry is what teardown, reap and `herdr-term-buffer-p' all read.
A buffer that started but never reached it is invisible to every one."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (agent . "claude") (terminal_id . "t7")))))))
        started)
    (herdr-term-test--attaching
        (lambda (buffer _program &optional args) (setq started (cons buffer args)) t)
      (let ((buffer (herdr-term--attach (herdr-current-connection)
                     state (herdr-state-pane state "w1:p1"))))
        (unwind-protect
            (progn
              (should (buffer-live-p buffer))
              (should (equal buffer (car started)))
              (should (equal '("terminal" "attach" "t7") (cdr started)))
              (should (equal buffer (herdr-term-buffer-for-pane (herdr-current-connection) "w1:p1"))))
          (kill-buffer buffer))))))

(ert-deftest herdr-term-attach-takes-the-terminal-only-when-asked ()
  "Attachment is exclusive per pane, so `--takeover' is the whole
difference between joining a pane and taking it.  Passing it by accident
would stop another client mid-session, so the flag is asserted rather
than assumed."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (terminal_id . "t7")))))))
        started)
    (herdr-term-test--attaching
        (lambda (_buffer _program &optional args) (setq started args) t)
      (let ((buffer (herdr-term--attach (herdr-current-connection) state
                                        (herdr-state-pane state "w1:p1") t)))
        (unwind-protect
            (should (equal '("terminal" "attach" "t7" "--takeover") started))
          (kill-buffer buffer)))
      (let ((buffer (herdr-term--attach (herdr-current-connection) state
                                        (herdr-state-pane state "w1:p1"))))
        (unwind-protect
            (should (equal '("terminal" "attach" "t7") started))
          (kill-buffer buffer))))))

(defun herdr-term-test--client-ended (text)
  "Return what `herdr-term--client-ended' says for a client that left TEXT."
  (let ((buffer (generate-new-buffer " *herdr-exit-test*"))
        (said nil))
    (unwind-protect
        (herdr-test-with-state
            (:cache (herdr-state-from-snapshot
                     '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")))))))
          (let ((herdr-term--buffers
                 (herdr-test-term-buffers (list (cons "w1:p1" buffer)))))
            (with-current-buffer buffer (insert text))
            (cl-letf (((symbol-function 'message)
                       (lambda (format &rest args)
                         (setq said (apply #'format-message format args)))))
              (herdr-term--client-ended buffer "exited abnormally with code 1"))
            said))
      (kill-buffer buffer))))

(ert-deftest herdr-term-client-end-tells-a-held-pane-from-a-closed-one ()
  "herdr exits 1 whichever way an attach ends.

Measured against 0.9.0: refused, taken over, and the pane closing under
a healthy attach all exit 1, so the status cannot tell them apart and
the text is the only signal there is.  Without this the third case and
the first look identical - a buffer that appears and vanishes - which is
the whole defect."
  (let ((held (herdr-term-test--client-ended
               (concat "herdr: server shut down: terminal attach failed: "
                       "terminal term_abc123 already has an attached client; "
                       "retry with --takeover\n")))
        (closed (herdr-term-test--client-ended "user@host /tmp %\n")))
    (should (string-match-p "w1:p1" held))
    (should (string-match-p "attached elsewhere" held))
    ;; A pane that simply closed says nothing, as it always did.
    (should-not closed)))

(ert-deftest herdr-term-client-end-reads-a-wrapped-refusal ()
  "A refusal wraps, and a hard wrap breaks a word rather than a space.

The buffer is a terminal grid, so the width of the window decides where
herdr's 130-character refusal breaks.  At 80 columns the phrase worth
matching is split across two rows, which a plain search misses - and a
narrow window is the ordinary case, not the awkward one."
  (let* ((line (concat "herdr: server shut down: terminal attach failed: "
                       "terminal term_abc1234567890 already has an attached "
                       "client; retry with --takeover"))
         (wrapped (mapconcat #'identity
                             (seq-partition line 80)
                             "\n")))
    (should-not (string-search "already has an attached client" wrapped))
    (should (string-match-p "attached elsewhere"
                            (herdr-term-test--client-ended wrapped)))))

(defconst herdr-term-test--source-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "The package root, found from this file rather than from `default-directory'.")

(ert-deftest herdr-term-desktop-handler-is-registered-by-the-autoloads ()
  "The registration has to be there before this file is loaded.

A desktop is read from `emacs-startup-hook', and `use-package' defers
this package, so nothing has called a herdr command yet: a registration
that waits for herdr-term.el to load is not there when desktop looks for
it, ghostel's handler answers instead, and every herdr buffer is skipped.
It shipped that way once, and the symptom was \"2 failed to restore\".

Nothing in-process can catch that - these tests load the file, which is
exactly what the real startup does not do - so the cookie is what gets
asserted."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "herdr-term.el" herdr-term-test--source-directory))
    (goto-char (point-min))
    (should (re-search-forward
             (rx bol ";;;###autoload" "\n"
                 "(with-eval-after-load " (? "'") "ghostel" (* space) "\n"
                 (* space) "(add-to-list " (? "'") "desktop-buffer-mode-handlers")
             nil t))))

(ert-deftest herdr-term-desktop-saves-the-pane-not-the-process ()
  "A pane outlives the Emacs showing it, so the pane is what to write down.

ghostel saves a directory and an identity, which is right for a shell
and useless for an attach: the terminal is on the server, and the only
part of it a later Emacs can use is which pane it was.  The connection
goes down as a NAME - a connection is a live socket and a process, and
the name is the part that still means something tomorrow."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (terminal_id . "t7"))))))))
    (herdr-test-with-state (:cache state)
      (herdr-term-test--attaching (lambda (&rest _) t)
        (let ((buffer (herdr-term--attach (herdr-current-connection) state
                                          (herdr-state-pane state "w1:p1"))))
          (unwind-protect
              (with-current-buffer buffer
                (should (eq #'herdr-term-desktop-save desktop-save-buffer))
                (should (equal (list 'herdr
                                     (herdr-connection-name
                                      (herdr-current-connection))
                                     "w1:p1")
                               (herdr-term-desktop-save "/tmp"))))
            (kill-buffer buffer)))))))

(ert-deftest herdr-term-desktop-restore-hands-other-shells-to-ghostel ()
  "This handler sits in front of ghostel's for the whole mode.

Both entries key on `ghostel-mode', and desktop takes the first `assq'
match, so herdr answers for every ghostel buffer in the session -
including the ones that are nothing to do with herdr.  Keeping them
would break shells this package never opened."
  (let (passed-on)
    (cl-letf (((symbol-function 'ghostel-desktop-restore-buffer)
               (lambda (file name misc) (setq passed-on (list file name misc)) 'ghostel)))
      ;; ghostel's own shape: (DIRECTORY IDENTITY).
      (should (eq 'ghostel (herdr-term-desktop-restore
                            nil "*shell*" '("/tmp" ((instance . 1))))))
      (should (equal '(nil "*shell*" ("/tmp" ((instance . 1)))) passed-on)))))

(ert-deftest herdr-term-desktop-restore-reattaches-a-pane-that-is-still-there ()
  "The whole point: the pane is still on the server, so pick it up again."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (terminal_id . "t7"))))))))
    (herdr-test-with-state (:cache state)
      (herdr-term-test--attaching (lambda (&rest _) t)
        (let* ((name (herdr-connection-name (herdr-current-connection)))
               (buffer (herdr-term-desktop-restore
                        nil "*herdr: w1:p1*" (list 'herdr name "w1:p1"))))
          (unwind-protect
              (progn
                (should (buffer-live-p buffer))
                (should (equal buffer (herdr-term-buffer-for-pane
                                       (herdr-current-connection) "w1:p1"))))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest herdr-term-desktop-restore-declines-what-it-cannot-reach ()
  "Answers nil rather than signalling, twice over.

A pane that has closed since the desktop was written is not a failure -
desktop reports a handler that signals as a buffer it could not load.
Neither is a connection that is not up: a desktop is read at startup as
well as by hand, and an unattended restore must not start a server."
  (let ((state (herdr-state-from-snapshot '((panes . ())))))
    (herdr-test-with-state (:cache state)
      (herdr-term-test--attaching (lambda (&rest _) t)
        (let ((name (herdr-connection-name (herdr-current-connection))))
          ;; Registered connection, pane gone.
          (should-not (herdr-term-desktop-restore
                       nil "*herdr: w1:p1*" (list 'herdr name "w1:p1")))
          ;; Unknown connection, and nothing may be started to find out.
          (cl-letf (((symbol-function 'herdr-server-live-p)
                     (lambda (&rest _) (error "must not probe a named server"))))
            (should-not (herdr-term-desktop-restore
                         nil "*herdr: w1:p1*"
                         '(herdr "a-server-that-is-not-here" "w1:p1")))))))))

(ert-deftest herdr-term-desktop-restore-connects-only-to-a-server-already-up ()
  "A desktop read at startup finds nothing connected yet.

So a restore has to be able to connect - and only to a server that is
already answering.  Starting one is what an unattended restore must not
do, and connecting to a dead socket is what makes it block instead."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (terminal_id . "t7"))))))))
    (herdr-term-test--attaching (lambda (&rest _) t)
      ;; Running: connect, then reattach.
      (let ((herdr-connections nil) connected)
        (cl-letf (((symbol-function 'herdr-server-live-p) (lambda (&rest _) t))
                  ((symbol-function 'herdr-connect)
                   (lambda (name path)
                     (setq connected (list name path))
                     (let ((connection (herdr-connection-local)))
                       (setf (herdr-connection-cache connection) state)
                       (herdr-connection-register connection)))))
          (let ((buffer (herdr-term-desktop-restore
                         nil "*herdr: w1:p1*" '(herdr "local" "w1:p1"))))
            (unwind-protect
                (progn
                  (should (equal (list "local" herdr-socket-path) connected))
                  (should (buffer-live-p buffer)))
              (when (buffer-live-p buffer) (kill-buffer buffer))))))
      ;; Not running: no connect, no buffer, no error.
      (let ((herdr-connections nil) connected)
        (cl-letf (((symbol-function 'herdr-server-live-p) (lambda (&rest _) nil))
                  ((symbol-function 'herdr-connect)
                   (lambda (&rest args) (setq connected args) nil)))
          (should-not (herdr-term-desktop-restore
                       nil "*herdr: w1:p1*" '(herdr "local" "w1:p1")))
          (should-not connected))))))

(ert-deftest herdr-term-attach-leaves-nothing-behind-when-the-client-fails ()
  "The defect this test exists for: a failing start used to be able to
leave a live, displayed buffer that never reached the registry, so
teardown could not kill it and the next select built a second buffer for
the same pane."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (agent . "claude") (terminal_id . "t7")))))))
        (before (buffer-list)))
    (herdr-term-test--attaching
        (lambda (&rest _) (error "ghostel: no such program"))
      (should-error (herdr-term--attach (herdr-current-connection) state (herdr-state-pane state "w1:p1")))
      (should (null herdr-term--buffers))
      (should (null (seq-difference (buffer-list) before))))))

(ert-deftest herdr-term-attach-refuses-a-pane-the-server-is-too-old-for ()
  "A pane with no `terminal_id' cannot be attached at all, and the
argv is built before the buffer is committed to, so nothing is created
and nothing is displayed."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (agent . "claude")))))))
        (before (buffer-list))
        shown)
    (let ((herdr-term--buffers nil))
      (cl-letf (((symbol-function 'ghostel-mode) #'ignore)
                ((symbol-function 'ghostel-exec)
                 (lambda (&rest _) (error "should not be reached")))
                ((symbol-function 'herdr-term--show)
                 (lambda (&rest _) (setq shown t))))
        (should-error (herdr-term--attach (herdr-current-connection) state (herdr-state-pane state "w1:p1"))
                      :type 'user-error)
        (should-not shown)
        (should (null herdr-term--buffers))
        (should (null (seq-difference (buffer-list) before)))))))


(ert-deftest herdr-term-attach-displays-the-buffer-before-starting-the-client ()
  "ghostel sizes the PTY from a displayed window and paints nothing into
a zero-sized one, so the order is load-bearing rather than incidental."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (agent . "claude") (terminal_id . "t7")))))))
        order)
    (let ((herdr-term--buffers nil))
      (cl-letf (((symbol-function 'ghostel-mode) #'ignore)
                ((symbol-function 'herdr-term--show)
                 (lambda (&rest _) (push 'shown order)))
                ((symbol-function 'ghostel-exec)
                 (lambda (&rest _) (push 'started order))))
        (let ((buffer (herdr-term--attach (herdr-current-connection) state (herdr-state-pane state "w1:p1"))))
          (unwind-protect
              (should (equal '(shown started) (nreverse order)))
            (kill-buffer buffer)))))))

(ert-deftest herdr-term-attach-cleans-up-when-any-step-fails ()
  "Not only the exec: a display action that signals used to leave the same
unregistered live buffer through a different door.

A pane whose cwd is not a string used to be a third door, by reaching
`file-directory-p' with a number.  It is validated now instead of
signalling: a malformed field is a directory the buffer cannot follow,
not a reason to refuse the terminal."
  (let ((state (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                             (agent . "claude") (terminal_id . "t7")
                             (cwd . 42)))))))
        (before (buffer-list)))
    (let ((herdr-term--buffers nil))
      (cl-letf (((symbol-function 'ghostel-mode) #'ignore)
                ((symbol-function 'ghostel-exec) #'ignore)
                ((symbol-function 'herdr-term--show) #'ignore))
        ;; A cwd of 42 names no directory, and the attach carries on.
        (let ((buffer (herdr-term--attach (herdr-current-connection) state
                                          (herdr-state-pane state "w1:p1"))))
          (should (buffer-live-p buffer))
          (should (equal 1 (length herdr-term--buffers)))
          (kill-buffer buffer))
        (setq herdr-term--buffers nil))
      (cl-letf (((symbol-function 'ghostel-mode) #'ignore)
                ((symbol-function 'ghostel-exec) #'ignore)
                ((symbol-function 'herdr-term--show)
                 (lambda (&rest _) (error "display-buffer: no window"))))
        (should-error (herdr-term--attach (herdr-current-connection) state (herdr-state-pane state "w1:p1")))
        (should (null herdr-term--buffers))
        (should (null (seq-difference (buffer-list) before)))))))

;;; Directory tracking

(ert-deftest herdr-term-set-directory-follows-the-pane ()
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (setq default-directory "/")
      (herdr-term--set-directory (herdr-current-connection) buffer '((cwd . "/tmp")))
      (should (equal "/tmp/" default-directory)))))

(ert-deftest herdr-term-set-directory-ignores-a-missing-directory ()
  "A stale cwd must not leave `default-directory' pointing at nothing."
  (with-temp-buffer
    (setq default-directory "/")
    (herdr-term--set-directory (herdr-current-connection) (current-buffer)
                               '((cwd . "/no/such/place/anywhere")))
    (should (equal "/" default-directory))))

;;; Directory sync

(ert-deftest herdr-term-sync-directories-is-per-buffer ()
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
           '((panes . (((pane_id . "w1:p1") (agent . "claude") (cwd . "/tmp"))
                       ((pane_id . "w1:p2") (agent . "codex") (cwd . "/usr")))))))(let* ((herdr-term-track-directory t) (one (generate-new-buffer " *pane1*")) (two (generate-new-buffer " *pane2*")) (herdr-term--buffers (herdr-test-term-buffers (list (cons "w1:p1" one) (cons "w1:p2" two)))))
    (unwind-protect
        (progn
          (herdr-term--sync-directories (herdr-current-connection))
          (should (equal "/tmp/" (buffer-local-value 'default-directory one)))
          (should (equal "/usr/" (buffer-local-value 'default-directory two))))
      (kill-buffer one) (kill-buffer two)))))

(ert-deftest herdr-term-sync-directories-respects-the-off-switch ()
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
           '((panes . (((pane_id . "w1:p1") (cwd . "/tmp")))))))(let* ((herdr-term-track-directory nil) (buffer (get-buffer-create "*herdr-off-switch*")) (herdr-term--buffers (herdr-test-term-buffers (list (cons "w1:p1" buffer)))))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq default-directory "/"))
          (herdr-term--sync-directories (herdr-current-connection))
          (should (equal "/" (buffer-local-value 'default-directory buffer))))
      (kill-buffer buffer)))))

;;; Buffers must follow their pane's identity

(ert-deftest herdr-term-renames-a-buffer-whose-pane-gained-an-agent ()
  "A shell pane that herdr later names as an agent keeps its buffer,
since the attachment is still valid, so the name is corrected in place."
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
           '((workspaces . (((workspace_id . "w1") (label . ".emacs.d"))))
             (panes . (((pane_id . "w1:p1") (agent . "claude")
                        (workspace_id . "w1")))))))(let* ((buffer (generate-new-buffer "*herdr: shell@.emacs.d*")) (herdr-term--buffers (herdr-test-term-buffers (list (cons "w1:p1" buffer)))))
    (unwind-protect
        (progn
          (herdr-term--rename-stale-buffers (herdr-current-connection))
          (should (equal "*herdr: claude@.emacs.d*" (buffer-name buffer))))
      (kill-buffer buffer)))))

(ert-deftest herdr-term-leaves-a-correctly-named-buffer-alone ()
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
           '((workspaces . (((workspace_id . "w1") (label . ".emacs.d"))))
             (panes . (((pane_id . "w1:p1") (agent . "claude")
                        (workspace_id . "w1")))))))(let* ((buffer (generate-new-buffer "*herdr: claude@.emacs.d*")) (herdr-term--buffers (herdr-test-term-buffers (list (cons "w1:p1" buffer)))))
    (unwind-protect
        (progn
          (herdr-term--rename-stale-buffers (herdr-current-connection))
          (should (equal "*herdr: claude@.emacs.d*" (buffer-name buffer))))
      (kill-buffer buffer)))))

(ert-deftest herdr-term-rename-stale-buffers-does-not-thrash-a-collision ()
  "The subtle failure mode: a buffer holding a uniquified name only
because another pane's buffer already has its wanted base name must not
be renamed on every sync.

Checking the resulting name after one call is not enough to catch this:
`rename-buffer' just hands the same `...<2>' suffix right back once the
collision persists, so a thrashing implementation still looks stable
that way.  What must not happen is `rename-buffer' being called at all
for a buffer that already carries an acceptable name — repeating that
from every `herdr-term--on-state-change' would be a rename loop hiding
behind an unchanging buffer list."
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
           '((workspaces . (((workspace_id . "w7") (label . ".emacs.d"))))
             (panes . (((pane_id . "w7:p2") (agent . "claude")
                        (workspace_id . "w7"))
                       ((pane_id . "w7:p5") (agent . "claude")
                        (workspace_id . "w7")))))))(let* ((first (generate-new-buffer "*herdr: claude@.emacs.d*")) (second (generate-new-buffer "*herdr: claude@.emacs.d*")) (herdr-term--buffers (herdr-test-term-buffers (list (cons "w7:p2" first)
                                          (cons "w7:p5" second)))))
    (unwind-protect
        (progn
          (should (equal "*herdr: claude@.emacs.d*<2>" (buffer-name second)))
          (let ((rename-calls 0))
            (cl-letf* ((real-rename-buffer (symbol-function 'rename-buffer))
                       ((symbol-function 'rename-buffer)
                        (lambda (&rest args)
                          (setq rename-calls (1+ rename-calls))
                          (apply real-rename-buffer args))))
              (dotimes (_ 3) (herdr-term--rename-stale-buffers (herdr-current-connection))))
            (should (= 0 rename-calls))))
      (kill-buffer first) (kill-buffer second)))))

;;; The pane this Emacs is running in

(ert-deftest herdr-term-refuses-to-attach-to-its-own-pane ()
  "Attaching to the pane drawing the frame renders Emacs inside itself.

herdr exports HERDR_PANE_ID into every pane it starts, so an Emacs
launched from one can be asked to go to that very pane - the dashboard
lists it like any other, and RET on the row is a reasonable mistake."
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
                                  '((panes . (((pane_id . "w1:p1")
                                               (agent . "claude")))))))
    (let* ((connection (herdr-current-connection))
           (herdr-self-pane-id "w1:p1")
           (herdr-self-socket-path (herdr-connection-socket-path connection)))
      (should-error (herdr-term-select-pane connection "w1:p1")
                    :type 'user-error)
      ;; Every other pane on that same server is unaffected.
      (should-not (herdr-self-pane-p connection "w1:p2")))))

(ert-deftest herdr-self-pane-needs-the-server-to-match-not-just-the-id ()
  "Ids are per-server counters, so the id alone names a pane everywhere.

Two machines each hold a `w1:p1'.  Refusing both would make the machine
this Emacs happens to sit on able to veto a pane on every other one."
  (let ((herdr-self-pane-id "w1:p1")
        (herdr-self-socket-path "/tmp/herdr-mine.sock"))
    (let ((mine (herdr-connection--make :name "mine"
                                        :socket-path "/tmp/herdr-mine.sock"))
          (other (herdr-connection--make :name "other"
                                         :socket-path "/tmp/herdr-other.sock"))
          (remote (herdr-connection--make :name "shadow"
                                          :socket-path "/tmp/herdr-mine.sock"
                                          :ssh-target "shadow")))
      (should (herdr-self-pane-p mine "w1:p1"))
      (should-not (herdr-self-pane-p other "w1:p1"))
      ;; A forward binds its local end wherever it likes, so a remote
      ;; connection can wear the same socket path and still not be us.
      (should-not (herdr-self-pane-p remote "w1:p1")))))

(ert-deftest herdr-self-pane-is-nothing-outside-a-herdr-pane ()
  "An Emacs started from the dock has no HERDR_PANE_ID, and everything
reading one has to degrade to doing nothing rather than to guessing."
  (let ((herdr-self-pane-id nil)
        (herdr-self-socket-path nil))
    (should-not (herdr-self-pane-p
                 (herdr-connection--make :name "local"
                                         :socket-path "/tmp/herdr.sock")
                 "w1:p1"))))

;;; Starting herdr must not rearrange windows

(ert-deftest herdr-term-select-pane-does-not-split-the-frame ()
  "Going to a pane reuses the current window; splitting is the user's
business, not a side effect of navigation."
  (herdr-test-with-state (:cache (herdr-state-from-snapshot
           '((panes . (((pane_id . "w1:p1") (agent . "claude")))))))(let* ((target (generate-new-buffer " *target*")) (herdr-term--buffers (herdr-test-term-buffers (list (cons "w1:p1" target)))))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((before (length (window-list))))
            (herdr-term-select-pane (herdr-current-connection) "w1:p1")
            (should (eq target (current-buffer)))
            (should (= before (length (window-list))))))
      (kill-buffer target)))))

;;; One display knob, honoured by every path

(ert-deftest herdr-term-show-honours-the-display-action ()
  (let* ((buffer (generate-new-buffer " *shown*"))
         (seen nil)
         (herdr-display-action '(my-action)))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (buf action &rest _) (setq seen (cons buf action)))))
          (herdr-term--show buffer)
          (should (eq buffer (car seen)))
          (should (equal '(my-action) (cdr seen))))
      (kill-buffer buffer))))

(ert-deftest herdr-display-action-defaults-to-reusing-the-window ()
  "The default must not delete the user's other windows."
  (should (equal '((display-buffer-reuse-window display-buffer-same-window))
                 (default-value 'herdr-display-action))))

;;; Bootstrap must outlive Emacs

(ert-deftest herdr-term-bootstrap-server-orphans-the-server ()
  "`herdr server' blocks and has no detach flag, so an Emacs child would
die with Emacs.  The spawn must go through a shell and end in `&'."
  (let (command)
    (cl-letf (((symbol-function 'call-process)
               (lambda (program &rest args)
                 (setq command (cons program (nthcdr 4 args)))
                 0))
              ((symbol-function 'herdr-server-live-p) (lambda (_connection) t)))
      (herdr-term--bootstrap-server (herdr-current-connection))
      (should (equal "sh" (car command)))
      (should (member "-c" (list (nth 1 command) "-c")))
      (let ((script (car (last command))))
        (should (string-match-p " server " script))
        (should (string-suffix-p "&" script))))))

(ert-deftest herdr-term-bootstrap-server-refuses-a-remote-connection ()
  "A remote server lives on the far host.  Starting one here would bring
up a local server the tunnel does not point at and report success."
  (let ((remote (herdr-connection--make :name "shadow" :ssh-target "shadow"))
        (spawned nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _) (setq spawned t) 0)))
      (should-error (herdr-term--bootstrap-server remote))
      (should-not spawned))))

(ert-deftest herdr-term-bootstrap-server-reports-what-the-server-said ()
  "A timeout with no reason is the failure the ghostel buffer used to
show.  The log the spawn redirects to is what replaces it."
  (let ((herdr-server-start-timeout 0.01))
    (cl-letf (((symbol-function 'call-process)
               (lambda (_program &rest args)
                 ;; Write into the log the real script redirects to.
                 (let ((script (car (last args))))
                   (should (string-match ">\\([^ ]+\\) 2>&1" script))
                   (write-region "address already in use" nil
                                 (match-string 1 script) nil 'quiet))
                 0))
              ((symbol-function 'herdr-server-live-p) (lambda (_connection) nil)))
      (let ((complaint (cadr (should-error
                              (herdr-term--bootstrap-server
                               (herdr-current-connection))))))
        (should (string-match-p "did not come up" complaint))
        (should (string-match-p "address already in use" complaint))
        (should (string-match-p "brew services" complaint))))))

;;; Timer teardown must cancel, not merely forget

;; Setting the variable to nil is not stopping the timer, and no test
;; that watches the refresh can tell the difference: the repair it
;; reaches is guarded, so a spurious later fire is swallowed and the
;; callback count comes out the same whether or not anything was
;; cancelled.  Measured — dropping the `cancel-timer' call below passed
;; the whole suite.  These assert the cancellation itself.

(ert-deftest herdr-term-cancel-directory-debounce-cancels-the-pending-timer ()
  "Teardown must reach a pending debounce.
Left running it keeps firing at a torn-down backend for the rest of the
session, and the leak is invisible until something it touches is gone."
  (let ((cancelled nil)
        (debounce (run-at-time 3600 nil #'ignore)))
    (unwind-protect
        (let ((herdr-term--directory-debounce-timers (list (cons 1 debounce))))
          (cl-letf (((symbol-function 'cancel-timer)
                     (lambda (timer) (push timer cancelled))))
            (herdr-term--cancel-directory-debounce))
          (should (equal (list debounce) cancelled))
          (should-not herdr-term--directory-debounce-timers))
      (cancel-timer debounce))))

(ert-deftest herdr-term-cancel-directory-debounce-has-nothing-to-cancel-when-idle ()
  "Teardown runs whether or not tracking ever started, so a nil slot must
not be handed to `cancel-timer', which signals on one."
  (let ((herdr-term--directory-debounce-timers nil)
        (cancelled nil))
    (cl-letf (((symbol-function 'cancel-timer)
               (lambda (timer) (push timer cancelled))))
      (herdr-term--cancel-directory-debounce))
    (should-not cancelled)))

(ert-deftest herdr-term-schedule-directory-refresh-cancels-before-it-rearms ()
  "A burst of pane events must coalesce into one refresh, not arm one each."
  (let ((pending (run-at-time 3600 nil #'ignore))
        (cancelled nil))
    (unwind-protect
        (let* ((connection (herdr-current-connection))
               (token (herdr-connection-token connection))
               (herdr-term-track-directory t)
               (herdr-term--directory-debounce-timers (list (cons token pending))))
          (cl-letf (((symbol-function 'cancel-timer)
                     (lambda (timer) (push timer cancelled)))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest _) 'replacement)))
            (herdr-term--schedule-directory-refresh connection))
          (should (equal (list pending) cancelled))
          (should (eq 'replacement
                      (alist-get token herdr-term--directory-debounce-timers))))
      (cancel-timer pending))))

(ert-deftest herdr-term-schedule-directory-refresh-reaches-the-repair ()
  "The debounce must repair the cache, not re-read it.
A `cd' produces no event herdr.el acts on, so a debounce that only
synced buffers would show a directory the cache was never told about,
degrading tracking from the debounce interval to the repair interval."
  (let ((herdr-term-track-directory t)
        (herdr-term--directory-debounce-timers nil)
        (repaired nil)
        (callback nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_delay _repeat fn) (setq callback fn) 'armed))
              ((symbol-function 'herdr-state-repair)
               (lambda (_connection) (setq repaired t))))
      (herdr-term--schedule-directory-refresh (herdr-current-connection))
      (should (eq 'armed (alist-get (herdr-connection-token
                                     (herdr-current-connection))
                                    herdr-term--directory-debounce-timers)))
      (funcall callback)
      (should repaired)
      (should-not (alist-get (herdr-connection-token (herdr-current-connection))
                                 herdr-term--directory-debounce-timers)))))

;;; Teardown must actually tear down

(ert-deftest herdr-term-teardown-kills-every-buffer ()
  "One buffer per pane, and the table has to be emptied with them.  A
stale entry names a dead buffer that reconciliation would count as
already attached."
  (let* ((herdr-state-change-functions (list #'herdr-term--on-state-change))
         (herdr-term--directory-debounce-timers nil)
         (one (generate-new-buffer " *agent-one*"))
         (two (generate-new-buffer " *agent-two*"))
         (herdr-term--buffers (herdr-test-term-buffers (list (cons "w1:p1" one)
                                          (cons "w1:p2" two)))))
    (unwind-protect
        (progn
          (herdr-term-teardown)
          (should-not (buffer-live-p one))
          (should-not (buffer-live-p two))
          (should-not herdr-term--buffers))
      (when (buffer-live-p one) (kill-buffer one))
      (when (buffer-live-p two) (kill-buffer two)))))

(ert-deftest herdr-term-teardown-cancels-a-pending-debounce ()
  "Teardown is the debounce's only canceller now that the poll is gone."
  (let ((debounce (run-at-time 3600 nil #'ignore))
        (cancelled nil))
    (unwind-protect
        (let ((herdr-term--buffers nil)
              (herdr-term--directory-debounce-timers (list (cons 1 debounce))))
          (cl-letf (((symbol-function 'cancel-timer)
                     (lambda (timer) (push timer cancelled))))
            (herdr-term-teardown))
          (should (equal (list debounce) cancelled))
          (should-not (alist-get (herdr-connection-token (herdr-current-connection))
                                 herdr-term--directory-debounce-timers)))
      (cancel-timer debounce))))

(ert-deftest herdr-term-a-reconcile-event-nudges-no-further-repair ()
  "A repair fires \"reconcile\" when it changed something.  Re-arming the
debounce there sent a second repair 0.4s later that found nothing, so
every real change cost two extra round trips on the main thread."
  (let ((herdr-term-track-directory t)
        (herdr-term--buffers nil)
        (herdr-term--directory-debounce-timers nil)
        (armed 0))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (cl-incf armed) 'armed))
              ((symbol-function 'herdr-term--sync-buffers) #'ignore)
              ((symbol-function 'herdr-term--sync-directories) #'ignore))
      (herdr-term--on-state-change (herdr-current-connection) "reconcile")
      (should (zerop armed))
      ;; Every other event still nudges one: a `cd' reaches the cache
      ;; only through a repair.
      (herdr-term--on-state-change (herdr-current-connection) "layout_updated")
      (should (= 1 armed)))))

;;; Directory tracking is a display option and nothing more

(ert-deftest herdr-term-track-directory-off-still-repairs-the-cache ()
  "The coupling this unit removes.
`herdr-term-track-directory' used to gate the only repeating timer in
the package, which drove the only periodic reconcile, so turning off a
display convenience turned off the liveness watchdog and reconnection
with it."
  (herdr-test-with-state (:running t :repairing nil)(let* ((herdr-term-track-directory nil) (reconciled nil))
    (cl-letf (((symbol-function 'herdr-state--reconcile-panes-async)
               (lambda (_connection done)
                 (push 'panes reconciled) (funcall done nil)))
              ((symbol-function 'herdr-state--reconcile-workspaces-async)
               (lambda (_connection done)
                 (push 'workspaces reconciled) (funcall done nil))))
      (herdr-state-repair (herdr-current-connection))
      (should (equal '(workspaces panes) reconciled))))))

(ert-deftest herdr-term-server-live-p-is-a-bounded-probe ()
  "A liveness ping answered in milliseconds by a healthy server must
not be able to cost ten seconds against a hung one: it runs in the
startup loop and before every start, where the full timeout added up
to a forty-second frozen startup."
  (let ((herdr-rpc-timeout 10.0)
        (herdr-rpc-background-timeout 2.0)
        (seen nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (&rest _) (setq seen herdr-rpc-timeout) '((ok . t)))))
      (should (herdr-server-live-p (herdr-current-connection)))
      (should (equal 2.0 seen)))))


;;; Belonging to the project

(ert-deftest herdr-term-buffer-p-answers-from-the-registry ()
  "The major mode cannot be the test: a herdr terminal is a `ghostel-mode'
buffer like any ghostel shell, and only herdr knows which are its panes.
It answers for a buffer whose pane has gone away too, which is a buffer
to clean up rather than one to protect."
  (let* ((mine (generate-new-buffer " *pane*"))
         (theirs (generate-new-buffer " *other*"))
         (herdr-term--buffers (herdr-test-term-buffers (list (cons "w1:p1" mine))))
         (herdr-connections (herdr-test-connections (herdr-test-connection (herdr-state-from-snapshot nil)))))
    (unwind-protect
        (progn
          (should (herdr-term-buffer-p mine))
          (should-not (herdr-term-buffer-p theirs))
          (should-not (herdr-term-pane-for-buffer mine)))
      (kill-buffer mine)
      (kill-buffer theirs))))

(ert-deftest herdr-term-buffers-are-killed-with-the-project ()
  "`project-kill-buffers' counted herdr's terminals and left them standing:
they answer to `project-buffers' through `default-directory', and no
default condition matches one.  Asserted both ways, because a test that
only kills would pass without the registration doing anything."
  (require 'project)
  (let* ((root "/tmp/herdr-project-test/")
         (buffer (generate-new-buffer "*herdr: claude@herdr-project-test*"))
         (herdr-term--buffers (herdr-test-term-buffers (list (cons "w1:p1" buffer))))
         (project (cons 'transient root)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq default-directory root)
            (setq major-mode 'ghostel-mode))
          ;; Without herdr's own clause, however this file was loaded:
          ;; requiring project.el registers it, and another test may have.
          ;; Pinned through `project-current' rather than passed, so the
          ;; test says which project it means on every supported version.
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) project)))
            (let ((project-kill-buffer-conditions
                   (remq #'herdr-term-buffer-p project-kill-buffer-conditions)))
              (project-kill-buffers t)
              (should (buffer-live-p buffer))
              (herdr-term--register-project)
              (project-kill-buffers t)
              (should-not (buffer-live-p buffer)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest herdr-term-registers-itself-when-project-loads ()
  "The registration is a load-time side effect.  Tests that call the helper
themselves pass with the `with-eval-after-load' form deleted, so this one
asks the loaded world instead."
  (require 'project)
  (should (memq #'herdr-term-buffer-p project-kill-buffer-conditions)))

(ert-deftest herdr-term-project-registration-cannot-break-loading ()
  "Unbound and restored rather than stubbed: `boundp' is what the guard
asks, and project.el's variables are not a contract."
  (require 'project)
  (let ((saved project-kill-buffer-conditions))
    (unwind-protect
        (progn
          (makunbound 'project-kill-buffer-conditions)
          (should-not (herdr-term--register-project)))
      (setq project-kill-buffer-conditions saved)))
  (let ((project-kill-buffer-conditions '(buffer-file-name)))
    (herdr-term--register-project)
    (should (memq #'herdr-term-buffer-p project-kill-buffer-conditions))
    ;; Appended, so herdr never outranks a condition the user put first.
    (should (equal 'buffer-file-name (car project-kill-buffer-conditions)))))

;;; Two servers can each issue the same id

(ert-deftest herdr-term-a-colliding-pane-id-gets-a-buffer-each ()
  "Ids are per-server counters, so two machines may each hold a `w1:p1'.
One registry keyed by the bare id would hand the second connection the
first one's buffer — two panes sharing one terminal, on different
machines."
  (let* ((one (herdr-test-connection))
         (two (herdr-test-connection))
         (snapshot '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                                (agent . "claude") (terminal_id . "t1"))))))
         (state (herdr-state-from-snapshot snapshot)))
    (setf (herdr-connection-cache one) state
          (herdr-connection-cache two) state)
    (herdr-term-test--attaching (lambda (&rest _) t)
      (let (buffers)
        (unwind-protect
            (let ((a (herdr-term--attach one state
                                         (herdr-state-pane state "w1:p1")))
                  (b (herdr-term--attach two state
                                         (herdr-state-pane state "w1:p1"))))
              (setq buffers (list a b))
              (should (buffer-live-p a))
              (should (buffer-live-p b))
              (should-not (eq a b))
              (should (eq a (herdr-term-buffer-for-pane one "w1:p1")))
              (should (eq b (herdr-term-buffer-for-pane two "w1:p1")))
              ;; Each buffer knows whose pane it is showing.
              (should (eq one (buffer-local-value 'herdr-buffer-connection a)))
              (should (eq two (buffer-local-value 'herdr-buffer-connection b))))
          (dolist (buffer buffers)
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest herdr-term-tearing-down-one-connection-leaves-the-other ()
  "Stopping one connection used to reap every terminal there was, because
the registry had no way to say whose a buffer was."
  (let* ((one (herdr-test-connection))
         (two (herdr-test-connection))
         (mine (generate-new-buffer " *one*"))
         (theirs (generate-new-buffer " *two*")))
    (unwind-protect
        (let ((herdr-term--buffers
               (list (cons (herdr-term--key one "w1:p1") mine)
                     (cons (herdr-term--key two "w1:p1") theirs))))
          (herdr-term-teardown one)
          (should-not (buffer-live-p mine))
          (should (buffer-live-p theirs))
          (should (eq theirs (herdr-term-buffer-for-pane two "w1:p1"))))
      (dolist (buffer (list mine theirs))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest herdr-term-a-reap-on-one-connection-spares-the-other ()
  "The change hook says which connection notified, and the reap is scoped
to it.  One server's cache knowing nothing of another server's pane is
the ordinary case, not a reason to kill its terminal."
  (let* ((one (herdr-test-connection (herdr-state-from-snapshot nil)))
         (two (herdr-test-connection
               (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (workspace_id . "w1"))))))))
         (mine (generate-new-buffer " *one*"))
         (theirs (generate-new-buffer " *two*"))
         (herdr-state-change-functions nil))
    (unwind-protect
        (let ((herdr-term--buffers
               (list (cons (herdr-term--key one "w1:p1") mine)
                     (cons (herdr-term--key two "w1:p1") theirs))))
          ;; One's cache has no panes at all, so its own buffer goes.
          (herdr-term--on-state-change one "reconcile")
          (should-not (buffer-live-p mine))
          (should (buffer-live-p theirs)))
      (dolist (buffer (list mine theirs))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest herdr-term-a-command-in-a-terminal-means-that-terminal-s-server ()
  "A command typed in a terminal buffer acts on that buffer's connection,
not on whichever one was resolved last."
  (let* ((one (herdr-test-connection))
         (two (herdr-test-connection))
         (herdr-connections (herdr-test-connections one))
         (buffer (generate-new-buffer " *pane*")))
    (unwind-protect
        (let ((herdr-term--buffers
               (list (cons (herdr-term--key two "w1:p1") buffer))))
          (setf (herdr-connection-cache two)
                (herdr-state-from-snapshot
                 '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")))))))
          (with-current-buffer buffer
            (setq herdr-buffer-connection two)
            (should (eq two (herdr-current-connection)))
            (should (equal "w1:p1" (herdr-term-pane-for-buffer)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest herdr-term-a-key-survives-a-mutation-of-the-connection ()
  "The key holds the token, not the struct.  `equal' on a struct compares
fields, so a key holding one would stop matching the moment a process or
a cache slot changed under it — which is every reconnect."
  (let* ((connection (herdr-test-connection))
         (buffer (generate-new-buffer " *pane*")))
    (unwind-protect
        (let ((herdr-term--buffers
               (list (cons (herdr-term--key connection "w1:p1") buffer))))
          (should (eq buffer (herdr-term-buffer-for-pane connection "w1:p1")))
          (setf (herdr-connection-cache connection) 'replaced
                (herdr-connection-generation connection) 99
                (herdr-connection-global-process connection) 'a-process)
          (should (eq buffer (herdr-term-buffer-for-pane connection "w1:p1"))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest herdr-term-a-remote-pane-keeps-its-buffer-remote ()
  "The pane's reported directory is a path on the server's machine.
Syncing it verbatim strips the buffer's remoteness, which is the defect:
the buffer then names a local path of the same name."
  (let ((remote (herdr-connection--make :name "shadow" :ssh-target "shadow"))
        (local (herdr-connection--make :name "local"))
        (buffer (generate-new-buffer " *pane*"))
        (pane '((pane_id . "w1:p1") (cwd . "/srv/app"))))
    (unwind-protect
        (progn
          (herdr-term--set-directory remote buffer pane)
          (should (equal "/ssh:shadow:/srv/app/"
                         (buffer-local-value 'default-directory buffer)))
          (should (file-remote-p
                   (buffer-local-value 'default-directory buffer)))
          ;; A local pane's buffer is not made remote.  A real
          ;; directory, because the local half still checks the local
          ;; filesystem — which is exactly what it cannot do for the
          ;; remote one.
          (herdr-term--set-directory local buffer '((pane_id . "w1:p1")
                                                    (cwd . "/tmp")))
          (should (equal "/tmp/"
                         (buffer-local-value 'default-directory buffer)))
          (should-not (file-remote-p
                       (buffer-local-value 'default-directory buffer))))
      (kill-buffer buffer))))

(ert-deftest herdr-term-a-remote-pane-spawns-on-its-own-machine ()
  "`ghostel-exec' reads `default-directory' to decide which machine to
spawn the pty on, so the buffer has to be remote before the client
starts.  Setting the directory afterwards told it nothing and ran a
remote pane's client here."
  (let* ((remote (herdr-connection--make :name "shadow" :ssh-target "shadow"))
         (state (herdr-state-from-snapshot
                 '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                              (agent . "claude") (terminal_id . "t7")
                              (cwd . "/srv/app")))))))
         (at-exec nil))
    (herdr-term-test--attaching
        (lambda (buffer _program &optional _args)
          (setq at-exec (buffer-local-value 'default-directory buffer))
          t)
      (let ((buffer (herdr-term--attach remote state
                                        (herdr-state-pane state "w1:p1"))))
        (unwind-protect
            (progn
              (should (equal "/ssh:shadow:/srv/app/" at-exec))
              (should (file-remote-p at-exec)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest herdr-term-a-remote-pane-with-no-cwd-still-spawns-remotely ()
  "The host is the floor.  A pane whose cwd says nothing must not fall
back to this machine, which is where the client would then attach — to a
terminal id that exists on another server."
  (let* ((remote (herdr-connection--make :name "shadow" :ssh-target "shadow"))
         (state (herdr-state-from-snapshot
                 '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                              (agent . "claude") (terminal_id . "t7")))))))
         (at-exec nil))
    (herdr-term-test--attaching
        (lambda (buffer _program &optional _args)
          (setq at-exec (buffer-local-value 'default-directory buffer))
          t)
      (let ((buffer (herdr-term--attach remote state
                                        (herdr-state-pane state "w1:p1"))))
        (unwind-protect
            (should (equal "/ssh:shadow:" (file-remote-p at-exec)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest herdr-term-a-local-pane-spawns-here ()
  "The other half: nothing about a local connection becomes remote."
  (let* ((local (herdr-connection--make :name "local"))
         (state (herdr-state-from-snapshot
                 '((panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                              (agent . "claude") (terminal_id . "t7")
                              (cwd . "/tmp")))))))
         (at-exec nil))
    (herdr-term-test--attaching
        (lambda (buffer _program &optional _args)
          (setq at-exec (buffer-local-value 'default-directory buffer))
          t)
      (let ((buffer (herdr-term--attach local state
                                        (herdr-state-pane state "w1:p1"))))
        (unwind-protect
            (progn
              (should-not (file-remote-p at-exec))
              (should (equal "/tmp/" at-exec)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest herdr-term-a-named-session-reaches-the-attach ()
  "`terminal attach' has no session option of its own, so a client for a
named session says so globally or attaches to the default one — which on
a host running two sessions is the wrong server's terminal."
  (let ((pane '((pane_id . "w1:p1") (terminal_id . "t7"))))
    (should (equal '("terminal" "attach" "t7")
                   (herdr-pane-attach-args pane nil)))
    (should (equal '("--session" "work" "terminal" "attach" "t7")
                   (herdr-pane-attach-args pane nil "work")))
    ;; The session goes before the subcommand; takeover stays after.
    (should (equal '("--session" "work" "terminal" "attach" "t7" "--takeover")
                   (herdr-pane-attach-args pane t "work")))))

(provide 'herdr-term-test)
;;; herdr-term-test.el ends here
