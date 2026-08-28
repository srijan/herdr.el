;;; herdr-cmd-test.el --- Tests for the curated commands -*- lexical-binding: t; -*-

;;; Commentary:

;; Hand-written wrappers rot as the server changes.  These check the
;; whole registry against the captured schema; the `:live' drift test
;; does the same against a running server.

;;; Code:

(require 'ert)
(require 'herdr-test-helper)
(require 'herdr-cmd)
(require 'herdr-schema)

(defvar herdr-cmd-test--fixture
  (expand-file-name "fixtures/schema-protocol-20.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro herdr-cmd-test-with-schema (&rest body)
  (declare (indent 0) (debug t))
  `(let ((herdr-schema--cache nil) (herdr-schema--cache-version nil))
     (herdr-schema-load-file herdr-cmd-test--fixture)
     ,@body))

(ert-deftest herdr-cmd-every-command-is-defined ()
  (dolist (entry herdr-cmd-methods)
    (should (fboundp (car entry)))))

(ert-deftest herdr-cmd-every-command-is-interactive ()
  (dolist (entry herdr-cmd-methods)
    (should (commandp (car entry)))))

(ert-deftest herdr-cmd-every-method-exists-in-the-schema ()
  (herdr-cmd-test-with-schema
    (let ((known (herdr-schema-methods)))
      (dolist (entry herdr-cmd-methods)
        (should (member (nth 1 entry) known))))))

