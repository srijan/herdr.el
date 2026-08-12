;;; herdr-term-test.el --- Tests for herdr terminal backends -*- lexical-binding: t; -*-

;;; Commentary:

;; Reconciliation is the whole of the `agent-windows' backend's
;; correctness: which agents need a buffer, and which buffers outlived
;; their pane.  It is a pure function so it can be tested without
;; ghostel, a PTY, or a server.

;;; Code:

(require 'ert)
(require 'herdr-term)

(defun herdr-term-test--state (&rest panes)
  (herdr-state-from-snapshot `((panes . ,panes))))

(defun herdr-term-test--pane (id &optional agent)
  `((pane_id . ,id) (agent . ,agent) (agent_status . "idle")
    (workspace_id . "w1") (terminal_title_stripped . ,(or agent "shell"))))

(ert-deftest herdr-term-reconcile-creates-buffers-for-new-agents ()
  (let* ((state (herdr-term-test--state
                 (herdr-term-test--pane "w1:p1" "claude")
                 (herdr-term-test--pane "w1:p2" "codex")))
         (result (herdr-term-reconcile state nil)))
    (should (equal '("w1:p1" "w1:p2")
                   (mapcar (lambda (p) (alist-get 'pane_id p)) (car result))))
    (should (null (cdr result)))))

(ert-deftest herdr-term-reconcile-ignores-panes-without-an-agent ()
  "Only detected agents are attachable; plain shells get no buffer."
  (let* ((state (herdr-term-test--state
                 (herdr-term-test--pane "w1:p1" "claude")
                 (herdr-term-test--pane "w1:p2")))
         (result (herdr-term-reconcile state nil)))
    (should (= 1 (length (car result))))
    (should (equal "w1:p1" (alist-get 'pane_id (car (car result)))))))

(ert-deftest herdr-term-reconcile-reaps-buffers-whose-pane-is-gone ()
  (let* ((state (herdr-term-test--state
                 (herdr-term-test--pane "w1:p1" "claude")))
         (result (herdr-term-reconcile state '(("w1:p1" . :buf1)
                                               ("w1:p9" . :buf9)))))
    (should (null (car result)))
    (should (equal '(:buf9) (cdr result)))))

(ert-deftest herdr-term-reconcile-reaps-buffers-whose-agent-disappeared ()
  "A pane that loses its agent is no longer attachable, so reap it."
  (let* ((state (herdr-term-test--state (herdr-term-test--pane "w1:p1")))
         (result (herdr-term-reconcile state '(("w1:p1" . :buf1)))))
    (should (null (car result)))
    (should (equal '(:buf1) (cdr result)))))

(ert-deftest herdr-term-reconcile-is-stable-when-nothing-changed ()
  (let* ((state (herdr-term-test--state
                 (herdr-term-test--pane "w1:p1" "claude")))
         (result (herdr-term-reconcile state '(("w1:p1" . :buf1)))))
    (should (null (car result)))
    (should (null (cdr result)))))

;;; Buffer naming: name first, workspace fallback

(ert-deftest herdr-term-agent-buffer-name-prefers-the-agent-name ()
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
                   (herdr-term-agent-buffer-name state pane)))))

(ert-deftest herdr-term-agent-buffer-name-falls-back-to-kind-at-workspace ()
  "An unnamed agent reads as KIND@WORKSPACE, not an opaque pane id."
  (let* ((state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "wG") (label . "srijan.ch"))))
                   (panes . (((pane_id . "wG:p3") (agent . "claude")
                              (workspace_id . "wG")))))))
         (pane (herdr-state-pane state "wG:p3")))
    (should (equal "*herdr: claude@srijan.ch*"
                   (herdr-term-agent-buffer-name state pane)))))

(ert-deftest herdr-term-agent-buffer-name-reads-an-adopted-shell-naturally ()
  "An adopted shell's agent field is already the shell placeholder name,
so it needs no special case to read as `shell@WORKSPACE'."
  (let* ((state (herdr-state-from-snapshot
                 `((workspaces . (((workspace_id . "w7") (label . ".emacs.d"))))
                   (panes . (((pane_id . "w7:p9")
                              (agent . ,herdr-shell-agent-name)
                              (workspace_id . "w7")))))))
         (pane (herdr-state-pane state "w7:p9")))
    (should (herdr-state-shell-pane-p pane))
    (should (equal "*herdr: shell@.emacs.d*"
                   (herdr-term-agent-buffer-name state pane)))))

(ert-deftest herdr-term-agent-buffer-name-falls-back-to-the-workspace-id ()
  "A workspace missing from STATE altogether — so its label is unknowable
— still yields a readable name, not a bare `KIND@'."
  (let* ((state (herdr-state-from-snapshot
                 '((panes . (((pane_id . "w9:p1") (agent . "claude")
                              (workspace_id . "w9")))))))
         (pane (herdr-state-pane state "w9:p1")))
    (should (equal "*herdr: claude@w9*"
                   (herdr-term-agent-buffer-name state pane)))))

