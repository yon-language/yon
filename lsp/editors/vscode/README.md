# Yon Language Support

Editor support for [Yon](https://yon-lang.org), The Topos of Programming. One
extension, three faces, all served by the `yon-lsp` language server:

- **Diagnostics** — compiler errors *and* linter warnings (`Wxxxx`), live on
  every edit, single-file or across a whole project (`yon.toml` + spaces).
- **Formatting** — `Format Document` via `yon-fmt` (fail-safe: it declines
  rather than corrupt). Pair with `editor.formatOnSave`.
- **Navigation** — hover, document symbols, completion.

Plus TextMate syntax highlighting for `.yon` files.

## Requirements

The `yon-lsp` binary must be reachable. Build it from the Yon repo with
`cd frontend && dune build` (the wrapper `toolchain/yon-lsp` points at it), then
either put `toolchain/` on your `PATH` or set `yon.lspPath` to an absolute path.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `yon.lspPath` | `yon-lsp` | Path or PATH name of the language server binary. |
| `yon.lint.enable` | `true` | Show linter warnings (`Wxxxx`) as diagnostics. |
| `yon.format.enable` | `true` | Provide `Format Document` via the server. |
| `yon.trace.server` | `off` | Trace the JSON-RPC traffic (debugging). |

Format-on-save, per language:

```jsonc
"[yon]": { "editor.formatOnSave": true }
```

## Install

From the Marketplace (once published): search "Yon Language Support", or
`code --install-extension yon-lang.yon-lang`.

From a local build: `Extensions` panel to "Install from VSIX...", or
`code --install-extension yon-lang-<version>.vsix`.

Works in VS Code and Cursor.
