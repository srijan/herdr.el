;;; herdr-schema-test.el --- Tests for herdr-schema -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-schema)

(defvar herdr-schema-test--fixture
  (expand-file-name "fixtures/schema-protocol-20.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro herdr-schema-test-with-fixture (&rest body)
  "Run BODY with the captured protocol-20 schema loaded."
  (declare (indent 0) (debug t))
  `(let ((herdr-schema--cache nil)
         (herdr-schema--cache-version nil))
     (herdr-schema-load-file herdr-schema-test--fixture)
     ,@body))

(ert-deftest herdr-schema-exposes-every-method ()
  (herdr-schema-test-with-fixture
    (let ((methods (herdr-schema-methods)))
      (should (= (length methods) 91))
      (should (member "ping" methods))
      (should (member "pane.read" methods))
      (should (member "events.subscribe" methods))
      (should (member "plugin.action.invoke" methods)))))

(ert-deftest herdr-schema-reports-required-params ()
  (herdr-schema-test-with-fixture
    (should (equal (sort (herdr-schema-required "pane.read") #'string<)
                   '("pane_id" "source")))
    (should (equal (herdr-schema-required "ping") nil))
    (should (member "direction" (herdr-schema-required "pane.split")))))

(ert-deftest herdr-schema-lists-all-params-not-only-required ()
  (herdr-schema-test-with-fixture
    (let ((names (mapcar #'car (herdr-schema-params "pane.read"))))
      (should (member "pane_id" names))
      (should (member "lines" names))
      (should (member "strip_ansi" names))
      (should (member "format" names)))))

(ert-deftest herdr-schema-resolves-ref-to-enum ()
  "`source' on pane.read is a $ref; its four values must resolve."
  (herdr-schema-test-with-fixture
    (let ((choices (herdr-schema-enum "pane.read" "source")))
      (should (equal (sort choices #'string<)
                     '("detection" "recent" "recent_unwrapped" "visible"))))))

(ert-deftest herdr-schema-resolves-nested-enum-for-split-direction ()
  (herdr-schema-test-with-fixture
    (should (equal (sort (herdr-schema-enum "pane.split" "direction") #'string<)
                   '("down" "right")))))

(ert-deftest herdr-schema-reports-boolean-params ()
  (herdr-schema-test-with-fixture
    (should (eq (herdr-schema-param-type "pane.split" "focus") 'boolean))
    (should (eq (herdr-schema-param-type "pane.read" "pane_id") 'string))
    (should (eq (herdr-schema-param-type "pane.read" "lines") 'integer))
    (should (eq (herdr-schema-param-type "pane.read" "source") 'enum))))

(ert-deftest herdr-schema-unknown-method-has-no-params ()
  (herdr-schema-test-with-fixture
    (should (null (herdr-schema-params "no.such.method")))
    (should (null (herdr-schema-required "no.such.method")))))

;;; The nullable shape, and the types nothing asked for

(ert-deftest herdr-schema-resolves-a-nullable-any-of-behind-a-ref ()
  "Optional parameters arrive as anyOf [<the real thing>, null].

That shape occurs sixteen times in this schema — it is how herdr spells
\"optional\" for anything that is not a bare scalar — and nothing
exercised it.  `pane.swap''s `direction' is one: without unwrapping the
anyOf and then the `$ref' behind it, the parameter has no type and no
enum at all, and `herdr-call' offers a free-text prompt where exactly
four values are legal."
  (herdr-schema-test-with-fixture
    (should (eq 'enum (herdr-schema-param-type "pane.swap" "direction")))
    (should (member "left" (herdr-schema-enum "pane.swap" "direction")))
    ;; Resolution must not land on the null branch, which is the other
    ;; thing picking the wrong element of the anyOf would do.
    (should-not (equal "null" (alist-get 'type (herdr-schema-param
                                                "pane.swap" "direction"))))))

(ert-deftest herdr-schema-maps-every-declared-type ()
  "number, object and array had no test, so the arm for each could answer
nil unnoticed — which is how `herdr-call' comes to prompt for a JSON
object as though it were a plain string."
  (herdr-schema-test-with-fixture
    (should (eq 'string (herdr-schema-param-type "pane.read" "pane_id")))
    (should (eq 'boolean (herdr-schema-param-type "pane.split" "focus")))
    (should (eq 'integer (herdr-schema-param-type "pane.read" "lines")))
    (should (eq 'number (herdr-schema-param-type "pane.split" "ratio")))
    (should (eq 'object (herdr-schema-param-type "workspace.create" "env")))
    (should (eq 'array (herdr-schema-param-type "agent.send_keys" "keys")))
    (should-not (herdr-schema-param-type "pane.read" "no_such_param"))))

;;; Prompting, one branch per JSON type

(ert-deftest herdr-schema-read-param-prompts-by-declared-type ()
  "Each type gets the prompt that can express it, and an empty answer
omits the parameter rather than sending an empty string, a zero, or a
JSON parse error."
  (herdr-schema-test-with-fixture
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "12"))
              ((symbol-function 'completing-read) (lambda (&rest _) "visible"))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (should (equal "visible" (herdr-schema-read-param "pane.read" "source")))
      (should (eq t (herdr-schema-read-param "pane.split" "focus")))
      (should (equal 12 (herdr-schema-read-param "pane.read" "lines")))
      (should (equal "12" (herdr-schema-read-param "pane.read" "pane_id"))))
    ;; A declined boolean is false on the wire, not absence.
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (should (eq :false (herdr-schema-read-param "pane.split" "focus"))))
    ;; Objects and arrays are read as JSON, not as text.
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "{\"A\": 1}")))
      (should (equal 1 (alist-get 'A (herdr-schema-read-param
                                      "workspace.create" "env")))))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "[\"a\"]")))
      (should (equal '("a") (herdr-schema-read-param
                             "agent.send_keys" "keys"))))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) ""))
              ((symbol-function 'completing-read) (lambda (&rest _) "")))
      (dolist (case '(("pane.read" "source") ("pane.read" "lines")
                      ("pane.read" "pane_id") ("workspace.create" "env")))
        (should-not (apply #'herdr-schema-read-param case))))))

(ert-deftest herdr-schema-read-param-says-which-prompts-are-optional ()
  "Being asked for five things with no way to tell which may be skipped
is what makes `herdr-call' with a prefix argument unusable."
  (herdr-schema-test-with-fixture
    (let (prompts)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &rest _) (push prompt prompts) "")))
        (herdr-schema-read-param "pane.read" "pane_id")
        (herdr-schema-read-param "pane.read" "lines"))
      (let ((for-lines (nth 0 prompts))
            (for-pane (nth 1 prompts)))
        (should (string-match-p "optional" for-lines))
        (should-not (string-match-p "optional" for-pane))
        (should (string-match-p "pane_id" for-pane))))))

;;; The cache is only good for the version it came from

(ert-deftest herdr-schema-refetches-when-the-server-version-moved ()
  "A cache kept across a herdr upgrade means the drift test checks the
old schema and reports no drift, which is the one thing it exists to
find."
  (let ((herdr-schema--cache '((schemas . nil)))
        (herdr-schema--cache-version "0.8.0")
        fetched)
    (cl-letf (((symbol-function 'herdr-schema--server-version)
               (lambda () "0.9.0"))
              ((symbol-function 'herdr-schema--fetch)
               (lambda () (setq fetched t herdr-schema--cache 'fresh))))
      (herdr-schema)
      (should fetched)
      (should (equal "0.9.0" herdr-schema--cache-version)))))

(ert-deftest herdr-schema-keeps-a-cache-the-server-still-matches ()
  "Shelling out to herdr on every schema question is the cost this cache
exists to avoid.

The version the server reports is a fresh string off the wire every
time, never the one already held, so the comparison has to be `equal'.
The stub copies its answer for that reason: handed the same object, an
`eq' would pass here and fail against a real server."
  (let ((herdr-schema--cache '((schemas . nil)))
        (herdr-schema--cache-version "0.9.0")
        fetched)
    (cl-letf (((symbol-function 'herdr-schema--server-version)
               (lambda () (copy-sequence "0.9.0")))
              ((symbol-function 'herdr-schema--fetch)
               (lambda () (setq fetched t))))
      (herdr-schema)
      (should-not fetched))
    ;; An unreachable server is not evidence that the cache is stale.
    (cl-letf (((symbol-function 'herdr-schema--server-version) (lambda () nil))
              ((symbol-function 'herdr-schema--fetch)
               (lambda () (setq fetched t))))
      (herdr-schema)
      (should-not fetched))))

(ert-deftest herdr-schema-resolve-picks-the-real-branch-whichever-way-round ()
  "Nothing promises the null branch comes second.

Resolution searches for the branch that is not null rather than taking a
fixed position, and that is only visible when the order is the other way
about — every anyOf in the captured schema happens to put the real thing
first, so the search and a plain `car' agree there."
  (should (equal '((type . "string"))
                 (herdr-schema-resolve
                  '((anyOf . (((type . "null")) ((type . "string"))))))))
  (should (equal '((type . "string"))
                 (herdr-schema-resolve
                  '((anyOf . (((type . "string")) ((type . "null"))))))))
  ;; Nothing but null: there is no real branch, so the node stands.
  (should (equal '((anyOf . (((type . "null")))))
                 (herdr-schema-resolve '((anyOf . (((type . "null")))))))))

(ert-deftest herdr-schema-fetch-shells-out-and-fails-loudly ()
  "The command is `herdr api schema --json', and a non-zero exit is an
error with a code rather than a silent nil: everything downstream would
otherwise see an empty schema and report that herdr has no methods.

Nothing is written to disk.  The schema used to be cached at
herdr/schema.json under `user-emacs-directory', which bought 7ms on a
command you invoke by hand and cost a 250K file whose staleness had to
be reasoned about — and whose read branch never once executed, because
the version it compared against lived only in a `defvar' that started
each session nil.  A scratch `user-emacs-directory' left empty by the
fetch catches a reintroduction at that path; the `boundp' catches one
at any other."
  (let ((herdr-schema--cache nil)
        (user-emacs-directory
         (file-name-as-directory (make-temp-file "herdr-schema-test" t)))
        args)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'call-process)
                     (lambda (program _in _buf _display &rest rest)
                       (setq args rest)
                       (insert "{\"protocol\": 17, \"schemas\": {}}")
                       (ignore program)
                       0)))
            (herdr-schema--fetch))
          (should (equal '("api" "schema" "--json") args))
          (should-not (directory-files user-emacs-directory nil "\\`[^.]"))
          (should-not (boundp 'herdr-schema-cache-file))
          (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 3)))
            (let ((err (should-error (herdr-schema--fetch) :type 'herdr-error)))
              (should (equal "schema_unavailable" (herdr-error-code err))))))
      (delete-directory user-emacs-directory t))))

(provide 'herdr-schema-test)
;;; herdr-schema-test.el ends here
