;;; herdr-cmd.el --- Curated herdr commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1"))

;;; Commentary:

;; Hand-written wrappers for the methods worth a keybinding.  herdr
;; exposes 89; generating all of them would produce a menu nobody can
;; read and prompts that cannot know a pane id should default to the
;; focused pane.  Everything not wrapped here stays reachable through
;; `herdr-call'.
;;
;; `herdr-cmd-methods' records what each command calls so the drift test
;; can check the whole set against the server's live schema.  When herdr
;; renames or removes something, that test fails instead of a user
;; discovering it as a runtime error.

;;; Code:

(require 'subr-x)
(require 'ansi-color)
(require 'herdr-rpc)
(require 'herdr-state)
(require 'herdr-select)
(require 'herdr-term)

(defconst herdr-cmd-methods
  '((herdr-pane-split-right      "pane.split"           "direction" "target_pane_id" "focus")
    (herdr-pane-split-down       "pane.split"           "direction" "target_pane_id" "focus")
    (herdr-pane-close            "pane.close"           "pane_id")
    (herdr-pane-zoom             "pane.zoom"            "pane_id" "mode")
    (herdr-pane-resize           "pane.resize"          "pane_id" "direction" "amount")
    (herdr-pane-swap             "pane.swap"            "pane_id" "direction")
    (herdr-pane-rename           "pane.rename"          "pane_id" "label")
    (herdr-pane-focus            "pane.focus"           "pane_id")
    (herdr-pane-read             "pane.read"            "pane_id" "source" "lines" "format" "strip_ansi")
    (herdr-pane-send-text        "pane.send_text"       "pane_id" "text")
    (herdr-pane-run              "pane.send_text"       "pane_id" "text")
    (herdr-pane-wait-for-output  "pane.wait_for_output" "pane_id" "source" "match" "timeout_ms")
    (herdr-tab-create            "tab.create"           "label" "focus")
    (herdr-tab-close             "tab.close"            "tab_id")
    (herdr-tab-focus             "tab.focus"            "tab_id")
    (herdr-tab-rename            "tab.rename"           "tab_id" "label")
    (herdr-workspace-create      "workspace.create"     "cwd" "label" "focus")
    (herdr-workspace-close       "workspace.close"      "workspace_id")
    (herdr-workspace-focus       "workspace.focus"      "workspace_id")
    (herdr-workspace-rename      "workspace.rename"     "workspace_id" "label")
    (herdr-worktree-list         "worktree.list"        "cwd")
    (herdr-worktree-create       "worktree.create"      "branch" "base" "cwd" "focus")
    (herdr-worktree-open         "worktree.open"        "branch" "cwd" "focus")
    (herdr-worktree-remove       "worktree.remove"      "workspace_id" "force")
    (herdr-agent-prompt          "agent.prompt"         "target" "text")
    (herdr-agent-read            "agent.read"           "target" "source" "lines" "format" "strip_ansi")
    (herdr-agent-wait            "agent.wait"           "target" "until" "timeout_ms")
    (herdr-agent-start           "agent.start"          "pane_id" "name" "kind")
    (herdr-agent-explain         "agent.explain"        "target")
    (herdr-agent-focus           "agent.focus"          "target")
    (herdr-notification-show     "notification.show"    "title" "body" "sound")
    (herdr-adopt-shell           "pane.report_agent"    "pane_id" "source" "agent" "state")
    (herdr-release-shell         "pane.release_agent"   "pane_id" "source" "agent"))
  "Every curated command, with the method and parameters it uses.
Each entry is (COMMAND METHOD PARAM...).  Verified against the live
schema by the drift test.")

(defcustom herdr-adopt-created-shells t
  "Obsolete and unread: no code path consults this variable any more.

It used to decide whether panes created from Emacs were adopted so they
got a buffer.  Every pane is attachable under `agent-windows' since
herdr 0.8.2, so a newly created pane is shown the same way regardless —
there is nothing left to opt into.  Kept only so a config that still
sets it does not error; use `herdr-adopt-shell' if you want a pane
labelled and reported as an agent, which is unrelated to whether it
gets a buffer."
  :type 'boolean
  :group 'herdr)
(make-obsolete-variable 'herdr-adopt-created-shells nil "0.2.0")

(defun herdr-cmd--current-pane-id ()
  "Return the id of the pane herdr currently considers focused."
  (ignore-errors
    (alist-get 'pane_id (alist-get 'pane (herdr-rpc-call "pane.current")))))

(defun herdr-cmd--created-pane-id (result)
  "Return the id of the pane a create-style RESULT reports.
`pane.split' answers with `pane'; `tab.create' and `workspace.create'
answer with `root_pane'.  Either shape names the pane just made."
  (alist-get 'pane_id (or (alist-get 'pane result)
                          (alist-get 'root_pane result))))

(defun herdr-cmd--follow-new-pane (pane-id)
  "Show PANE-ID, the pane a create command just made.
PANE-ID comes from the creating call's own response rather than a
follow-up `pane.current': herdr.el reaches the socket as a paneless
client, for which `pane.current' answers with the server's global focus.
The cache may not hold the pane yet — creation was announced on the
event stream — so a miss waits for reconciliation instead of failing."
  (when (and pane-id (eq herdr-terminal-backend 'agent-windows))
    (unless (herdr-term-select-pane pane-id)
      (herdr-cmd--select-pane-when-ready pane-id))))

(defun herdr-cmd--select-pane-when-ready (pane-id)
  "Select PANE-ID's buffer as soon as reconciliation has built it.

Gated on `herdr-state-generation', captured at the first attempt: this
chain keeps no handle anywhere for `herdr-stop' to cancel, so a
`herdr-stop' followed by a quick restart while a chain is still
retrying would otherwise go on selecting buffers for a session it no
longer belongs to — possibly a different pane's, if ids are reused.
Checking the generation on every attempt cannot cancel an already-armed
timer, but it makes each attempt after a restart a no-op instead of an
action, which is what matters."
  (let ((generation (herdr-state-generation)))
    (letrec ((attempts 0)
             (check
              (lambda ()
                (setq attempts (1+ attempts))
                (when (= generation (herdr-state-generation))
                  (cond
                   ((herdr-term-select-pane pane-id))
                   ((< attempts 20) (run-at-time 0.25 nil check)))))))
      (run-at-time 0.25 nil check))))

(defun herdr-cmd--read-source (&optional prompt)
  "Read a `ReadSource' value, defaulting to the one worth having.
PROMPT overrides the default \"Source: \" prompt text.
`recent_unwrapped' is the useful default: it is the whole recent
scrollback with terminal line-wrapping undone, which is what makes the
result greppable."
  (completing-read (or prompt "Source: ")
                   '("recent_unwrapped" "recent" "visible" "detection")
                   nil t nil nil "recent_unwrapped"))

;;; Panes

(defun herdr-pane-split-right (&optional target)
  "Split TARGET, or the focused pane, to the right."
  (interactive)
  (herdr-cmd--follow-new-pane
   (herdr-cmd--created-pane-id
    (herdr-rpc-call "pane.split"
                    `((direction . "right")
                      (target_pane_id . ,(or target (herdr-select-target-pane)))
                      (focus . t))))))

(defun herdr-pane-split-down (&optional target)
  "Split TARGET, or the focused pane, downward."
  (interactive)
  (herdr-cmd--follow-new-pane
   (herdr-cmd--created-pane-id
    (herdr-rpc-call "pane.split"
                    `((direction . "down")
                      (target_pane_id . ,(or target (herdr-select-target-pane)))
                      (focus . t))))))

(defun herdr-pane-close (&optional pane-id)
  "Close PANE-ID, or the pane being acted on."
  (interactive)
  (let ((pane (or pane-id (herdr-select-target-pane "Close pane: "))))
    (if (y-or-n-p (format "Close pane %s? " pane))
        (progn
          (herdr-rpc-call "pane.close" `((pane_id . ,pane)))
          ;; Say something afterwards.  Closing reaps the pane's buffer,
          ;; so redisplay happens while the confirmation prompt is still
          ;; on screen and it otherwise sits there looking unanswered.
          (message "herdr: closed %s" pane))
      (message "herdr: %s left open" pane))))

(defun herdr-pane-zoom (&optional pane-id)
  "Toggle zoom on PANE-ID, or the focused pane."
  (interactive)
  (herdr-rpc-call "pane.zoom"
                  `((pane_id . ,(or pane-id (herdr-select-target-pane)))
                    (mode . "toggle"))))

(defun herdr-pane-resize (direction &optional amount pane-id)
  "Resize the split around PANE-ID by AMOUNT toward DIRECTION."
  (interactive
   (list (completing-read "Direction: " '("left" "right" "up" "down") nil t)
         (read-number "Amount: " 0.1)))
  (herdr-rpc-call "pane.resize"
                  `((pane_id . ,(or pane-id (herdr-select-target-pane)))
                    (direction . ,direction)
                    (amount . ,(or amount 0.1)))))

(defun herdr-pane-swap (direction &optional pane-id)
  "Swap PANE-ID with its neighbour toward DIRECTION."
  (interactive
   (list (completing-read "Direction: " '("left" "right" "up" "down") nil t)))
  (herdr-rpc-call "pane.swap"
                  `((pane_id . ,(or pane-id (herdr-select-target-pane)))
                    (direction . ,direction))))

(defun herdr-pane-rename (label &optional pane-id)
  "Rename PANE-ID, or the focused pane, to LABEL."
  (interactive (list (read-string "Pane label: ")))
  (herdr-rpc-call "pane.rename"
                  `((pane_id . ,(or pane-id (herdr-select-target-pane)))
                    (label . ,label))))

(defun herdr-pane-focus (&optional pane-id)
  "Focus PANE-ID, prompting when not given, and select its buffer.

Focusing is server-side.  Under `agent-windows' that has no visible
effect on its own, because each pane is a separate Emacs buffer and
nothing repaints — so Emacs is moved to match."
  (interactive)
  (let ((pane (or pane-id (herdr-select-pane "Focus pane: "))))
    (herdr-rpc-call "pane.focus" `((pane_id . ,pane)))
    (or (herdr-term-select-pane pane)
        (herdr-cmd--select-pane-when-ready pane))
    pane))

(defun herdr-cmd--follow-focus ()
  "Show whichever pane herdr now considers focused.

Focusing a workspace or tab lands on one of its panes — the server
decides which — so the pane has to be asked for rather than assumed.
The cache may not hold it yet — the focus change was announced on the
event stream — so a miss waits for reconciliation instead of failing."
  (or (herdr-term-select-focused)
      (when-let* ((pane (herdr-cmd--current-pane-id)))
        (herdr-cmd--select-pane-when-ready pane))))

(defun herdr-cmd-read-text (result)
  "Return the terminal text carried by a read RESULT.

Both `pane.read' and `agent.read' answer with an envelope — type plus a
nested `read' object — rather than a bare text field, so the text has to
be unwrapped."
  (or (alist-get 'text (alist-get 'read result))
      (alist-get 'text result)
      ""))

(defun herdr-cmd-read-truncated-p (result)
  "Return non-nil when read RESULT reports older rows were omitted.
herdr sets `truncated' on the read envelope (or, defensively, the
top-level result) when the requested window dropped earlier terminal
rows.  JSON `false' and `null' both decode to nil, so a plain non-nil
test is enough."
  (or (alist-get 'truncated (alist-get 'read result))
      (alist-get 'truncated result)))

(defun herdr-cmd--display-read (name result)
  "Show READ RESULT in a buffer called NAME and return that buffer."
  (let ((buffer (get-buffer-create name))
        (text (herdr-cmd-read-text result))
        (truncated (herdr-cmd-read-truncated-p result)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (when truncated
          (insert (propertize "⋯ older rows omitted (read truncated) ⋯\n"
                              'face 'font-lock-comment-face)))
        (insert text)
        (ansi-color-apply-on-region (point-min) (point-max))
        (goto-char (point-max)))
      (special-mode))
    (pop-to-buffer buffer)
    buffer))

(defun herdr-pane-read (&optional pane-id source lines)
  "Read PANE-ID's output from SOURCE into a buffer, at most LINES lines."
  (interactive)
  (let* ((pane (or pane-id (herdr-select-target-pane "Read pane: ")))
         (source (or source (herdr-cmd--read-source)))
         (result (herdr-rpc-call "pane.read"
                                 `((pane_id . ,pane)
                                   (source . ,source)
                                   (lines . ,lines)
                                   (format . "ansi")
                                   (strip_ansi . :false)))))
    (herdr-cmd--display-read (format "*herdr read: %s*" pane) result)))

(defun herdr-pane-send-text (text &optional pane-id)
  "Send TEXT to PANE-ID verbatim, without a trailing newline."
  (interactive (list (read-string "Send text: ")))
  (herdr-rpc-call "pane.send_text"
                  `((pane_id . ,(or pane-id (herdr-select-target-pane)))
                    (text . ,text))))

(defun herdr-pane-run (command &optional pane-id)
  "Run COMMAND in PANE-ID.
There is no `pane.run' method — the CLI subcommand of that name is
`pane.send_text' with a newline, which is what this does."
  (interactive (list (read-string "Run in pane: ")))
  (herdr-rpc-call "pane.send_text"
                  `((pane_id . ,(or pane-id (herdr-select-target-pane)))
                    (text . ,(concat command "\n")))))

(defun herdr-pane-wait-for-output (pattern &optional pane-id timeout)
  "Wait for PATTERN in PANE-ID's output, then report, without blocking Emacs.
TIMEOUT is in seconds.  PATTERN is treated as a regular expression."
  (interactive (list (read-string "Wait for regex: ")))
  (let ((pane (or pane-id (herdr-select-target-pane "Wait on pane: "))))
    (herdr-rpc-call-async
     "pane.wait_for_output"
     `((pane_id . ,pane)
       (source . "recent_unwrapped")
       (match . ((type . "regex") (value . ,pattern)))
       (timeout_ms . ,(round (* 1000 (or timeout 600)))))
     (lambda (result err)
       (if err
           (message "herdr: wait on %s failed: %s" pane (alist-get 'message err))
         (message "herdr: %s matched: %s" pane
                  (string-trim (or (alist-get 'matched_line result) ""))))))
    (message "herdr: watching %s for %s" pane pattern)))

;;; Tabs

(defun herdr-tab-create (&optional label)
  "Create a tab called LABEL."
  (interactive (list (read-string "Tab label (optional): ")))
  (herdr-cmd--follow-new-pane
   (herdr-cmd--created-pane-id
    (herdr-rpc-call "tab.create"
                    `((label . ,(unless (string-empty-p (or label "")) label))
                      (focus . t))))))

(defun herdr-tab-close (&optional tab-id)
  "Close TAB-ID, prompting when not given.
Confirms first, like every other close: a tab takes its panes with it,
and the dispatcher puts `k\\=' one keystroke from any tab line."
  (interactive)
  (let ((tab (or tab-id (herdr-select-tab "Close tab: "))))
    (if (y-or-n-p (format "Close tab %s? " tab))
        (progn
          (herdr-rpc-call "tab.close" `((tab_id . ,tab)))
          ;; Say something afterwards, for the reason `herdr-pane-close'
          ;; does: closing reaps the tab's panes and their buffers, so
          ;; redisplay happens while the prompt is still on screen.
          (message "herdr: closed tab %s" tab))
      (message "herdr: tab %s left open" tab))))

(defun herdr-tab-focus (&optional tab-id)
  "Focus TAB-ID, prompting when not given, and follow it in Emacs."
  (interactive)
  (herdr-rpc-call "tab.focus"
                  `((tab_id . ,(or tab-id (herdr-select-tab "Focus tab: ")))))
  ;; Which pane that lands on is the server's decision, so ask.
  (herdr-cmd--follow-focus))

(defun herdr-tab-rename (label &optional tab-id)
  "Rename TAB-ID to LABEL."
  (interactive (list (read-string "New tab label: ")))
  (herdr-rpc-call "tab.rename"
                  `((tab_id . ,(or tab-id (herdr-select-tab "Rename tab: ")))
                    (label . ,label))))

;;; Workspaces

(defun herdr-workspace-create (cwd &optional label)
  "Create a workspace rooted at CWD called LABEL."
  (interactive (list (read-directory-name "Workspace directory: ")))
  (herdr-cmd--follow-new-pane
   (herdr-cmd--created-pane-id
    (herdr-rpc-call "workspace.create"
                    `((cwd . ,(expand-file-name cwd))
                      (label . ,(or label (file-name-nondirectory
                                           (directory-file-name cwd))))
                      (focus . t))))))

(defun herdr-workspace-close (&optional workspace-id)
  "Close WORKSPACE-ID, prompting when not given."
  (interactive)
  (let ((workspace (or workspace-id (herdr-select-workspace "Close workspace: "))))
    (if (y-or-n-p (format "Close workspace %s? " workspace))
        (progn
          (herdr-rpc-call "workspace.close" `((workspace_id . ,workspace)))
          (message "herdr: closed workspace %s" workspace))
      (message "herdr: workspace %s left open" workspace))))

(defun herdr-workspace-focus (&optional workspace-id)
  "Focus WORKSPACE-ID, prompting when not given, and follow it in Emacs."
  (interactive)
  (herdr-rpc-call "workspace.focus"
                  `((workspace_id . ,(or workspace-id
                                         (herdr-select-workspace "Focus: ")))))
  (herdr-cmd--follow-focus))

(defun herdr-workspace-rename (label &optional workspace-id)
  "Rename WORKSPACE-ID to LABEL."
  (interactive (list (read-string "New workspace label: ")))
  (herdr-rpc-call "workspace.rename"
                  `((workspace_id . ,(or workspace-id
                                         (herdr-select-workspace "Rename: ")))
                    (label . ,label))))

;;; Worktrees

(defun herdr-worktree-list ()
  "Show the git worktrees herdr knows about for the current directory."
  (interactive)
  (let ((result (herdr-rpc-call "worktree.list"
                                `((cwd . ,(expand-file-name default-directory))))))
    (message "herdr worktrees: %s"
             (mapconcat (lambda (worktree)
                          (format "%s (%s)"
                                  (or (alist-get 'branch worktree) "?")
                                  (or (alist-get 'path worktree) "?")))
                        (alist-get 'worktrees result)
                        ", "))))

(defun herdr-worktree-create (branch &optional base)
  "Create a git worktree for BRANCH off BASE and open it as a workspace.
This is the command that pays for the package: one step from a branch
name to a worktree with its own herdr workspace."
  (interactive (list (read-string "New worktree branch: ")
                     (read-string "Base ref (optional): ")))
  (herdr-rpc-call "worktree.create"
                  `((branch . ,branch)
                    (base . ,(unless (string-empty-p (or base "")) base))
                    (cwd . ,(expand-file-name default-directory))
                    (focus . t))))

(defun herdr-worktree-open (branch)
  "Open the existing worktree for BRANCH as a workspace."
  (interactive (list (read-string "Worktree branch: ")))
  (herdr-rpc-call "worktree.open"
                  `((branch . ,branch)
                    (cwd . ,(expand-file-name default-directory))
                    (focus . t))))

(defun herdr-worktree-remove (&optional workspace-id force)
  "Remove the worktree workspace WORKSPACE-ID, forcing when FORCE."
  (interactive)
  (let ((workspace (or workspace-id (herdr-select-workspace "Remove worktree: "))))
    (if (yes-or-no-p (format "Remove worktree workspace %s? " workspace))
        (progn
          (herdr-rpc-call "worktree.remove"
                          `((workspace_id . ,workspace)
                            (force . ,(if force t :false))))
          (message "herdr: removed worktree %s" workspace))
      (message "herdr: worktree %s kept" workspace))))

;;; Agents

(defcustom herdr-agent-kinds
  '("pi" "claude" "codex" "gemini" "cursor" "devin" "agy" "cline"
    "omp" "mastracode" "opencode" "copilot" "kimi" "kiro" "droid"
    "amp" "grok" "hermes" "kilo" "qodercli" "qwen" "maki")
  "Known agent kinds offered when starting an agent.
Completion candidates only, not a closed set: herdr types
`agent.start''s `kind' parameter as a free string rather than an enum,
so a kind not listed here is still accepted.  Add your own to taste."
  :type '(repeat string)
  :group 'herdr)

(defun herdr-agent-prompt (text &optional target)
  "Send TEXT as a prompt to the agent in TARGET."
  (interactive (list (read-string "Prompt: ")))
  (herdr-rpc-call "agent.prompt"
                  `((target . ,(or target (herdr-select-agent "Prompt agent: ")))
                    (text . ,text))))

(defun herdr-agent-read (&optional target source lines)
  "Read the agent in TARGET from SOURCE into a buffer, at most LINES lines."
  (interactive)
  (let* ((agent (or target (herdr-select-agent "Read agent: ")))
         (source (or source (herdr-cmd--read-source)))
         (result (herdr-rpc-call "agent.read"
                                 `((target . ,agent)
                                   (source . ,source)
                                   (lines . ,lines)
                                   (format . "ansi")
                                   (strip_ansi . :false)))))
    (herdr-cmd--display-read (format "*herdr agent: %s*" agent) result)))

(defun herdr-agent-wait (&optional target until timeout)
  "Report when the agent in TARGET reaches one of UNTIL, without blocking.
UNTIL defaults to done and blocked, which are the states worth knowing
about.  TIMEOUT is in seconds."
  (interactive)
  (let ((agent (or target (herdr-select-agent "Wait on agent: "))))
    (herdr-rpc-call-async
     "agent.wait"
     `((target . ,agent)
       (until . ,(herdr-rpc-array (or until '("done" "blocked"))))
       (timeout_ms . ,(round (* 1000 (or timeout 1800)))))
     (lambda (result err)
       (if err
           (message "herdr: wait on %s failed: %s" agent (alist-get 'message err))
         (message "herdr: agent %s is now %s" agent
                  (or (alist-get 'agent_status result) "done")))))
    (message "herdr: watching agent %s" agent)))

(defun herdr-cmd--new-tab-pane (&optional workspace-id cwd)
  "Create a tab and return its root pane's id.
WORKSPACE-ID nil means whatever workspace the server has focused; CWD
nil inherits the workspace directory.  One tab per agent, rather than a
split: Emacs ignores herdr's layout, but the TUI does not, and N agents
as N full-width tabs beats N slivers of one tab."
  (herdr-cmd--created-pane-id
   (herdr-rpc-call "tab.create"
                   `((workspace_id . ,workspace-id)
                     (cwd . ,cwd)
                     (focus . t)))))

(defun herdr-agent-start (name kind &optional pane-id)
  "Start agent NAME of KIND in PANE-ID.
Interactively, PANE-ID is chosen from the panes not already running an
agent: `agent.start' can only take over a shell sitting idle, so
offering a busy pane would just earn a server rejection.  The picker also
offers a create-new entry that creates a fresh tab to start in, so a
full session is no longer a dead end."
  (interactive
   (list (read-string "Agent name: ")
         (completing-read "Agent kind: " herdr-agent-kinds nil nil)))
  (let ((pane (or pane-id (herdr-select-available-shell))))
    (when (eq pane :create-new)
      (setq pane (herdr-cmd--new-tab-pane)))
    (herdr-rpc-call "agent.start"
                    `((pane_id . ,pane) (name . ,name) (kind . ,kind)))
    ;; Surface the agent that was just started.  Focusing is server-side,
    ;; so under `session' the TUI repaints to it; under `agent-windows'
    ;; the pane only just gained an agent, so its buffer is built off the
    ;; event stream and may not exist yet — select it now if it does, and
    ;; otherwise wait for reconciliation rather than looking like a no-op.
    (herdr-rpc-call "pane.focus" `((pane_id . ,pane)))
    (unless (herdr-term-select-pane pane)
      (herdr-cmd--select-pane-when-ready pane))
    pane))

(defun herdr-agent-explain (&optional target)
  "Explain how herdr detected the agent in TARGET."
  (interactive)
  (let* ((agent (or target (herdr-select-pane "Explain pane: ")))
         (result (herdr-rpc-call "agent.explain" `((target . ,agent)))))
    (message "herdr: %s" (or (alist-get 'explanation result)
                             (format "%S" result)))))

(defun herdr-agent-focus (&optional target)
  "Focus the agent in TARGET and select its buffer."
  (interactive)
  (let ((agent (or target (herdr-select-agent "Focus agent: "))))
    (herdr-rpc-call "agent.focus" `((target . ,agent)))
    ;; TARGET may be a pane id or an agent name, so resolve via the server.
    (or (herdr-term-select-pane agent) (herdr-term-select-focused))))

;;; Adopting plain shells

(defconst herdr-cmd-adopt-source "herdr.el"
  "The `source' herdr.el reports agent lifecycle under.
herdr uses it to attribute reports, and `pane.release_agent' requires
the same value it was adopted with.")

(defun herdr-adopt-shell (&optional pane-id)
  "Report an agent named `herdr-shell-agent-name' on PANE-ID.
Every pane is attachable in Emacs whether or not it carries one, so this
buys nothing there any more; it only changes how herdr's own sidebar and
`agent.start' see the pane.  Reverse it with `herdr-release-shell'."
  (interactive)
  (let ((pane (or pane-id (herdr-select-pane "Adopt shell pane: "))))
    (herdr-rpc-call "pane.report_agent"
                    `((pane_id . ,pane)
                      (source . ,herdr-cmd-adopt-source)
                      (agent . ,(with-suppressed-warnings
                                    ((obsolete herdr-shell-agent-name))
                                  herdr-shell-agent-name))
                      (state . "idle")))
    ;; Adoption and release are not reliably announced on the event
    ;; stream, so settle the cache rather than waiting for news.
    (herdr-state-resync)
    (message "herdr: reported an agent on %s" pane)))
(make-obsolete 'herdr-adopt-shell
               "every pane is attachable; adoption buys nothing since herdr 0.8.2."
               "0.2.0")

(defun herdr-release-shell (&optional pane-id)
  "Undo `herdr-adopt-shell' for PANE-ID, dropping its reported agent.
The pane and its shell are untouched; only the report goes away."
  (interactive)
  (let ((pane (or pane-id
                  (herdr-select--read
                   "Release shell pane: "
                   (mapcar (lambda (p) (alist-get 'pane_id p))
                           (with-suppressed-warnings
                               ((obsolete herdr-state-shell-pane-p))
                             (seq-filter #'herdr-state-shell-pane-p
                                         (herdr-state-panes (herdr-state-current)))))
                   'herdr-pane #'herdr-select--annotate-pane))))
    (herdr-rpc-call "pane.release_agent"
                    `((pane_id . ,pane)
                      (source . ,herdr-cmd-adopt-source)
                      (agent . ,(with-suppressed-warnings
                                    ((obsolete herdr-shell-agent-name))
                                  herdr-shell-agent-name))))
    (herdr-state-resync)
    (message "herdr: released %s" pane)))
(make-obsolete 'herdr-release-shell
               "every pane is attachable; adoption buys nothing since herdr 0.8.2."
               "0.2.0")

;;; Miscellaneous

(defun herdr-notification-show (title &optional body)
  "Show a herdr-side notification with TITLE and BODY."
  (interactive (list (read-string "Title: ") (read-string "Body: ")))
  (herdr-rpc-call "notification.show"
                  `((title . ,title)
                    (body . ,(unless (string-empty-p (or body "")) body))
                    (sound . "none"))))

(provide 'herdr-cmd)
;;; herdr-cmd.el ends here
