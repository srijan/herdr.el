;;; herdr-agents-test.el --- Tests for the agent surface -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'herdr-tree)
(require 'herdr-agents)

(defun herdr-agents-test--state (&rest specs)
  "Build a state from SPECS, each (ID AGENT STATUS)."
  (herdr-state-from-snapshot
   `((panes . ,(mapcar (lambda (spec)
                         `((pane_id . ,(nth 0 spec))
                           (agent . ,(nth 1 spec))
                           (agent_status . ,(nth 2 spec))
                           (workspace_id . "w1")))
                       specs)))))

(ert-deftest herdr-agents-segment-counts-noteworthy-statuses ()
  (should (equal "herdr:2\u23f81\u2713"
                 (herdr-agents--segment
                  (herdr-agents-test--state
                   '("w1:p1" "claude" "blocked")
                   '("w1:p2" "codex" "blocked")
                   '("w1:p3" "gemini" "done"))))))

(ert-deftest herdr-agents-segment-omits-idle ()
  "An always-on count stops being read; idle agents are not news."
  (should (equal "" (herdr-agents--segment
                     (herdr-agents-test--state '("w1:p1" "claude" "idle"))))))

(ert-deftest herdr-agents-segment-is-empty-without-agents ()
  (should (equal "" (herdr-agents--segment (herdr-state-empty))))
  (should (equal "" (herdr-agents--segment
                     (herdr-agents-test--state '("w1:p1" nil nil))))))

(ert-deftest herdr-agents-segment-shows-working ()
  (should (equal "herdr:1\u25b6"
                 (herdr-agents--segment
                  (herdr-agents-test--state '("w1:p1" "claude" "working"))))))

(ert-deftest herdr-agents-counts-ignore-non-agent-panes ()
  (let ((counts (herdr-agents--counts
                 (herdr-agents-test--state '("w1:p1" "claude" "blocked")
                                           '("w1:p2" nil "unknown")))))
    (should (equal 1 (alist-get "blocked" counts nil nil #'equal)))
    (should (null (alist-get "unknown" counts nil nil #'equal)))))

(ert-deftest herdr-agents-segment-uses-the-shared-glyphs ()
  "The modeline and the dispatcher must not disagree about a status."
  (should (equal (concat "herdr:1" (herdr-tree-glyph "blocked"))
                 (herdr-agents--segment
                  (herdr-agents-test--state '("w1:p1" "claude" "blocked"))))))

(ert-deftest herdr-agents-segment-ignores-adopted-shells ()
  "An adopted shell has a buffer but is not an agent; it must not count."
  (should (equal "herdr:1⏸"
                 (herdr-agents--segment
                  (herdr-agents-test--state
                   '("w1:p1" "claude" "blocked")
                   '("w1:p2" "shell" "blocked"))))))

;;; Mode line wiring

(ert-deftest herdr-agents-global-mode-string-leads-with-an-empty-string ()
  "A mode-line list starting with a symbol is read as a conditional.
On a fresh Emacs `global-mode-string' is nil, so appending our symbol
gave (herdr-agents-mode-line-string), which rendered as *invalid* in
every mode line."
  (let ((global-mode-string nil))
    (herdr-agents--ensure-global-mode-string)
    (should (equal '("") global-mode-string))
    (add-to-list 'global-mode-string 'herdr-agents-mode-line-string t)
    (should (equal "" (car global-mode-string)))
    (should (memq 'herdr-agents-mode-line-string global-mode-string))))

(ert-deftest herdr-agents-global-mode-string-preserves-existing-entries ()
  (let ((global-mode-string '("" display-time-string)))
    (herdr-agents--ensure-global-mode-string)
    (should (equal '("" display-time-string) global-mode-string))))

(ert-deftest herdr-agents-global-mode-string-prefixes-a-symbol-led-list ()
  (let ((global-mode-string '(display-time-string)))
    (herdr-agents--ensure-global-mode-string)
    (should (equal '("" display-time-string) global-mode-string))))

(ert-deftest herdr-agents-global-mode-string-tolerates-a-non-list ()
  (let ((global-mode-string "raw"))
    (herdr-agents--ensure-global-mode-string)
    (should (equal '("" "raw") global-mode-string))))

(ert-deftest herdr-agents-mode-line-string-is-risky ()
  "Without this its keymap and mouse properties are stripped."
  (should (get 'herdr-agents-mode-line-string 'risky-local-variable)))

(provide 'herdr-agents-test)
;;; herdr-agents-test.el ends here
