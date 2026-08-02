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

(ert-deftest herdr-select-consult-source-lists-panes ()
  (herdr-select-test-with-state
      '(((pane_id . "w1:p1") (agent . "claude")) ((pane_id . "w1:p2")))
    (let ((source (herdr-select--consult-source)))
      (should (equal 'herdr-pane (plist-get source :category)))
      (should (equal '("w1:p1" "w1:p2") (funcall (plist-get source :items)))))))

(provide 'herdr-select-test)
;;; herdr-select-test.el ends here
