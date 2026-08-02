;;; herdr-transient.el --- Transient menus for herdr -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Eddie Jesinsky

;; Author: Eddie Jesinsky
;; Keywords: processes, terminals, tools
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "28.1") (transient "0.4.0"))

;;; Commentary:

;; The command surface.  Every prefix shows which pane it is about to
;; act on, taken from the cache rather than asked for, so the common
;; case costs no prompting.  A prefix argument on any command retargets
;; through the picker instead.

;;; Code:

(require 'transient)
(require 'herdr-state)
(require 'herdr-term)
(require 'herdr-cmd)
(require 'herdr-select)
(require 'herdr-call)
(require 'herdr-agents)

;; `herdr-project' lives in herdr.el, which loads this file lazily; a
;; top-level require here would be circular.
(declare-function herdr-project "herdr" ())
(autoload 'herdr-project "herdr" nil t)

(defun herdr-transient--target ()
  "Return a short description of the pane commands will act on."
  (let* ((state (herdr-state-current))
         (id (herdr-state-focused-pane-id state))
         (pane (and id (herdr-state-pane state id))))
    (if (not pane)
        "no pane"
      (format "%s  %s%s"
              id
              (or (alist-get 'agent pane) "shell")
              (if-let* ((status (alist-get 'agent_status pane)))
                  (format ":%s" status)
                "")))))

(defun herdr-transient--heading ()
  "Return the root prefix heading."
  (format "herdr  [%s]   C-u on any command retargets"
          (herdr-transient--target)))

;;;###autoload (autoload 'herdr-transient "herdr-transient" nil t)
(transient-define-prefix herdr-transient ()
  "Control the herdr session."
  [:description herdr-transient--heading
   ["Navigate"
    ("j" "pane"       herdr-pane-focus)
    ("J" "agent"      herdr-agent-focus)
    ("w" "workspace"  herdr-workspace-focus)
    ("t" "tab"        herdr-tab-focus)]
   ["Act on"
    ("p" "pane…"      herdr-transient-pane)
    ("a" "agent…"     herdr-transient-agent)
    ("T" "tab…"       herdr-transient-tab)
    ("W" "workspace…" herdr-transient-workspace)
    ("k" "worktree…"  herdr-transient-worktree)]
   ["Session"
    ("g" "resync"     herdr-state-resync)
    ("G" "agents"     herdr-agents)
    ("?" "status"     herdr-transient-status)
    ("x" "any method…" herdr-call)]])

(transient-define-prefix herdr-transient-pane ()
  "Act on a pane."
  [:description herdr-transient--heading
   ["Layout"
    ("s" "split right" herdr-pane-split-right)
    ("S" "split down"  herdr-pane-split-down)
    ("z" "zoom"        herdr-pane-zoom)
    ("=" "resize"      herdr-pane-resize)
    ("m" "swap"        herdr-pane-swap)]
   ["Content"
    ("r" "read → buffer" herdr-pane-read)
    ("!" "run command"   herdr-pane-run)
    ("i" "send text"     herdr-pane-send-text)
    ("o" "wait output…"  herdr-pane-wait-for-output)]
   ["Manage"
    ("R" "rename" herdr-pane-rename)
    ("k" "close"  herdr-pane-close)]])

(transient-define-prefix herdr-transient-agent ()
  "Act on an agent."
  [:description herdr-transient--heading
   ["Interact"
    ("p" "prompt"        herdr-agent-prompt)
    ("r" "read → buffer" herdr-agent-read)
    ("w" "wait until…"   herdr-agent-wait)]
   ["Manage"
    ("s" "start"   herdr-agent-start)
    ("f" "focus"   herdr-agent-focus)
    ("e" "explain" herdr-agent-explain)]])

(transient-define-prefix herdr-transient-tab ()
  "Act on a tab."
  ["Tab"
   ("c" "create" herdr-tab-create)
   ("f" "focus"  herdr-tab-focus)
   ("R" "rename" herdr-tab-rename)
   ("k" "close"  herdr-tab-close)])

(transient-define-prefix herdr-transient-workspace ()
  "Act on a workspace."
  ["Workspace"
   ("c" "create"          herdr-workspace-create)
   ("p" "for project"     herdr-project)
   ("f" "focus"           herdr-workspace-focus)
   ("R" "rename"          herdr-workspace-rename)
   ("k" "close"           herdr-workspace-close)])

(transient-define-prefix herdr-transient-worktree ()
  "Act on git worktrees."
  ["Worktree"
   ("l" "list"   herdr-worktree-list)
   ("c" "create" herdr-worktree-create)
   ("o" "open"   herdr-worktree-open)
   ("k" "remove" herdr-worktree-remove)])

(defun herdr-transient-status ()
  "Report server and cache status in the echo area."
  (interactive)
  (let* ((pong (ignore-errors (herdr-rpc-call "ping")))
         (state (herdr-state-current)))
    (message
     "herdr %s protocol %s | %d workspaces, %d panes, %d agents | stream %s | backend %s"
     (or (alist-get 'version pong) "unreachable")
     (or (alist-get 'protocol pong) "?")
     (length (herdr-state-workspaces state))
     (length (herdr-state-panes state))
     (length (herdr-state-agents state))
     (if (herdr-state-running-p) "up" "down")
     herdr-terminal-backend)))

(provide 'herdr-transient)
;;; herdr-transient.el ends here
