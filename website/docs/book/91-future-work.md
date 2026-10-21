---
id: future-work
title: "Appendix B. Limits and honest status"
sidebar_position: 91
slug: /book/future-work
---

# Appendix B, Limits and honest status

A limit you know is a contract; a limit you discover is a bug. This page keeps
the two apart: what the current version (`yon version` prints `1.2-dev`)
guarantees, what it leaves out by design, and what it does not do yet.

## The contract of the current version

These are numbers you can build on. Each is fixed by an encoding width, not by a
timeout or a heuristic, so it holds at *every* size right up to the wall, where the
runtime refuses out loud rather than degrading in silence.

- **Space cells**: 1,024 per process. A cell is the identity mechanism, not a
  container; if you find yourself allocating thousands, you want a collection.
- **The heap**: 196,560 *distinct* contents per heap (the count of minimal
  vectors of Λ<sub>24</sub>), on a 64&nbsp;MB payload arena. Deduplication makes
  repeats free; the budget is spent on distinct values, not on allocations.
- **The heap chain**: when a heap fills, a successor is created and linked; a
  reference is global (8-bit heap id, 24-bit slot), and deduplication stays global
  through a process-wide content index, so O(1) equality survives the boundary. Up
  to 256 chained heaps: roughly 18&nbsp;GB of globally deduplicated content per
  process. Measured exact at a million map entries across six heaps.
- **Fixed pools, loud refusal**: 256 instances per pooled collection type (a
  HashMap or a HashSet is not pooled: it is a value in the heap), 64 Spaces, 64
  streams, 16 RPC sessions. Like a fixed-width address bus, these buy predictable
  memory and rule out runaway allocation. Process isolation by the kernel's MMU
  keeps any local fault inside the one server binary that raised it.
- **The call door**: at most four arguments per cross-Space call, all `f64`.
  Strings and sections are process-local handles and do not travel on a call;
  they cross by copy on a `Wire<T>` (chapter 17).
- **Exit codes**: `main`'s value mod 256, like every Unix process.

## Absent by design

These are not on any roadmap. They are the design.

- **No garbage collector.** Slots are stable for the life of the process; the heap
  grows with distinct content only (chapter 14). Reclamation is by *region*, never
  tracing: a whole Space's heap is released in one move, at a checked `drop X` or
  automatically at the Space's last use.
- **No threads.** The unit of concurrency is the process; Spaces talk over a
  shared-memory wire (chapter 17).
- **No exceptions.** Failure is data, a declaration, or a process exit, never a
  thrown stack (chapter 19).
- **No interfaces, typeclasses, or virtual dispatch.** An arrow is the interface: a
  place's presheaf of observations (chapters 0, 5).
- **No central package registry.** Dependencies are git.

## Honest status: not yet

What follows does not exist yet. Each line says what is absent today; none is a
date.

- **Capabilities are declared, not enforced.** A move whose `requires`
  capability is absent is not yet refused, and the static rule (a caller of a
  `requires` move must itself hold the capability) is not yet checked
  (chapter 20).
- **A string in a cross-Space signature is not yet refused.** It compiles, and
  the call returns a wrong value (`0`). This is a defect (chapter 19).
- **The concurrent drain of a `Wire<T>`** (both processes live, the consumer
  draining while the producer fills, under contention) is not yet verified; the
  verified shape is the producer running to completion first (chapter 17).
- **Runtime-driven Space release** is not yet there: a Space is released at a
  `drop X` or at its last use, points the compiler names, not when its wires
  fall silent at run time.
- **An observer** of the live Space and Wire graph, and any debugger, do not
  exist yet (chapter 21).
- **Monomorphisation** is not yet done: a generic place has one uniform runtime
  layout, and a place instance is not yet checked against its type argument
  (chapter 10).
- **A surface constructor for comprehension values**, carrying the witness, does
  not exist yet; the comprehension is a type-level discipline (chapter 9).
- **Law-licensed rewrites** are not yet in the optimizer: a declared law is
  verified against the algebra catalog, and no pass rewrites code because of it
  (chapter 0).
- **The adjointness of a geomorph** is not yet checked: `pull` and `push` are
  declared as a pair, and the compiler does not verify that they are adjoint
  (chapter 7).
- **Higher coherences** are not yet checked: the type checker computes by
  conversion and the cubical surface lets a path compute (chapter 9), but the
  equation behind each path is not yet checked.
- **Deeper Tarski reflection** is not yet there: a universe code lowers to its
  inhabitant and cannot inspect its own structure (chapter 22, `quote`).
- **A full treatment of cubical type theory** in this book is not yet written;
  chapter 9 and the keyword entries cover what the kernel runs.
- **Prebuilt binaries and a Homebrew tap** do not exist yet; Yon builds from
  source (chapter 1).
- **The VS Code extension** is not yet published on the Marketplace; it is
  installed from the packaged `.vsix` (chapter 21).

## Not yet measured

Appendix D publishes the benchmarks with method and sources; the numbers on the
landing page come from there. Two questions are not yet measured: what the
structural-value-numbering pass catches that classical value numbering does not,
and the physical cost of the categorical structure in the final object code.
