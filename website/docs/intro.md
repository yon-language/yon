---
id: intro
title: "Yon: a topos-oriented programming language"
sidebar_label: Introduction
sidebar_position: 1
slug: /intro
description: "Yon is a research programming language with topos-theoretic foundations, compiled to native code via MLIR and LLVM, with a content-addressed heap on the Leech lattice."
keywords: [topos, programming language, category theory, MLIR, LLVM, content-addressed, Leech lattice, HoTT]
---

# The Yon Programming Language

Yon is a research programming language whose foundations are categorical: its
type system is grounded in topos theory, the Yoneda lemma, and homotopy type theory
(HoTT), with algebraic effects and an intuitionistic
logic core. It is, at the same time, a research program and a working compiler:
Yon source compiles, through a custom MLIR dialect, down to LLVM IR and then to a
native executable.

This book teaches Yon from the ground up. It is structured as a progression: each
chapter builds on the previous one.

## How Yon compiles

```
.yon source
   │   frontend (OCaml)
   ▼
MLIR "topos" dialect
   │   topos-opt  (lowering passes)
   ▼
LLVM IR
   │   llc + link (runtime + libmmgroup)
   ▼
native executable
```

The single command `yonc` drives this whole pipeline. You can also stop at any
intermediate stage (for example to inspect the generated LLVM IR).

## Table of contents

Start with the [Syntax Reference](./syntax-reference.md), the normative
description of Yon 1.2.1, then follow the book:

0. [Topos-Oriented Programming](./book/00-topos-oriented-programming.md), the paradigm: sites, the Yoneda principle, structure that works for you.
1. [Installation](./book/01-installation.md), what you need, build, verify, the toolchain.
2. [Hello, world](./book/02-hello-world.md), your first program, `yonc`, exit codes.
3. [Values and bindings](./book/03-values-and-bindings.md), numbers, strings (and their fusion), durations, truth.
4. [Control flow and mutation](./book/04-control-flow.md), `when`/`is`, loops, `=` and Space cells.
5. [Functions and effects](./book/05-functions-and-effects.md), inference, lambdas, pipes, `visits`.
6. [Worlds and places](./book/06-worlds-and-places.md), the categorical data model, operations, certified laws.
7. [Arrows](./book/07-arrows.md), moves, views, reductions, handle lambdas, composition, geometric morphisms.
8. [The Heyting core](./book/08-heyting-core.md), present/absent/unknown, the operator families, `heyting`.
9. [Types from HoTT](./book/09-hott-types.md), Pi/Sigma/Id, `refl`, comprehension types.
10. [Generics](./book/10-generics.md), type parameters on functions, places, and arrows, anchored to the universe.
11. [Spaces and packages](./book/11-spaces-and-packages.md), hermeticity, cross-package calls, hermetic scopes.
12. [A tour of the standard library](./book/12-standard-library.md), collections, streams, system, the exotic corner.

**Part II, the machine model:**

13. [The content-addressed heap](./book/13-content-addressed-heap.md), addresses are content, equality for free, the Leech lattice.
14. [Values, cells, and lifetime](./book/14-values-cells-lifetime.md), immutability, identity, types at runtime, no-GC by design.
15. [Data structures on the lattice](./book/15-data-structures-on-the-lattice.md), persistent collections, MerkleTree, Golay-sealed storage, cells across processes.

**Part III, the system:**

16. [Projects, yon.toml, and packages](./book/16-projects-and-packages.md), directory layout, the manifest, yon-pkg, imports and namespaces.
17. [How Spaces talk](./book/17-how-spaces-talk.md), the dispatch symbol, spawn, the shared-memory channel, epochs and recovery, backends.
18. [The project: a ledger in three packages](./book/18-the-project.md), everything at once: a git dependency, a service, a client over the wire.
19. [When things go wrong](./book/19-when-things-go-wrong.md), errors as places, failure as a value, process failure, the Heyting horizon.
20. [Capabilities](./book/20-capabilities.md), authority attached to arrows, never ambient.
21. [Tooling](./book/21-tooling.md), yon-doc, the language server, inspecting the compiler.

Appendices: [Glossary](./book/90-glossary.md) · [Future work](./book/91-future-work.md) · [Coming from elsewhere](./book/92-coming-from.md) · [Benchmarks](./book/93-benchmarks.mdx)

## Toolchain at a glance

| Tool | What it does |
|------|--------------|
| `yonc` | end-to-end compiler (`.yon` → native binary, or any intermediate stage) |
| `yon-pkg` | package manager (`init`, `install`, `list`, `uninstall`) |
| `yon-lsp` | Language Server Protocol implementation (editor integration) |
| `yon-fmt` | code formatter (meaning-preserving, idempotent) |
| `yon-lint` | linter (dead code, unused bindings/parameters) |
| `yon-doc` | API reference generator (Markdown from source) |

## Platforms

Yon is developed on Linux (x86-64). It is buildable on macOS (Apple Silicon)
from source, see the build instructions in chapter 2. The final artifact is, in
all cases, a native executable produced through LLVM.
