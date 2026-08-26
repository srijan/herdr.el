;;; herdr-select-test.el --- Tests for herdr completion -*- lexical-binding: t; -*-

;;; Commentary:

;; The integrations here touch third-party variables on their own
;; release schedules.  `marginalia-annotator-registry' was renamed to
;; `marginalia-annotators', and referencing the old name unguarded broke
;; Emacs startup with a void-variable error.  A cosmetic integration
;; must degrade instead.

;;; Code:

(require 'ert)
(require 'herdr-select)
(require 'herdr-term)

;; Declared, deliberately unbound: `let' on an undeclared symbol under
;; lexical binding is invisible to `boundp' elsewhere, which is exactly
;; what these tests exercise.  Marking them special makes the bindings
;; dynamic without giving them a global value, so the "API is unknown"
;; case still sees them unbound.
(defvar marginalia-annotators)
(defvar marginalia-annotator-registry)

(defmacro herdr-select-test-with-state (panes &rest body)
  (declare (indent 1) (debug t))
  `(let ((herdr-state--current (herdr-state-from-snapshot `((panes . ,,panes)))))
     ,@body))

;;; Annotations

(ert-deftest herdr-select-annotates-an-agent-pane ()
  (herdr-select-test-with-state
      '(((pane_id . "w1:p1") (agent . "claude") (agent_status . "blocked")
         (cwd . "/tmp") (terminal_title_stripped . "Claude Code")))
    (let ((annotation (herdr-select--annotate-pane "w1:p1")))
      (should (string-match-p "claude" annotation))
      (should (string-match-p "⏸" annotation))
      (should (string-match-p "Claude Code" annotation))
      ;; The directory is the other half of what makes two panes running
      ;; the same agent tellable apart.
      (should (string-match-p "/tmp" annotation)))))

(ert-deftest herdr-select-annotation-carries-the-pane-label ()
  "A renamed pane, or a plugin pane seated with its manifest title, is
findable by the name it is known by as well as by what it is doing."
  (herdr-select-test-with-state
      '(((pane_id . "w16:p2") (agent . "claude") (agent_status . "working")
         (label . "Lantern") (cwd . "/tmp")
         (terminal_title_stripped . "fixing tests")))
    (let ((annotation (herdr-select--annotate-pane "w16:p2")))
      (should (string-match-p "Lantern" annotation))
      (should (string-match-p "fixing tests" annotation)))))

(ert-deftest herdr-select-annotates-a-shell-pane ()
  (herdr-select-test-with-state
      '(((pane_id . "w1:p2") (agent . nil) (cwd . "/tmp")))
    (should (string-match-p "shell" (herdr-select--annotate-pane "w1:p2")))))

(ert-deftest herdr-select-annotation-of-an-unknown-pane-is-empty ()
  (herdr-select-test-with-state '()
    (should (equal "" (herdr-select--annotate-pane "w9:p9")))))

;;; Marginalia registration must not be able to break loading

