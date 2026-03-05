# claude-code.el

Claude Code integration for Emacs. Uses your Claude Code subscription (same as the VSCode extension) -- not API keys.

## How it works

This package spawns the `claude` CLI as a subprocess with `--input-format stream-json --output-format stream-json` and injects an Emacs-native MCP server that gives Claude access to your editor state.

```
┌──────────────────────────────────────────────┐
│                    Emacs                      │
│                                               │
│  ┌──────────────┐     ┌───────────────────┐   │
│  │ claude-code   │     │  TCP eval server  │   │
│  │ (chat buffer, │     │  (port auto)      │   │
│  │  stream-json) │     │                   │   │
│  └───────┬───────┘     └─────────▲─────────┘   │
│          │ stdin/stdout          │ TCP          │
│          ▼                       │              │
│    ┌───────────┐     ┌───────────┴──────────┐  │
│    │ claude CLI │────▶│  MCP server          │  │
│    │           │     │  (emacs --batch)     │  │
│    └───────────┘     └──────────────────────┘  │
└──────────────────────────────────────────────┘
```

The MCP server runs as a separate `emacs --batch` process (spawned by the CLI) and communicates back to the main Emacs via a lightweight TCP eval server. No `emacsclient` dependency.

## MCP Tools

The MCP server exposes these tools to Claude, mirroring the VSCode extension:

| Tool | Description |
|------|-------------|
| `getDiagnostics` | Flymake/Flycheck errors and warnings |
| `getOpenBuffers` | List of open file-visiting buffers |
| `getCurrentSelection` | Active region text and position |
| `openFile` | Open a file, optionally at a line/column |
| `openDiff` | Show a diff between files or content |
| `getWorkspaceFolders` | Project roots via `project.el` |
| `checkDocumentDirty` | Check if a buffer has unsaved changes |
| `saveDocument` | Save a buffer |

## Requirements

- Emacs 28.1+
- `claude` CLI installed and authenticated (`claude auth login`)
- A Claude Code subscription (Pro, Max, or Team)

## Installation

### Manual

```elisp
(add-to-list 'load-path "/path/to/claude-code.el")
(require 'claude-code)
```

### use-package

```elisp
(use-package claude-code
  :load-path "/path/to/claude-code.el")
```

### Doom Emacs

In `packages.el`:
```elisp
(package! claude-code :recipe (:host github :repo "kovan/claude-code.el"))
```

In `config.el`:
```elisp
(use-package! claude-code)
```

## Usage

1. Open a source file you want to work with
2. Optionally select a region of code for context
3. `M-x claude-code`
4. Type at the prompt and press `RET` to send

### Key bindings

| Key | Action |
|-----|--------|
| `RET` | Send message |
| `C-j` | Insert newline (for multi-line input) |
| `C-c C-c` | Send message (alternative) |
| `C-c C-k` | Interrupt current operation |
| `C-c C-q` | Quit the session |
| `C-c C-n` | Start a new session |

### Context

Context from your current buffer is automatically attached when you send a message (file path, line number, and active selection).

You can also use `@` mentions for explicit context:

| Mention | Description |
|---------|-------------|
| `@buffer` | Contents of the current buffer (truncated at 10k chars) |
| `@selection` | The active region in the origin buffer |
| `@file:/path/to/file` | Contents of a specific file |
| `@buffers` | List of all open file-visiting buffers |

### Tool confirmations

By default, Claude will ask for your approval (via `y-or-n-p`) before modifying editor state -- opening files, showing diffs, or saving buffers. Diffs are shown using `ediff`.

To disable confirmations:

```elisp
(setq claude-code-confirm-tool-calls nil)
```

## Configuration

```elisp
;; Use a specific model
(setq claude-code-model "sonnet")

;; Auto-accept edits (careful!)
(setq claude-code-permission-mode "acceptEdits")

;; Custom claude CLI path
(setq claude-code-cli-program "/usr/local/bin/claude")

;; Don't ask before opening files/diffs/saving (default: t)
(setq claude-code-confirm-tool-calls nil)
```

## Running Tests

```sh
emacs --batch -L . -l claude-code-test.el -f ert-run-tests-batch-and-exit
```

## License

MIT
