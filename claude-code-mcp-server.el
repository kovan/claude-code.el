;;; claude-code-mcp-server.el --- MCP server for Claude Code Emacs integration -*- lexical-binding: t; -*-

;; This file is meant to be run as: emacs --batch --load claude-code-mcp-server.el
;; It implements an MCP (Model Context Protocol) server over stdio that
;; communicates with the main Emacs instance via a TCP connection.

;;; Commentary:
;;
;; MCP stdio transport: read JSON-RPC lines from stdin, write to stdout.
;; For tool calls, we connect to a TCP server running inside the main Emacs
;; (started by claude-code.el) to evaluate expressions and get results.
;;
;; Protocol with main Emacs is simple:
;;   - Send a single line of Elisp to evaluate
;;   - Receive the result as a single line back
;;
;; Tools exposed:
;;   - getDiagnostics
;;   - getOpenBuffers
;;   - getCurrentSelection
;;   - openFile
;;   - openDiff
;;   - getWorkspaceFolders
;;   - checkDocumentDirty
;;   - saveDocument

;;; Code:

(require 'json)

;; ---------------------------------------------------------------------------
;; Configuration
;; ---------------------------------------------------------------------------

(defvar claude-mcp--emacs-port nil
  "Port of the TCP eval server in the main Emacs.")

;; Read port from env
(when (getenv "CLAUDE_EMACS_PORT")
  (setq claude-mcp--emacs-port (string-to-number (getenv "CLAUDE_EMACS_PORT"))))

;; ---------------------------------------------------------------------------
;; Helpers: TCP communication with main Emacs
;; ---------------------------------------------------------------------------

(defun claude-mcp--eval-in-emacs (form-string)
  "Evaluate FORM-STRING in the running Emacs via TCP.
Returns the result as a string."
  (unless claude-mcp--emacs-port
    (error "CLAUDE_EMACS_PORT not set"))
  (let* ((buf (generate-new-buffer " *claude-tcp*"))
         (received-line nil))
    (unwind-protect
        (condition-case err
            (let ((proc (open-network-stream "claude-eval" buf
                                             "127.0.0.1" claude-mcp--emacs-port)))
              ;; Use a filter that captures just the first line
              (set-process-filter
               proc
               (lambda (_p output)
                 (unless received-line
                   (let ((nl (string-match "\n" output)))
                     (if nl
                         (setq received-line (substring output 0 nl))
                       (setq received-line output))))))
              ;; Suppress "connection broken" sentinel messages
              (set-process-sentinel proc #'ignore)
              (process-send-string proc (concat form-string "\n"))
              (process-send-eof proc)
              ;; Wait for response
              (let ((start (float-time)))
                (while (and (not received-line)
                            (< (- (float-time) start) 30))
                  (accept-process-output proc 0.1)))
              (delete-process proc)
              (or received-line
                  "{\"error\": \"TCP eval timeout\"}"))
          (error
           (format "{\"error\": \"TCP eval failed: %s\"}" (error-message-string err))))
      (kill-buffer buf))))

;; Fallback to emacsclient if no TCP port configured
(defvar claude-mcp--emacsclient-program "emacsclient"
  "Path to emacsclient binary.")

(defvar claude-mcp--socket-name nil
  "Emacs server socket name for emacsclient fallback.")

(when (getenv "EMACS_SOCKET_NAME")
  (setq claude-mcp--socket-name (getenv "EMACS_SOCKET_NAME")))

(defun claude-mcp--emacsclient-eval (form-string)
  "Evaluate FORM-STRING via emacsclient (fallback)."
  (let* ((cli-args (append (list "--eval" form-string)
                           (when claude-mcp--socket-name
                             (list "--socket-name" claude-mcp--socket-name))))
         (buf (generate-new-buffer " *emacsclient*"))
         (exit-code (apply #'call-process
                           claude-mcp--emacsclient-program
                           nil buf nil cli-args)))
    (unwind-protect
        (let ((output (with-current-buffer buf
                        (string-trim (buffer-string)))))
          (if (= exit-code 0)
              (if (and (> (length output) 1)
                       (string-prefix-p "\"" output)
                       (string-suffix-p "\"" output))
                  (read output)
                output)
            (format "{\"error\": \"emacsclient failed (exit %d): %s\"}"
                    exit-code output)))
      (kill-buffer buf))))

(defun claude-mcp--eval (form-string)
  "Evaluate FORM-STRING in the main Emacs, using TCP if available."
  (if claude-mcp--emacs-port
      (claude-mcp--eval-in-emacs form-string)
    (claude-mcp--emacsclient-eval form-string)))

;; ---------------------------------------------------------------------------
;; Helpers: JSON-RPC
;; ---------------------------------------------------------------------------

(defun claude-mcp--json-encode (obj)
  "Encode OBJ to JSON string."
  (let ((json-encoding-pretty-print nil))
    (json-encode obj)))

(defun claude-mcp--respond (id result)
  "Send a JSON-RPC success response for ID with RESULT."
  (let ((resp `((jsonrpc . "2.0")
                (id . ,id)
                (result . ,result))))
    (princ (claude-mcp--json-encode resp))
    (princ "\n")
    (sit-for 0)))

(defun claude-mcp--respond-error (id code message)
  "Send a JSON-RPC error response for ID with CODE and MESSAGE."
  (let ((resp `((jsonrpc . "2.0")
                (id . ,id)
                (error . ((code . ,code)
                           (message . ,message))))))
    (princ (claude-mcp--json-encode resp))
    (princ "\n")
    (sit-for 0)))

;; ---------------------------------------------------------------------------
;; Server info & capabilities
;; ---------------------------------------------------------------------------

(defvar claude-mcp--server-info
  '((name . "claude-emacs")
    (version . "0.1.0")))

(defvar claude-mcp--capabilities
  '((tools . ((listChanged . :json-false)))))

(defvar claude-mcp--tools
  (vector
   `((name . "getDiagnostics")
     (description . "Get Flymake/Flycheck diagnostics from Emacs. Returns errors and warnings for open buffers.")
     (inputSchema . ((type . "object")
                     (properties . ((uri . ((type . "string")
                                            (description . "Optional file path to get diagnostics for. If not provided, gets diagnostics for all files.")))))
                     (required . []))))
   `((name . "getOpenBuffers")
     (description . "Get information about currently open file-visiting buffers in Emacs.")
     (inputSchema . ((type . "object")
                     (properties . ,(make-hash-table))
                     (required . []))))
   `((name . "getCurrentSelection")
     (description . "Get the current region (selection) in the active Emacs buffer.")
     (inputSchema . ((type . "object")
                     (properties . ,(make-hash-table))
                     (required . []))))
   `((name . "openFile")
     (description . "Open a file in Emacs and optionally go to a specific line.")
     (inputSchema . ((type . "object")
                     (properties . ((filePath . ((type . "string")
                                                 (description . "Path to the file to open.")))
                                    (line . ((type . "integer")
                                             (description . "Optional line number to go to.")))
                                    (column . ((type . "integer")
                                               (description . "Optional column number.")))))
                     (required . ["filePath"]))))
   `((name . "openDiff")
     (description . "Open a diff view comparing two files or a file with new contents.")
     (inputSchema . ((type . "object")
                     (properties . ((old_file_path . ((type . "string")
                                                      (description . "Path to the original file.")))
                                    (new_file_path . ((type . "string")
                                                      (description . "Path to the new file.")))
                                    (new_file_contents . ((type . "string")
                                                          (description . "If provided, compare old_file_path against this content instead of new_file_path.")))))
                     (required . ["old_file_path"]))))
   `((name . "getWorkspaceFolders")
     (description . "Get the project root directories known to Emacs (via project.el or projectile).")
     (inputSchema . ((type . "object")
                     (properties . ,(make-hash-table))
                     (required . []))))
   `((name . "checkDocumentDirty")
     (description . "Check if a buffer visiting a file has unsaved changes.")
     (inputSchema . ((type . "object")
                     (properties . ((filePath . ((type . "string")
                                                 (description . "Path to the file to check.")))))
                     (required . ["filePath"]))))
   `((name . "saveDocument")
     (description . "Save a buffer visiting the given file.")
     (inputSchema . ((type . "object")
                     (properties . ((filePath . ((type . "string")
                                                 (description . "Path to the file to save.")))))
                     (required . ["filePath"]))))))

;; ---------------------------------------------------------------------------
;; Tool implementations
;; ---------------------------------------------------------------------------

(defun claude-mcp--tool-get-diagnostics (args)
  "Get Flymake/Flycheck diagnostics.  ARGS may contain uri."
  (let* ((uri (cdr (assq 'uri args)))
         (form (if uri
                   (format "(claude-code--get-diagnostics %S)" uri)
                 "(claude-code--get-diagnostics nil)"))
         (result (claude-mcp--eval form)))
    `((content . [((type . "text")
                   (text . ,result))]))))

(defun claude-mcp--tool-get-open-buffers (_args)
  "Get list of open file-visiting buffers."
  (let ((result (claude-mcp--eval "(claude-code--get-open-buffers)")))
    `((content . [((type . "text")
                   (text . ,result))]))))

(defun claude-mcp--tool-get-current-selection (_args)
  "Get the active region in Emacs."
  (let ((result (claude-mcp--eval "(claude-code--get-current-selection)")))
    `((content . [((type . "text")
                   (text . ,result))]))))

(defun claude-mcp--tool-open-file (args)
  "Open a file, optionally at a line/column.  ARGS contains filePath, line, column."
  (let* ((file-path (cdr (assq 'filePath args)))
         (line (cdr (assq 'line args)))
         (column (cdr (assq 'column args)))
         (form (format "(claude-code--open-file %S %s %s)"
                       file-path
                       (if line (number-to-string line) "nil")
                       (if column (number-to-string column) "nil")))
         (result (claude-mcp--eval form)))
    `((content . [((type . "text")
                   (text . ,result))]))))

(defun claude-mcp--tool-open-diff (args)
  "Open a diff view.  ARGS contains old_file_path, new_file_path, new_file_contents."
  (let* ((old-path (cdr (assq 'old_file_path args)))
         (new-path (cdr (assq 'new_file_path args)))
         (new-contents (cdr (assq 'new_file_contents args)))
         (form (format "(claude-code--open-diff %S %s %s)"
                       old-path
                       (if new-path (format "%S" new-path) "nil")
                       (if new-contents (format "%S" new-contents) "nil")))
         (result (claude-mcp--eval form)))
    `((content . [((type . "text")
                   (text . ,result))]))))

(defun claude-mcp--tool-get-workspace-folders (_args)
  "Get project root directories."
  (let ((result (claude-mcp--eval "(claude-code--get-workspace-folders)")))
    `((content . [((type . "text")
                   (text . ,result))]))))

(defun claude-mcp--tool-check-document-dirty (args)
  "Check if file has unsaved changes.  ARGS contains filePath."
  (let* ((file-path (cdr (assq 'filePath args)))
         (form (format "(claude-code--check-document-dirty %S)" file-path))
         (result (claude-mcp--eval form)))
    `((content . [((type . "text")
                   (text . ,result))]))))

(defun claude-mcp--tool-save-document (args)
  "Save a file buffer.  ARGS contains filePath."
  (let* ((file-path (cdr (assq 'filePath args)))
         (form (format "(claude-code--save-document %S)" file-path))
         (result (claude-mcp--eval form)))
    `((content . [((type . "text")
                   (text . ,result))]))))

(defun claude-mcp--dispatch-tool (name args)
  "Dispatch tool call by NAME with ARGS."
  (pcase name
    ("getDiagnostics" (claude-mcp--tool-get-diagnostics args))
    ("getOpenBuffers" (claude-mcp--tool-get-open-buffers args))
    ("getCurrentSelection" (claude-mcp--tool-get-current-selection args))
    ("openFile" (claude-mcp--tool-open-file args))
    ("openDiff" (claude-mcp--tool-open-diff args))
    ("getWorkspaceFolders" (claude-mcp--tool-get-workspace-folders args))
    ("checkDocumentDirty" (claude-mcp--tool-check-document-dirty args))
    ("saveDocument" (claude-mcp--tool-save-document args))
    (_ nil)))

;; ---------------------------------------------------------------------------
;; Request handler
;; ---------------------------------------------------------------------------

(defun claude-mcp--handle-request (id method params)
  "Handle a JSON-RPC request with ID, METHOD, and PARAMS."
  (pcase method
    ("initialize"
     (claude-mcp--respond id
                          `((protocolVersion . "2025-06-18")
                            (capabilities . ,claude-mcp--capabilities)
                            (serverInfo . ,claude-mcp--server-info))))
    ("ping"
     (claude-mcp--respond id '()))
    ("tools/list"
     (claude-mcp--respond id `((tools . ,claude-mcp--tools))))
    ("tools/call"
     (let* ((tool-name (cdr (assq 'name params)))
            (arguments (cdr (assq 'arguments params)))
            (result (claude-mcp--dispatch-tool tool-name arguments)))
       (if result
           (claude-mcp--respond id result)
         (claude-mcp--respond-error id -32601 (format "Unknown tool: %s" tool-name)))))
    ("resources/list"
     (claude-mcp--respond id '((resources . []))))
    ("prompts/list"
     (claude-mcp--respond id '((prompts . []))))
    (_
     (claude-mcp--respond-error id -32601 (format "Unknown method: %s" method)))))

(defun claude-mcp--handle-notification (_method _params)
  "Handle a JSON-RPC notification (no response needed)."
  nil)

;; ---------------------------------------------------------------------------
;; Main loop
;; ---------------------------------------------------------------------------

(defun claude-mcp--process-message (msg)
  "Process a single JSON-RPC MSG (parsed alist)."
  (let ((id (cdr (assq 'id msg)))
        (method (cdr (assq 'method msg))))
    (if id
        (claude-mcp--handle-request id method (cdr (assq 'params msg)))
      (claude-mcp--handle-notification method (cdr (assq 'params msg))))))

(defun claude-mcp--main-loop ()
  "Read JSON-RPC messages from stdin line by line and process them."
  (let ((line nil))
    (while (setq line (ignore-errors (read-from-minibuffer "")))
      (when (and line (not (string-empty-p (string-trim line))))
        (condition-case err
            (let ((msg (json-read-from-string line)))
              (claude-mcp--process-message msg))
          (error
           (message "claude-emacs-mcp: parse error: %S" err)))))))

;; Start the server
(claude-mcp--main-loop)

;;; claude-code-mcp-server.el ends here
