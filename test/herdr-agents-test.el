;;; herdr-agents-test.el --- Tests for the agent surface -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
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

;;; Notifications fire on a transition, not on an observation

(ert-deftest herdr-agents-notifies-only-when-a-status-changes ()
  "The first sight of a status is not a change into it.

`herdr-agents--maybe-notify' runs from `herdr-state-change-hook', so
without its `previous' guard every agent already sitting blocked would
announce itself the moment Emacs first heard about it, and again after
every restart and every resync.  The function had no test at all, so
dropping that guard passed the suite.

The whole sequence is walked, because each step is a different branch:
first sight, a real transition, the same status seen again, and a
transition into a status nobody asked to hear about."
  (let ((herdr-agents--last-status (make-hash-table :test 'equal))
        (herdr-notify-statuses '("blocked" "done"))
        notified)
    (cl-letf (((symbol-function 'herdr-agents--notify)
               (lambda (title body) (push (cons title body) notified))))
      (let ((herdr-state--current
             (herdr-agents-test--state '("w1:p1" "claude" "working"))))
        (herdr-agents--maybe-notify))
      (should-not notified)
      (let ((herdr-state--current
             (herdr-agents-test--state '("w1:p1" "claude" "blocked"))))
        (herdr-agents--maybe-notify))
      (should (= 1 (length notified)))
      (should (string-match-p "claude" (car (car notified))))
      (should (string-match-p "blocked" (car (car notified))))
      ;; Seen again is not another transition.
      (let ((herdr-state--current
             (herdr-agents-test--state '("w1:p1" "claude" "blocked"))))
        (herdr-agents--maybe-notify))
      (should (= 1 (length notified)))
      ;; A transition into a status nobody asked about stays quiet, but
      ;; is still recorded, so the next one back is a transition again.
      (let ((herdr-state--current
             (herdr-agents-test--state '("w1:p1" "claude" "idle"))))
        (herdr-agents--maybe-notify))
      (should (= 1 (length notified)))
      (let ((herdr-state--current
             (herdr-agents-test--state '("w1:p1" "claude" "done"))))
        (herdr-agents--maybe-notify))
      (should (= 2 (length notified))))))

(ert-deftest herdr-agents-notifies-nothing-when-nothing-is-opted-into ()
  "Nil `herdr-notify-statuses' means never, and must not even record —
opting in later should then treat what is already on screen as history
rather than as news."
  (let ((herdr-agents--last-status (make-hash-table :test 'equal))
        (herdr-notify-statuses nil)
        notified)
    (cl-letf (((symbol-function 'herdr-agents--notify)
               (lambda (&rest _) (push t notified))))
      (let ((herdr-state--current
             (herdr-agents-test--state '("w1:p1" "claude" "blocked"))))
        (herdr-agents--maybe-notify))
      (should-not notified))))

(ert-deftest herdr-agents-mode-line-mode-unhooks-itself-when-turned-off ()
  "Leaving the refresh on the state hook keeps recomputing a segment
nothing shows, for the rest of the session."
  (let ((herdr-state-change-hook nil)
        (global-mode-string nil))
    (cl-letf (((symbol-function 'herdr-agents--refresh-segment) #'ignore))
      (herdr-agents-mode-line-mode 1)
      (should (memq #'herdr-agents--refresh-segment herdr-state-change-hook))
      (should (memq 'herdr-agents-mode-line-string global-mode-string))
      (herdr-agents-mode-line-mode -1)
      (should-not (memq #'herdr-agents--refresh-segment herdr-state-change-hook))
      (should-not (memq 'herdr-agents-mode-line-string global-mode-string)))))

(provide 'herdr-agents-test)
;;; herdr-agents-test.el ends here
