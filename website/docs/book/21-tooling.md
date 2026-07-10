---
id: tooling
title: "21. Tooling"
sidebar_position: 21
---

# Tooling

Beyond `yonc` and `yon-pkg` (chapters 1, 16), the toolchain ships a small set of
developer-facing programs: a language server, a linter, a formatter, and a
documentation generator. They are described one by one below, but they share a
single design decision worth stating first, because it is the reason the set
holds together.

## One implementation per question

A program is read by more than one tool. The compiler asks "does this project
type-check, and do its Spaces respect their boundaries?". The editor asks the
same question, as you type. The linter asks "is anything here well-typed but
suspicious?". The formatter asks "what is the canonical way to write this?".

Each of those questions is answered in exactly one place, and every tool that
needs the answer calls that place. The compiler and the language server run the
same project checker; the `yon-lint` command and the editor's warnings run the
same linter; the `yon-fmt` command and format-on-save run the same formatter.
The consequence is not convenience, it is agreement: the editor can never green
a project the compiler rejects, or format code the command line would format
differently. There is no second implementation to drift.

## Diagnostics have stable codes

Every diagnostic the toolchain can emit (an error from the compiler, a warning
from the linter) carries a stable identifier, and it is the identifier, not the
sentence, that is the contract. A tool that keys off `E3001` keeps working when
the prose is reworded; the sentence is for the human, the code is for the
machine. The identifiers are grouped by what they are about:

| Range   | What it covers                                              |
|---------|-------------------------------------------------------------|
| `E1xxx` | syntax (the lexer and the parser)                           |
| `E2xxx` | types (the checker)                                         |
| `E3xxx` | Space semantics: `drop` of a Space still used downstream (`E3001`), a wire that crosses a world boundary (`E3010`) |
| `E4xxx` | project layout: one topos per space, the entrypoint, file placement, the manifest |
| `Wxxx`  | lint warnings (well-typed but suspicious; never a rejection) |

The `E3xxx` range is the one no single-file view can produce: it is read off the
communication graph (which Space talks to which), and that graph only exists
once the whole package is in scope.

## yon-lsp, the language server

`yon-lsp` speaks the Language Server Protocol. It is project-aware: when you open
a file that lives inside a package, the server loads the whole package, not just
the buffer, and runs the same checks the compiler runs. That scope is what lets
it give the diagnostics that matter in Yon:

- **the Space-semantic ones**, an illegal `drop` (`E3001`) or a wire that crosses a
  world boundary (`E3010`), surfaced in the editor at the offending site, in
  process, with no shelling out to the compiler;
- **cross-file resolution**: a place, type, or function defined in a sibling file
  is found, so calling it is not a false "unknown ..."; the type-check runs over
  the merged program and attributes each error back to the file that owns it.

Alongside diagnostics it provides **hover** (the inferred surface type under the
cursor), **document symbols** (the outline of worlds, places, functions),
**completion**, and **formatting** (see `yon-fmt` below; the editor calls the same
formatter). There is no rename and no go-to-definition yet. Diagnostics came
first because in Yon the error messages are the teaching tool (the boundary
rules, the layout and entrypoint rules, the Space lifetimes), and getting them
into the editor mattered more than navigation.

## yon-lint, the linter

`yon-lint file.yon` reports code that is well-typed but suspicious. It never
rejects; it warns, under the `Wxxx` codes, and the same warnings appear in the
editor as you type. The rules are syntactic:

- `W1001` a function referenced nowhere in the program. Note the criterion:
  *referenced nowhere*, not *unreachable from `main`*. In Yon a Space's functions
  are its interface, called across Spaces (a subscriber calls a producer, a morph
  maps an object), not from a single entry point, so "reachable from `main`" would
  wrongly call a live producer dead.
- `W1002` a `be` binding never read afterwards; `W1003` a parameter never used. A
  leading underscore (`_x`) marks a deliberate discard and is exempt from both.
- `W3001` an `import ... from S` whose symbol is never used: a dead dependency on
  Space `S`, a communication arc with no traffic. This is the linter's one
  Space-aware rule, and it comes from the same graph the boundary diagnostics read.

## yon-fmt, the formatter

`yon-fmt file.yon` prints the canonical form; `yon-fmt --write file.yon` rewrites
the file in place. A formatter for a language whose code is meant to be a
projection of a specification has one duty above readability: it must never change
what the code means. `yon-fmt` earns that by re-parsing its own output and
comparing: it rewrites the file only if the output parses back to the same
top-level structure *and* formatting it again reproduces it unchanged (a fixed
point). If either check fails (an uncovered construct, an unstable result) it
leaves the file exactly as it found it. The worst case is "not formatted", never
"formatted wrong".

## Using these in an editor (VS Code)

The language server, the linter, and the formatter reach the editor through one
extension. Install the Yon extension (it ships as a `.vsix` with the GitHub
releases, or build it from `lsp/editors/vscode`) and, if `yon-lsp` is not on your
`PATH`, point the `yon.lspPath` setting at your built binary. With that in place:

- **diagnostics and warnings appear inline as you type.** Compiler errors under
  their `Exxxx` codes, linter warnings under their `Wxxx` codes, each at its site.
  The same messages `yonc` and `yon-lint` print on the command line.
- **format on save runs the formatter.** Enable it for Yon files in `settings.json`:

  ```json
  "[yon]": { "editor.formatOnSave": true }
  ```

- **hover, the symbol outline, and completion** come from the same server.

From a terminal the same jobs are `yon-fmt --write file.yon` and
`yon-lint file.yon`; editor and command line give identical results because they
run the same code. Neovim users can source `lsp/editors/neovim.lua` for the
diagnostics-and-hover setup.

## yon-doc, API reference from source

`yon-doc file.yon -o doc.md` walks the surface AST and emits a Markdown API
reference: places (with their fields and `subcontains` sub-object lines) and
functions with their signatures. The world is inferred from the filesystem, so it
prints as `__INFER`. Run on the `SyntaxError.yon` file of chapter 5's subsumption
example it produces, verbatim:

```markdown
# API Reference: SyntaxError

## Places

### place `SyntaxError` in `__INFER`
- subcontains (sub-object of): `Error`

Fields:
- `message`: number
- `line`: number
```

It reads declarations, not comments. What it prints is what the checker checked.

## Looking inside the compiler

Every stage of the pipeline is inspectable from the CLI: `--emit=mlir` for the
Topos dialect as the frontend wrote it, `--emit=standard` after structural
collapse and lowering, `--emit=ll` for the LLVM IR. When a chapter of this book
claims something about what the compiler does, this is how it was checked.

## What is not here yet

There is no debugger. A step-into, break-point debugger sits badly with a system
of isolated Spaces and append-only memory: there is little "current line" to stop
on. The planned tool is an *observer* instead, a view of the live Space and Wire
graph (which Space is running and which arcs are open at a moment), built on the
same communication protocol the runtime already uses. It belongs with the dynamic
Space reclamation of a later edition, and is described there, not here.
