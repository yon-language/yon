---
id: intro
title: Introduction
sidebar_position: 1
slug: /
---

# The Yon Programming Language

Yon is a research programming language whose foundations are categorical: its
type system is grounded in topos theory, the Yoneda lemma, homotopy type theory
(HoTT), and cubical type theory, with algebraic effects and an intuitionistic
logic core. It is, at the same time, a research program and a working compiler:
Yon source compiles, through a custom MLIR dialect, down to LLVM IR and then to a
native executable.

This book teaches Yon from the ground up. It is structured as a progression: each
chapter builds on the previous one, and every code snippet in it has been compiled
and run before being written down.

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

Start with the [Syntax Reference](./syntax-reference.md) — the normative
description of Yon 1.0 — then follow the book:

0. [Topos-Oriented Programming](./book/00-topos-oriented-programming.md) — the paradigm: sites, the Yoneda principle, structure that works for you.
1. [Hello, world](./book/01-hello-world.md) — your first program, `yonc`, exit codes.
2. [Values and bindings](./book/02-values-and-bindings.md) — numbers, strings (and their fusion), durations, truth.
3. [Control flow and mutation](./book/03-control-flow.md) — `when`/`is`, loops, `becomes` and Space cells.
4. [Functions and effects](./book/04-functions-and-effects.md) — inference, lambdas, pipes, `visits`.
5. [Worlds and places](./book/05-worlds-and-places.md) — the categorical data model, operations, certified laws.
6. [Arrows](./book/06-arrows.md) — moves, views, reductions, handle lambdas, composition, geometric morphisms.
7. [The Heyting core](./book/07-heyting-core.md) — present/absent/unknown, the operator families, `heyt_int`.
8. [Types from HoTT](./book/08-hott-types.md) — Pi/Sigma/Id, `refl`, comprehension types.
9. [Spaces and packages](./book/09-spaces-and-packages.md) — hermeticity, cross-package calls, hermetic scopes.
10. [A tour of the standard library](./book/10-standard-library.md) — collections, streams, system, the exotic corner.

**Part II — the machine model:**

11. [The content-addressed heap](./book/11-content-addressed-heap.md) — addresses are content, equality for free, the Leech lattice.
12. [Values, cells, and lifetime](./book/12-values-cells-lifetime.md) — immutability, identity, types at runtime, no-GC by design.
13. [Data structures on the lattice](./book/13-data-structures-on-the-lattice.md) — persistent collections, Merkle, Golay-sealed storage, cells across processes.

**Part III — the system:**

14. [Projects, yon.toml, and packages](./book/14-projects-and-packages.md) — directory layout, the manifest, yon-pkg, imports and namespaces.
15. [How Spaces talk](./book/15-how-spaces-talk.md) — the dispatch symbol, spawn, the shared-memory channel, epochs and recovery, backends.
16. [The project: a ledger in three packages](./book/16-the-project.md) — everything at once: a git dependency, a service, a client over the wire.
17. [When things go wrong](./book/17-when-things-go-wrong.md) — errors as places, failure as a value, process failure, the Heyting horizon.
18. [Showpieces](./book/18-showpieces.md) — optimization as algebra with certificates; equality up to symmetry.
19. [Capabilities](./book/19-capabilities.md) — authority attached to arrows, never ambient.
20. [Tooling](./book/20-tooling.md) — yon_doc, the language server, inspecting the compiler.

Appendices: [Glossary](./book/90-glossary.md) · [The limits of 1.0](./book/91-limits.md) · [Coming from elsewhere](./book/92-coming-from.md) · [Benchmarks](./book/93-benchmarks.md)

Every snippet in the book is compiled and run before being written down.

## Toolchain at a glance

| Tool | What it does |
|------|--------------|
| `yonc` | end-to-end compiler (`.yon` → native binary, or any intermediate stage) |
| `yon-pkg` | package manager (`init`, `install`, `list`, `uninstall`) |
| `yon_lsp` | Language Server Protocol implementation (editor integration) |
| `yonfmt` | code formatter (meaning-preserving, idempotent) |
| `yon_lint` | linter (dead code, unused bindings/parameters) |
| `yon_doc` | API reference generator (Markdown from source) |

## Platforms

Yon is developed on Linux (x86-64). It is buildable on macOS (Apple Silicon)
from source — see the build instructions in chapter 2. The final artifact is, in
all cases, a native executable produced through LLVM.
