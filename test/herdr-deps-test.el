;;; herdr-deps-test.el --- Tests for the dependency search -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-deps)

(ert-deftest herdr-deps-makes-magit-section-loadable ()
  "The suite must run with magit-section present, always.

This is the whole of what `test/herdr-deps.el' is for.  A bare
`make test' used to run 325 tests and skip 97 of them — every
`herdr-dispatch-' test there is — and report success, because the
dispatcher tests were written to skip themselves when magit-section
could not be found.

The assertion is deliberately about `locate-library' rather than about
any test skipping.  A skip cannot be asserted from inside the suite, and
a `featurep' check would pass in a session where something else had
already loaded the library; what has to hold is that this file's search
made it findable under `emacs -Q'."
  (should (locate-library "magit-section"))
  (should (locate-library "transient"))
  (should (featurep 'herdr-dispatch)))

(ert-deftest herdr-deps-fails-loudly-when-a-dependency-is-missing ()
  "Not finding a required library must stop the build, not warn.

The guard this replaces was `(require 'magit-section nil t)', whose
whole failure mode was being quiet: it could not tell an absent
dependency from a broken one, and answered nil to both.  So the error is
the behaviour under test, and the message has to name the escape hatch —
a developer who hits this needs to be told how to supply the library,
not merely that it is gone."
  (let ((herdr-deps-libraries '("herdr-no-such-library"))
        (herdr-deps-required-libraries '("herdr-no-such-library")))
    (let ((message (cadr (should-error (herdr-deps-ensure) :type 'error))))
      (should (string-match-p "herdr-no-such-library" message))
      (should (string-match-p "EXTRA_LOAD_PATH" message)))))

(defmacro herdr-deps-test-with-planted (names &rest body)
  "Create a directory holding an empty `magit-section.el' per name in NAMES.
Bound to `root' for BODY, with the full paths in `planted' in NAMES
order, and removed afterwards."
  (declare (indent 1) (debug t))
  `(let* ((root (make-temp-file "herdr-deps-test" t))
          (planted (mapcar (lambda (name)
                             (let ((directory (expand-file-name name root)))
                               (make-directory directory)
                               (with-temp-file (expand-file-name
                                                "magit-section.el" directory))
                               directory))
                           ,names)))
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(ert-deftest herdr-deps-leaves-an-already-loadable-library-alone ()
  "EXTRA_LOAD_PATH wins outright over the search.

The Makefile puts EXTRA_LOAD_PATH on the load path before this file is
loaded, so a developer testing against a particular checkout of
magit-section must not have a copy found elsewhere pushed in front of
it.

A decoy is what makes this a test of precedence.  Asserting only that
the function returns nil proves nothing: by the time any test runs,
loading this file has already put every library on `load-path', so
`locate-library' answers for all of them and nil is the answer whatever
the guard does — it passes identically with EXTRA_LOAD_PATH unset, and
would go on passing with the guard deleted.

So `load-path' is cut down to a directory holding a magit-section.el of
our own.  `add-to-list' PREPENDS, so a search that ran anyway would put
the real magit-section in front of the decoy and `locate-library' would
change its answer.  Both halves are asserted: nothing was added, and the
decoy is still what resolves."
  (herdr-deps-test-with-planted '("decoy")
    (let ((load-path (list (car planted)))
          (herdr-deps-libraries '("magit-section")))
      (should-not (herdr-deps-add-to-load-path))
      (should (equal (expand-file-name "magit-section.el" (car planted))
                     (locate-library "magit-section"))))))

(ert-deftest herdr-deps-locate-finds-a-package-directory ()
  "Compiled or not, and nil rather than a guess when nothing matches."
  (let ((directory (file-name-directory (locate-library "magit-section"))))
    (should (equal (directory-file-name directory)
                   (directory-file-name
                    (herdr-deps-locate "magit-section" (list directory)))))
    (should-not (herdr-deps-locate "herdr-no-such-library"
                                   (list directory)))))

(ert-deftest herdr-deps-locate-prefers-the-highest-version ()
  "package.el leaves old copies behind, and the search used to pick one.

`directory-files' was read with NOSORT and the first hit taken, so the
answer was `readdir' order.  Given these three side by side under an
`elpa', that resolved to `20230601.1' — neither newest nor oldest, just
whatever the filesystem listed first.  A search that finds the wrong
copy is worse than the skip it replaced, because the suite still reports
every test passing.

The list is passed in an order where neither first-wins nor last-wins
would give the right answer, so a fix that merely reversed the old one
could not pass."
  (herdr-deps-test-with-planted '("magit-section-20230601.1"
                                  "magit-section-20260101.1"
                                  "magit-section-20200101.1")
    (should (equal (nth 1 planted)
                   (herdr-deps-locate "magit-section" planted)))
    (should (equal (nth 1 planted)
                   (herdr-deps-locate "magit-section" (reverse planted))))))

(ert-deftest herdr-deps-locate-compares-versions-not-strings ()
  "4.10.0 is newer than 4.9.0 and sorts before it as a string.

Sorting the directory listing by name would have looked like a fix and
would have picked 4.9.0 here.  Versions are numbers in parts, so they
are compared as `version-to-list' reads them."
  (herdr-deps-test-with-planted '("magit-section-4.9.0" "magit-section-4.10.0")
    (should (equal (nth 1 planted)
                   (herdr-deps-locate "magit-section" planted))))
  (should (equal '(4 10 0) (herdr-deps-version
                            "magit-section" "/x/magit-section-4.10.0")))
  (should-not (herdr-deps-version "magit-section" "/x/magit-section"))
  ;; A suffix that is not a version at all parses as nothing rather than
  ;; signalling out of the middle of a sort.
  (should-not (herdr-deps-version "magit-section" "/x/magit-section-git")))

(ert-deftest herdr-deps-locate-prefers-a-bare-name-and-keeps-root-order ()
  "elpaca and straight.el keep one directory per package, named exactly.

There is nothing to choose between copies there, so the root order — set
by `herdr-deps-roots', checkout-local first — is what should stand, and
an unversioned name therefore outranks a versioned one.  Two unversioned
names tie, and `sort' is stable, so the order they arrived in decides."
  (herdr-deps-test-with-planted '("magit-section-20260101.1" "magit-section")
    (should (equal (nth 1 planted)
                   (herdr-deps-locate "magit-section" planted))))
  (herdr-deps-test-with-planted '("first" "second")
    (should (equal (nth 0 planted)
                   (herdr-deps-locate "magit-section" planted)))
    (should (equal (nth 1 planted)
                   (herdr-deps-locate "magit-section" (reverse planted))))))

(ert-deftest herdr-deps-locate-does-not-let-an-unparseable-name-outrank-a-version ()
  "A name nobody can parse is not the bare elpaca shape, and used to win.

`herdr-deps-version' answers nil to two different questions — a
directory called exactly LIBRARY, and one whose suffix `version-to-list'
cannot read — and the ranking read both as the bare name that outranks
every versioned copy.  So `magit-section-git' beside
`magit-section-4.10.0' resolved to the checkout, and the suite went on
reporting every test passing against whatever was in it.  That is an
inverted ranking, not a missing one.

Each case is asserted in both orders, so neither first-wins nor
last-wins could pass by accident."
  ;; An unparseable suffix now loses to a real version.
  (herdr-deps-test-with-planted '("magit-section-git" "magit-section-4.10.0")
    (should (equal (nth 1 planted) (herdr-deps-locate "magit-section" planted)))
    (should (equal (nth 1 planted)
                   (herdr-deps-locate "magit-section" (reverse planted)))))
  ;; A bare name still outranks both.
  (herdr-deps-test-with-planted '("magit-section-melpa" "magit-section-4.10.0"
                                  "magit-section")
    (should (equal (nth 2 planted) (herdr-deps-locate "magit-section" planted)))
    (should (equal (nth 2 planted)
                   (herdr-deps-locate "magit-section" (reverse planted)))))
  ;; Two unparseable names tie, so the order they arrived in stands.
  (herdr-deps-test-with-planted '("magit-section-git" "magit-section-melpa")
    (should (equal (nth 0 planted) (herdr-deps-locate "magit-section" planted)))
    (should (equal (nth 1 planted)
                   (herdr-deps-locate "magit-section" (reverse planted)))))
  (should (herdr-deps-bare-p "magit-section" "/x/magit-section/"))
  (should-not (herdr-deps-bare-p "magit-section" "/x/magit-section-git")))

(ert-deftest herdr-deps-directories-are-sorted ()
  "The candidate list has to be the same list on every machine.
`directory-files' was read with NOSORT, which made the input to the
choice depend on the filesystem; the choice is version-ordered now, but
ties fall back to this order, so it may not be `readdir''s."
  (herdr-deps-test-with-planted '("c-pkg" "a-pkg" "b-pkg")
    (cl-letf (((symbol-function 'herdr-deps-roots)
               (lambda () (list root))))
      (should (equal (sort (copy-sequence planted) #'string<)
                     (herdr-deps-directories))))))

(provide 'herdr-deps-test)
;;; herdr-deps-test.el ends here
