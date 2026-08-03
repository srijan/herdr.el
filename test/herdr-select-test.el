;;; herdr-select-test.el --- Tests for herdr completion -*- lexical-binding: t; -*-

;;; Commentary:

;; The integrations here touch third-party variables on their own
;; release schedules.  `marginalia-annotator-registry' was renamed to
;; `marginalia-annotators', and referencing the old name unguarded broke
;; Emacs startup with a void-variable error.  A cosmetic integration
;; must degrade instead.

;;; Code:

(require 'ert)
(require 'herdr-select)
(require 'herdr-term)

;; Declared, deliberately unbound: `let' on an undeclared symbol under
;; lexical binding is invisible to `boundp' elsewhere, which is exactly
;; what these tests exercise.  Marking them special makes the bindings
;; dynamic without giving them a global value, so the "API is unknown"
;; case still sees them unbound.
(defvar marginalia-annotators)
(defvar marginalia-annotator-registry)

(defmacro herdr-select-test-with-state (panes &rest body)
  (declare (indent 1) (debug t))
  `(let ((herdr-state--current (herdr-state-from-snapshot `((panes . ,,panes)))))
     ,@body))

;;; Annotations

(ert-deftest herdr-select-annotates-an-agent-pane ()
  (herdr-select-test-with-state
      '(((pane_id . "w1:p1") (agent . "claude") (agent_status . "blocked")
         (cwd . "/tmp") (terminal_title_stripped . "Claude Code")))
    (let ((annotation (herdr-select--annotate-pane "w1:p1")))
      (should (string-match-p "claude" annotation))
      (should (string-match-p "⏸" annotation))
      (should (string-match-p "Claude Code" annotation)))))

(ert-deftest herdr-select-annotates-a-shell-pane ()
  (herdr-select-test-with-state
      '(((pane_id . "w1:p2") (agent . nil) (cwd . "/tmp")))
    (should (string-match-p "shell" (herdr-select--annotate-pane "w1:p2")))))

(ert-deftest herdr-select-annotation-of-an-unknown-pane-is-empty ()
  (herdr-select-test-with-state '()
    (should (equal "" (herdr-select--annotate-pane "w9:p9")))))

;;; Marginalia registration must not be able to break loading

