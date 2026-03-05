;;; claude-code-test.el --- Tests for claude-code.el -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the Claude Code Emacs package.
;; Run with: emacs --batch -L . -l claude-code-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'json)
(require 'claude-code)

;; ---------------------------------------------------------------------------
;; JSON encoding
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-json-encode ()
  "Test JSON encoding helper."
  (should (equal (claude-code--json-encode '((a . 1) (b . "hello")))
                 "{\"a\":1,\"b\":\"hello\"}"))
  (should (equal (claude-code--json-encode `((x . ,json-null)))
                 "{\"x\":null}"))
  (should (equal (claude-code--json-encode `((y . ,json-false)))
                 "{\"y\":false}")))

;; ---------------------------------------------------------------------------
;; Tool functions (editor state queries)
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-get-open-buffers ()
  "Test that get-open-buffers returns valid JSON array."
  (let ((result (claude-code--get-open-buffers)))
    ;; Should be valid JSON
    (should (stringp result))
    (let ((parsed (json-read-from-string result)))
      ;; Should be a vector
      (should (vectorp parsed)))))

(ert-deftest claude-code-test-get-open-buffers-includes-file-buffers ()
  "Test that file-visiting buffers appear in the result."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (find-file-noselect temp-file)
          (let* ((result (claude-code--get-open-buffers))
                 (parsed (json-read-from-string result))
                 (paths (mapcar (lambda (b) (cdr (assq 'filePath b)))
                                (append parsed nil))))
            (should (member temp-file paths))))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (kill-buffer buf))
      (delete-file temp-file))))

