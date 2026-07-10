---
id: future-work
title: "Appendix B. Future work"
sidebar_position: 91
slug: /book/future-work
---

# Appendix B, Future work

1.1.0 draws its perimeter on purpose. A limit you know is a contract; a limit you
discover is a bug. This page keeps the two apart: what the current version
guarantees, what it leaves out by design and always will, and, held in outline on
purpose, what is coming.

## The contract of 1.1.0

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
- **Fixed pools, loud refusal**: 256 instances per collection type, 64 Spaces, 64
  streams, 16 RPC sessions. Like a fixed-width address bus, these buy predictable
  memory and rule out runaway allocation. Process isolation by the kernel's MMU
  keeps any local fault inside the one server binary that raised it.
- **Directories with no knobs**: HashMap and HashSet hold one invariant, load
  factor ≤ 0.7, which under linear probing guarantees an expected O(1) probe at
  every size; they double and rehash before it is ever violated. No maximum, no
  degraded regime: growth is bounded by memory alone.
- **The wire**: at most four arguments per cross-Space call, all `f64`. Strings
  and sections never cross; they are process-local handles.
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

## On the horizon

Some of what follows the grammar already reserves; some is being *proved* before it
is promised. The shapes are drawn. What you get here is the outline, not the
blueprint: the full telling belongs to the editions that land each one.

<div style={{display: 'grid', gap: 'var(--sp-4)', margin: 'var(--sp-5) 0'}}>

<div style={{borderLeft: '3px solid var(--viz-accent)', background: 'rgba(28, 23, 62, 0.5)', borderRadius: '0 12px 12px 0', padding: 'var(--sp-4) var(--sp-5)', boxShadow: 'var(--elev-1)'}}>

**Memory that lets itself go.** Today a Space's heap is released at a point the
compiler can name in your source. The next step teaches the runtime to watch its
own topology and let a Space go the instant its conversations fall silent, read
off a graph the compiler already proved, not a count it has to keep. Sound, because
nothing is guessed. That is as much as it will say for now.

</div>

<div style={{borderLeft: '3px solid var(--viz-gold)', background: 'rgba(28, 23, 62, 0.5)', borderRadius: '0 12px 12px 0', padding: 'var(--sp-4) var(--sp-5)', boxShadow: 'var(--elev-1)'}}>

**A window on the living system.** Not a debugger that stops time, which fits an
append-only world of isolated Spaces poorly, there being little "current line" to
stop on. Something closer to an instrument: the Spaces and wires alive at an
instant, the arcs opening and closing, over the very protocol the wire already
speaks. The heap picture in this book is the still frame; this is the moving one.

</div>

<div style={{borderLeft: '3px solid var(--viz-green)', background: 'rgba(28, 23, 62, 0.5)', borderRadius: '0 12px 12px 0', padding: 'var(--sp-4) var(--sp-5)', boxShadow: 'var(--elev-1)'}}>

**A logic that proves more of what it means.** The type checker already computes by
conversion, and the cubical surface of chapter 9 already lets a path *compute*: an
equivalence doing real work on values. What the work underway adds is *checking*,
letting the checker quantify the higher coherences the mathematics has been
promising all along: the Yoneda correspondence in full, the equation behind each
path and not only its computation. Where 1.1.0 checks the structural precondition,
the coming editions check the equation.

</div>

<div style={{borderLeft: '3px solid var(--viz-accent-2)', background: 'rgba(28, 23, 62, 0.5)', borderRadius: '0 12px 12px 0', padding: 'var(--sp-4) var(--sp-5)', boxShadow: 'var(--elev-1)'}}>

**The grammar, rounding out.** More syntax is reserved than 1.1.0 lowers to a stable
runtime: ephemeral sub-runtimes and their reclaimed arenas, stream producers folded
into settled streams, paths into a section's fields. Each parses and type-checks
today and waits only on the runtime and the regression coverage that make a promise
safe to print. The collection API, kept deliberately small, fills in alongside.

</div>

</div>

## Measured, and measured next

Appendix D publishes the benchmarks with method and sources; the numbers on the
landing page come from there, not from memory. Two empirical questions stay open in
the development notes and will be answered the same way, numbers before claims: what
the structural-collapse pass catches that classical value numbering does not, and
the physical cost of the categorical structure in the final object code.