(ert-deftest herdr-cmd-every-param-exists-on-its-method ()
  "A wrapper passing an unknown parameter is rejected by the server."
  (herdr-cmd-test-with-schema
    (dolist (entry herdr-cmd-methods)
      (let* ((method (nth 1 entry))
             (declared (mapcar #'car (herdr-schema-params method))))
        (dolist (param (nthcdr 2 entry))
          (should (member param declared)))))))

(ert-deftest herdr-cmd-every-required-param-is-supplied ()
  "Omitting a required parameter fails at runtime; catch it here."
  (herdr-cmd-test-with-schema
    (dolist (entry herdr-cmd-methods)
      (let ((method (nth 1 entry))
            (passed (nthcdr 2 entry)))
        (dolist (required (herdr-schema-required method))
          (should (member required passed)))))))

(ert-deftest herdr-cmd-registry-has-no-duplicate-commands ()
  (let ((names (mapcar #'car herdr-cmd-methods)))
    (should (= (length names) (length (delete-dups (copy-sequence names)))))))

(ert-deftest herdr-cmd-is-the-set-it-means-to-be ()
  "The registry is pinned, not floored: adding a command is the change
worth arguing about now."
  (should (equal '(herdr-pane-close
                   herdr-pane-rename
                   herdr-pane-focus
                   herdr-pane-read
                   herdr-workspace-create
                   herdr-workspace-close
                   herdr-workspace-focus
                   herdr-workspace-rename
                   herdr-worktree-create
                   herdr-worktree-remove
                   herdr-agent-prompt)
                 (mapcar #'car herdr-cmd-methods))))

(ert-deftest herdr-cmd-offers-no-surface-the-dashboard-does-not-use ()
  "The cut commands, asserted absent rather than merely unbound.
Each is still reachable through \\[herdr-call], which is what made
deleting them safe."
  (dolist (command '(herdr-pane-split-right herdr-pane-split-down
                     herdr-pane-zoom herdr-pane-resize herdr-pane-swap
                     herdr-pane-send-text herdr-pane-run
                     herdr-pane-wait-for-output
                     herdr-tab-create herdr-tab-close herdr-tab-focus
                     herdr-tab-rename
                     herdr-worktree-list herdr-worktree-open
                     herdr-agent-read herdr-agent-wait herdr-agent-focus
                     herdr-agent-explain
                     herdr-notification-show
                     herdr-adopt-shell herdr-release-shell
                     herdr-transient))
    (should-not (fboundp command)))
  (dolist (variable '(herdr-adopt-created-shells herdr-shell-agent-name))
    (should-not (boundp variable)))
  ;; The escape hatch that makes the rest of this test safe.
  (should (commandp 'herdr-call)))

(ert-deftest herdr-cmd-read-text-unwraps-the-read-envelope ()
  "pane.read and agent.read nest their text under a `read' object."
  (should (equal "hello"
                 (herdr-cmd-read-text
                  '((type . "pane_read")
                    (read . ((pane_id . "w1:p1") (text . "hello")))))))
  ;; Tolerate a flat shape too, rather than returning nil if it changes.
  (should (equal "flat" (herdr-cmd-read-text '((text . "flat")))))
  (should (equal "" (herdr-cmd-read-text '((type . "pane_read"))))))

(ert-deftest herdr-cmd-read-truncated-reads-the-envelope-flag ()
  "herdr 0.8.0 flags dropped rows as `truncated' on the read envelope."
  (should (herdr-cmd-read-truncated-p
           '((type . "pane_read") (read . ((text . "x") (truncated . t))))))
  ;; Tolerate the flag arriving flat, mirroring `herdr-cmd-read-text'.
  (should (herdr-cmd-read-truncated-p '((truncated . t))))
  (should-not (herdr-cmd-read-truncated-p '((read . ((text . "x"))))))
  ;; JSON `false' decodes to nil, so an untruncated read must read as nil.
  (should-not (herdr-cmd-read-truncated-p '((read . ((truncated . nil)))))))

;;; Focus must move Emacs, not just the server

(ert-deftest herdr-pane-focus-selects-the-buffer-for-that-pane ()
  "Focusing is server-side and nothing repaints, so
Emacs has to be moved to match or the command looks like a no-op."
  (let (selected)
    (cl-letf (((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-pane-focus "w1:p7")
        (should (equal "w1:p7" selected))))))

(ert-deftest herdr-pane-focus-waits-when-select-fails ()
  "When the immediate select cannot show the pane yet — the cache has
not caught up with the focus change — the retry chain is armed instead
of the command silently going nowhere."
  (let (deferred)
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) nil))
              ((symbol-function 'herdr-cmd--select-pane-when-ready)
               (lambda (pane) (setq deferred pane))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-pane-focus "w1:p7")
        (should (equal "w1:p7" deferred))))))

(ert-deftest herdr-workspace-focus-follows-in-emacs ()
  (let (asked)
    (cl-letf (((symbol-function 'herdr-term-select-focused)
               (lambda () (setq asked t)))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () nil)))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-workspace-focus "w2")
        (should asked)))))

(ert-deftest herdr-cmd-follow-focus-waits-when-nothing-is-selected ()
  "When neither the immediate select-focused nor the fallback pane
lookup can show anything yet, the miss is handed to the retry chain
rather than the command going silently nowhere."
  (let (deferred)
    (cl-letf (((symbol-function 'herdr-term-select-focused) (lambda () nil))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () "w1:p4"))
              ((symbol-function 'herdr-cmd--select-pane-when-ready)
               (lambda (pane) (setq deferred pane))))
      (herdr-cmd--follow-focus)
      (should (equal "w1:p4" deferred)))))

;;; Panes created from Emacs must become visible

(ert-deftest herdr-cmd-created-pane-id-reads-pane-or-root-pane ()
  "pane.split answers with `pane'; tab/workspace create with `root_pane'.
Either shape names the pane just made."
  (should (equal "w1:p9"
                 (herdr-cmd--created-pane-id
                  '((type . "pane_info") (pane . ((pane_id . "w1:p9")))))))
  (should (equal "w2:p0"
                 (herdr-cmd--created-pane-id
                  '((type . "tab_created") (root_pane . ((pane_id . "w2:p0"))))))))

(ert-deftest herdr-cmd-new-tab-pane-creates-a-tab-and-returns-its-root-pane ()
  "tab.create carries the workspace to create in and focuses the result;
the pane to show is its `root_pane', the same shape `pane.split' answers
with `pane'."
  (let (sent)
    (herdr-test-with-server
        (lambda (req)
          (setq sent req)
          (cons (herdr-test-ok req '((type . "tab_created")
                                     (root_pane . ((pane_id . "wZ:p9")))))
                nil))
      (should (equal "wZ:p9" (herdr-cmd--new-tab-pane "wZ")))
      (should (equal "tab.create" (alist-get 'method sent)))
      (should (equal "wZ" (alist-get 'workspace_id (alist-get 'params sent))))
      (should (eq t (alist-get 'focus (alist-get 'params sent)))))))

(ert-deftest herdr-cmd-follow-new-pane-selects-or-waits ()
  "When select cannot show the pane yet, because the cache has not
caught up with a creation announced on the event stream, the retry chain
is armed."
  (let (deferred reported)
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) nil))
              ((symbol-function 'herdr-cmd--select-pane-when-ready)
               (lambda (pane) (setq deferred pane)))
              ((symbol-function 'herdr-rpc-call)
               (lambda (method &rest _)
                 (when (equal method "pane.report_agent") (setq reported t)))))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should (equal "w1:p9" deferred))
      (should-not reported))))

(ert-deftest herdr-cmd-follow-new-pane-waits-only-when-select-fails ()
  "The retry chain is armed exactly when the immediate select comes up
empty; a pane already in the cache must not also be handed to it."
  (dolist (select-succeeds '(nil t))
    (let (deferred)
      (cl-letf (((symbol-function 'herdr-term-select-pane)
                 (lambda (_) select-succeeds))
                ((symbol-function 'herdr-cmd--select-pane-when-ready)
                 (lambda (pane) (setq deferred pane))))
        (herdr-cmd--follow-new-pane "w1:p9")
        (should (equal (unless select-succeeds "w1:p9") deferred))))))

;;; What reached the server is the assertion

;; Both helpers below run against the fake server and assert on what it
;; received, because that is the only place a command's effect is
;; visible: a message, a prompt and a return value all read the same
;; whether or not the request went out.

(defmacro herdr-cmd-test--capturing-params (var &rest body)
  "Run BODY against a fake server, binding VAR to the last request params."
  (declare (indent 1) (debug t))
  `(let (,var)
     (herdr-test-with-server
         (lambda (req)
           (setq ,var (alist-get 'params req))
           (cons (herdr-test-ok req '((type . "ok"))) nil))
       ,@body)))

(ert-deftest herdr-cmd-every-command-sends-the-method-its-entry-names ()
  "The registry and the body beside it were never checked against each other.

Every other test in this file reads `herdr-cmd-methods', and so does the
drift test: they check that the *entry* names a method the schema knows
and parameters that method declares.  Nothing checked that the
`herdr-rpc-call' inside the command sends what its entry says it does.
Measured: twenty-odd of those method literals could be replaced with
nonsense and the whole suite stayed green, because the entry beside them
still read `pane.zoom'.

Each command is run with its prompts, its terminal and its cache
stubbed, and the methods that reach the fake server must include the one
its entry names.  Inclusion rather than equality: several of these
legitimately send more than one — a split is followed by a focus — and
which extra calls are right is the business of the tests above.

`inhibit-interaction' is bound so that a prompt this does not know to
stub signals `inhibited-interaction' at once.  Without it the reader
blocks on the minibuffer, which under a tty is a hang rather than a
failure — the test only failed cleanly because batch CI closes stdin.

Every command is run before anything is asserted, so a run names every
offender rather than stopping at the first — and a command can fail
either way, so both are collected.  A wrong method literal fails
silently, leaving the method off the wire; an unstubbed prompt signals.
Collecting only the silent kind gave a docstring that promised a full
list and a body that still stopped at the first command to raise, which
is the very case this sentence describes."
  (let (missing)
    (dolist (entry herdr-cmd-methods)
      (let ((command (nth 0 entry))
            (method (nth 1 entry))
            (inhibit-interaction t)
            ;; Enough of a session for every picker to have something to
            ;; offer: one pane running an agent, one bare shell.
            (herdr-state--current
             (herdr-state-from-snapshot
              '((workspaces . (((workspace_id . "w1") (label . "ws"))))
                (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                           (tab_id . "w1:t1") (agent . "claude")
                           (agent_status . "idle") (cwd . "/tmp"))
                          ((pane_id . "w1:p2") (workspace_id . "w1")
                           (tab_id . "w1:t1") (cwd . "/tmp")))))))
            wire)
        (ert-info ((format "%s -> %s" command method))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "x"))
                    ((symbol-function 'herdr-state-refresh) #'ignore)
                    ((symbol-function 'read-directory-name)
                     (lambda (&rest _) "/tmp/herdr-test-dir/"))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) "w1:p1"))
                    ((symbol-function 'read-number) (lambda (&rest _) 1))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                    ((symbol-function 'message) #'ignore)
                    ((symbol-function 'pop-to-buffer) #'ignore)
                    ((symbol-function 'herdr-state-resync) #'ignore)
                    ((symbol-function 'herdr-term-select-pane)
                     (lambda (&rest _) t))
                    ((symbol-function 'herdr-term-select-focused) #'ignore)
                    ((symbol-function 'herdr-cmd--select-pane-when-ready)
                     #'ignore))
            (herdr-test-with-server
                (lambda (req)
                  (push (alist-get 'method req) wire)
                  (cons (herdr-test-ok req '((type . "ok"))) nil))
              (condition-case err
                  (progn
                    (call-interactively command)
                    ;; The two wait commands go out through
                    ;; `herdr-rpc-call-async', so their request may not
                    ;; have reached the server when the command returns.
                    ;; Everything else is already on the wire: the fake
                    ;; server's filter runs inside `herdr-rpc-call''s own
                    ;; `accept-process-output' loop.  Measured, the
                    ;; asynchronous pair need exactly one turn and
                    ;; everything else needs none, so the deadline below
                    ;; is forty times what the slow case wants.  It is a
                    ;; deadline rather than a turn count because a turn
                    ;; count under load reads as a regression that is not
                    ;; there, and it is one second rather than five
                    ;; because it is paid once per command that never
                    ;; arrives: a wholesale breakage should cost this
                    ;; suite half a minute and produce a complete list,
                    ;; not run into the Makefile's own deadline.
                    (let ((deadline (+ (float-time) 1)))
                      (while (and (not (member method wire))
                                  (< (float-time) deadline))
                        (accept-process-output nil 0.02))))
                (error
                 (push (list command method (error-message-string err))
                       missing))))))
        (unless (or (member method wire) (assq command missing))
          (push (list command method (nreverse wire)) missing))))
    (should-not missing)))

;;; Confirmations must not be left on screen

;; A message naming the id is not evidence that the id was spared: both
;; branches of every one of these verbs mention it.  So these tests
;; assert the wire — the methods the fake server actually received, in
;; order — with the message checked alongside rather than instead.  A
;; mutation inverting any of these confirmations passed the suite while
;; the assertion was on the text.

(defmacro herdr-cmd-test--answering (answer wire said &rest body)
  "Run BODY with every confirmation answered ANSWER.
WIRE is bound to the RPC methods the fake server received, in the order
it received them, and SAID to the last message.  Both `y-or-n-p' and
`yes-or-no-p' are stubbed: the destructive verbs are split across the
two, and a test that stubbed only one would prompt for real in batch."
  (declare (indent 3) (debug t))
  `(let (,wire ,said)
     (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) ,answer))
               ((symbol-function 'yes-or-no-p) (lambda (_) ,answer))
               ((symbol-function 'message)
                (lambda (fmt &rest args) (setq ,said (apply #'format fmt args)))))
       (herdr-test-with-server
           (lambda (req)
             (push (alist-get 'method req) ,wire)
             (cons (herdr-test-ok req '((type . "ok"))) nil))
         ,@body
         (setq ,wire (nreverse ,wire))))))

(ert-deftest herdr-pane-close-closes-only-when-confirmed ()
  "Declining must reach no server at all.

Closing also reaps the pane's buffer, so redisplay happens while the
confirmation is still up and a following message is what keeps the
prompt from sitting there looking unanswered — but that message names
the pane on both branches, so it cannot be the assertion.  The methods
received are."
  (dolist (answer '(t nil))
    (herdr-cmd-test--answering answer wire said
      (herdr-pane-close "w1:p1")
      (should (equal (if answer '("pane.close") nil) wire))
      (should (string-match-p "w1:p1" (or said ""))))))

(ert-deftest herdr-workspace-close-closes-only-when-confirmed ()
  "A workspace takes every tab and pane in it, so declining must send
nothing.  This used to assert only the message, and only for the yes
branch — so the no branch was never run at all."
  (dolist (answer '(t nil))
    (herdr-cmd-test--answering answer wire said
      (herdr-workspace-close "w1")
      (should (equal (if answer '("workspace.close") nil) wire))
      (should (string-match-p "w1" (or said ""))))))

(ert-deftest herdr-worktree-remove-removes-only-when-confirmed ()
  "The one verb that deletes a checkout on disk, and it had no test.

It confirms through `yes-or-no-p' rather than `y-or-n-p' — a whole word,
because the loss is not recoverable by reopening — and the force flag
travels as JSON `false' rather than being omitted, since the server
types it as a boolean."
  (dolist (answer '(t nil))
    (herdr-cmd-test--answering answer wire said
      (herdr-worktree-remove "w3")
      (should (equal (if answer '("worktree.remove") nil) wire))
      (should (string-match-p "w3" (or said "")))))
  (herdr-cmd-test--capturing-params params
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
      (herdr-worktree-remove "w3")
      (should (equal "w3" (alist-get 'workspace_id params)))
      ;; JSON `false' decodes to nil here, so presence of the key is what
      ;; separates "sent as false" from "omitted"; the point of the
      ;; `:false' in the source is that it is not omitted.
      (should (assq 'force params))
      (should-not (alist-get 'force params))))
  (herdr-cmd-test--capturing-params params
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
      (herdr-worktree-remove "w3" t)
      (should (eq t (alist-get 'force params))))))

;;; Value-shaping wrappers: the transform is the behaviour worth locking

;; The pure passthrough commands are covered by the drift test, which
;; checks their parameters against the schema.  These few do something to
;; a value on the way through — add a newline, drop an empty field, derive
;; a default — and that transform is where a silent regression hides, so
;; it is asserted against the payload the fake server actually receives.

(ert-deftest herdr-worktree-create-omits-an-empty-base ()
  "An empty base means \"off the current ref\"; a blank string is a
different request, and nil is dropped from the payload entirely."
  (dolist (case '(("" . nil) ("main" . "main")))
    (herdr-cmd-test--capturing-params params
      (herdr-worktree-create "feature" (car case))
      (should (equal "feature" (alist-get 'branch params)))
      (should (equal (cdr case) (alist-get 'base params))))))

(ert-deftest herdr-workspace-create-defaults-the-label-to-the-directory ()
  "An unnamed workspace should still read as something, so it borrows the
directory's own name."
  (herdr-cmd-test--capturing-params params
    (herdr-workspace-create "/tmp/herdr-example/" nil)
    (should (equal "herdr-example" (alist-get 'label params)))))

;;; Opening a terminal: the one create mechanism

(ert-deftest herdr-cmd-pane-in-directory-opens-a-workspace-when-none-is-there ()
  "The pane returned is the new workspace\\='s root pane; asking
`tab.create\\=' for another would leave an empty tab behind."
  (let ((calls nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (method params)
                 (push (cons method params) calls)
                 '((root_pane . ((pane_id . "w7:p1")))))))
      (let ((herdr-state--current (herdr-state-empty)))
        (should (equal "w7:p1" (herdr-cmd-pane-in-directory "/tmp/fresh/")))
        (should (equal '(("workspace.create" . ((cwd . "/tmp/fresh/")
                                                (label . "fresh")
                                                (focus . t))))
                       (reverse calls)))))))

(ert-deftest herdr-cmd-pane-in-directory-adds-a-tab-to-a-workspace-already-open ()
  "A workspace already at the directory is used as it is."
  (let ((calls nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (method params)
                 (push (cons method params) calls)
                 '((root_pane . ((pane_id . "w9:p2")))))))
      (let ((herdr-state--current
             (herdr-state-from-snapshot
              '((workspaces . (((workspace_id . "w9"))))
                (panes . (((pane_id . "w9:p1") (workspace_id . "w9")
                           (cwd . "/tmp/open"))))))))
        (should (equal "w9:p2" (herdr-cmd-pane-in-directory "/tmp/open")))
        (should (equal '(("tab.create" . ((workspace_id . "w9")
                                          (cwd . nil)
                                          (focus . t))))
                       (reverse calls)))))))

(ert-deftest herdr-new-terminal-adds-a-tab-when-given-a-workspace-id ()
  "A string the cache holds as a workspace is a workspace; anything else
is a directory."
  (let ((calls nil)
        (followed nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (method params)
                 (push (cons method params) calls)
                 '((root_pane . ((pane_id . "w9:p2"))))))
              ((symbol-function 'herdr-cmd--follow-new-pane)
               (lambda (pane) (setq followed pane))))
      (let ((herdr-state--current
             (herdr-state-from-snapshot
              '((workspaces . (((workspace_id . "w9"))))
                (panes . (((pane_id . "w9:p1") (workspace_id . "w9")
                           (cwd . "/tmp/open"))))))))
        (herdr-new-terminal "w9")
        (should (equal "tab.create" (car (car calls))))
        (should (equal "w9" (alist-get 'workspace_id (cdr (car calls)))))
        (should (equal "w9:p2" followed))))))

(ert-deftest herdr-new-terminal-opens-a-directory-that-is-not-a-workspace ()
  "A directory goes through `herdr-cmd-pane-in-directory\\=', which opens
it first."
  (let ((calls nil)
        (followed nil))
    (cl-letf (((symbol-function 'herdr-rpc-call)
               (lambda (method params)
                 (push (cons method params) calls)
                 '((root_pane . ((pane_id . "w7:p1"))))))
              ((symbol-function 'herdr-cmd--follow-new-pane)
               (lambda (pane) (setq followed pane))))
      (let ((herdr-state--current (herdr-state-empty)))
        (herdr-new-terminal "/tmp/fresh/")
        (should (equal "workspace.create" (car (car calls))))
        (should (equal "w7:p1" followed))))))

;;; Pane-selection retry chain

(ert-deftest herdr-cmd-select-pane-when-ready-stops-after-a-generation-change ()
  "The retry chain keeps no handle anywhere for `herdr-stop' to cancel.
A restart mid-chain (a new generation) must turn every further attempt
into a no-op instead of an action, or a chain begun for one session
could go on to select a buffer belonging to a different, later one."
  (let ((herdr-state--generation 1)
        (scheduled nil))
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (&rest _) nil))
              ((symbol-function 'run-at-time)
               (lambda (_secs _repeat fn) (setq scheduled fn) 'timer)))
      (herdr-cmd--select-pane-when-ready "w1:p1")
      (should scheduled)
      ;; Same generation: the chain keeps retrying.
      (let ((fn scheduled)) (setq scheduled nil) (funcall fn))
      (should scheduled)
      ;; The session was stopped and restarted mid-chain.
      (setq herdr-state--generation 2)
      (let ((fn scheduled)) (setq scheduled nil) (funcall fn))
      (should-not scheduled))))

(provide 'herdr-cmd-test)
;;; herdr-cmd-test.el ends here
