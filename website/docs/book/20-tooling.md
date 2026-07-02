---
id: tooling
title: "20. Tooling"
sidebar_position: 20
---

# Tooling

Beyond `yonc` and `yon-pkg` (chapters 1, 15), the toolchain ships two
developer-facing pieces.

## yon-doc, API reference from source

`yon-doc file.yon -o doc.md` walks the surface AST and emits a Markdown
API reference: places (with fields and their `subcontains`
sub-object lines), functions with signatures. The world is inferred from
the filesystem, so it prints as `__INFER`. Run on the `SyntaxError.yon`
file of chapter 5's subsumption example it produces, verbatim:

```markdown
# API Reference — SyntaxError

## Places

### place `SyntaxError` in `__INFER`
- subcontains (sub-object of): `Error`

Fields:
- `message`: number
- `line`: number
```

It reads declarations, not comments. What it prints is what the checker
checked.

## yon-lsp, the language server

`yon-lsp` speaks the Language Server Protocol. 1.0 scope, stated plainly:
**real-time diagnostics** (parse errors and type errors, the same ones
`yonc` would give, surfaced as you type) and **hover** (the inferred
surface type of the expression under the cursor). No rename and no
go-to-definition yet. Diagnostics came first because Yon's error messages
are the teaching tool (the closed-morphism discipline, the layout and entrypoint
rules), and getting them into the editor mattered more than navigation.

## Looking inside the compiler

Every stage of the pipeline is inspectable from the CLI: `--emit=mlir`
for the Topos dialect as the frontend wrote it, `--emit=standard` after
structural collapse and lowering, `--emit=ll` for the LLVM IR. When a
chapter of this book claims something about what the compiler does, this
is how it was checked.
