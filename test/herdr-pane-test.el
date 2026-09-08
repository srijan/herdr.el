;;; herdr-pane-test.el --- Tests for what a pane is called -*- lexical-binding: t; -*-

;;; Commentary:

;; Two names, two questions.  `herdr-pane-name' is what a pane is doing
;; and may be empty; `herdr-pane-identity' is what you call it and never
;; is.  Both are pure functions of their arguments — the facts identity
;; cannot read off the record arrive as arguments — so nothing here
;; builds a cache.

;;; Code:

(require 'ert)
(require 'herdr-pane)

;;; What a pane is doing

(ert-deftest herdr-pane-name-joins-the-label-and-the-title ()
  "Both halves: the label says which pane this is, the title says what it
is doing, and a row that dropped either lost something real."
  (should (equal "Lantern · fixing tests"
                 (herdr-pane-name
                  '((pane_id . "w16:p2") (label . "Lantern")
                    (terminal_title_stripped . "fixing tests"))))))


(ert-deftest herdr-pane-name-does-not-print-a-repeat ()
  (should (equal "Lantern"
                 (herdr-pane-name
                  '((pane_id . "w16:p2") (label . "Lantern")
                    (terminal_title_stripped . "Lantern"))))))


(ert-deftest herdr-pane-name-strips-the-spinner-from-the-title ()
  "The title half goes through `herdr-pane-steady-title' like it always
did, so a labelled pane does not reintroduce the churn."
  (should (equal "Lantern · fixing tests"
                 (herdr-pane-name
                  '((pane_id . "w16:p2") (label . "Lantern")
                    (terminal_title_stripped . "◐ fixing tests"))))))


