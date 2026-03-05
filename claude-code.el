;;; claude-code.el --- Claude Code integration for Emacs -*- lexical-binding: t; -*-

;; Author: Claude Code Emacs Project
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (json "1.5") (project "0.9"))
;; Keywords: tools, ai

;;; Commentary:
;;
;; This package provides Claude Code integration for Emacs, similar to the
;; VSCode Claude Code extension.  It spawns the `claude` CLI with
;; --input-format stream-json --output-format stream-json and injects an
;; Emacs-specific MCP server that gives Claude access to editor state
;; (diagnostics, open buffers, selections, etc.).
;;
;; The MCP server communicates with the main Emacs via a TCP eval server
;; running inside Emacs — no emacsclient dependency.
;;
;; Usage:
;;   M-x claude-code  — Start or switch to a Claude Code session

;;; Code:

(require 'json)
(require 'project)

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
  "Open a diff.  Compare OLD-FILE-PATH with NEW-FILE-PATH or NEW-FILE-CONTENTS."
  (if new-file-contents
      (let ((temp-file (make-temp-file "claude-diff-")))
        (with-temp-file temp-file
          (insert new-file-contents))
        (diff old-file-path temp-file nil 'noasync)
        (json-encode `((success . t))))
    (when new-file-path
      (diff old-file-path new-file-path nil 'noasync)
      (json-encode `((success . t))))))

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
    (if buf
        (with-current-buffer buf
          (save-buffer)
          (json-encode `((success . t) (filePath . ,file-path))))
      (json-encode `((success . :json-false)
                     (message . ,(format "No buffer visiting %s" file-path)))))))

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

(defun claude-code--handle-stream-message (msg)
  "Handle a single stream-json MSG from Claude CLI."
  (let ((type (cdr (assq 'type msg)))
        (buf (get-buffer claude-code--buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
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
                            (insert (propertize text 'face 'claude-code-assistant-face)))))
                       ("tool_use"
                        (let ((name (cdr (assq 'name block))))
                          (insert (propertize
                                   (format "\n[Tool: %s]\n" name)
                                   'face 'claude-code-tool-face))))))))))
            ("user"
             (let* ((message (cdr (assq 'message msg)))
                    (content (cdr (assq 'content message))))
               (when (vectorp content)
                 (seq-doseq (block content)
                   (when (equal (cdr (assq 'type block)) "tool_result")
                     (insert (propertize
                              (format "[Tool result: %s]\n"
                                      (truncate-string-to-width
                                       (or (cdr (assq 'content block)) "")
                                       200))
                              'face 'claude-code-tool-result-face)))))))
            ("result"
             (insert (propertize "\n--- Done ---\n" 'face 'claude-code-separator-face))
             (claude-code--show-prompt))
            ("error"
             (insert (propertize
                      (format "\n[Error: %s]\n"
                              (or (cdr (assq 'error msg)) msg))
                      'face 'error)))))))))

(defun claude-code--process-sentinel (proc event)
  "Sentinel for Claude CLI process PROC.  EVENT describes what happened."
  (let ((buf (process-buffer proc)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (propertize (format "\n[Process %s]\n" (string-trim event))
                              'face 'claude-code-separator-face))))))
  ;; Clean up eval server when CLI exits
  (unless (process-live-p proc)
    (claude-code--eval-server-stop)))

;; ---------------------------------------------------------------------------
;; Sending messages
;; ---------------------------------------------------------------------------

(defun claude-code-send (text)
  "Send TEXT as a user message to the Claude CLI process."
  (interactive "sPrompt: ")
  (when (and claude-code--process
             (process-live-p claude-code--process))
    (let* ((msg `((type . "user")
                  (session_id . "")
                  (parent_tool_use_id . nil)
                  (message . ((role . "user")
                              (content . [((type . "text")
                                           (text . ,text))])))))
           (json-str (concat (claude-code--json-encode msg) "\n")))
      (with-current-buffer (get-buffer claude-code--buffer-name)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (propertize (format "\nYou: %s\n\n" text)
                              'face 'claude-code-user-face))))
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

(defvar claude-code-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-code-send-input)
    (define-key map (kbd "C-c C-k") #'claude-code-interrupt)
    (define-key map (kbd "C-c C-q") #'claude-code-quit)
    map)
  "Keymap for `claude-code-mode'.")

(define-derived-mode claude-code-mode special-mode "Claude-Code"
  "Major mode for Claude Code chat interface.

\\{claude-code-mode-map}"
  (setq-local claude-code--partial-line ""))

(defun claude-code--show-prompt ()
  "Show input prompt at the bottom of the chat buffer."
  (with-current-buffer (get-buffer claude-code--buffer-name)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (propertize "\n> " 'face 'minibuffer-prompt
                          'rear-nonsticky t)))))

(defun claude-code-send-input ()
  "Read input from minibuffer and send to Claude."
  (interactive)
  (let ((input (read-string "Claude> " nil 'claude-code--input-history)))
    (when (and input (not (string-empty-p input)))
      (claude-code-send input))))

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

;; ---------------------------------------------------------------------------
;; Entry point
;; ---------------------------------------------------------------------------

;;;###autoload
(defun claude-code ()
  "Start or switch to a Claude Code session."
  (interactive)
  ;; If we already have a live session, just switch to it
  (when (and claude-code--process (process-live-p claude-code--process))
    (pop-to-buffer claude-code--buffer-name)
    (user-error "Claude Code session already running.  Use C-c C-k to interrupt or C-c C-q to quit"))
  ;; Start the TCP eval server
  (claude-code--eval-server-start)
  (message "Claude Code: eval server on port %d" claude-code--eval-server-port)
  ;; Create buffer
  (let ((buf (get-buffer-create claude-code--buffer-name)))
    (with-current-buffer buf
      (claude-code-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Claude Code for Emacs\n" 'face '(:weight bold :height 1.2)))
        (insert (propertize "C-c C-c to send | C-c C-k to interrupt | C-c C-q to quit\n"
                            'face 'claude-code-separator-face))
        (insert (propertize (make-string 60 ?─) 'face 'claude-code-separator-face))
        (insert "\n")))
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
    (message "Claude Code session started.  Use C-c C-c to send a message.")))

(provide 'claude-code)

;;; claude-code.el ends here
