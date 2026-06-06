# Yon Language Support

Syntax highlighting and language-server integration for [Yon](https://yon-lang.org), The Topos of Programming.

## Features
- Highlighting for `.yon` files (keywords, places, strings, operators)
- Real-time diagnostics from the compiler frontend
- Hover, document symbols, completion (via `yon-lsp`)

## Setup
1. Build the language server: `cd frontend && dune build`
2. Set `yon.lspPath` in your settings to the absolute path of
   `frontend/_build/default/yon_lsp.exe`
3. Open a `.yon` file.

Works in VS Code and Cursor. Install from `.vsix`: Extensions panel,
"Install from VSIX...".