(ert-deftest herdr-pane-name-is-just-the-label-without-a-title ()
  (should (equal "Lantern"
                 (herdr-pane-name
                  '((pane_id . "w16:p2") (label . "Lantern"))))))


(ert-deftest herdr-pane-name-falls-back-to-the-steady-title ()
  "An unlabelled pane — most of them — reads exactly as it did before."
  (should (equal "fixing tests"
                 (herdr-pane-name
                  '((pane_id . "w1:p1")
                    (terminal_title_stripped . "fixing tests"))))))


(ert-deftest herdr-pane-name-is-empty-with-neither ()
  (should (equal "" (herdr-pane-name '((pane_id . "w1:p1"))))))


(ert-deftest herdr-pane-keeps-the-words-of-a-title-it-normalises ()
  "Only the leading glyph run and the space after it come off.

A title is the agent's own words; stripping is for the animation, not
for the message.  A title that is nothing but a spinner is the one case
that ends up empty, and it says nothing anyway."
  (should (equal "Debug webmentions from fed.brid.gy"
                 (herdr-pane-steady-title
                  "◐ Debug webmentions from fed.brid.gy")))
  (should (equal "Debug webmentions" (herdr-pane-steady-title
                                      "Debug webmentions")))
  (should (equal "" (herdr-pane-steady-title "◑ ")))
  (should (equal "" (herdr-pane-steady-title "")))
  ;; Not from the middle or the end: those are the agent's characters.
  (should (equal "phase ◐ two" (herdr-pane-steady-title "phase ◐ two")))
  (should (equal "done ◑" (herdr-pane-steady-title "done ◑"))))


(ert-deftest herdr-pane-spinner-glyphs-are-quoted-into-the-character-class ()
  "The constant is interpolated into a regexp, and it invites editing.

Its docstring says to add a glyph when another agent turns up, so the
next character in it is chosen by whoever hits that.  Interpolated raw
between brackets, some characters stop being characters:

  a leading `^' negates the class — `[^◐]' matches everything that is
  NOT the spinner, so the first title word is deleted and the rest of
  the line with it, on every pane, silently;

  a `-' between two others makes a range — `[a-z]' is twenty-six
  characters nobody put there.

`regexp-opt-charset' quotes both back into literals (`[◐^]', `[az-]'),
and these are the two sets that tell the two spellings apart.  A set of
`]', `^' and `-' does NOT: Emacs happens to read `[]^-]' as three
literals either way, so a test using that one passes over the raw
version — which a mutation run found it doing."
  (let ((herdr-pane-spinner-glyphs '(?^ ?◐)))
    (should (equal "working" (herdr-pane-steady-title "^ working")))
    (should (equal "working" (herdr-pane-steady-title "◐ working")))
    ;; The whole point: a title with no glyph at its head keeps every
    ;; character it had.
    (should (equal "hello world" (herdr-pane-steady-title "hello world"))))
  (let ((herdr-pane-spinner-glyphs '(?a ?- ?z)))
    (should (equal "hello world" (herdr-pane-steady-title "hello world")))
    (should (equal "world" (herdr-pane-steady-title "az- world"))))
  ;; A single glyph is a class of one, which needs no brackets at all and
  ;; must still not swallow the character after it.
  (let ((herdr-pane-spinner-glyphs '(?◐)))
    (should (equal "working" (herdr-pane-steady-title "◐ working")))
    (should (equal "◑ working" (herdr-pane-steady-title "◑ working")))))


;;; What you call a pane

(ert-deftest herdr-pane-identity-prefers-the-name-somebody-set ()
  "`agent.rename\\=' outranks everything: it is the one name a person
chose for this pane and nothing else."
  (should (equal "Lantern"
                 (herdr-pane-identity
                  '((pane_id . "w1:p1") (label . "ignored")
                    (agent . "claude"))
                  "Lantern" "web"))))

(ert-deftest herdr-pane-identity-falls-through-to-the-label ()
  (should (equal "Lantern"
                 (herdr-pane-identity
                  '((pane_id . "w1:p1") (label . "Lantern")
                    (agent . "claude"))
                  nil "web"))))

(ert-deftest herdr-pane-identity-composes-the-kind-and-the-workspace ()
  "The common case: nobody has named this pane, so it is known by what
runs in it and where."
  (should (equal "claude@web"
                 (herdr-pane-identity
                  '((pane_id . "w1:p1") (agent . "claude")) nil "web"))))

(ert-deftest herdr-pane-identity-prefers-the-display-agent ()
  "`display_agent\\=' is what the server wants shown; `agent\\=' is what it
detected.  For a name, shown wins."
  (should (equal "opencode@web"
                 (herdr-pane-identity
                  '((pane_id . "w1:p1") (agent . "claude")
                    (display_agent . "opencode"))
                  nil "web"))))

(ert-deftest herdr-pane-identity-reads-a-plain-shell-naturally ()
  (should (equal "shell@web"
                 (herdr-pane-identity '((pane_id . "w1:p1")) nil "web"))))

(ert-deftest herdr-pane-identity-falls-back-to-the-workspace-id ()
  "Without a label passed in — a workspace the cache has not caught up
with — the id the pane carries still tells two panes apart, which a bare
kind would not."
  (should (equal "claude@w1"
                 (herdr-pane-identity
                  '((pane_id . "w1:p1") (workspace_id . "w1")
                    (agent . "claude"))))))

(ert-deftest herdr-pane-identity-is-never-empty ()
  "A prompt has to print something.  This is the floor callers fall back
to when `herdr-pane-name\\=' is empty."
  (should (equal "shell" (herdr-pane-identity '((pane_id . "w1:p1"))))))

(ert-deftest herdr-pane-identity-collides-for-two-unnamed-siblings ()
  "Stated, not fixed: callers that name a buffer with this must uniquify.
`herdr-term--unique-buffer-name\\=' is what does."
  (let ((one '((pane_id . "w1:p1") (agent . "claude") (workspace_id . "w1")))
        (two '((pane_id . "w1:p2") (agent . "claude") (workspace_id . "w1"))))
    (should (equal (herdr-pane-identity one) (herdr-pane-identity two)))))

(ert-deftest herdr-pane-name-and-identity-answer-different-questions ()
  "The whole reason this module exists.  One pane, two names: the row
shows what it is doing, the buffer is called what it is."
  (let ((pane '((pane_id . "w1:p1") (agent . "claude")
                (terminal_title_stripped . "Fix the reconcile order"))))
    (should (equal "Fix the reconcile order" (herdr-pane-name pane)))
    (should (equal "claude@web" (herdr-pane-identity pane nil "web")))))

(provide 'herdr-pane-test)
;;; herdr-pane-test.el ends here