(ert-deftest herdr-select-registers-with-current-marginalia-api ()
  (let ((marginalia-annotators nil))
    (herdr-select--register-marginalia)
    (should (assq 'herdr-pane marginalia-annotators))
    (should (equal '(herdr-pane herdr-select--annotate-pane builtin none)
                   (assq 'herdr-pane marginalia-annotators)))))

(ert-deftest herdr-select-registers-with-the-pre-rename-marginalia-api ()
  "Older marginalia called it `marginalia-annotator-registry'."
  (let ((marginalia-annotator-registry nil))
    (herdr-select--register-marginalia)
    (should (assq 'herdr-tab marginalia-annotator-registry))))

(ert-deftest herdr-select-registration-is-a-noop-when-the-api-is-unknown ()
  "A third rename must degrade to no annotations, not a void-variable."
  (should-not (herdr-select--register-marginalia)))

(ert-deftest herdr-select-registration-does-not-duplicate ()
  (let ((marginalia-annotators nil))
    (herdr-select--register-marginalia)
    (herdr-select--register-marginalia)
    (should (= 3 (length marginalia-annotators)))))

;;; Consult source

(ert-deftest herdr-select-consult-source-only-lists-panes-with-buffers ()
  "A buffer switcher must not offer entries it cannot switch to.
Listing every pane put plain shells in `consult-buffer' that had no
buffer at all: they appeared in the list and selecting one left you
where you were."
  (let ((herdr-terminal-backend 'agent-windows)
        (live (generate-new-buffer " *pane-with-buffer*")))
    (unwind-protect
        (let ((herdr-term--agent-buffers (list (cons "w1:p1" live)))
              (herdr-state--current
               (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1") (agent . "claude"))
                            ((pane_id . "w1:p2"))))))))
          (should (equal '("w1:p1") (herdr-select-panes-with-buffers)))
          (let ((source (herdr-select--consult-source)))
            (should (equal 'herdr-pane (plist-get source :category)))
            ;; The source reconciles against the server before listing;
            ;; stub that out so the suite stays hermetic.
            (cl-letf (((symbol-function 'herdr-state-reconcile-panes)
                       (lambda () nil)))
              (should (equal '("w1:p1")
                             (funcall (plist-get source :items)))))))
      (kill-buffer live))))

(ert-deftest herdr-select-consult-source-bounds-its-reconcile-timeout ()
  "This runs on every `consult-buffer', a path the user attributes to
buffer switching rather than to herdr.  Against a wedged server, an
unbounded reconcile here freezes ordinary buffer switching for the full
`herdr-rpc-timeout' — the same class of freeze `herdr-server-live-p'
and `herdr-term--poll-directories' already guard against by binding
down to `herdr-rpc-background-timeout'."
  (let ((herdr-state--current (herdr-state-from-snapshot nil))
        (herdr-rpc-timeout 10.0)
        (herdr-rpc-background-timeout 2.0)
        seen-timeout)
    (cl-letf (((symbol-function 'herdr-state-reconcile-panes)
               (lambda () (setq seen-timeout herdr-rpc-timeout) nil)))
      (funcall (plist-get (herdr-select--consult-source) :items))
      (should (equal 2.0 seen-timeout))
      ;; The binding must not leak past the call.
      (should (equal 10.0 herdr-rpc-timeout)))))

(ert-deftest herdr-select-consult-source-lists-everything-under-session ()
  "Under `session' every pane shares the one buffer, so all qualify."
  (let* ((herdr-terminal-backend 'session)
         (buffer (get-buffer-create herdr-term-session-buffer-name)))
    (unwind-protect
        (let ((herdr-state--current
               (herdr-state-from-snapshot
                '((panes . (((pane_id . "w1:p1")) ((pane_id . "w1:p2"))))))))
          (should (equal '("w1:p1" "w1:p2") (herdr-select-panes-with-buffers))))
      (kill-buffer buffer))))

(ert-deftest herdr-select-consult-visit-switches-and-focuses ()
  "Selecting must both move Emacs and move herdr's focus."
  (let ((herdr-terminal-backend 'agent-windows)
        (target (generate-new-buffer " *target*"))
        focused)
    (unwind-protect
        (let ((herdr-term--agent-buffers (list (cons "w1:p1" target))))
          (cl-letf (((symbol-function 'herdr-rpc-call)
                     (lambda (method params)
                       (when (equal method "pane.focus")
                         (setq focused (alist-get 'pane_id params))))))
            (save-window-excursion
              (herdr-select--consult-visit "w1:p1")
              (should (eq target (current-buffer)))))
          (should (equal "w1:p1" focused)))
      (kill-buffer target))))

;;; Which pane a command acts on

(ert-deftest herdr-select-target-prefers-the-buffer-you-are-in ()
  "Acting from inside one agent's buffer used to target whichever pane
you last went to, because herdr's focus is server-side and does not
follow Emacs."
  (let* ((herdr-terminal-backend 'agent-windows)
         (mine (generate-new-buffer " *pane-b*"))
         (herdr-term--agent-buffers (list (cons "w1:pB" mine)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA")
             (panes . (((pane_id . "w1:pA")) ((pane_id . "w1:pB")))))))
         (current-prefix-arg nil))
    (unwind-protect
        (with-current-buffer mine
          (should (equal "w1:pB" (herdr-select-target-pane))))
      (kill-buffer mine))))

(ert-deftest herdr-select-target-falls-back-to-herdr-focus ()
  "Outside a herdr buffer there is no local answer, so use the server's."
  (let* ((herdr-terminal-backend 'agent-windows)
         (herdr-term--agent-buffers nil)
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA") (panes . (((pane_id . "w1:pA")))))))
         (current-prefix-arg nil))
    (with-temp-buffer
      (should (equal "w1:pA" (herdr-select-target-pane))))))

(ert-deftest herdr-select-target-ignores-a-buffer-whose-pane-is-gone ()
  (let* ((herdr-terminal-backend 'agent-windows)
         (orphan (generate-new-buffer " *orphan*"))
         (herdr-term--agent-buffers (list (cons "w1:gone" orphan)))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA") (panes . (((pane_id . "w1:pA")))))))
         (current-prefix-arg nil))
    (unwind-protect
        (with-current-buffer orphan
          (should (equal "w1:pA" (herdr-select-target-pane))))
      (kill-buffer orphan))))

(ert-deftest herdr-select-target-under-session-uses-herdr-focus ()
  "One buffer serves every pane there, so it cannot disambiguate."
  (let* ((herdr-terminal-backend 'session)
         (buffer (get-buffer-create herdr-term-session-buffer-name))
         (herdr-state--current
          (herdr-state-from-snapshot
           '((focused_pane_id . "w1:pA") (panes . (((pane_id . "w1:pA")))))))
         (current-prefix-arg nil))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (herdr-term-pane-for-buffer))
          (should (equal "w1:pA" (herdr-select-target-pane))))
      (kill-buffer buffer))))

;;; Available-shell selection for agent.start

(ert-deftest herdr-select-available-shell-lists-only-unoccupied-panes ()
  "Panes running a real agent are occupied and must not be offered."
  (herdr-select-test-with-state
      '(((pane_id . "w1:p1") (agent . "claude"))
        ((pane_id . "w1:p2") (agent . nil))
        ((pane_id . "w1:p3")))
    (should (equal '("w1:p2" "w1:p3")
                   (herdr-select--available-shell-ids (herdr-state-current))))))

;;; A "create new" entry lets agent.start make its own shell

(ert-deftest herdr-select-available-shell-offers-create-new-last ()
  "The picker always ends with a create-new entry, so a fresh shell can
be made without leaving the command."
  (let (offered)
    (herdr-select-test-with-state
        '(((pane_id . "w1:p2") (agent . nil))
          ((pane_id . "w1:p3")))
      (cl-letf (((symbol-function 'herdr-state-refresh) #'ignore)
                ((symbol-function 'herdr-select--read)
                 (lambda (_prompt candidates &rest _)
                   (setq offered candidates) (car candidates))))
        (herdr-select-available-shell)
        (should (member herdr-select-create-new-shell offered))
        (should (equal herdr-select-create-new-shell (car (last offered))))))))

(ert-deftest herdr-select-available-shell-returns-create-new-when-chosen ()
  "Choosing create-new yields a marker the caller acts on, not a pane id."
  (herdr-select-test-with-state
      '(((pane_id . "w1:p2") (agent . nil)))
    (cl-letf (((symbol-function 'herdr-state-refresh) #'ignore)
              ((symbol-function 'herdr-select--read)
               ;; A copy, because `completing-read' returns one: matching
               ;; the marker by identity works only against the constant.
               (lambda (&rest _) (copy-sequence herdr-select-create-new-shell))))
      (should (eq :create-new (herdr-select-available-shell))))))

(ert-deftest herdr-select-available-shell-returns-a-chosen-pane-id ()
  "Choosing a real pane returns its id, exactly as before."
  (herdr-select-test-with-state
      '(((pane_id . "w1:p2") (agent . nil)))
    (cl-letf (((symbol-function 'herdr-state-refresh) #'ignore)
              ((symbol-function 'herdr-select--read)
               (lambda (&rest _) "w1:p2")))
      (should (equal "w1:p2" (herdr-select-available-shell))))))

(ert-deftest herdr-select-available-shell-offers-create-new-when-none-free ()
  "With every pane busy the create-new entry is the only choice, so the
command no longer dead-ends with an error."
  (let (offered)
    (herdr-select-test-with-state
        '(((pane_id . "w1:p1") (agent . "claude"))
          ((pane_id . "w1:p2") (agent . "codex")))
      (cl-letf (((symbol-function 'herdr-state-refresh) #'ignore)
                ((symbol-function 'herdr-select--read)
                 (lambda (_prompt candidates &rest _)
                   (setq offered candidates) (car candidates))))
        (herdr-select-available-shell)
        (should (equal (list herdr-select-create-new-shell) offered))))))

(ert-deftest herdr-select-annotates-the-create-new-entry ()
  "The create-new entry explains what picking it will do.

Annotated through a copy of the marker, not the marker itself:
`completing-read' hands back a fresh string, so an `eq' comparison in
the annotator would pass against the constant here and answer nothing at
all in use."
  (should (string-match-p
           "tab" (herdr-select--annotate-pane
                  (copy-sequence herdr-select-create-new-shell)))))

;;; Every glyph, and the two annotators nothing exercised

(ert-deftest herdr-select-glyphs-every-status-distinctly ()
  "One status was covered and the other four were not, so swapping
working, done and idle around went unnoticed.  All five are asked for,
and asserted to be distinct — a mapping that answers the same glyph for
two statuses says nothing on screen."
  (let ((glyphs (mapcar #'herdr-select--status-glyph
                        '("working" "blocked" "done" "idle" "no-such-status"))))
    (should (equal '("▶" "⏸" "✓" "·" " ") glyphs))
    (should (= 5 (length (delete-dups (copy-sequence glyphs)))))))

(ert-deftest herdr-select-annotates-a-workspace-by-its-own-id ()
  "The annotator matches rows on `workspace_id'; reading any other field
annotates every workspace with the first one's label."
  (let ((herdr-state--current
         (herdr-state-from-snapshot
          '((workspaces . (((workspace_id . "w1") (label . "first")
                            (pane_count . 3))
                           ((workspace_id . "w2") (label . "second")
                            (pane_count . 1))))))))
    (should (string-match-p "second" (herdr-select--annotate-workspace "w2")))
    (should (string-match-p "1 panes" (herdr-select--annotate-workspace "w2")))
    (should (string-match-p "first" (herdr-select--annotate-workspace "w1")))
    (should (string-match-p "3 panes" (herdr-select--annotate-workspace "w1")))
    (should (equal "" (herdr-select--annotate-workspace "w9")))))

(ert-deftest herdr-select-annotates-a-tab-by-its-own-id ()
  "The same defect, in the same shape, one function down."
  (let ((herdr-state--current
         (herdr-state-from-snapshot
          '((tabs . (((tab_id . "w1:t1") (label . "build") (pane_count . 2))
                     ((tab_id . "w1:t2") (label . "edit") (pane_count . 5))))))))
    (should (string-match-p "edit" (herdr-select--annotate-tab "w1:t2")))
    (should (string-match-p "5 panes" (herdr-select--annotate-tab "w1:t2")))
    (should (string-match-p "build" (herdr-select--annotate-tab "w1:t1")))
    (should (equal "" (herdr-select--annotate-tab "w9:t9")))))

(ert-deftest herdr-select-read-refuses-an-empty-candidate-list ()
  "An empty completion prompt looks broken rather than empty, so the
error names herdr instead."
  (should-error (herdr-select--read "x: " nil 'herdr-pane #'ignore)
                :type 'user-error))

(ert-deftest herdr-select-read-tags-its-table-with-category-and-annotator ()
  "The category is what marginalia and embark key off, and the annotator
is the only reason the picker shows anything but bare ids."
  (let (table)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _) (setq table collection) "a")))
      (herdr-select--read "x: " '("a" "b") 'herdr-pane
                          #'herdr-select--annotate-pane))
    (let ((metadata (funcall table "" nil 'metadata)))
      (should (eq 'herdr-pane (alist-get 'category (cdr metadata))))
      (should (eq #'herdr-select--annotate-pane
                  (alist-get 'annotation-function (cdr metadata)))))
    (should (equal '("a" "b") (funcall table "" nil t)))))

(provide 'herdr-select-test)
;;; herdr-select-test.el ends here
