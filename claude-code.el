;;; claude-code.el --- Claude Code integration for Emacs -*- lexical-binding: t; -*-

;; Author: kovan <kovan@github>
;; Maintainer: kovan <kovan@github>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (seq "2.0"))
;; Keywords: tools, ai, convenience
;; URL: https://github.com/kovan/claude-code.el

;; This file is not part of GNU Emacs.

;; MIT License
;;
;; Copyright (c) 2025 kovan
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:
;;
;; Claude Code integration for Emacs, similar to the VSCode Claude Code
;; extension.  Uses your Claude Code subscription (not API keys).
;;
;; This package spawns the `claude' CLI with stream-json I/O and injects an
;; Emacs-native MCP server that gives Claude access to editor state
;; (diagnostics, open buffers, selections, etc.).
;;
;; The MCP server communicates with the main Emacs via a TCP eval server
;; running inside Emacs -- no emacsclient dependency.
;;
;; Usage:
;;   M-x claude-code  -- Start or switch to a Claude Code session

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'seq)

;; ---------------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------------

(defgroup claude-code nil
  "Claude Code integration for Emacs."
  :group 'tools
  :prefix "claude-code-")

(defcustom claude-code-cli-program "claude"
  "Path to the claude CLI executable."
  :type 'string
  :group 'claude-code)

(defcustom claude-code-model nil
  "Model to use.  If nil, uses the CLI default."
  :type '(choice (const nil) string)
  :group 'claude-code)

(defcustom claude-code-permission-mode "default"
  "Permission mode for the Claude session."
  :type '(choice (const "default")
                 (const "plan")
                 (const "acceptEdits")
                 (const "bypassPermissions"))
  :group 'claude-code)

(defcustom claude-code-mcp-server-script
  (expand-file-name "claude-code-mcp-server.el"
                    (file-name-directory (or load-file-name buffer-file-name
                                             default-directory)))
  "Path to the MCP server Elisp script."
  :type 'string
  :group 'claude-code)

;; ---------------------------------------------------------------------------
;; Internal variables
;; ---------------------------------------------------------------------------

(defvar claude-code--process nil
  "The Claude CLI process.")

(defvar claude-code--eval-server nil
  "The TCP eval server process.")

(defvar claude-code--eval-server-port nil
  "Port the TCP eval server is listening on.")

(defvar claude-code--buffer-name "*Claude Code*"
  "Name of the Claude Code chat buffer.")

(defvar claude-code--input-history nil
  "History of user inputs.")

(defvar claude-code--partial-line ""
  "Accumulator for partial lines from process output.")

;; ---------------------------------------------------------------------------
;; TCP eval server — runs inside Emacs, serves MCP server requests
;; ---------------------------------------------------------------------------

(defun claude-code--eval-server-start ()
  "Start a TCP server that evaluates Elisp expressions from the MCP server.
Returns the port number."
  (when (and claude-code--eval-server
             (process-live-p claude-code--eval-server))
    (delete-process claude-code--eval-server))
  (let ((server (make-network-process
                 :name "claude-code-eval"
                 :server t
                 :host "127.0.0.1"
                 :service 0  ; auto-assign port
                 :family 'ipv4
                 :filter #'claude-code--eval-server-filter
                 :sentinel #'claude-code--eval-server-sentinel
                 :noquery t)))
    (setq claude-code--eval-server server)
    (setq claude-code--eval-server-port
          (process-contact server :service))
    claude-code--eval-server-port))

(defun claude-code--eval-server-stop ()
  "Stop the TCP eval server."
  (when (and claude-code--eval-server
             (process-live-p claude-code--eval-server))
    (delete-process claude-code--eval-server)
    (setq claude-code--eval-server nil
          claude-code--eval-server-port nil)))

(defvar claude-code--eval-client-buffers (make-hash-table :test 'eq)
  "Map from client process to accumulated input.")

(defun claude-code--eval-server-filter (proc output)
  "Handle data from a client connection PROC.  OUTPUT is the data received."
  ;; Accumulate data until we get a newline
  (let ((existing (gethash proc claude-code--eval-client-buffers "")))
    (setq existing (concat existing output))
    (while (string-match "\n" existing)
      (let* ((pos (match-end 0))
             (line (substring existing 0 (1- pos))))
        (setq existing (substring existing pos))
        ;; Evaluate and respond
        (let ((result (condition-case err
                          (let ((val (eval (read line))))
                            (if (stringp val) val (prin1-to-string val)))
                        (error (format "{\"error\": %S}"
                                       (error-message-string err))))))
          (when (process-live-p proc)
            (process-send-string proc (concat result "\n"))))))
    (puthash proc existing claude-code--eval-client-buffers)))

(defun claude-code--eval-server-sentinel (proc event)
  "Clean up when client PROC disconnects.  EVENT is the event string."
  (when (string-match-p "\\(deleted\\|connection broken\\|finished\\)" event)
    (remhash proc claude-code--eval-client-buffers)))

;; ---------------------------------------------------------------------------
;; Functions called by the MCP server via the eval server
;; ---------------------------------------------------------------------------

(defun claude-code--get-diagnostics (&optional file-path)
  "Return diagnostics as a JSON string.
If FILE-PATH is non-nil, only return diagnostics for that file."
  (let ((results '()))
    (cond
     ;; Try Flymake first
     ((fboundp 'flymake-diagnostics)
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (and buffer-file-name
                     (or (null file-path)
                         (string= buffer-file-name file-path))
                     (bound-and-true-p flymake-mode))
            (dolist (diag (flymake-diagnostics))
              (push `((file . ,buffer-file-name)
                      (line . ,(line-number-at-pos (flymake-diagnostic-beg diag)))
                      (severity . ,(symbol-name (flymake-diagnostic-type diag)))
                      (message . ,(flymake-diagnostic-text diag)))
                    results))))))
     ;; Fallback to Flycheck
     ((fboundp 'flycheck-overlay-errors-in)
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (and buffer-file-name
                     (or (null file-path)
                         (string= buffer-file-name file-path))
                     (bound-and-true-p flycheck-mode))
            (dolist (err (bound-and-true-p flycheck-current-errors))
              (push `((file . ,buffer-file-name)
                      (line . ,(flycheck-error-line err))
                      (severity . ,(symbol-name (flycheck-error-level err)))
                      (message . ,(flycheck-error-message err)))
                    results)))))))
    (json-encode results)))

(defun claude-code--get-open-buffers ()
  "Return JSON array of open file-visiting buffers."
  (let ((results '()))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when buffer-file-name
          (push `((filePath . ,buffer-file-name)
                  (name . ,(buffer-name))
                  (modified . ,(if (buffer-modified-p) t :json-false))
                  (active . ,(if (eq buf (window-buffer (selected-window))) t :json-false)))
                results))))
    (json-encode (vconcat results))))