(ert-deftest herdr-select-registers-with-current-marginalia-api ()
  (let ((marginalia-annotators nil))
    (herdr-select--register-marginalia)
    (should (assq 'herdr-pane marginalia-annotators))
    (should (equal '(herdr-pane herdr-select--annotate-pane builtin none)
                   (assq 'herdr-pane marginalia-annotators)))))

(ert-deftest herdr-select-registers-with-the-pre-rename-marginalia-api ()
  "Older marginalia called it `marginalia-annotator-registry'."
  (let ((marginalia-annotator-registry nil))
    (herdr-select--register-marginalia)
    (should (assq 'herdr-tab marginalia-annotator-registry))))

(ert-deftest herdr-select-registration-is-a-noop-when-the-api-is-unknown ()
  "A third rename must degrade to no annotations, not a void-variable."
  (should-not (herdr-select--register-marginalia)))

(ert-deftest herdr-select-registration-does-not-duplicate ()
  (let ((marginalia-annotators nil))
    (herdr-select--register-marginalia)
    (herdr-select--register-marginalia)
    (should (= 3 (length marginalia-annotators)))))

;;; Consult source

(ert-deftest herdr-select-consult-source-only-lists-panes-with-buffers ()
  "A buffer switcher must not offer entries it cannot switch to.
Listing every pane put plain shells in `consult-buffer' that had no
buffer at all: they appeared in the list and selecting one left you
where you were."
  (let ((herdr-terminal-backend 'agent-windows)
        (live (generate-new-buffer " *pane-with-buffer*")))
    (unwind-protect
        (let ((herdr-term--agent-buffers (list (cons "w1:p1" live)))
              (herdr-state--current
               (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (agent . "claude"))
                            ((pane_id . "w1:p2"))))))))
          (should (equal '("w1:p1") (herdr-select-panes-with-buffers)))
          (let ((source (herdr-select--consult-source)))
            (should (equal 'herdr-pane (plist-get source :category)))
            ;; The source reconciles against the server before listing;
            ;; stub that out so the suite stays hermetic.
            (cl-letf (((symbol-function 'herdr-state-reconcile-panes)
                       (lambda () nil)))
              (should (equal '("w1:p1")
                             (funcall (plist-get source :items)))))))
      (kill-buffer live))))

(ert-deftest herdr-select-consult-source-lists-everything-under-session ()
  "Under `session' every pane shares the one buffer, so all qualify."
  (let* ((herdr-terminal-backend 'session)
         (buffer (get-buffer-create herdr-term-session-buffer-name)))
    (unwind-protect
        (let ((herdr-state--current
               (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1")) ((pane_id . "w1:p2"))))))))
          (should (equal '("w1:p1" "w1:p2") (herdr-select-panes-with-buffers))))
      (kill-buffer buffer))))

(ert-deftest herdr-select-consult-visit-switches-and-focuses ()
  "Selecting must both move Emacs and move herdr's focus."
  (let ((herdr-terminal-backend 'agent-windows)
        (target (generate-new-buffer " *target*"))
        focused)
    (unwind-protect
        (let ((herdr-term--agent-buffers (list (cons "w1:p1" target))))
          (cl-letf (((symbol-function 'herdr-rpc-call)
                     (lambda (method params)
                       (when (equal method "pane.focus")
                         (setq focused (alist-get 'pane_id params))))))
            (save-window-excursion
              (herdr-select--consult-visit "w1:p1")
              (should (eq target (current-buffer)))))
          (should (equal "w1:p1" focused)))
      (kill-buffer target))))

;;; Which pane a command acts on

(ert-deftest herdr-select-target-prefers-the-buffer-you-are-in ()
  "Acting from inside one agent's buffer used to target whichever pane
you last went to, because herdr's focus is server-side and does not
follow Emacs."
  (let* ((herdr-terminal-backend 'agent-windows)
         (mine (generate-new-buffer " *pane-b*"))
         (herdr-term--agent-buffers (list (cons "w1:pB" mine)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA")
             (panes . (((pane_id . "w1:pA")) ((pane_id . "w1:pB")))))))
         (current-prefix-arg nil))
    (unwind-protect
        (with-current-buffer mine
          (should (equal "w1:pB" (herdr-select-target-pane))))
      (kill-buffer mine))))

(ert-deftest herdr-select-target-falls-back-to-herdr-focus ()
  "Outside a herdr buffer there is no local answer, so use the server's."
  (let* ((herdr-terminal-backend 'agent-windows)
         (herdr-term--agent-buffers nil)
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA") (panes . (((pane_id . "w1:pA")))))))
         (current-prefix-arg nil))
    (with-temp-buffer
      (should (equal "w1:pA" (herdr-select-target-pane))))))

(ert-deftest herdr-select-target-ignores-a-buffer-whose-pane-is-gone ()
  (let* ((herdr-terminal-backend 'agent-windows)
         (orphan (generate-new-buffer " *orphan*"))
         (herdr-term--agent-buffers (list (cons "w1:gone" orphan)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA") (panes . (((pane_id . "w1:pA")))))))
         (current-prefix-arg nil))
    (unwind-protect
        (with-current-buffer orphan
          (should (equal "w1:pA" (herdr-select-target-pane))))
      (kill-buffer orphan))))

(ert-deftest herdr-select-target-under-session-uses-herdr-focus ()
  "One buffer serves every pane there, so it cannot disambiguate."
  (let* ((herdr-terminal-backend 'session)
         (buffer (get-buffer-create herdr-term-session-buffer-name))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA") (panes . (((pane_id . "w1:pA")))))))
         (current-prefix-arg nil))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (herdr-term-pane-for-buffer))
          (should (equal "w1:pA" (herdr-select-target-pane))))
      (kill-buffer buffer))))

;;; Available-shell selection for agent.start

(ert-deftest herdr-select-available-shell-lists-only-unoccupied-panes ()
  "Panes running a real agent are occupied and must not be offered."
  (herdr-select-test-with-state
      '(((pane_id . "w1:p1") (agent . "claude"))
        ((pane_id . "w1:p2") (agent . nil))
        ((pane_id . "w1:p3")))
    (should (equal '("w1:p2" "w1:p3")
                   (herdr-select--available-shell-ids (herdr-state-current))))))

(ert-deftest herdr-select-available-shell-counts-adopted-shells-as-free ()
  "An adopted shell wears a label but runs no agent, so it stays available."
  (let ((herdr-shell-agent-name "herdr-shell"))
    (herdr-select-test-with-state
        `(((pane_id . "w1:p1") (agent . ,herdr-shell-agent-name))
          ((pane_id . "w1:p2") (agent . "codex")))
      (should (equal '("w1:p1")
                     (herdr-select--available-shell-ids
                      (herdr-state-current)))))))

;;; A "create new" entry lets agent.start make its own shell

(ert-deftest herdr-select-available-shell-offers-create-new-last ()
  "The picker always ends with a create-new entry, so a fresh shell can
be made without leaving the command."
  (let (offered)
    (herdr-select-test-with-state
        '(((pane_id . "w1:p2") (agent . nil))
          ((pane_id . "w1:p3")))
      (cl-letf (((symbol-function 'herdr-state-refresh) #'ignore)
                ((symbol-function 'herdr-select--read)
                 (lambda (_prompt candidates &rest _)
                   (setq offered candidates) (car candidates))))
        (herdr-select-available-shell)
        (should (member herdr-select-create-new-shell offered))
        (should (equal herdr-select-create-new-shell (car (last offered))))))))

(ert-deftest herdr-select-available-shell-returns-create-new-when-chosen ()
  "Choosing create-new yields a marker the caller acts on, not a pane id."
  (herdr-select-test-with-state
      '(((pane_id . "w1:p2") (agent . nil)))
    (cl-letf (((symbol-function 'herdr-state-refresh) #'ignore)
              ((symbol-function 'herdr-select--read)
               (lambda (&rest _) herdr-select-create-new-shell)))
      (should (eq :create-new (herdr-select-available-shell))))))

(ert-deftest herdr-select-available-shell-returns-a-chosen-pane-id ()
  "Choosing a real pane returns its id, exactly as before."
  (herdr-select-test-with-state
      '(((pane_id . "w1:p2") (agent . nil)))
    (cl-letf (((symbol-function 'herdr-state-refresh) #'ignore)
              ((symbol-function 'herdr-select--read)
               (lambda (&rest _) "w1:p2")))
      (should (equal "w1:p2" (herdr-select-available-shell))))))

(ert-deftest herdr-select-available-shell-offers-create-new-when-none-free ()
  "With every pane busy the create-new entry is the only choice, so the
command no longer dead-ends with an error."
  (let (offered)
    (herdr-select-test-with-state
        '(((pane_id . "w1:p1") (agent . "claude"))
          ((pane_id . "w1:p2") (agent . "codex")))
      (cl-letf (((symbol-function 'herdr-state-refresh) #'ignore)
                ((symbol-function 'herdr-select--read)
                 (lambda (_prompt candidates &rest _)
                   (setq offered candidates) (car candidates))))
        (herdr-select-available-shell)
        (should (equal (list herdr-select-create-new-shell) offered))))))

(ert-deftest herdr-select-annotates-the-create-new-entry ()
  "The create-new entry explains what picking it will do."
  (should (string-match-p
           "split" (herdr-select--annotate-pane herdr-select-create-new-shell))))

(provide 'herdr-select-test)
;;; herdr-select-test.el ends here
