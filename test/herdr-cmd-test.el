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
               (lambda () (setq asked t))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-tab-focus "w1:t2")
        (should asked)))))

(ert-deftest herdr-workspace-focus-follows-in-emacs ()
  (let (asked)
    (cl-letf (((symbol-function 'herdr-term-select-focused)
               (lambda () (setq asked t))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-workspace-focus "w2")
        (should asked)))))

;;; Panes created from Emacs must become visible

(ert-deftest herdr-cmd-created-pane-is-adopted-so-it-gets-a-buffer ()
  "Under `agent-windows' a new pane is a plain shell, which herdr will
not attach to.  A pane the user asked herdr.el to create should still
appear, so it is adopted."
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells t)
        adopted selected)
    (cl-letf (((symbol-function 'herdr-term-select-focused) (lambda () nil))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () "w1:p9"))
              ((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p)))
              ((symbol-function 'herdr-term-select-pane)
               (lambda (p) (setq selected p) t)))
      (herdr-cmd--follow-new-pane)
      (should (equal "w1:p9" adopted))
      (should (equal "w1:p9" selected)))))

(ert-deftest herdr-cmd-created-pane-is-not-adopted-when-disabled ()
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells nil)
        adopted)
    (cl-letf (((symbol-function 'herdr-term-select-focused) (lambda () nil))
              ((symbol-function 'herdr-cmd--current-pane-id) (lambda () "w1:p9"))
              ((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane)
      (should-not adopted))))

(ert-deftest herdr-cmd-created-pane-is-left-alone-under-session ()
  "The session backend shows every pane already; adopting would only
add a spurious row to herdr's own agents list."
  (let ((herdr-terminal-backend 'session)
        (herdr-adopt-created-shells t)
        adopted)
    (cl-letf (((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane)
      (should-not adopted))))

(ert-deftest herdr-cmd-existing-agent-pane-is-selected-not-adopted ()
  "If the new pane already has an agent there is nothing to adopt."
  (let ((herdr-terminal-backend 'agent-windows)
        (herdr-adopt-created-shells t)
        adopted)
    (cl-letf (((symbol-function 'herdr-term-select-focused) (lambda () t))
              ((symbol-function 'herdr-adopt-shell) (lambda (p) (setq adopted p))))
      (herdr-cmd--follow-new-pane)
      (should-not adopted))))

;;; Confirmations must not be left on screen

(ert-deftest herdr-pane-close-reports-afterwards ()
  "Closing reaps the pane's buffer, so redisplay happens while the
confirmation is still up; without a following message it sits there
looking unanswered."
  (dolist (answer '(t nil))
    (let (said)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) answer))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
        (herdr-test-with-server
            (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
          (herdr-pane-close "w1:p1")
          (should said)
          (should (string-match-p "w1:p1" said)))))))

(ert-deftest herdr-workspace-close-reports-afterwards ()
  (let (said)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "ok"))) nil))
        (herdr-workspace-close "w1")
        (should (string-match-p "w1" (or said "")))))))

(provide 'herdr-cmd-test)
;;; herdr-cmd-test.el ends here
