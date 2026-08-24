;;; herdr-call-test.el --- Tests for the schema-driven escape hatch -*- lexical-binding: t; -*-

;;; Commentary:

;; `herdr-call' is the one command that can reach all eighty-nine server
;; methods, and it had no test file at all: every mutation tried against
;; it — a no-op annotator, an inverted picker condition, inverted
;; prefix-argument logic, an inverted display threshold, reversed
;; parameter order — survived the whole suite.
;;
;; What is worth pinning here is not the prompting, which is
;; `herdr-schema''s job and is tested there.  It is the three decisions
;; this file makes on top of it: which parameters get asked for, which
;; prompt is used for an id, and what ends up on the wire in what order.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'herdr-test-helper)
(require 'herdr-call)

(defvar herdr-call-test--fixture
  (expand-file-name "fixtures/schema-protocol-20.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defmacro herdr-call-test-with-schema (&rest body)
  "Run BODY with the captured protocol-20 schema loaded and no live state."
  (declare (indent 0) (debug t))
  `(let ((herdr-schema--cache nil)
         (herdr-schema--cache-version nil)
         (herdr-state--current (herdr-state-from-snapshot nil))
         (current-prefix-arg nil))
     (herdr-schema-load-file herdr-call-test--fixture)
     ,@body))

;;; Annotation

(ert-deftest herdr-call-annotates-a-method-with-its-required-params ()
  "The annotation is the only thing that says what a method will ask for.

A method with nothing required annotates as the empty string rather than
as two stray spaces, because the completion frame appends it verbatim."
  (herdr-call-test-with-schema
    (let ((annotation (herdr-call--annotate "pane.read")))
      (should (string-prefix-p "  " annotation))
      (should (string-match-p "pane_id" annotation))
      (should (string-match-p "source" annotation))
      ;; Space-separated, not run together.
      (should (string-match-p "\\_<source\\_>" annotation)))
    (should (equal "" (herdr-call--annotate "ping")))
    (should (equal "" (herdr-call--annotate "no.such.method")))))

;;; The method prompt

(ert-deftest herdr-call-offers-every-schema-method-and-annotates-it ()
  "The completion table has to carry the annotator, not just the names.

Asserting the returned string proves nothing — that is whatever the stub
said.  What matters is the collection handed to `completing-read': every
method the schema knows, a category so marginalia and friends can hook
it, the annotator wired in, and a require-match, since a method the
server does not have is a guaranteed error rather than a typo to
tolerate."
  (herdr-call-test-with-schema
    (let (table require-match)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &optional _pred require &rest _)
                   (setq table collection require-match require)
                   "ping")))
        (should (equal "ping" (herdr-call--read-method))))
      (should require-match)
      (let ((candidates (funcall table "" nil t)))
        (should (member "ping" candidates))
        (should (member "pane.read" candidates))
        (should (= (length (herdr-schema-methods)) (length candidates))))
      (let ((metadata (funcall table "" nil 'metadata)))
        (should (eq 'metadata (car metadata)))
        (should (eq 'herdr-method (alist-get 'category (cdr metadata))))
        (should (eq 'herdr-call--annotate
                    (alist-get 'annotation-function (cdr metadata))))))))

;;; Reading one parameter

(ert-deftest herdr-call-reads-an-id-through-the-pane-picker ()
  "A generic string prompt for a pane id is worse than the picker, and
`pane_id' and `target' are the two parameters that name one.

Both halves are asserted, because a mutation that always picks — or
never picks — leaves the other branch looking right."
  (herdr-call-test-with-schema
    (let ((herdr-state--current
           (herdr-state-from-snapshot '((panes . (((pane_id . "w1:p1"))))))))
      (cl-letf (((symbol-function 'herdr-select-pane)
                 (lambda (&rest _) "picked"))
                ((symbol-function 'herdr-schema-read-param)
                 (lambda (&rest _) "typed")))
        (should (equal "picked" (herdr-call--read-value "pane.read" "pane_id")))
        (should (equal "picked" (herdr-call--read-value "pane.move" "target")))
        ;; Anything else still goes through the schema's own prompt.
        (should (equal "typed" (herdr-call--read-value "pane.read" "lines")))))))

(ert-deftest herdr-call-picker-omits-an-empty-choice-rather-than-sending-it ()
  "`herdr-call's own docstring promises an empty prompt omits the
parameter, same as every other schema-read-param branch.  But
`completing-read' returns \"\" rather than nil on empty input, so the
picker branch has to map that back to nil itself, or an optional
pane_id/target left blank goes out as an explicit empty string instead
of being left off the request."
  (herdr-call-test-with-schema
    (let ((herdr-state--current
           (herdr-state-from-snapshot '((panes . (((pane_id . "w1:p1"))))))))
      (cl-letf (((symbol-function 'herdr-select-pane) (lambda (&rest _) "")))
        (should-not (herdr-call--read-value "pane.read" "pane_id"))))))

(ert-deftest herdr-call-falls-back-to-typing-an-id-when-no-panes-are-known ()
  "With an empty cache the picker has nothing to offer, and offering an
empty completion list instead of a prompt is how the escape hatch stops
being one."
  (herdr-call-test-with-schema
    (cl-letf (((symbol-function 'herdr-select-pane)
               (lambda (&rest _) (error "The picker must not be used here")))
              ((symbol-function 'herdr-schema-read-param)
               (lambda (&rest _) "typed")))
      (should (equal "typed" (herdr-call--read-value "pane.read" "pane_id"))))))

;;; What goes on the wire

(defmacro herdr-call-test--answering (answers method params &rest body)
  "Run BODY against a fake server, answering prompts from ANSWERS.
ANSWERS is an alist of parameter name to value; a name absent from it
reads as an empty prompt, which is nil.  METHOD is bound to the method
the server received and PARAMS to its parameters, in the order they
arrived on the wire."
  (declare (indent 3) (debug t))
  `(let (,method ,params)
     (cl-letf (((symbol-function 'herdr-schema-read-param)
                (lambda (_method name) (cdr (assoc name ,answers)))))
       (herdr-test-with-server
           (lambda (req)
             (setq ,method (alist-get 'method req)
                   ,params (alist-get 'params req))
             (cons (herdr-test-ok req '((type . "ok"))) nil))
         ,@body))))

(ert-deftest herdr-call-sends-only-the-required-params-without-a-prefix ()
  "Optional parameters are asked for only on request; that is the whole
difference the prefix argument makes, and it decides both what the user
is prompted for and what the server is sent."
  (herdr-call-test-with-schema
    (herdr-call-test--answering '(("pane_id" . "w1:p1") ("source" . "visible")
                                  ("lines" . 40))
        method params
      (herdr-call "pane.read")
      (should (equal "pane.read" method))
      (should (equal "w1:p1" (alist-get 'pane_id params)))
      (should (equal "visible" (alist-get 'source params)))
      ;; `lines' is optional, so it was never asked for and never sent —
      ;; even though an answer for it was available.
      (should-not (assq 'lines params))
      (should (equal (sort (mapcar #'car params) #'string<)
                     '(pane_id source))))))

(ert-deftest herdr-call-sends-every-answered-param-with-a-prefix ()
  "With a prefix argument the optional parameters are offered too, and an
empty answer omits that parameter rather than sending a null."
  (herdr-call-test-with-schema
    (let ((current-prefix-arg '(4)))
      (herdr-call-test--answering '(("pane_id" . "w1:p1") ("source" . "visible")
                                    ("lines" . 40))
          method params
        (herdr-call "pane.read")
        (should (equal "pane.read" method))
        (should (equal 40 (alist-get 'lines params)))
        ;; Answered nowhere, so left out entirely rather than sent as null.
        (should-not (assq 'strip_ansi params))
        (should-not (assq 'format params))))))

(ert-deftest herdr-call-sends-params-in-the-order-it-asked-for-them ()
  "`herdr-call' builds its payload by pushing and reversing, and dropping
the reverse leaves a request that still works — JSON objects are
unordered — so nothing else in the suite would notice.  It is asserted
because the order is what the prompts followed, and a payload that reads
backwards from the questions is the kind of thing that is debugged for
an hour."
  (herdr-call-test-with-schema
    (herdr-call-test--answering '(("pane_id" . "w1:p1") ("source" . "visible"))
        method params
      (herdr-call "pane.read")
      (should (equal (herdr-schema-required "pane.read")
                     (mapcar (lambda (cell) (symbol-name (car cell))) params))))))

(ert-deftest herdr-call-returns-the-result-when-called-from-lisp ()
  "Non-interactively it is a function, so it answers with the result
rather than displaying it."
  (herdr-call-test-with-schema
    (cl-letf (((symbol-function 'herdr-call--display)
               (lambda (&rest _) (error "Must not display from Lisp"))))
      (herdr-test-with-server
          (lambda (req) (cons (herdr-test-ok req '((type . "pong"))) nil))
        (should (equal '((type . "pong")) (herdr-call "ping")))))))

;;; Displaying the answer

(ert-deftest herdr-call-shows-a-small-result-in-the-echo-area ()
  "A one-line answer in a pop-up window is a window to dismiss for
nothing, so the short case must not make a buffer at all."
  (let (said)
    (when (get-buffer "*herdr: ping*") (kill-buffer "*herdr: ping*"))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
      (should (equal '((protocol . 19)) (herdr-call--display "ping" '((protocol . 19))))))
    (should (string-match-p "ping" said))
    (should (string-match-p "protocol" said))
    (should-not (get-buffer "*herdr: ping*"))))

(ert-deftest herdr-call-shows-a-large-result-in-a-buffer ()
  "Past the threshold the echo area truncates, so the answer goes to a
buffer named for the method — and the result is still returned, because
`herdr-call' hands it back to its caller."
  (let ((result (mapcar (lambda (i) (cons (intern (format "pane_%d" i))
                                          "a value long enough to matter"))
                        (number-sequence 1 20)))
        (name "*herdr: pane.list*")
        said)
    (when (get-buffer name) (kill-buffer name))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'message)
                   (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
          (should (eq result (herdr-call--display "pane.list" result)))
          (should-not said)
          (should (get-buffer name))
          (with-current-buffer name
            (should (string-match-p "pane_20" (buffer-string)))
            (should (= (point) (point-min)))))
      (when (get-buffer name) (kill-buffer name)))))

(provide 'herdr-call-test)
;;; herdr-call-test.el ends here