(defun claude-code--get-current-selection ()
  "Return the current region as JSON, or null if no region active."
  (let* ((buf (window-buffer (selected-window))))
    (with-current-buffer buf
      (if (use-region-p)
          (json-encode `((filePath . ,buffer-file-name)
                         (text . ,(buffer-substring-no-properties
                                   (region-beginning) (region-end)))
                         (startLine . ,(line-number-at-pos (region-beginning)))
                         (endLine . ,(line-number-at-pos (region-end)))))
        (json-encode `((success . :json-false)
                       (message . "No active region")))))))

(defun claude-code--open-file (file-path &optional line column)
  "Open FILE-PATH, optionally at LINE and COLUMN."
  (find-file file-path)
  (when line
    (goto-char (point-min))
    (forward-line (1- line))
    (when column
      (forward-char (1- column))))
  (json-encode `((success . t)
                 (filePath . ,file-path))))

(defun claude-code--open-diff (old-file-path &optional new-file-path new-file-contents)
  "Open an ediff session.  Compare OLD-FILE-PATH with NEW-FILE-PATH or NEW-FILE-CONTENTS."
  (let ((file-b (if new-file-contents
                    (let ((temp (make-temp-file "claude-diff-")))
                      (with-temp-file temp (insert new-file-contents))
                      temp)
                  new-file-path)))
    (if file-b
        (progn
          (ediff-files old-file-path file-b)
          (json-encode `((success . t))))
      (json-encode `((success . :json-false)
                     (message . "No new file or contents to compare"))))))

(defun claude-code--get-workspace-folders ()
  "Return JSON array of project root directories."
  (let ((roots '()))
    (when-let ((proj (project-current)))
      (push (project-root proj) roots))
    (when (fboundp 'project-known-project-roots)
      (dolist (root (project-known-project-roots))
        (unless (member root roots)
          (push root roots))))
    (json-encode (vconcat roots))))

(defun claude-code--check-document-dirty (file-path)
  "Check if FILE-PATH buffer has unsaved changes."
  (let ((buf (find-buffer-visiting file-path)))
    (json-encode `((isDirty . ,(if (and buf (buffer-modified-p buf)) t :json-false))
                   (filePath . ,file-path)))))

