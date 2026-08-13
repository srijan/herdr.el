;;; herdr-deps-test.el --- Tests for the dependency search -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
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

(ert-deftest herdr-deps-leaves-an-already-loadable-library-alone ()
  "EXTRA_LOAD_PATH wins outright over the search.

The Makefile puts EXTRA_LOAD_PATH on the load path before this file is
loaded, so a developer testing against a particular checkout of
magit-section must not have a copy found elsewhere pushed in front of
it.  `locate-library' answering is what stops the search, and the
directories returned are what would have been added — an empty return
is the assertion that nothing was."
  (should-not (herdr-deps-add-to-load-path)))

(ert-deftest herdr-deps-locate-finds-a-package-directory ()
  "Compiled or not, and nil rather than a guess when nothing matches."
  (let ((directory (file-name-directory (locate-library "magit-section"))))
    (should (equal (directory-file-name directory)
                   (directory-file-name
                    (herdr-deps-locate "magit-section" (list directory)))))
    (should-not (herdr-deps-locate "herdr-no-such-library"
                                   (list directory)))))

(provide 'herdr-deps-test)
;;; herdr-deps-test.el ends here
