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
  (expand-file-name "fixtures/schema-protocol-17.json"
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

(ert-deftest herdr-cmd-covers-the-curated-surface ()
  "Guard against the registry quietly shrinking."
  (should (>= (length herdr-cmd-methods) 27)))

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
  "Focusing is server-side; under `agent-windows' nothing repaints, so
Emacs has to be moved to match or the command looks like a no-op."
  (let (selected)
    (cl-letf (((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-pane-focus "w1:p7")
        (should (equal "w1:p7" selected))))))

(ert-deftest herdr-agent-focus-selects-a-buffer ()
  (let (selected)
    (cl-letf (((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane)))
              ((symbol-function 'herdr-term-select-focused) (lambda () nil)))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-agent-focus "w1:p3")
        (should (equal "w1:p3" selected))))))

(ert-deftest herdr-tab-focus-follows-to-whatever-pane-the-server-picked ()
  "Which pane a tab lands on is the server's choice, so it must be asked."
  (let (asked)
    (cl-letf (((symbol-function 'herdr-term-select-focused)
               (lambda () (setq asked t)))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () nil)))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-tab-focus "w1:t2")
        (should asked)))))

(ert-deftest herdr-workspace-focus-follows-in-emacs ()
  (let (asked)
    (cl-letf (((symbol-function 'herdr-term-select-focused)
               (lambda () (setq asked t)))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () nil)))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-workspace-focus "w2")
        (should asked)))))

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

(ert-deftest herdr-cmd-created-pane-is-adopted-so-it-gets-a-buffer ()
  "Under `agent-windows' a new pane is a plain shell, which herdr will
not attach to.  A pane the user asked herdr.el to create should still
appear, so it is adopted."
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells t)
        adopted selected)
    ;; select-pane fails until adoption has run, then succeeds — the shell
    ;; is not attachable until it wears an agent label.
    (cl-letf (((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p)))
              ((symbol-function 'herdr-term-select-pane)
               (lambda (p) (setq selected p) adopted)))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should (equal "w1:p9" adopted))
      (should (equal "w1:p9" selected)))))

(ert-deftest herdr-cmd-created-pane-is-not-adopted-when-disabled ()
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells nil)
        adopted)
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) nil))
              ((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should-not adopted))))

(ert-deftest herdr-cmd-created-pane-is-left-alone-under-session ()
  "The session backend shows every pane already; adopting would only
add a spurious row to herdr's own agents list."
  (let ((herdr-terminal-backend 'session)
        (herdr-adopt-created-shells t)
        adopted)
    (cl-letf (((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should-not adopted))))

(ert-deftest herdr-cmd-existing-agent-pane-is-selected-not-adopted ()
  "If the new pane already has an agent there is nothing to adopt."
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells t)
        adopted)
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) t))
              ((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane "w1:p9")
      (should-not adopted))))

