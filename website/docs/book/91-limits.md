---
id: limits
title: "Appendix B. The limits of 1.0"
sidebar_position: 91
---

# Appendix B — The limits of 1.0

Everything on this page is deliberate. A limit you know is a contract; a
limit you discover is a bug.

## Hard numbers

- **Space cells:** 1,024 per process. Cells are the identity mechanism,
  not a data structure; if you are allocating thousands, you want a
  collection.
- **Heap slots:** 196,560 *distinct contents* per heap, 64 MB payload
  arena (~70 MB per heap mapped). Deduplication means repeats are free;
  the budget is on distinct values.
- **The heap chain:** every structure on the heap (strings, lists,
  HashMap entries, Merkle nodes, sets) allocates through the allocator's
  chain — when a heap fills, a new one is created and linked
  automatically, references are global (8-bit heap id, 24-bit slot), and
  **deduplication stays global** through a process-wide content index:
  the same content returns the same reference wherever it lives, so O(1)
  equality survives the boundary. The ceiling is memory, up to 256
  chained heaps of 196,560 contents each. Measured: one million map
  entries across six heaps, exact on every side; 60,000 distinct string
  keys with zero collisions and exact re-derivation.
- **Fixed pools, loud refusal.** Macro-architecture limits are fixed by
  encoding width and refuse explicitly when exhausted: 256 heaps per
  chain (8-bit heap id — a perimeter of roughly 18 GB of globally
  deduplicated content per process), 256 instances per collection type,
  64 Spaces, 64 streams, 16 RPC sessions. These are specifications, not
  defects: like a fixed-width address bus, they buy predictability of
  memory and rule out runaway allocation. The wire's internal buffers
  are static and larger than the protocol can ever fill (the wire is at
  most 4×`f64` = 32 bytes); process isolation by the kernel's MMU
  contains any local fault to the single server binary.
- **No tuning knobs in the data path.** Directories (HashMap and
  HashSet) keep a single invariant — load factor ≤ 0.7, which with
  linear probing guarantees an expected O(1) probe count at *every*
  size — by doubling with a rehash whenever it would be violated. There
  is no maximum size and no degraded regime: growth is bounded by
  memory alone, like the chain. 256 instances per structure per
  process.
- **VoyagerList:** capacity grows dynamically (doubling, from 1,024 up to
  1,048,576 codewords; codewords live outside the heap). 256 lists per
  process.
- **The wire:** at most 4 arguments per cross-Space call, all `f64`.
  Strings and sections never cross (they are process-local handles).
- **Exit codes:** `main`'s value mod 256, like every Unix process.

## Absent by design

- **No garbage collector** — slots are stable for the life of the process;
  the heap grows with distinct content only (chapter 12).
- **No threads, no intra-process spawn** — the unit of concurrency is the
  process (chapter 15).
- **No exceptions** — failure is data, declarations, or a process matter
  (chapter 17).
- **No interfaces / typeclasses / virtual dispatch** — arrows are the
  interface (chapters 0, 4).
- **No `src/` convention, no central package registry** — a package is a
  directory; dependencies are git (chapter 14).

## Declared but not implemented in 1.0

These parse (the grammar reserves them) but the compiler rejects them;
they are contracts for later versions, listed in the normative reference
with the same flag:

- `produce { emit e }` — the stream-producer block.
- `ind_path(C, d, p)` — the J eliminator (the runnable HoTT fragment is
  `refl`/`pair`/`fst`/`snd`).
- `x.f becomes e` — field mutation (sections are immutable; mutate through
  cells).
- Static capability checking (`requires` is enforced at runtime; the
  caller-side static rule is design, chapter 19).
- Value-level construction of comprehension types (the type and its
  coercion are live, chapter 8).
- True parallel execution of `for every` / `when here` (sequential in 1.0,
  declared intent).

## Not measured yet

No performance claims appear in this book because no benchmarks have been
published. Two open empirical questions are recorded in the development
diary: what the structural-collapse pass catches that classical value
numbering does not, and the physical cost of the "zero-bit" categorical
structure in final object code. Numbers will precede claims.