(ert-deftest herdr-term-agent-buffer-name-has-a-sensible-floor ()
  "Neither a kind nor a workspace must not produce `*herdr: @*'."
  (should (equal "*herdr: agent*"
                 (herdr-term-agent-buffer-name
                  (herdr-state-empty) '((pane_id . "p1"))))))

(ert-deftest herdr-term-agent-buffer-name-collides-for-two-unnamed-siblings ()
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
    (should (equal (herdr-term-agent-buffer-name state one)
                   (herdr-term-agent-buffer-name state two)))))

(ert-deftest herdr-term-unique-agent-buffer-name-avoids-a-collision ()
  "The hazard: `get-buffer-create' on a colliding wanted name returns a
different pane's existing buffer.  `herdr-term--unique-agent-buffer-name'
is what `herdr-term--attach-1' creates buffers under instead, precisely
to make that impossible."
  (let* ((existing (generate-new-buffer "*herdr: claude@.emacs.d*"))
         (state (herdr-state-from-snapshot
                 '((workspaces . (((workspace_id . "w7") (label . ".emacs.d"))))
                   (panes . (((pane_id . "w7:p5") (agent . "claude")
                              (workspace_id . "w7")))))))
         (pane (herdr-state-pane state "w7:p5")))
    (unwind-protect
        (let* ((name (herdr-term--unique-agent-buffer-name state pane))
               (created (get-buffer-create name)))
          (unwind-protect
              (progn
                (should-not (equal "*herdr: claude@.emacs.d*" name))
                (should-not (eq existing created)))
            (kill-buffer created)))
      (kill-buffer existing))))

(ert-deftest herdr-term-attach-args-target-the-pane ()
  (should (equal '("agent" "attach" "w1:p1")
                 (herdr-term-attach-args "w1:p1" nil)))
  (should (equal '("agent" "attach" "w1:p1" "--takeover")
                 (herdr-term-attach-args "w1:p1" t))))

(ert-deftest herdr-term-session-args-are-empty ()
  "The session backend runs bare herdr, which attaches the whole session."
  (should (equal nil (herdr-term-session-args))))

;;; Adopted shells and directory tracking

(ert-deftest herdr-term-reconcile-creates-a-buffer-for-an-adopted-shell ()
  "An adopted shell is attachable, so it must get a buffer."
  (let* ((state (herdr-term-test--state
                 (herdr-term-test--pane "w1:p1" "claude")
                 (herdr-term-test--pane "w1:p2" "shell")))
         (result (herdr-term-reconcile state nil)))
    (should (equal '("w1:p1" "w1:p2")
                   (mapcar (lambda (p) (alist-get 'pane_id p)) (car result))))))

(ert-deftest herdr-term-reconcile-reaps-a-released-shell ()
  "Releasing the adopted agent makes the pane unattachable again."
  (let* ((state (herdr-term-test--state (herdr-term-test--pane "w1:p2" nil)))
         (result (herdr-term-reconcile state '(("w1:p2" . :buf)))))
    (should (null (car result)))
    (should (equal '(:buf) (cdr result)))))

(ert-deftest herdr-term-set-directory-follows-the-pane ()
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (setq default-directory "/")
      (herdr-term--set-directory buffer '((cwd . "/tmp")))
      (should (equal "/tmp/" default-directory)))))

(ert-deftest herdr-term-set-directory-ignores-a-missing-directory ()
  "A stale cwd must not leave `default-directory' pointing at nothing."
  (with-temp-buffer
    (setq default-directory "/")
    (herdr-term--set-directory (current-buffer)
                               '((cwd . "/no/such/place/anywhere")))
    (should (equal "/" default-directory))))

;;; Directory sync differs per backend

(ert-deftest herdr-term-sync-directories-follows-the-focused-pane-under-session ()
  "One buffer serves the whole session, so it tracks whatever is focused."
  (let* ((herdr-terminal-backend 'session)
         (herdr-term-track-directory t)
         (buffer (get-buffer-create herdr-term-session-buffer-name))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:p2")
             (panes . (((pane_id . "w1:p1") (cwd . "/"))
                       ((pane_id . "w1:p2") (cwd . "/tmp"))))))))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq default-directory "/"))
          (herdr-term--sync-directories)
          (should (equal "/tmp/" (buffer-local-value 'default-directory buffer))))
      (kill-buffer buffer))))

(ert-deftest herdr-term-sync-directories-is-per-buffer-under-agent-windows ()
  (let* ((herdr-terminal-backend 'agent-windows)
         (herdr-term-track-directory t)
         (one (generate-new-buffer " *pane1*"))
         (two (generate-new-buffer " *pane2*"))
         (herdr-term--agent-buffers (list (cons "w1:p1" one) (cons "w1:p2" two)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((panes . (((pane_id . "w1:p1") (agent . "claude") (cwd . "/tmp"))
                       ((pane_id . "w1:p2") (agent . "codex") (cwd . "/usr"))))))))
    (unwind-protect
        (progn
          (herdr-term--sync-directories)
          (should (equal "/tmp/" (buffer-local-value 'default-directory one)))
          (should (equal "/usr/" (buffer-local-value 'default-directory two))))
      (kill-buffer one) (kill-buffer two))))

(ert-deftest herdr-term-sync-directories-respects-the-off-switch ()
  (let* ((herdr-terminal-backend 'session)
         (herdr-term-track-directory nil)
         (buffer (get-buffer-create herdr-term-session-buffer-name))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:p1")
             (panes . (((pane_id . "w1:p1") (cwd . "/tmp"))))))))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq default-directory "/"))
          (herdr-term--sync-directories)
          (should (equal "/" (buffer-local-value 'default-directory buffer))))
      (kill-buffer buffer))))

(ert-deftest herdr-term-select-pane-under-session-uses-the-one-buffer ()
  "Under `session' every pane lives in the same buffer, so any pane id
resolves to it — that is what makes Go to work there too."
  (let* ((herdr-terminal-backend 'session)
         (buffer (get-buffer-create herdr-term-session-buffer-name)))
    (unwind-protect
        (should (eq buffer (herdr-term-buffer-for-pane "w9:p9")))
      (kill-buffer buffer))))

;;; Buffers must follow their pane's identity

(ert-deftest herdr-term-renames-a-buffer-whose-pane-was-promoted ()
  "A shell adopted and later promoted keeps its buffer — attachment is
still valid — so the name has to be corrected in place."
  (let* ((herdr-terminal-backend 'agent-windows)
         (buffer (generate-new-buffer "*herdr: shell@.emacs.d*"))
         (herdr-term--agent-buffers (list (cons "w1:p1" buffer)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((workspaces . (((workspace_id . "w1") (label . ".emacs.d"))))
             (panes . (((pane_id . "w1:p1") (agent . "claude")
                        (workspace_id . "w1"))))))))
    (unwind-protect
        (progn
          (herdr-term--rename-stale-buffers)
          (should (equal "*herdr: claude@.emacs.d*" (buffer-name buffer))))
      (kill-buffer buffer))))

(ert-deftest herdr-term-leaves-a-correctly-named-buffer-alone ()
  (let* ((herdr-terminal-backend 'agent-windows)
         (buffer (generate-new-buffer "*herdr: claude@.emacs.d*"))
         (herdr-term--agent-buffers (list (cons "w1:p1" buffer)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((workspaces . (((workspace_id . "w1") (label . ".emacs.d"))))
             (panes . (((pane_id . "w1:p1") (agent . "claude")
                        (workspace_id . "w1"))))))))
    (unwind-protect
        (progn
          (herdr-term--rename-stale-buffers)
          (should (equal "*herdr: claude@.emacs.d*" (buffer-name buffer))))
      (kill-buffer buffer))))

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
  (let* ((herdr-terminal-backend 'agent-windows)
         ;; `generate-new-buffer' uniquifies on creation exactly like
         ;; `herdr-term--unique-agent-buffer-name' does, so the second
         ;; buffer starts life as `...<2>' here without any special-casing.
         (first (generate-new-buffer "*herdr: claude@.emacs.d*"))
         (second (generate-new-buffer "*herdr: claude@.emacs.d*"))
         (herdr-term--agent-buffers (list (cons "w7:p2" first)
                                          (cons "w7:p5" second)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((workspaces . (((workspace_id . "w7") (label . ".emacs.d"))))
             (panes . (((pane_id . "w7:p2") (agent . "claude")
                        (workspace_id . "w7"))
                       ((pane_id . "w7:p5") (agent . "claude")
                        (workspace_id . "w7"))))))))
    (unwind-protect
        (progn
          (should (equal "*herdr: claude@.emacs.d*<2>" (buffer-name second)))
          (let ((rename-calls 0))
            (cl-letf* ((real-rename-buffer (symbol-function 'rename-buffer))
                       ((symbol-function 'rename-buffer)
                        (lambda (&rest args)
                          (setq rename-calls (1+ rename-calls))
                          (apply real-rename-buffer args))))
              (dotimes (_ 3) (herdr-term--rename-stale-buffers)))
            (should (= 0 rename-calls))))
      (kill-buffer first) (kill-buffer second))))

;;; Starting herdr must not rearrange windows

(ert-deftest herdr-term-display-does-nothing-under-agent-windows ()
  "There is no primary buffer to show, and popping an arbitrary agent
would mean `M-x herdr' takes a window before being asked to."
  (let* ((herdr-terminal-backend 'agent-windows)
         (buffer (generate-new-buffer " *an-agent*"))
         (herdr-term--agent-buffers (list (cons "w1:p1" buffer))))
    (unwind-protect
        (save-window-excursion
          (let ((before (current-window-configuration)))
            (should-not (herdr-term-display))
            (should (compare-window-configurations
                     before (current-window-configuration)))))
      (kill-buffer buffer))))

(ert-deftest herdr-term-display-shows-the-tui-under-session ()
  (let* ((herdr-terminal-backend 'session)
         (buffer (get-buffer-create herdr-term-session-buffer-name)))
    (unwind-protect
        (save-window-excursion
          (should (herdr-term-display)))
      (kill-buffer buffer))))

(ert-deftest herdr-term-select-pane-does-not-split-the-frame ()
  "Going to a pane reuses the current window; splitting is the user's
business, not a side effect of navigation."
  (let* ((herdr-terminal-backend 'agent-windows)
         (target (generate-new-buffer " *target*"))
         (herdr-term--agent-buffers (list (cons "w1:p1" target)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((panes . (((pane_id . "w1:p1") (agent . "claude"))))))))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let ((before (length (window-list))))
            (herdr-term-select-pane "w1:p1")
            (should (eq target (current-buffer)))
            (should (= before (length (window-list))))))
      (kill-buffer target))))

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

(ert-deftest herdr-term-display-and-select-use-the-same-action ()
  "The same buffer must not appear one way from `M-x herdr' and another
way from Go to."
  (let* ((herdr-terminal-backend 'session)
         (buffer (get-buffer-create herdr-term-session-buffer-name))
         (actions nil)
         (herdr-display-action '(recorded)))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (_buf action &rest _) (push action actions) _buf)))
          (herdr-term-display)
          (herdr-term-select-pane "w1:p1")
          (should (equal '((recorded) (recorded)) actions)))
      (kill-buffer buffer))))

(ert-deftest herdr-display-action-defaults-to-reusing-the-window ()
  "The default must not delete the user's other windows."
  (should (equal '((display-buffer-reuse-window display-buffer-same-window))
                 (default-value 'herdr-display-action))))

(provide 'herdr-term-test)
;;; herdr-term-test.el ends here
