;;; herdr-cmd-test.el --- Tests for the curated commands -*- lexical-binding: t; -*-

;;; Commentary:

;; Hand-written wrappers rot as the server changes.  These check the
;; whole registry against the captured schema; the `:live' drift test
;; does the same against a running server.

;;; Code:

(require 'ert)
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

(provide 'herdr-cmd-test)
;;; herdr-cmd-test.el ends here
