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

```
M-x claude-code       Start a Claude Code session
C-c C-c               Send a message
C-c C-k               Interrupt current operation
C-c C-q               Quit the session
```

## Configuration

```elisp
;; Use a specific model
(setq claude-code-model "sonnet")

;; Auto-accept edits (careful!)
(setq claude-code-permission-mode "acceptEdits")

;; Custom claude CLI path
(setq claude-code-cli-program "/usr/local/bin/claude")
```

## Running Tests

```sh
emacs --batch -L . -l claude-code-test.el -f ert-run-tests-batch-and-exit
```

## License

MIT