(defun claude-code--save-document (file-path)
  "Save the buffer visiting FILE-PATH."
  (let ((buf (find-buffer-visiting file-path)))
    (if (not buf)
        (json-encode `((success . :json-false)
                       (message . ,(format "No buffer visiting %s" file-path))))
      (with-current-buffer buf
        (save-buffer)
        (json-encode `((success . t) (filePath . ,file-path)))))))

;; ---------------------------------------------------------------------------
;; MCP config generation
;; ---------------------------------------------------------------------------

(defun claude-code--mcp-config ()
  "Generate a temporary MCP config JSON file and return its path."
  (let* ((emacs-bin (expand-file-name invocation-name invocation-directory))
         (port-str (number-to-string claude-code--eval-server-port))
         (config `((mcpServers
                    . ((claude-emacs
                        . ((command . ,emacs-bin)
                           (args . ,(vector "--batch"
                                            "--load" claude-code-mcp-server-script))
                           (env . ((CLAUDE_EMACS_PORT . ,port-str)))))))))
         (config-file (make-temp-file "claude-mcp-config-" nil ".json")))
    (with-temp-file config-file
      (insert (let ((json-encoding-pretty-print t))
                (json-encode config))))
    config-file))

;; ---------------------------------------------------------------------------
;; Process management
;; ---------------------------------------------------------------------------

(defun claude-code--build-cli-args ()
  "Build the argument list for the claude CLI."
  (let ((args (list "--output-format" "stream-json"
                    "--input-format" "stream-json"
                    "--verbose"
                    "--mcp-config" (claude-code--mcp-config)
                    "--permission-mode" claude-code-permission-mode)))
    (when claude-code-model
      (setq args (append args (list "--model" claude-code-model))))
    args))

(defun claude-code--process-filter (proc output)
  "Process filter for Claude CLI.  PROC is the process, OUTPUT is new text."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq claude-code--partial-line
              (concat claude-code--partial-line output))
        (let ((lines (split-string claude-code--partial-line "\n")))
          (setq claude-code--partial-line (car (last lines)))
          (setq lines (butlast lines))
          (dolist (line lines)
            (when (and line (not (string-empty-p (string-trim line))))
              (condition-case nil
                  (claude-code--handle-stream-message
                   (json-read-from-string line))
                (error nil)))))))))

(defun claude-code--tool-use-summary (name input)
  "Return a human-readable summary for tool NAME with INPUT args."
  (pcase name
    ("Read" (format "%s" (or (cdr (assq 'file_path input)) "")))
    ("Write" (format "%s" (or (cdr (assq 'file_path input)) "")))
    ("Edit" (format "%s" (or (cdr (assq 'file_path input)) "")))
    ("MultiEdit" (format "%s" (or (cdr (assq 'file_path input)) "")))
    ("Bash" (let ((cmd (or (cdr (assq 'command input)) "")))
              (truncate-string-to-width cmd 80)))
    ("Glob" (format "%s" (or (cdr (assq 'pattern input)) "")))
    ("Grep" (format "%s" (or (cdr (assq 'pattern input)) "")))
    ("LS" (format "%s" (or (cdr (assq 'path input)) "")))
    ("ToolSearch" (format "%s" (or (cdr (assq 'query input)) "")))
    ("WebSearch" (format "%s" (or (cdr (assq 'query input)) "")))
    ("WebFetch" (format "%s" (or (cdr (assq 'url input)) "")))
    ("getDiagnostics" (let ((uri (cdr (assq 'uri input))))
                        (if uri (format "%s" uri) "all files")))
    ("openFile" (format "%s" (or (cdr (assq 'filePath input)) "")))
    ("openDiff" (format "%s" (or (cdr (assq 'old_file_path input)) "")))
    ("saveDocument" (format "%s" (or (cdr (assq 'filePath input)) "")))
    ("checkDocumentDirty" (format "%s" (or (cdr (assq 'filePath input)) "")))
    (_ nil)))

(defun claude-code--handle-stream-message (msg)
  "Handle a single stream-json MSG from Claude CLI."
  (let ((type (cdr (assq 'type msg)))
        (buf (get-buffer claude-code--buffer-name)))
    (when (buffer-live-p buf)
      (pcase type
        ("assistant"
         (let* ((message (cdr (assq 'message msg)))
                (content (cdr (assq 'content message))))
           (when (vectorp content)
             (seq-doseq (block content)
               (let ((block-type (cdr (assq 'type block))))
                 (pcase block-type
                   ("text"
                    (let ((text (cdr (assq 'text block))))
                      (when text
                        (claude-code--insert-output
                         (propertize text 'face 'claude-code-assistant-face)))))
                   ("tool_use"
                    (let* ((name (cdr (assq 'name block)))
                           (input (cdr (assq 'input block)))
                           (detail (claude-code--tool-use-summary name input)))
                      (claude-code--insert-output
                       (propertize (format "\n[Tool: %s%s]\n" name
                                          (if detail (concat " — " detail) ""))
                                   'face 'claude-code-tool-face))))))))))
        ("user"
         (let* ((message (cdr (assq 'message msg)))
                (content (cdr (assq 'content message))))
           (when (vectorp content)
             (seq-doseq (block content)
               (when (equal (cdr (assq 'type block)) "tool_result")
                 (claude-code--insert-output
                  (propertize
                   (format "[Tool result: %s]\n"
                           (truncate-string-to-width
                            (or (cdr (assq 'content block)) "") 200))
                   'face 'claude-code-tool-result-face)))))))
        ("result"
         (claude-code--insert-output
          (propertize "\n--- Done ---\n" 'face 'claude-code-separator-face)))
        ("error"
         (claude-code--insert-output
          (propertize (format "\n[Error: %s]\n"
                              (or (cdr (assq 'error msg)) msg))
                      'face 'error)))))))

(defun claude-code--process-sentinel (proc event)
  "Sentinel for Claude CLI process PROC.  EVENT describes what happened."
  (when (buffer-live-p (process-buffer proc))
    (claude-code--insert-output
     (propertize (format "\n[Process %s]\n" (string-trim event))
                 'face 'claude-code-separator-face)))
  ;; Clean up eval server when CLI exits
  (unless (process-live-p proc)
    (claude-code--eval-server-stop)))

;; ---------------------------------------------------------------------------
;; Context capture
;; ---------------------------------------------------------------------------

(defvar claude-code--origin-buffer nil
  "Buffer the user was in before switching to *Claude Code*.")

(defun claude-code--capture-context ()
  "Capture context from the origin buffer for the next message.
Returns a context string to prepend, or nil."
  (when (and claude-code--origin-buffer
             (buffer-live-p claude-code--origin-buffer))
    (with-current-buffer claude-code--origin-buffer
      (let ((parts '()))
        (when buffer-file-name
          (push (format "[Current file: %s, line %d]"
                        buffer-file-name (line-number-at-pos))
                parts))
        (when (use-region-p)
          (let ((sel (buffer-substring-no-properties
                      (region-beginning) (region-end))))
            (when (> (length sel) 0)
              (push (format "[Selected text from %s, lines %d-%d:\n```\n%s\n```]"
                            (or buffer-file-name (buffer-name))
                            (line-number-at-pos (region-beginning))
                            (line-number-at-pos (region-end))
                            sel)
                    parts))))
        (when parts
          (string-join (nreverse parts) "\n"))))))

;; ---------------------------------------------------------------------------
;; @ mention expansion
;; ---------------------------------------------------------------------------

(defun claude-code--expand-mentions (text)
  "Expand @mentions in TEXT.
Supported: @buffer, @selection, @file:PATH, @buffers."
  (let ((result text))
    ;; @file:PATH — insert file contents (do first, most specific)
    (while (string-match "@file:\\([^ \t\n]+\\)" result)
      (let* ((path (match-string 1 result))
             (expanded (expand-file-name path))
             (content (if (file-readable-p expanded)
                          (with-temp-buffer
                            (insert-file-contents expanded)
                            (let ((s (buffer-string)))
                              (if (> (length s) 10000)
                                  (concat (substring s 0 10000) "\n[...truncated]")
                                s)))
                        (format "[file not found: %s]" path))))
        (setq result (replace-regexp-in-string
                      (regexp-quote (match-string 0 result))
                      (format "[%s]\n```\n%s\n```" expanded content)
                      result t t))))
    ;; @selection — insert current selection
    (when (string-match-p "@selection\\b" result)
      (let ((sel (when (and claude-code--origin-buffer
                            (buffer-live-p claude-code--origin-buffer))
                   (with-current-buffer claude-code--origin-buffer
                     (when (use-region-p)
                       (buffer-substring-no-properties
                        (region-beginning) (region-end)))))))
        (setq result (replace-regexp-in-string
                      "@selection\\b"
                      (or sel "[no active selection]")
                      result t t))))
    ;; @buffers — list open buffers (before @buffer!)
    (when (string-match-p "@buffers\\b" result)
      (let ((bufs (mapconcat
                   (lambda (b)
                     (with-current-buffer b
                       (when buffer-file-name
                         (format "  %s%s"
                                 buffer-file-name
                                 (if (buffer-modified-p) " [modified]" "")))))
                   (buffer-list) "\n")))
        (setq result (replace-regexp-in-string
                      "@buffers\\b"
                      (format "[Open buffers:\n%s]" bufs)
                      result t t))))
    ;; @buffer — insert current buffer contents (truncated)
    (when (string-match-p "@buffer\\b" result)
      (let ((content (when (and claude-code--origin-buffer
                                (buffer-live-p claude-code--origin-buffer))
                       (with-current-buffer claude-code--origin-buffer
                         (let ((s (buffer-substring-no-properties
                                   (point-min) (point-max))))
                           (if (> (length s) 10000)
                               (concat (substring s 0 10000) "\n[...truncated]")
                             s))))))
        (setq result (replace-regexp-in-string
                      "@buffer\\b"
                      (format "```\n%s\n```" (or content "[no buffer]"))
                      result t t))))
    result))

;; ---------------------------------------------------------------------------
;; Sending messages
;; ---------------------------------------------------------------------------

(defun claude-code-send (text)
  "Send TEXT as a user message to the Claude CLI process."
  (when (and claude-code--process
             (process-live-p claude-code--process))
    ;; Expand @mentions
    (let* ((expanded (claude-code--expand-mentions text))
           ;; Auto-attach context if no explicit mentions
           (context (unless (string-match-p "@" text)
                      (claude-code--capture-context)))
           (full-text (if context
                          (concat context "\n\n" expanded)
                        expanded))
           (msg `((type . "user")
                  (session_id . "")
                  (parent_tool_use_id . nil)
                  (message . ((role . "user")
                              (content . [((type . "text")
                                           (text . ,full-text))])))))
           (json-str (concat (claude-code--json-encode msg) "\n")))
      ;; Display user message in chat (show original, not expanded)
      (claude-code--insert-output
       (propertize (format "\nYou: %s\n\n" text)
                   'face 'claude-code-user-face))
      (process-send-string claude-code--process json-str))))