(ert-deftest claude-code-test-get-current-selection-no-region ()
  "Test getCurrentSelection when no region is active."
  (with-temp-buffer
    ;; Ensure no region
    (deactivate-mark)
    (let* ((result (claude-code--get-current-selection))
           (parsed (json-read-from-string result)))
      (should (equal (cdr (assq 'success parsed)) :json-false)))))

(ert-deftest claude-code-test-check-document-dirty-nonexistent ()
  "Test checkDocumentDirty for a file with no visiting buffer."
  (let* ((result (claude-code--check-document-dirty "/tmp/nonexistent-file-12345"))
         (parsed (json-read-from-string result)))
    (should (equal (cdr (assq 'isDirty parsed)) :json-false))
    (should (equal (cdr (assq 'filePath parsed)) "/tmp/nonexistent-file-12345"))))

(ert-deftest claude-code-test-check-document-dirty-clean ()
  "Test checkDocumentDirty for a clean buffer."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file (insert "hello"))
          (find-file-noselect temp-file)
          (let* ((result (claude-code--check-document-dirty temp-file))
                 (parsed (json-read-from-string result)))
            (should (equal (cdr (assq 'isDirty parsed)) :json-false))))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (kill-buffer buf))
      (delete-file temp-file))))

(ert-deftest claude-code-test-check-document-dirty-modified ()
  "Test checkDocumentDirty for a modified buffer."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file (insert "hello"))
          (let ((buf (find-file-noselect temp-file)))
            (with-current-buffer buf
              (insert "modification")
              (let* ((result (claude-code--check-document-dirty temp-file))
                     (parsed (json-read-from-string result)))
                (should (equal (cdr (assq 'isDirty parsed)) t))))))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (set-buffer-modified-p nil)
        (kill-buffer buf))
      (delete-file temp-file))))

(ert-deftest claude-code-test-save-document-no-buffer ()
  "Test saveDocument for a file with no visiting buffer."
  (let* ((result (claude-code--save-document "/tmp/nonexistent-file-12345"))
         (parsed (json-read-from-string result)))
    (should (equal (cdr (assq 'success parsed)) :json-false))))

(ert-deftest claude-code-test-get-diagnostics-returns-json ()
  "Test that getDiagnostics returns valid JSON."
  (let ((result (claude-code--get-diagnostics)))
    (should (stringp result))
    ;; Should parse without error
    (json-read-from-string result)))

(ert-deftest claude-code-test-get-workspace-folders-returns-json ()
  "Test that getWorkspaceFolders returns valid JSON array."
  (let ((result (claude-code--get-workspace-folders)))
    (should (stringp result))
    (let ((parsed (json-read-from-string result)))
      (should (vectorp parsed)))))

(ert-deftest claude-code-test-open-file ()
  "Test openFile opens a file and returns success."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (let* ((result (claude-code--open-file temp-file))
               (parsed (json-read-from-string result)))
          (should (equal (cdr (assq 'success parsed)) t))
          (should (equal (cdr (assq 'filePath parsed)) temp-file))
          ;; Buffer should now exist
          (should (find-buffer-visiting temp-file)))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (kill-buffer buf))
      (delete-file temp-file))))

(ert-deftest claude-code-test-open-file-at-line ()
  "Test openFile navigates to the correct line."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "line1\nline2\nline3\nline4\n"))
          (claude-code--open-file temp-file 3)
          (let ((buf (find-buffer-visiting temp-file)))
            (should buf)
            (with-current-buffer buf
              (should (= (line-number-at-pos) 3)))))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (kill-buffer buf))
      (delete-file temp-file))))

;; ---------------------------------------------------------------------------
;; TCP eval server
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-eval-server-start-stop ()
  "Test that the eval server starts and stops cleanly."
  (claude-code--eval-server-start)
  (should claude-code--eval-server)
  (should claude-code--eval-server-port)
  (should (integerp claude-code--eval-server-port))
  (should (> claude-code--eval-server-port 0))
  (should (process-live-p claude-code--eval-server))
  (claude-code--eval-server-stop)
  (should-not claude-code--eval-server)
  (should-not claude-code--eval-server-port))

(ert-deftest claude-code-test-eval-server-evaluates ()
  "Test that the eval server can evaluate Elisp over TCP."
  (claude-code--eval-server-start)
  (unwind-protect
      (let* ((proc (open-network-stream "test-client" nil
                                        "127.0.0.1"
                                        claude-code--eval-server-port))
             (received nil))
        (set-process-filter
         proc (lambda (_p output) (setq received output)))
        (set-process-sentinel proc #'ignore)
        (process-send-string proc "(+ 1 2)\n")
        ;; Wait for response
        (let ((start (float-time)))
          (while (and (not received)
                      (< (- (float-time) start) 5))
            (accept-process-output proc 0.1)))
        (delete-process proc)
        (should received)
        (should (equal (string-trim received) "3")))
    (claude-code--eval-server-stop)))

(ert-deftest claude-code-test-eval-server-string-result ()
  "Test that the eval server returns strings directly."
  (claude-code--eval-server-start)
  (unwind-protect
      (let* ((proc (open-network-stream "test-client" nil
                                        "127.0.0.1"
                                        claude-code--eval-server-port))
             (received nil))
        (set-process-filter
         proc (lambda (_p output) (setq received output)))
        (set-process-sentinel proc #'ignore)
        (process-send-string proc "(concat \"hello\" \" \" \"world\")\n")
        (let ((start (float-time)))
          (while (and (not received)
                      (< (- (float-time) start) 5))
            (accept-process-output proc 0.1)))
        (delete-process proc)
        (should received)
        (should (equal (string-trim received) "hello world")))
    (claude-code--eval-server-stop)))

(ert-deftest claude-code-test-eval-server-error-handling ()
  "Test that the eval server handles errors gracefully."
  (claude-code--eval-server-start)
  (unwind-protect
      (let* ((proc (open-network-stream "test-client" nil
                                        "127.0.0.1"
                                        claude-code--eval-server-port))
             (received nil))
        (set-process-filter
         proc (lambda (_p output) (setq received output)))
        (set-process-sentinel proc #'ignore)
        (process-send-string proc "(/ 1 0)\n")
        (let ((start (float-time)))
          (while (and (not received)
                      (< (- (float-time) start) 5))
            (accept-process-output proc 0.1)))
        (delete-process proc)
        (should received)
        (should (string-match-p "error" received)))
    (claude-code--eval-server-stop)))

;; ---------------------------------------------------------------------------
;; MCP server protocol (test via subprocess)
;; ---------------------------------------------------------------------------

(defun claude-code-test--mcp-request (messages)
  "Send MESSAGES (list of JSON strings) to the MCP server and return output lines."
  (let* ((input (mapconcat #'identity messages "\n"))
         (script-path (expand-file-name "claude-code-mcp-server.el"
                                        (file-name-directory
                                         (or load-file-name
                                             buffer-file-name
                                             default-directory))))
         (buf (generate-new-buffer " *mcp-test*"))
         (exit-code (call-process
                     "emacs" nil buf nil
                     "--batch" "--load" script-path)))
    (unwind-protect
        (with-current-buffer buf
          (let ((lines (split-string (string-trim (buffer-string)) "\n" t)))
            (mapcar #'json-read-from-string lines)))
      (kill-buffer buf))))

(ert-deftest claude-code-test-mcp-initialize ()
  "Test MCP initialize handshake."
  ;; Need to provide input via a temp file since call-process doesn't support stdin strings easily
  (let* ((input-file (make-temp-file "mcp-test-" nil ".jsonl"))
         (script-path (expand-file-name "claude-code-mcp-server.el"
                                        (file-name-directory
                                         (or load-file-name
                                             buffer-file-name
                                             default-directory)))))
    (unwind-protect
        (progn
          (with-temp-file input-file
            (insert "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n"))
          (let ((buf (generate-new-buffer " *mcp-test*")))
            (unwind-protect
                (progn
                  (call-process "emacs" input-file buf nil
                                "--batch" "--load" script-path)
                  (with-current-buffer buf
                    (let* ((output (string-trim (buffer-string)))
                           (resp (json-read-from-string output))
                           (result (cdr (assq 'result resp))))
                      (should (equal (cdr (assq 'id resp)) 1))
                      (should (equal (cdr (assq 'protocolVersion result)) "2025-06-18"))
                      (should (assq 'capabilities result))
                      (should (assq 'serverInfo result)))))
              (kill-buffer buf))))
      (delete-file input-file))))

(ert-deftest claude-code-test-mcp-tools-list ()
  "Test MCP tools/list returns all expected tools."
  (let* ((input-file (make-temp-file "mcp-test-" nil ".jsonl"))
         (script-path (expand-file-name "claude-code-mcp-server.el"
                                        (file-name-directory
                                         (or load-file-name
                                             buffer-file-name
                                             default-directory)))))
    (unwind-protect
        (progn
          (with-temp-file input-file
            (insert "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}\n"))
          (let ((buf (generate-new-buffer " *mcp-test*")))
            (unwind-protect
                (progn
                  (call-process "emacs" input-file buf nil
                                "--batch" "--load" script-path)
                  (with-current-buffer buf
                    (let* ((output (string-trim (buffer-string)))
                           (resp (json-read-from-string output))
                           (tools (cdr (assq 'tools (cdr (assq 'result resp)))))
                           (names (mapcar (lambda (t) (cdr (assq 'name t)))
                                          (append tools nil))))
                      (should (= (length tools) 8))
                      (should (member "getDiagnostics" names))
                      (should (member "getOpenBuffers" names))
                      (should (member "getCurrentSelection" names))
                      (should (member "openFile" names))
                      (should (member "openDiff" names))
                      (should (member "getWorkspaceFolders" names))
                      (should (member "checkDocumentDirty" names))
                      (should (member "saveDocument" names)))))
              (kill-buffer buf))))
      (delete-file input-file))))

(ert-deftest claude-code-test-mcp-ping ()
  "Test MCP ping."
  (let* ((input-file (make-temp-file "mcp-test-" nil ".jsonl"))
         (script-path (expand-file-name "claude-code-mcp-server.el"
                                        (file-name-directory
                                         (or load-file-name
                                             buffer-file-name
                                             default-directory)))))
    (unwind-protect
        (progn
          (with-temp-file input-file
            (insert "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"ping\"}\n"))
          (let ((buf (generate-new-buffer " *mcp-test*")))
            (unwind-protect
                (progn
                  (call-process "emacs" input-file buf nil
                                "--batch" "--load" script-path)
                  (with-current-buffer buf
                    (let* ((output (string-trim (buffer-string)))
                           (resp (json-read-from-string output)))
                      (should (equal (cdr (assq 'id resp)) 42))
                      (should (assq 'result resp)))))
              (kill-buffer buf))))
      (delete-file input-file))))

(ert-deftest claude-code-test-mcp-unknown-method ()
  "Test MCP returns error for unknown method."
  (let* ((input-file (make-temp-file "mcp-test-" nil ".jsonl"))
         (script-path (expand-file-name "claude-code-mcp-server.el"
                                        (file-name-directory
                                         (or load-file-name
                                             buffer-file-name
                                             default-directory)))))
    (unwind-protect
        (progn
          (with-temp-file input-file
            (insert "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"bogus/method\"}\n"))
          (let ((buf (generate-new-buffer " *mcp-test*")))
            (unwind-protect
                (progn
                  (call-process "emacs" input-file buf nil
                                "--batch" "--load" script-path)
                  (with-current-buffer buf
                    (let* ((output (string-trim (buffer-string)))
                           (resp (json-read-from-string output))
                           (err (cdr (assq 'error resp))))
                      (should (equal (cdr (assq 'id resp)) 99))
                      (should err)
                      (should (equal (cdr (assq 'code err)) -32601)))))
              (kill-buffer buf))))
      (delete-file input-file))))

(ert-deftest claude-code-test-mcp-unknown-tool ()
  "Test MCP returns error for unknown tool."
  (let* ((input-file (make-temp-file "mcp-test-" nil ".jsonl"))
         (script-path (expand-file-name "claude-code-mcp-server.el"
                                        (file-name-directory
                                         (or load-file-name
                                             buffer-file-name
                                             default-directory)))))
    (unwind-protect
        (progn
          (with-temp-file input-file
            (insert "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"noSuchTool\",\"arguments\":{}}}\n"))
          (let ((buf (generate-new-buffer " *mcp-test*")))
            (unwind-protect
                (progn
                  (call-process "emacs" input-file buf nil
                                "--batch" "--load" script-path)
                  (with-current-buffer buf
                    (let* ((output (string-trim (buffer-string)))
                           (resp (json-read-from-string output))
                           (err (cdr (assq 'error resp))))
                      (should err)
                      (should (string-match-p "noSuchTool"
                                              (cdr (assq 'message err)))))))
              (kill-buffer buf))))
      (delete-file input-file))))

;; ---------------------------------------------------------------------------
;; Stream message handling
;; ---------------------------------------------------------------------------

(defmacro claude-code-test--with-chat-buffer (&rest body)
  "Set up a temporary Claude Code chat buffer and run BODY."
  (declare (indent 0))
  `(let ((claude-code--buffer-name "*Claude Code Test*"))
     (with-current-buffer (get-buffer-create claude-code--buffer-name)
       (claude-code-mode)
       (let ((inhibit-read-only t))
         (erase-buffer))
       (claude-code--insert-prompt)
       (unwind-protect
           (progn ,@body)
         (kill-buffer claude-code--buffer-name)))))

(ert-deftest claude-code-test-handle-assistant-text ()
  "Test that assistant text messages are inserted into the buffer."
  (claude-code-test--with-chat-buffer
    (claude-code--handle-stream-message
     '((type . "assistant")
       (message . ((content . [((type . "text")
                                (text . "Hello from Claude!"))])))))
    (should (string-match-p "Hello from Claude!" (buffer-string)))))

(ert-deftest claude-code-test-handle-tool-use ()
  "Test that tool_use messages show the tool name and details."
  (claude-code-test--with-chat-buffer
    (claude-code--handle-stream-message
     '((type . "assistant")
       (message . ((content . [((type . "tool_use")
                                (name . "Read")
                                (id . "tool_123")
                                (input . ((file_path . "/tmp/foo.el"))))])))))
    (should (string-match-p "\\[Tool: Read" (buffer-string)))
    (should (string-match-p "/tmp/foo.el" (buffer-string)))))

(ert-deftest claude-code-test-tool-use-summary ()
  "Test tool use summary generation."
  (should (equal (claude-code--tool-use-summary "Read" '((file_path . "/tmp/x")))
                 "/tmp/x"))
  (should (equal (claude-code--tool-use-summary "Bash" '((command . "ls -la")))
                 "ls -la"))
  (should (equal (claude-code--tool-use-summary "openFile" '((filePath . "/tmp/y")))
                 "/tmp/y"))
  (should (equal (claude-code--tool-use-summary "getDiagnostics" nil)
                 "all files"))
  (should-not (claude-code--tool-use-summary "unknownTool" nil)))

(ert-deftest claude-code-test-handle-result ()
  "Test that result messages show the done separator."
  (claude-code-test--with-chat-buffer
    (claude-code--handle-stream-message
     '((type . "result")))
    (should (string-match-p "Done" (buffer-string)))))

(ert-deftest claude-code-test-handle-error ()
  "Test that error messages are displayed."
  (claude-code-test--with-chat-buffer
    (claude-code--handle-stream-message
     '((type . "error")
       (error . "something went wrong")))
    (should (string-match-p "something went wrong" (buffer-string)))))

;; ---------------------------------------------------------------------------
;; MCP config generation
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-mcp-config-generates-valid-json ()
  "Test that MCP config generation produces valid JSON."
  (let ((claude-code--eval-server-port 12345))
    (let ((config-file (claude-code--mcp-config)))
      (unwind-protect
          (let* ((json-str (with-temp-buffer
                             (insert-file-contents config-file)
                             (buffer-string)))
                 (parsed (json-read-from-string json-str))
                 (servers (cdr (assq 'mcpServers parsed)))
                 (emacs-server (cdr (assq 'claude-emacs servers)))
                 (env (cdr (assq 'env emacs-server))))
            (should emacs-server)
            (should (cdr (assq 'command emacs-server)))
            (should (equal (cdr (assq 'CLAUDE_EMACS_PORT env)) "12345")))
        (delete-file config-file)))))

;; ---------------------------------------------------------------------------
;; @ mention expansion
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-expand-mentions-file ()
  "Test @file:PATH expansion."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file (insert "file contents here"))
          (let ((result (claude-code--expand-mentions
                         (format "look at @file:%s please" temp-file))))
            (should (string-match-p "file contents here" result))
            (should-not (string-match-p "@file:" result))))
      (delete-file temp-file))))

(ert-deftest claude-code-test-expand-mentions-file-not-found ()
  "Test @file:PATH with nonexistent file."
  (let ((result (claude-code--expand-mentions "@file:/tmp/no-such-file-99999")))
    (should (string-match-p "file not found" result))))

(ert-deftest claude-code-test-expand-mentions-buffers ()
  "Test @buffers expansion lists open buffers."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (find-file-noselect temp-file)
          (let ((result (claude-code--expand-mentions "show me @buffers")))
            (should (string-match-p temp-file result))
            (should-not (string-match-p "@buffers" result))))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (kill-buffer buf))
      (delete-file temp-file))))

(ert-deftest claude-code-test-expand-mentions-selection-no-origin ()
  "Test @selection with no origin buffer."
  (let ((claude-code--origin-buffer nil))
    (let ((result (claude-code--expand-mentions "explain @selection")))
      (should (string-match-p "no active selection" result)))))

(ert-deftest claude-code-test-expand-mentions-no-at ()
  "Test that text without @ mentions is returned unchanged."
  (should (equal (claude-code--expand-mentions "hello world")
                 "hello world")))

;; ---------------------------------------------------------------------------
;; Input area
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-input-prompt-setup ()
  "Test that the input prompt creates an editable area."
  (claude-code-test--with-chat-buffer
    (should (marker-position claude-code--input-marker))
    ;; Should be able to type after the marker
    (goto-char (point-max))
    (insert "test input")
    (should (equal (claude-code--get-input) "test input"))))

(ert-deftest claude-code-test-insert-output-preserves-input ()
  "Test that inserting output preserves in-progress input."
  (claude-code-test--with-chat-buffer
    (goto-char (point-max))
    (insert "my typing")
    (claude-code--insert-output "some output\n")
    (should (string-match-p "some output" (buffer-string)))
    (should (equal (claude-code--get-input) "my typing"))))

;; ---------------------------------------------------------------------------
;; save-document success
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-save-document-success ()
  "Test saveDocument actually saves a modified buffer."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file (insert "original"))
          (let ((buf (find-file-noselect temp-file)))
            (with-current-buffer buf
              (goto-char (point-max))
              (insert " modified")
              (should (buffer-modified-p)))
            (let* ((result (claude-code--save-document temp-file))
                   (parsed (json-read-from-string result)))
              (should (equal (cdr (assq 'success parsed)) t))
              (with-current-buffer buf
                (should-not (buffer-modified-p))))))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (kill-buffer buf))
      (delete-file temp-file))))

;; ---------------------------------------------------------------------------
;; open-file with column
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-open-file-at-line-and-column ()
  "Test openFile navigates to correct line and column."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "abcdef\nghijkl\nmnopqr\n"))
          (claude-code--open-file temp-file 2 4)
          (let ((buf (find-buffer-visiting temp-file)))
            (should buf)
            (with-current-buffer buf
              (should (= (line-number-at-pos) 2))
              (should (= (current-column) 3)))))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (kill-buffer buf))
      (delete-file temp-file))))

;; ---------------------------------------------------------------------------
;; open-diff
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-open-diff-no-content ()
  "Test openDiff returns failure when no new file or contents provided."
  (let ((claude-code-confirm-tool-calls nil))
    (let* ((result (claude-code--open-diff "/tmp/some-file"))
           (parsed (json-read-from-string result)))
      (should (equal (cdr (assq 'success parsed)) :json-false)))))

;; ---------------------------------------------------------------------------
;; get-current-selection with active region
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-get-current-selection-with-region ()
  "Test getCurrentSelection returns selected text."
  (with-temp-buffer
    (insert "line one\nline two\nline three\n")
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-min))
    (set-mark (point))
    (forward-line 2)
    (activate-mark)
    (let* ((result (claude-code--get-current-selection))
           (parsed (json-read-from-string result)))
      (should (equal (cdr (assq 'text parsed)) "line one\nline two\n"))
      (should (equal (cdr (assq 'startLine parsed)) 1))
      (should (equal (cdr (assq 'endLine parsed)) 3)))))

;; ---------------------------------------------------------------------------
;; @ mention: @buffer
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-expand-mentions-buffer ()
  "Test @buffer expansion includes buffer contents."
  (let ((claude-code--origin-buffer
         (generate-new-buffer " *test-origin*")))
    (unwind-protect
        (progn
          (with-current-buffer claude-code--origin-buffer
            (insert "buffer content xyz"))
          (let ((result (claude-code--expand-mentions "check @buffer")))
            (should (string-match-p "buffer content xyz" result))
            (should-not (string-match-p "@buffer" result))))
      (kill-buffer claude-code--origin-buffer))))

;; ---------------------------------------------------------------------------
;; @ mention: @selection with active region
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-expand-mentions-selection-with-region ()
  "Test @selection expansion with an active region."
  (let ((claude-code--origin-buffer
         (generate-new-buffer " *test-origin*")))
    (unwind-protect
        (progn
          (with-current-buffer claude-code--origin-buffer
            (insert "hello world")
            (set-mark 1)
            (goto-char 6)
            (activate-mark))
          (let ((result (claude-code--expand-mentions "explain @selection")))
            (should (string-match-p "hello" result))
            (should-not (string-match-p "@selection" result))))
      (kill-buffer claude-code--origin-buffer))))

;; ---------------------------------------------------------------------------
;; Context capture
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-capture-context-with-file ()
  "Test context capture includes file path and line number."
  (let ((temp-file (make-temp-file "claude-test-")))
    (unwind-protect
        (progn
          (find-file temp-file)
          (insert "line1\nline2\n")
          (goto-char (point-min))
          (forward-line 1)
          (let ((claude-code--origin-buffer (current-buffer)))
            (let ((ctx (claude-code--capture-context)))
              (should ctx)
              (should (string-match-p temp-file ctx))
              (should (string-match-p "line 2" ctx)))))
      (when-let ((buf (find-buffer-visiting temp-file)))
        (set-buffer-modified-p nil)
        (kill-buffer buf))
      (delete-file temp-file))))

(ert-deftest claude-code-test-capture-context-nil-when-no-origin ()
  "Test context capture returns nil when no origin buffer."
  (let ((claude-code--origin-buffer nil))
    (should-not (claude-code--capture-context))))

;; ---------------------------------------------------------------------------
;; CLI args
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-build-cli-args-default ()
  "Test CLI args include required flags."
  (let ((claude-code--eval-server-port 9999)
        (claude-code-model nil)
        (claude-code-permission-mode "default"))
    (let ((args (claude-code--build-cli-args)))
      (should (member "--output-format" args))
      (should (member "stream-json" args))
      (should (member "--input-format" args))
      (should (member "--verbose" args))
      (should (member "--mcp-config" args))
      (should (member "--permission-mode" args))
      (should (member "default" args))
      ;; No --model when nil
      (should-not (member "--model" args)))))

(ert-deftest claude-code-test-build-cli-args-with-model ()
  "Test CLI args include --model when set."
  (let ((claude-code--eval-server-port 9999)
        (claude-code-model "opus")
        (claude-code-permission-mode "default"))
    (let ((args (claude-code--build-cli-args)))
      (should (member "--model" args))
      (should (member "opus" args)))))

;; ---------------------------------------------------------------------------
;; Stream: tool_result in user message
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-handle-tool-result ()
  "Test that tool_result messages display truncated content."
  (claude-code-test--with-chat-buffer
    (claude-code--handle-stream-message
     '((type . "user")
       (message . ((content . [((type . "tool_result")
                                (content . "result data here"))])))))
    (should (string-match-p "Tool result:.*result data here" (buffer-string)))))

;; ---------------------------------------------------------------------------
;; MCP resources/list and prompts/list
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-mcp-resources-list ()
  "Test MCP resources/list returns empty list."
  (let* ((input-file (make-temp-file "mcp-test-" nil ".jsonl"))
         (script-path (expand-file-name "claude-code-mcp-server.el"
                                        (file-name-directory
                                         (or load-file-name
                                             buffer-file-name
                                             default-directory)))))
    (unwind-protect
        (progn
          (with-temp-file input-file
            (insert "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"resources/list\",\"params\":{}}\n"))
          (let ((buf (generate-new-buffer " *mcp-test*")))
            (unwind-protect
                (progn
                  (call-process "emacs" input-file buf nil
                                "--batch" "--load" script-path)
                  (with-current-buffer buf
                    (let* ((output (string-trim (buffer-string)))
                           (resp (json-read-from-string output))
                           (result (cdr (assq 'result resp))))
                      (should (equal (cdr (assq 'id resp)) 1))
                      (should (equal (cdr (assq 'resources result)) [])))))
              (kill-buffer buf))))
      (delete-file input-file))))

(ert-deftest claude-code-test-mcp-prompts-list ()
  "Test MCP prompts/list returns empty list."
  (let* ((input-file (make-temp-file "mcp-test-" nil ".jsonl"))
         (script-path (expand-file-name "claude-code-mcp-server.el"
                                        (file-name-directory
                                         (or load-file-name
                                             buffer-file-name
                                             default-directory)))))
    (unwind-protect
        (progn
          (with-temp-file input-file
            (insert "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"prompts/list\",\"params\":{}}\n"))
          (let ((buf (generate-new-buffer " *mcp-test*")))
            (unwind-protect
                (progn
                  (call-process "emacs" input-file buf nil
                                "--batch" "--load" script-path)
                  (with-current-buffer buf
                    (let* ((output (string-trim (buffer-string)))
                           (resp (json-read-from-string output))
                           (result (cdr (assq 'result resp))))
                      (should (equal (cdr (assq 'id resp)) 2))
                      (should (equal (cdr (assq 'prompts result)) [])))))
              (kill-buffer buf))))
      (delete-file input-file))))

;; ---------------------------------------------------------------------------
;; MCP config with model
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-mcp-config-has-correct-args ()
  "Test MCP config includes --batch and --load with correct script."
  (let ((claude-code--eval-server-port 5555))
    (let ((config-file (claude-code--mcp-config)))
      (unwind-protect
          (let* ((json-str (with-temp-buffer
                             (insert-file-contents config-file)
                             (buffer-string)))
                 (parsed (json-read-from-string json-str))
                 (servers (cdr (assq 'mcpServers parsed)))
                 (emacs-server (cdr (assq 'claude-emacs servers)))
                 (args (cdr (assq 'args emacs-server))))
            (should (vectorp args))
            (should (equal (aref args 0) "--batch"))
            (should (equal (aref args 1) "--load")))
        (delete-file config-file)))))

;; ---------------------------------------------------------------------------
;; Multiple output insertions
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-multiple-outputs-preserve-input ()
  "Test that multiple output insertions preserve user input."
  (claude-code-test--with-chat-buffer
    (goto-char (point-max))
    (insert "work in progress")
    (claude-code--insert-output "first output\n")
    (claude-code--insert-output "second output\n")
    (should (string-match-p "first output" (buffer-string)))
    (should (string-match-p "second output" (buffer-string)))
    (should (equal (claude-code--get-input) "work in progress"))))

;; ---------------------------------------------------------------------------
;; @buffer does not match @buffers
;; ---------------------------------------------------------------------------

(ert-deftest claude-code-test-expand-mentions-buffer-vs-buffers ()
  "Test that @buffer does not interfere with @buffers."
  (let ((claude-code--origin-buffer
         (generate-new-buffer " *test-origin*")))
    (unwind-protect
        (progn
          (with-current-buffer claude-code--origin-buffer
            (insert "origin content"))
          ;; Only @buffers, not @buffer
          (let ((result (claude-code--expand-mentions "list @buffers please")))
            (should (string-match-p "Open buffers:" result))
            (should-not (string-match-p "@buffers" result))
            ;; Should NOT contain the origin buffer contents
            (should-not (string-match-p "origin content" result))))
      (kill-buffer claude-code--origin-buffer))))

(provide 'claude-code-test)

;;; claude-code-test.el ends here
