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

(ert-deftest herdr-term-agent-buffer-name-is-derived-from-the-pane ()
  (let ((name (herdr-term-agent-buffer-name
               (herdr-term-test--pane "w1:p1" "claude"))))
    (should (string-match-p "claude" name))
    (should (string-match-p "w1:p1" name))))

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
         (buffer (generate-new-buffer "*herdr: shell w1:p1*"))
         (herdr-term--agent-buffers (list (cons "w1:p1" buffer)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((panes . (((pane_id . "w1:p1") (agent . "claude"))))))))
    (unwind-protect
        (progn
          (herdr-term--rename-stale-buffers)
          (should (equal "*herdr: claude w1:p1*" (buffer-name buffer))))
      (kill-buffer buffer))))

(ert-deftest herdr-term-leaves-a-correctly-named-buffer-alone ()
  (let* ((herdr-terminal-backend 'agent-windows)
         (buffer (generate-new-buffer "*herdr: claude w1:p1*"))
         (herdr-term--agent-buffers (list (cons "w1:p1" buffer)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((panes . (((pane_id . "w1:p1") (agent . "claude"))))))))
    (unwind-protect
        (progn
          (herdr-term--rename-stale-buffers)
          (should (equal "*herdr: claude w1:p1*" (buffer-name buffer))))
      (kill-buffer buffer))))

(provide 'herdr-term-test)
;;; herdr-term-test.el ends here