(defun claude-code--json-encode (obj)
  "Encode OBJ to a JSON string."
  (let ((json-encoding-pretty-print nil))
    (json-encode obj)))

;; ---------------------------------------------------------------------------
;; Chat UI
;; ---------------------------------------------------------------------------

(defface claude-code-user-face
  '((t :foreground "#6cb6ff" :weight bold))
  "Face for user messages."
  :group 'claude-code)

(defface claude-code-assistant-face
  '((t :foreground "#e6edf3"))
  "Face for assistant messages."
  :group 'claude-code)

(defface claude-code-tool-face
  '((t :foreground "#d2a8ff" :slant italic))
  "Face for tool use indicators."
  :group 'claude-code)

(defface claude-code-tool-result-face
  '((t :foreground "#7ee787" :slant italic))
  "Face for tool results."
  :group 'claude-code)

(defface claude-code-separator-face
  '((t :foreground "#484f58"))
  "Face for separators."
  :group 'claude-code)

(defface claude-code-prompt-face
  '((t :foreground "#6cb6ff"))
  "Face for the input prompt marker."
  :group 'claude-code)

(defvar claude-code--input-marker nil
  "Marker for the beginning of user input area.")

(defvar claude-code-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-code-send-input)
    (define-key map (kbd "C-c C-c") #'claude-code-send-input)
    (define-key map (kbd "C-j") #'newline)
    (define-key map (kbd "C-c C-k") #'claude-code-interrupt)
    (define-key map (kbd "C-c C-q") #'claude-code-quit)
    (define-key map (kbd "C-c C-n") #'claude-code-new-session)
    map)
  "Keymap for `claude-code-mode'.")

(define-derived-mode claude-code-mode nil "Claude-Code"
  "Major mode for Claude Code chat interface.

Type at the prompt and press RET to send.  Use C-j for newlines.

\\{claude-code-mode-map}"
  (setq-local claude-code--partial-line "")
  (setq-local claude-code--input-marker (make-marker))
  (visual-line-mode 1))

(defun claude-code--insert-output (text)
  "Insert TEXT into the output area (above the input prompt)."
  (with-current-buffer (get-buffer claude-code--buffer-name)
    (let ((inhibit-read-only t)
          (input-text (claude-code--get-input)))
      ;; Remove the input area
      (when (marker-position claude-code--input-marker)
        (delete-region claude-code--input-marker (point-max)))
      ;; Insert output
      (goto-char (point-max))
      (insert text)
      ;; Re-create the input area
      (claude-code--insert-prompt)
      ;; Restore any in-progress input
      (when (and input-text (not (string-empty-p input-text)))
        (goto-char (point-max))
        (insert input-text))
      ;; Scroll to bottom
      (goto-char (point-max))
      (let ((win (get-buffer-window (current-buffer))))
        (when win (set-window-point win (point-max)))))))

(defun claude-code--insert-prompt ()
  "Insert the input prompt and set up the editable area."
  (goto-char (point-max))
  (let ((inhibit-read-only t))
    (insert (propertize "\n" 'claude-code-separator t 'read-only t 'rear-nonsticky t))
    (insert (propertize "Claude> " 'face 'claude-code-prompt-face
                        'read-only t 'rear-nonsticky t
                        'claude-code-prompt t))
    (set-marker claude-code--input-marker (point))))

(defun claude-code--get-input ()
  "Get the current input text from the prompt area."
  (when (and claude-code--input-marker
             (marker-position claude-code--input-marker))
    (buffer-substring-no-properties claude-code--input-marker (point-max))))

(defun claude-code-send-input ()
  "Send the text at the input prompt to Claude."
  (interactive)
  (let ((input (claude-code--get-input)))
    (when (and input (not (string-empty-p (string-trim input))))
      ;; Clear the input area
      (let ((inhibit-read-only t))
        (delete-region claude-code--input-marker (point-max)))
      ;; Add to history
      (push (string-trim input) claude-code--input-history)
      ;; Send
      (claude-code-send (string-trim input)))))

(defun claude-code-interrupt ()
  "Send interrupt to Claude CLI process."
  (interactive)
  (when (and claude-code--process (process-live-p claude-code--process))
    (interrupt-process claude-code--process)))

(defun claude-code-quit ()
  "Kill the Claude Code session."
  (interactive)
  (when (and claude-code--process (process-live-p claude-code--process))
    (kill-process claude-code--process))
  (setq claude-code--process nil)
  (claude-code--eval-server-stop))

(defun claude-code-new-session ()
  "Start a new Claude Code session, killing the current one."
  (interactive)
  (claude-code-quit)
  (claude-code))

;; ---------------------------------------------------------------------------
;; Entry point
;; ---------------------------------------------------------------------------

;;;###autoload
(defun claude-code ()
  "Start or switch to a Claude Code session.
Remembers the buffer you were in so it can provide context to Claude."
  (interactive)
  ;; Remember where the user came from
  (setq claude-code--origin-buffer (current-buffer))
  ;; If we already have a live session, just switch to it
  (if (and claude-code--process (process-live-p claude-code--process))
      (progn
        (pop-to-buffer claude-code--buffer-name)
        (goto-char (point-max))
        (message "Session active.  Type at the prompt and press RET to send."))
  ;; Start the TCP eval server
  (claude-code--eval-server-start)
  ;; Create buffer
  (let ((buf (get-buffer-create claude-code--buffer-name)))
    (with-current-buffer buf
      (claude-code-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Claude Code for Emacs\n"
                            'face '(:weight bold :height 1.2)
                            'read-only t 'rear-nonsticky t))
        (insert (propertize "RET send | C-j newline | C-c C-k interrupt | C-c C-q quit | C-c C-n new session\n"
                            'face 'claude-code-separator-face
                            'read-only t 'rear-nonsticky t))
        (insert (propertize "@buffer @selection @file:path @buffers for context\n"
                            'face 'claude-code-separator-face
                            'read-only t 'rear-nonsticky t))
        (insert (propertize (concat (make-string 60 ?-) "\n")
                            'face 'claude-code-separator-face
                            'read-only t 'rear-nonsticky t)))
      (claude-code--insert-prompt))
    ;; Spawn Claude CLI with clean env (remove parent Claude Code vars)
    (let* ((process-environment (seq-remove
                                 (lambda (s)
                                   (or (string-prefix-p "CLAUDECODE=" s)
                                       (string-prefix-p "CLAUDE_CODE_ENTRYPOINT=" s)))
                                 process-environment))
           (args (claude-code--build-cli-args))
           (proc (make-process
                  :name "claude-code"
                  :buffer buf
                  :command (cons claude-code-cli-program args)
                  :filter #'claude-code--process-filter
                  :sentinel #'claude-code--process-sentinel
                  :connection-type 'pipe
                  :noquery t)))
      (setq claude-code--process proc)
      (set-process-coding-system proc 'utf-8 'utf-8))
    (pop-to-buffer buf)
    (goto-char (point-max))
    (message "Claude Code ready.  Type at the prompt and press RET."))))

(provide 'claude-code)

;;; claude-code.el ends here
