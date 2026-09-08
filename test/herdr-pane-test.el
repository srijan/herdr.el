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
  "An unlabelled pane — most of them — reads exactly as it did before,
and steady means steady: the spinner comes off this half too, which is
the half most panes are named by."
  (should (equal "fixing tests"
                 (herdr-pane-name
                  '((pane_id . "w1:p1")
                    (terminal_title_stripped . "fixing tests")))))
  (should (equal "fixing tests"
                 (herdr-pane-name
                  '((pane_id . "w1:p1")
                    (terminal_title_stripped . "◐ fixing tests"))))))


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

(ert-deftest herdr-pane-identity-treats-an-empty-string-as-absent ()
  "The server sends \"\" for a pane nobody named, and an empty name reads
as a missing one.  Before this, a pane labelled \"\" was called nothing at
all, and a workspace labelled \"\" made every pane in it `claude@\='."
  (should (equal "claude@web"
                 (herdr-pane-identity
                  '((pane_id . "w1:p1") (label . "") (agent . "claude"))
                  "" "web")))
  (should (equal "claude@w1"
                 (herdr-pane-identity
                  '((pane_id . "w1:p1") (workspace_id . "w1")
                    (agent . "claude"))
                  nil "")))
  (should (equal "shell" (herdr-pane-identity '((label . "")))))
  ;; An empty `display_agent' must not mask the agent that was detected:
  ;; the fallback is what `display_agent' is for.
  (should (equal "claude@w1"
                 (herdr-pane-identity
                  '((pane_id . "w1:p1") (workspace_id . "w1")
                    (display_agent . "") (agent . "claude")))))
  (should (equal "claude" (herdr-pane-display-agent
                           '((display_agent . "") (agent . "claude"))))))

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

;;; Fields

(ert-deftest herdr-pane-directory-prefers-cwd ()
  (should (equal "/tmp/" (herdr-pane-directory
                          '((cwd . "/tmp") (foreground_cwd . "/usr")))))
  (should (equal "/usr/" (herdr-pane-directory
                          '((foreground_cwd . "/usr")))))
  (should (null (herdr-pane-directory '((pane_id . "w1:p1")))))
  (should (null (herdr-pane-directory
                 '((cwd . "/definitely/not/here/at/all"))))))

(ert-deftest herdr-pane-label-is-a-significant-field ()
  "A `pane.rename' must redraw the surfaces that now show the label.
Left off `herdr-pane-significant-fields', a rename reached the
cache silently and appeared nowhere until an unrelated change happened
to redraw.  It is safe to watch: unlike the terminal title it moves only
when somebody moves it."
  (should (memq 'label herdr-pane-significant-fields))
  (should (herdr-pane-differs-p
           '((pane_id . "w16:p2") (agent . "claude"))
           '((pane_id . "w16:p2") (agent . "claude") (label . "Lantern"))))
  ;; The volatile ones stay off it.
  (should-not (herdr-pane-differs-p
               '((pane_id . "w16:p2") (agent . "claude")
                 (terminal_title_stripped . "a"))
               '((pane_id . "w16:p2") (agent . "claude")
                 (terminal_title_stripped . "b")))))


(ert-deftest herdr-pane-attach-args-target-the-terminal-stream ()
  "Attach goes through `herdr terminal attach', which takes any pane."
  (should (equal '("terminal" "attach" "t7")
                 (herdr-pane-attach-args '((pane_id . "w1:p1") (terminal_id . "t7")) nil)))
  (should (equal '("terminal" "attach" "t7" "--takeover")
                 (herdr-pane-attach-args '((pane_id . "w1:p1") (terminal_id . "t7")) t))))

(ert-deftest herdr-pane-attach-args-refuses-a-pane-without-a-terminal-id ()
  (should-error (herdr-pane-attach-args '((pane_id . "w1:p1")) nil)
                :type 'user-error))


;;; The seam, asserted rather than hoped for

(defconst herdr-pane-test--source-directory
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "The package root, found from this file rather than from `default-directory'.
`make test' and a test run from inside Emacs do not agree about the
latter.")

(defun herdr-pane-test--sources ()
  "Return the package's own source files, `herdr-pane.el' excluded."
  (seq-remove (lambda (file)
                (equal "herdr-pane.el" (file-name-nondirectory file)))
              (directory-files herdr-pane-test--source-directory t
                               "\\`herdr.*\\.el\\'")))

(ert-deftest herdr-pane-is-the-only-file-that-reads-a-pane-record ()
  "The wire lives in one file, and this is what keeps it there.

Before this module the six surfaces each destructured the record herdr
sends, so a field rename was a grep and a hope.  The rule is narrow on
purpose: a variable called `pane' holds a pane record, and only
`herdr-pane.el' may read a field off one.  It cannot catch a pane bound
to some other name — `alist-get' on an event payload called `data' is
legitimate and looks identical — so it is a floor, not a proof."
  (let (offenders)
    (dolist (file (herdr-pane-test--sources))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        ;; `pane)' and `pane nil)' and a line break between them: the
        ;; three-argument form and a wrapped call are the two ways the
        ;; first version of this regexp was walked past.
        (while (re-search-forward "(alist-get[ \t\n]+'[a-z_]+[ \t\n]+pane[ \t\n)]"
                                  nil t)
          (push (format "%s:%d" (file-name-nondirectory file)
                        (line-number-at-pos))
                offenders))))
    (should-not offenders)))

(ert-deftest herdr-pane-requires-no-herdr-module ()
  "A leaf, and it has to stay one.

`herdr-state' requires this file, so a `require' pointing back would be
a cycle.  It is also what keeps both names pure: the facts identity
cannot read off the record arrive as arguments precisely because there
is no cache to ask."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "herdr-pane.el" herdr-pane-test--source-directory))
    (goto-char (point-min))
    ;; Not anchored to column zero: `eval-when-compile' and `with-eval-
    ;; after-load' both indent a `require' out of a column-zero match.
    (should-not (re-search-forward "(require 'herdr" nil t))))

(provide 'herdr-pane-test)
;;; herdr-pane-test.el ends here
