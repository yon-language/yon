---
id: tooling
title: "20. Tooling"
sidebar_position: 20
---

# Tooling

Beyond `yonc` and `yon-pkg` (chapters 1, 14), the toolchain ships two
developer-facing pieces.

## yon_doc — API reference from source

`yon_doc file.yon -o doc.md` walks the surface AST and emits a Markdown
API reference — worlds, places (with fields and their `extends`
sub-object lines), functions with signatures. Run on chapter 4's
subsumption example it produces, verbatim:

```markdown
# API Reference — extends_subsumption

## Worlds

### world `W`

## Places

### place `Error` in `W`

Fields:
- `message`: number

### place `SyntaxError` in `W`
- extends (sub-object of): `Error`
```

It reads declarations, not comments — what it prints is what the checker
checked.

## yon_lsp — the language server

`yon_lsp` speaks the Language Server Protocol. 1.0 scope, stated plainly:
**real-time diagnostics** (parse errors and type errors, the same ones
`yonc` would give, surfaced as you type) and **hover** (the inferred
surface type of the expression under the cursor). No rename, no
go-to-definition yet — diagnostics-first was the choice, because Yon's
error messages are the teaching tool (E1110 and friends), and getting them
into the editor mattered more than navigation.

## Looking inside the compiler

Every stage of the pipeline is inspectable from the CLI — `--emit=mlir`
for the Topos dialect as the frontend wrote it, `--emit=standard` after
structural collapse and lowering, `--emit=ll` for the LLVM IR. When a
chapter of this book claims something about what the compiler does, this
is how it was checked.
