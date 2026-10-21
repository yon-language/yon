# Yon LSP

The Yon language server. It runs on the client side (stdin/stdout, JSON-RPC):
nothing to host. It reuses the frontend (lexer, parser, type checker, linter,
formatter): an LSP diagnostic is a compiler diagnostic translated into the
protocol.

## What it does
- Diagnostics on `didOpen`/`didChange`: syntax and type errors (every error in
  the program, not only the first) and linter warnings (`Wxxxx`).
- Hover.
- Document symbols.
- Completion (keywords and names in scope; `.` is a trigger character).
- Document formatting, through the shared formatter (fail-safe: it declines
  rather than produce a different program).

## Build
The binary is a frontend executable (it shares the modules):
```
cd frontend && dune build
# -> frontend/_build/default/yon_lsp.exe   (wrapper: toolchain/yon-lsp)
```

## CLI use (tests/CI)
```
yon_lsp.exe --check file.yon   # prints the diagnostics; exit code = their number (at most 255)
yon_lsp.exe --check dir/       # whole project (Project.check_all, the check the driver runs)
```

## Editors
- Neovim: see `editors/neovim.lua` (native `vim.lsp`, no plugin).
- VS Code and Cursor: see `editors/vscode/`.

## Not yet implemented
- Go-to-definition.
- Rename.
