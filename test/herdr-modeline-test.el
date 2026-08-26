;;; herdr-modeline-test.el --- Tests for the modeline and notifications -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-tree)
(require 'herdr-modeline)

(defun herdr-modeline-test--state (&rest specs)
  "Build a state from SPECS, each (ID AGENT STATUS)."
  (herdr-state-from-snapshot
   `((panes . ,(mapcar (lambda (spec)
                         `((pane_id . ,(nth 0 spec))
                           (agent . ,(nth 1 spec))
                           (agent_status . ,(nth 2 spec))
                           (workspace_id . "w1")))
                       specs)))))

(ert-deftest herdr-modeline-segment-counts-noteworthy-statuses ()
  (should (equal "herdr:2\u23f81\u2713"
                 (herdr-modeline--segment
                  (herdr-modeline-test--state
                   '("w1:p1" "claude" "blocked")
                   '("w1:p2" "codex" "blocked")
                   '("w1:p3" "gemini" "done"))))))

(ert-deftest herdr-modeline-segment-omits-idle ()
  "An always-on count stops being read; idle agents are not news."
  (should (equal "" (herdr-modeline--segment
                     (herdr-modeline-test--state '("w1:p1" "claude" "idle"))))))

(ert-deftest herdr-modeline-segment-is-empty-without-agents ()
  (should (equal "" (herdr-modeline--segment (herdr-state-empty))))
  (should (equal "" (herdr-modeline--segment
                     (herdr-modeline-test--state '("w1:p1" nil nil))))))

(ert-deftest herdr-modeline-segment-shows-working ()
  (should (equal "herdr:1\u25b6"
                 (herdr-modeline--segment
                  (herdr-modeline-test--state '("w1:p1" "claude" "working"))))))

(ert-deftest herdr-modeline-counts-ignore-non-agent-panes ()
  (let ((counts (herdr-modeline--counts
                 (herdr-modeline-test--state '("w1:p1" "claude" "blocked")
                                           '("w1:p2" nil "unknown")))))
    (should (equal 1 (alist-get "blocked" counts nil nil #'equal)))
    (should (null (alist-get "unknown" counts nil nil #'equal)))))

(ert-deftest herdr-modeline-segment-uses-the-shared-glyphs ()
  "The modeline and the dispatcher must not disagree about a status."
  (should (equal (concat "herdr:1" (herdr-tree-glyph "blocked"))
                 (herdr-modeline--segment
                  (herdr-modeline-test--state '("w1:p1" "claude" "blocked"))))))

;;; Mode line wiring

(ert-deftest herdr-modeline-global-mode-string-leads-with-an-empty-string ()
  "A mode-line list starting with a symbol is read as a conditional.
On a fresh Emacs `global-mode-string' is nil, so appending our symbol
gave (herdr-modeline-string), which rendered as *invalid* in
every mode line."
  (let ((global-mode-string nil))
    (herdr-modeline--ensure-global-mode-string)
    (should (equal '("") global-mode-string))
    (add-to-list 'global-mode-string 'herdr-modeline-string t)
    (should (equal "" (car global-mode-string)))
    (should (memq 'herdr-modeline-string global-mode-string))))

(ert-deftest herdr-modeline-global-mode-string-preserves-existing-entries ()
  (let ((global-mode-string '("" display-time-string)))
    (herdr-modeline--ensure-global-mode-string)
    (should (equal '("" display-time-string) global-mode-string))))

(ert-deftest herdr-modeline-global-mode-string-prefixes-a-symbol-led-list ()
  (let ((global-mode-string '(display-time-string)))
    (herdr-modeline--ensure-global-mode-string)
    (should (equal '("" display-time-string) global-mode-string))))

(ert-deftest herdr-modeline-global-mode-string-tolerates-a-non-list ()
  (let ((global-mode-string "raw"))
    (herdr-modeline--ensure-global-mode-string)
    (should (equal '("" "raw") global-mode-string))))

(ert-deftest herdr-modeline-string-is-risky ()
  "Without this its keymap and mouse properties are stripped."
  (should (get 'herdr-modeline-string 'risky-local-variable)))

(ert-deftest herdr-modeline-refresh-pads-only-a-non-empty-count ()
  "An empty segment must be empty, not a lone space.

`global-mode-string' entries sit next to each other with nothing
between, so the segment carries its own leading space — and a segment
with nothing to say must not carry it, or the mode line grows a gap that
never goes away.  The function had no test, so either half of that could
invert unnoticed."
  (let ((herdr-modeline-string "stale")
        ;; Bound beside the string it shadows: the pair is assigned
        ;; together, and the unchanged-skip compares against this half.
        (herdr-modeline--text "stale"))
    (cl-letf (((symbol-function 'force-mode-line-update) #'ignore))
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "idle"))))
        (herdr-modeline--refresh)
        (should (equal "" herdr-modeline-string)))
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "blocked"))))
        (herdr-modeline--refresh)
        (should (string-prefix-p " herdr:" herdr-modeline-string))
        ;; The keymap is what makes the count clickable; stripping the
        ;; properties would leave a segment that only looks right.
        ;;
        ;; Asserting the map is present is not enough, and this test used
        ;; to stop there.  Renaming this file's prefix rewrote the click
        ;; target to `herdr-modeline', a function that does not exist, and
        ;; all 411 tests still passed: the map was there, it just led
        ;; nowhere.  Only the byte compiler noticed.  So check where it
        ;; goes, not that it goes somewhere — and note the target is
        ;; `herdr-agents', which lives in herdr-dispatch and is nothing to
        ;; do with this file's own `herdr-modeline-' names.
        (let ((map (get-text-property 1 'local-map herdr-modeline-string)))
          (should map)
          (should (eq #'herdr-agents (lookup-key map [mode-line mouse-1]))))))))

(ert-deftest herdr-modeline-refresh-redisplays-only-on-a-changed-segment ()
  "Unchanged text must not force every mode line in Emacs to redraw.

The change hook fires ~7.5 times a second per busy agent, and nearly
every one of those events is title churn the segment does not display.
An unconditional `force-mode-line-update' there redrew every frame's
mode lines several times a second for identical text — the reported
constant flicker.  So: two refreshes over the same state cost one
redisplay, and a refresh that changes the counts costs another."
  (let ((herdr-modeline-string "")
        (herdr-modeline--text "")
        (updates 0))
    (cl-letf (((symbol-function 'force-mode-line-update)
               (lambda (&rest _) (cl-incf updates))))
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "blocked"))))
        (herdr-modeline--refresh)
        (should (= 1 updates))
        (herdr-modeline--refresh)
        (should (= 1 updates)))
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "blocked")
                                         '("w1:p2" "codex" "blocked"))))
        (herdr-modeline--refresh)
        (should (= 2 updates))
        (should (string-prefix-p " herdr:" herdr-modeline-string))))))

;;; Notifications fire on a transition, not on an observation

(ert-deftest herdr-notify-fires-only-when-a-status-changes ()
  "The first sight of a status is not a change into it.

`herdr-notify--maybe' runs from `herdr-state-change-functions', so
without its `previous' guard every agent already sitting blocked would
announce itself the moment Emacs first heard about it, and again after
every restart and every resync.  The function had no test at all, so
dropping that guard passed the suite.

The whole sequence is walked, because each step is a different branch:
first sight, a real transition, the same status seen again, and a
transition into a status nobody asked to hear about."
  (let ((herdr-notify--last-status (make-hash-table :test 'equal))
        (herdr-notify-statuses '("blocked" "done"))
        notified)
    (cl-letf (((symbol-function 'herdr-notify--send)
               (lambda (title body) (push (cons title body) notified))))
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "working"))))
        (herdr-notify--maybe))
      (should-not notified)
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "blocked"))))
        (herdr-notify--maybe))
      (should (= 1 (length notified)))
      (should (string-match-p "claude" (car (car notified))))
      (should (string-match-p "blocked" (car (car notified))))
      ;; Seen again is not another transition.
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "blocked"))))
        (herdr-notify--maybe))
      (should (= 1 (length notified)))
      ;; A transition into a status nobody asked about stays quiet, but
      ;; is still recorded, so the next one back is a transition again.
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "idle"))))
        (herdr-notify--maybe))
      (should (= 1 (length notified)))
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "done"))))
        (herdr-notify--maybe))
      (should (= 2 (length notified))))))

(ert-deftest herdr-notify-does-not-announce-an-agent-that-was-already-blocked ()
  "The regression the `previous' guard exists to stop happens at startup,
not on a change.

The sequence test above never puts the guard on the path: its first
sighting is `working', which nobody opted into, so the
`herdr-notify-statuses' membership test already answers no and the guard
is never what decided.  Here the first sighting is `blocked' — a status
that IS opted into — so the only thing standing between it and a desktop
notification is having no `previous' to compare against.  Dropping that
conjunct fires one notification per agent on every Emacs start, every
reconnect and every resync.

The statuses are still recorded, or the first real transition afterwards
would be swallowed as though it were another first sighting."
  (let ((herdr-notify--last-status (make-hash-table :test 'equal))
        (herdr-notify-statuses '("blocked" "done"))
        notified)
    (cl-letf (((symbol-function 'herdr-notify--send)
               (lambda (&rest _) (push t notified))))
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "blocked")
                                       '("w1:p2" "codex" "done"))))
        (herdr-notify--maybe))
      (should-not notified)
      (should (= 2 (hash-table-count herdr-notify--last-status)))
      ;; And the transition that follows is still news.
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "done")
                                       '("w1:p2" "codex" "done"))))
        (herdr-notify--maybe))
      (should (= 1 (length notified))))))

(ert-deftest herdr-notify-fires-nothing-when-nothing-is-opted-into ()
  "Nil `herdr-notify-statuses' means never, and must not even record —
opting in later should then treat what is already on screen as history
rather than as news.

Asserting only that nothing was announced does not test the outer guard
at all: with the list nil the membership test inside answers no for
every status anyway, so the guard could be `(when t)' and this would
still hold.  What separates the two is the recording, which happens
above the membership test and below the guard — so the table is what is
asked about."
  (let ((herdr-notify--last-status (make-hash-table :test 'equal))
        (herdr-notify-statuses nil)
        notified)
    (cl-letf (((symbol-function 'herdr-notify--send)
               (lambda (&rest _) (push t notified))))
      (let ((herdr-state--current
             (herdr-modeline-test--state '("w1:p1" "claude" "blocked"))))
        (herdr-notify--maybe))
      (should-not notified)
      (should (= 0 (hash-table-count herdr-notify--last-status))))))

(ert-deftest herdr-modeline-mode-unhooks-itself-when-turned-off ()
  "Leaving the refresh on the state hook keeps recomputing a segment
nothing shows, for the rest of the session."
  (let ((herdr-state-change-functions nil)
        (global-mode-string nil))
    (cl-letf (((symbol-function 'herdr-modeline--refresh) #'ignore))
      (herdr-modeline-mode 1)
      (should (memq #'herdr-modeline--refresh herdr-state-change-functions))
      (should (memq 'herdr-modeline-string global-mode-string))
      (herdr-modeline-mode -1)
      (should-not (memq #'herdr-modeline--refresh herdr-state-change-functions))
      (should-not (memq 'herdr-modeline-string global-mode-string)))))

(provide 'herdr-modeline-test)
;;; herdr-modeline-test.el ends here