(ert-deftest herdr-pane-split-follows-the-pane-from-the-split-response ()
  "The pane to show comes from `pane.split''s own answer, not a follow-up
`pane.current': for a paneless client the latter is the server's global
focus and can name a different pane entirely."
  (let (followed)
    (cl-letf (((symbol-function 'herdr-select-target-pane) (lambda (&rest _) "w1:p1"))
              ((symbol-function 'herdr-cmd--follow-new-pane)
               (lambda (pane) (setq followed pane))))
      (herdr-test-with-server
          (lambda (req)
            (pcase (alist-get 'method req)
              ("pane.split"
               (cons (herdr-test-ok req '((type . "pane_info")
                                          (pane . ((pane_id . "w1:p9"))))) nil))
              ;; Would-be trap: consulting this instead is the old bug.
              ("pane.current"
               (cons (herdr-test-ok req '((type . "pane_current")
                                          (pane . ((pane_id . "w1:pWRONG"))))) nil))
              (_ (cons (herdr-test-ok req '((type . "ok"))) nil))))
        (herdr-pane-split-right)
        (should (equal "w1:p9" followed))))))

(ert-deftest herdr-tab-create-follows-its-root-pane ()
  "A new tab's pane is its `root_pane', carried in tab.create's answer."
  (let (followed)
    (cl-letf (((symbol-function 'herdr-cmd--follow-new-pane)
               (lambda (pane) (setq followed pane))))
      (herdr-test-with-server
          (lambda (req)
            (if (equal (alist-get 'method req) "tab.create")
                (cons (herdr-test-ok req '((type . "tab_created")
                                           (root_pane . ((pane_id . "w1:p5"))))) nil)
              (cons (herdr-test-ok req '((type . "ok"))) nil)))
        (herdr-tab-create "")
        (should (equal "w1:p5" followed))))))

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
            (herdr-terminal-backend 'session)
            ;; Enough of a session for every picker to have something to
            ;; offer: an agent pane, a bare shell for `agent.start' to
            ;; take over, and an adopted one for `herdr-release-shell'.
            (herdr-state--current
             (herdr-state-from-snapshot
              `((workspaces . (((workspace_id . "w1") (label . "ws"))))
                (tabs . (((tab_id . "w1:t1") (workspace_id . "w1"))))
                (panes . (((pane_id . "w1:p1") (workspace_id . "w1")
                           (tab_id . "w1:t1") (agent . "claude")
                           (agent_status . "idle") (cwd . "/tmp"))
                          ((pane_id . "w1:p2") (workspace_id . "w1")
                           (tab_id . "w1:t1") (cwd . "/tmp"))
                          ((pane_id . "w1:p3") (workspace_id . "w1")
                           (tab_id . "w1:t1")
                           (agent . ,herdr-shell-agent-name)
                           (cwd . "/tmp")))))))
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
                     #'ignore)
                    ((symbol-function 'herdr-cmd--offer-to-adopt) #'ignore))
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

(ert-deftest herdr-tab-close-confirms-before-closing ()
  "A tab takes its panes with it, and the dispatcher binds `k\\=' one
keystroke from any tab line, so declining must reach no server at all —
a test that only checked the message would pass on a close that asked
and then closed regardless."
  (dolist (answer '(t nil))
    (let (said asked methods)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (setq asked prompt) answer))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (herdr-test-with-server
            (lambda (req)
              (push (alist-get 'method req) methods)
              (cons (herdr-test-ok req '((type . "ok"))) nil))
          (herdr-tab-close "w1:t1")
          (should (string-match-p "w1:t1" (or asked "")))
          (should (string-match-p "w1:t1" (or said "")))
          (should (equal (if answer '("tab.close") nil) methods)))))))

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

(ert-deftest herdr-workspace-focus-offers-to-adopt-an-unattachable-pane ()
  "Landing on a plain shell would otherwise do nothing at all."
  (let (offered)
    (cl-letf (((symbol-function 'herdr-term-select-focused) (lambda () nil))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () "w1:p4"))
              ((symbol-function 'herdr-cmd--offer-to-adopt)
               (lambda (p) (setq offered p))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-workspace-focus "w1")
        (should (equal "w1:p4" offered))))))

;;; Value-shaping wrappers: the transform is the behaviour worth locking

;; The pure passthrough commands are covered by the drift test, which
;; checks their parameters against the schema.  These few do something to
;; a value on the way through — add a newline, drop an empty field, derive
;; a default — and that transform is where a silent regression hides, so
;; it is asserted against the payload the fake server actually receives.

(ert-deftest herdr-pane-run-sends-a-trailing-newline ()
  "There is no pane.run method: running a command is send_text plus the
newline that submits it.  Drop the newline and the command sits at the
prompt unentered."
  (herdr-cmd-test--capturing-params params
    (herdr-pane-run "make test" "w1:p1")
    (should (equal "make test\n" (alist-get 'text params)))))

(ert-deftest herdr-pane-send-text-sends-verbatim ()
  "The counterpart to `herdr-pane-run': text goes as typed, with no
newline, so it can fill a prompt without submitting it."
  (herdr-cmd-test--capturing-params params
    (herdr-pane-send-text "make test" "w1:p1")
    (should (equal "make test" (alist-get 'text params)))))

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
  (let ((herdr-terminal-backend 'session))
    (herdr-cmd-test--capturing-params params
      (herdr-workspace-create "/tmp/herdr-example/" nil)
      (should (equal "herdr-example" (alist-get 'label params))))))

(ert-deftest herdr-notification-show-omits-an-empty-body ()
  "A blank body is absence, not an empty line; only title and sound go."
  (herdr-cmd-test--capturing-params params
    (herdr-notification-show "Done" "")
    (should (equal "Done" (alist-get 'title params)))
    (should (null (alist-get 'body params)))
    (should (equal "none" (alist-get 'sound params)))))

;;; Starting an agent must surface it

(ert-deftest herdr-agent-start-focuses-and-shows-the-new-agent ()
  "Starting an agent that goes nowhere on screen reads as a no-op: the
pane it runs in must be focused server-side and its buffer selected, or
you only learn it worked on the next reload."
  (let (selected focused)
    (cl-letf (((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane) t)))
      (herdr-test-with-server
          (lambda (req)
            (when (equal (alist-get 'method req) "pane.focus")
              (setq focused (alist-get 'pane_id (alist-get 'params req))))
            (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-agent-start "web" "claude" "w1:p1")
        (should (equal "w1:p1" selected))
        (should (equal "w1:p1" focused))))))

(ert-deftest herdr-agent-start-waits-for-a-buffer-that-is-not-ready ()
  "Under `agent-windows' the buffer is built off the event stream, so it
may not exist the instant `agent.start' returns.  When select cannot
show it yet the command schedules a retry rather than giving up."
  (let (deferred)
    (cl-letf (((symbol-function 'herdr-term-select-pane) (lambda (_) nil))
              ((symbol-function 'herdr-cmd--select-pane-when-ready)
               (lambda (pane) (setq deferred pane))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-agent-start "web" "claude" "w1:p1")
        (should (equal "w1:p1" deferred))))))

(ert-deftest herdr-agent-start-create-new-splits-then-starts-on-the-new-pane ()
  "Picking create-new splits the current pane and starts the agent in the
pane the split returns, then shows it — no detour through a manual split."
  (let (split-target started-in selected)
    (cl-letf (((symbol-function 'herdr-select-available-shell)
               (lambda (&rest _) :create-new))
              ((symbol-function 'herdr-select-current-target)
               (lambda (&rest _) "w1:p1"))
              ((symbol-function 'herdr-term-select-pane)
               (lambda (pane) (setq selected pane) t)))
      (herdr-test-with-server
          (lambda (req)
            (let ((method (alist-get 'method req))
                  (params (alist-get 'params req)))
              (cond
               ((equal method "pane.split")
                (setq split-target (alist-get 'target_pane_id params))
                (cons (herdr-test-ok req '((type . "pane_info")
                                           (pane . ((pane_id . "w1:p9")))))
                      nil))
               ((equal method "agent.start")
                (setq started-in (alist-get 'pane_id params))
                (cons (herdr-test-ok req '((type . "ok"))) nil))
               (t (cons (herdr-test-ok req '((type . "ok"))) nil)))))
        (should (equal "w1:p9" (herdr-agent-start "web" "claude")))
        (should (equal "w1:p1" split-target))
        (should (equal "w1:p9" started-in))
        (should (equal "w1:p9" selected))))))

(provide 'herdr-cmd-test)
;;; herdr-cmd-test.el ends here
