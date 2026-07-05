# Changelog

## 0.3.0

- Syntax highlighting: a real TextMate grammar (`syntaxes/yon.tmLanguage.json`),
  with keywords derived from the compiler lexer, plus a language configuration
  (comments, brackets, auto-close). Previously the extension referenced these
  files but did not ship them.
- Formatting and linting surfaced as first-class, configurable features of the
  single language server: `yon.lint.enable`, `yon.format.enable`.
- `yon.trace.server` for debugging the JSON-RPC traffic.
- Marketplace metadata: categories (Programming Languages, Linters, Formatters),
  keywords, icon, gallery banner, license.

## 0.2.1

- Minimal language client launching `yon-lsp` for diagnostics, hover, document
  symbols, and completion.
