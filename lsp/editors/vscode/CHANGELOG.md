# Changelog

## 0.4.0

- Color theme **Yon (Frappé)**: a Catppuccin-Frappé-derived palette tuned with
  Refactoring-UI principles (one cool-tinted gray ramp for the chrome, pastel
  accents used semantically, blue/mauve as the Yon primary).
- File icon theme **Yon Icons**: the azure Y for `.yon` / `yon.toml` / `yon.lock`,
  plus generic file and folder icons. Reliable in the explorer (unlike the
  extension-contributed language icon, which the default Seti theme ignores).

## 0.3.1

- Extension icon: the real Yon logo (the enso cat).
- File icon: `.yon` files show an azure **Y** in the explorer
  (`contributes.languages.icon`).

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
