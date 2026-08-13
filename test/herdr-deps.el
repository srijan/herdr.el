;;; herdr-deps.el --- Put herdr's external dependencies on the load path -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Loaded by every Makefile target before anything else, so that
;; `emacs -Q' — which initialises no package system and reads no user
;; init — can still find magit-section and transient.
;;
;; What this replaces.  herdr-dispatch.el requires magit-section, and
;; `make test' used to cope by letting the dispatcher tests skip
;; themselves when the library was absent, while `make compile' left
;; the file out of the compile set for the same reason.  Measured on
;; this checkout, a bare `make test' ran 325 tests and skipped 97 of
;; them — every skip a `herdr-dispatch-' test, which is to say the
;; whole dashboard — and reported success.  The guard was spelled
;; `(require 'magit-section nil t)', which cannot tell an absent
;; dependency from a broken one, so a magit-section that failed to
;; load read as a skip too.
;;
;; magit-section is a declared dependency in herdr.el's
;; `Package-Requires'.  A declared dependency that a third of the suite
;; silently arranges to do without is not a dependency, so it is found
;; here instead, and failing to find it is a hard error naming the
;; escape hatch.  Nothing skips.

;;; Code:

(require 'seq)

(defconst herdr-deps-libraries
  '("magit-section" "transient" "compat" "dash" "llama" "cond-let")
  "Libraries herdr needs that Emacs does not ship.

magit-section and transient are the two herdr itself requires; the rest
are magit-section's own dependencies, which have to be reachable for it
to load at all.  A library on this list that cannot be found is not by
itself an error — magit-section's dependency set differs between
versions, and demanding all six would break on a version that needs
five.  `herdr-deps-required-libraries' is what must be found.")

(defconst herdr-deps-required-libraries '("magit-section" "transient")
  "Libraries whose absence stops the build.
These two are named in a `Package-Requires' header; the rest of
`herdr-deps-libraries' is whatever those two happen to pull in.")

(defun herdr-deps-roots ()
  "Return the directories under which installed packages are looked for.

Each is a directory of package directories rather than a load-path entry
itself; see `herdr-deps-directories'.

The first entry is relative to this checkout rather than to any home
directory: elpaca clones a package into `var/elpaca/sources/NAME' and
builds it into `var/elpaca/builds/NAME', so from the repository root
`../../builds/' names the built copies of everything installed
alongside herdr, wherever the user keeps their configuration.  The rest
cover the same question asked of `user-emacs-directory' — elpaca again,
then package.el, then straight.el — for a checkout that lives somewhere
else entirely."
  (let ((repository (expand-file-name
                     ".." (file-name-directory
                           (or load-file-name buffer-file-name
                               default-directory)))))
    (list (expand-file-name "../../builds/" repository)
          (expand-file-name "var/elpaca/builds/" user-emacs-directory)
          (expand-file-name "elpa/" user-emacs-directory)
          (expand-file-name "straight/build/" user-emacs-directory))))

(defun herdr-deps-directories ()
  "Return every directory that might hold an installed package.

The immediate subdirectories of `herdr-deps-roots', which is the shape
all three package managers share: one directory per package, named for
it and — under package.el — for its version, so the names cannot be
predicted and the directory listing is what answers instead.

Sorted, and the roots stay in their own order, so that the list this
returns is the same list on every machine and every run.  It was read
with NOSORT and taken first-hit-wins, which made the answer the
filesystem's `readdir' order — reproducibly wrong rather than randomly
so, and invisible either way; see `herdr-deps-locate'."
  (seq-mapcat (lambda (root)
                (when (file-directory-p root)
                  (seq-filter #'file-directory-p
                              (directory-files root t "\\`[^.]"))))
              (herdr-deps-roots)))

(defun herdr-deps-version (library directory)
  "Return the version DIRECTORY\\='s name encodes for LIBRARY, or nil.
Nil for a directory named exactly LIBRARY, and for a suffix that is not
a version at all — `version-to-list' signals on those, and a name nobody
can parse is not evidence of anything."
  (let ((name (file-name-nondirectory (directory-file-name directory))))
    (when (string-prefix-p (concat library "-") name)
      (ignore-errors
        (version-to-list (substring name (1+ (length library))))))))

(defun herdr-deps-bare-p (library directory)
  "Return non-nil when DIRECTORY is named exactly LIBRARY.
That is the elpaca and straight.el shape, and the thing
`herdr-deps-preferred-p' ranks above every versioned copy.  It is asked
by name rather than inferred from `herdr-deps-version' answering nil,
because that answer has two causes and only one of them is this one."
  (equal library (file-name-nondirectory (directory-file-name directory))))

(defun herdr-deps-preferred-p (library a b)
  "Return non-nil when directory A should be preferred to B for LIBRARY.

Three ranks, best first: a bare name — a directory called exactly
LIBRARY — then a parseable version, highest first, then everything else.
Ties are left to `sort', which is stable, so they keep the order
`herdr-deps-directories' produced and root precedence stands.

That ranking is not arbitrary.  A bare name is what elpaca and
straight.el produce, and they keep exactly one directory per package, so
there is nothing to choose between and the root order already expresses
the preference.  Versioned names are package.el's, and package.el is the
one manager that leaves older copies behind — which is the whole reason
any of this compares versions.

The third rank is the fix for reading `herdr-deps-version' as though nil
meant bare.  It does not: it also means a suffix nobody can parse, so a
directory called `magit-section-git' or `magit-section-melpa' was
classed as unversioned and thereby outranked every properly versioned
copy beside it.  That inverts the ranking rather than merely failing to
apply it, so an unparseable name now loses to a version instead of
beating it, and only an exact match still wins outright."
  (let ((bare-a (herdr-deps-bare-p library a))
        (bare-b (herdr-deps-bare-p library b))
        (va (herdr-deps-version library a))
        (vb (herdr-deps-version library b)))
    (cond ((or bare-a bare-b) (and bare-a (not bare-b)))
          ((and va vb) (version-list-< vb va))
          (va t)
          (vb nil))))

(defun herdr-deps-locate (library directories)
  "Return the directory in DIRECTORIES holding LIBRARY, or nil.

Compiled or not: a package manager that has byte-compiled the library
and deleted nothing is the ordinary case, and either file makes the
directory the right load-path entry.

The highest version wins, by `herdr-deps-preferred-p'.  This used to
take the first hit in `directory-files' order with NOSORT, which is
`readdir' order: given `magit-section-20200101.1', `-20230601.1' and
`-20260101.1' side by side under a package.el `elpa', it resolved to the
middle one — neither newest nor oldest, just whatever the filesystem
listed first.  A search that finds the wrong copy is worse than the skip
it replaced, because the suite still reports every test passing; nothing
about a stale magit-section says so out loud."
  (car (sort (seq-filter
              (lambda (directory)
                (or (file-exists-p (expand-file-name (concat library ".el")
                                                     directory))
                    (file-exists-p (expand-file-name (concat library ".elc")
                                                     directory))))
              directories)
             (lambda (a b) (herdr-deps-preferred-p library a b)))))

(defun herdr-deps-add-to-load-path ()
  "Put every library in `herdr-deps-libraries' on `load-path'.

Libraries `locate-library' already answers for are left alone, so an
EXTRA_LOAD_PATH given on the command line wins outright over anything
found by searching — the Makefile puts it on the load path before this
file is loaded.  Returns the directories added."
  (delq nil
        (let ((directories (herdr-deps-directories)))
          (mapcar (lambda (library)
                    (unless (locate-library library)
                      (when-let* ((found (herdr-deps-locate library
                                                            directories)))
                        (add-to-list 'load-path found)
                        found)))
                  herdr-deps-libraries))))

(defun herdr-deps-ensure ()
  "Make herdr's external dependencies loadable, or fail saying how to.

An error rather than a warning, and raised while the load path is still
the only thing that has happened: a missing dependency that is allowed
past this point becomes a suite that skips a third of itself and passes,
which is the failure this file exists to end."
  (herdr-deps-add-to-load-path)
  (dolist (library herdr-deps-required-libraries)
    (unless (locate-library library)
      (error "herdr: cannot find %s.  Searched %s.  Supply it with
  make <target> EXTRA_LOAD_PATH=\"/path/to/%s /path/to/its/deps\""
             library
             (mapconcat #'identity (herdr-deps-roots) ", ")
             library))))

(herdr-deps-ensure)

(provide 'herdr-deps)
;;; herdr-deps.el ends here
