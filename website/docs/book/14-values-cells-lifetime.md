---
id: values-cells-lifetime
title: "14. Values, cells, and lifetime"
sidebar_position: 14
---

import SpaceReclaim from '@site/src/components/SpaceReclaim';

# Values, cells, and lifetime

## Values have no identity

In Yon a value is **immutable content**. A "reference" is a handle, and a
handle is determined by content, so there is no aliasing to reason about:
nobody can mutate a value behind your back, because *nothing* mutates a
value, ever. Structural sharing is automatic and global: if two lists share
a tail, the tail occupies its slots once; if two trees are equal, they are
the same slots. Copying does not exist as an operation; there is nothing a
copy would do.

## Cells are the only identity

When you *do* need something that changes, a counter, a cursor, an
accumulator, you need identity, not content. That is the **Space cell**:
an entry in a small registry (ids are sequential, up to 1024 per process)
whose *current value* is a handle into the heap. The cell has identity; what
it holds is still immutable content.

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be v holds 7
  be c1 holds Space.make(v)            // a cell holding 7
  be c2 holds Space.make(v)            // ANOTHER cell holding 7
  be _s holds Space.set(c1, 40)
  be x holds Space.get(c1)             // 40
  be y holds Space.get(c2)             // still 7: cells have identity
  return x + y - 5                     // 42
}
```

Two cells with the same content are *different cells*, exactly the opposite
of values, where same content is the same thing. Assignment with `=` (chapter
3) is surface sugar over precisely this: a variable you reassign with `x = e`
**is** a cell.

## Types at runtime

Types are a compile-time discipline; at the IR level the world is spartan:
`number` is an `f64`, a section is an `f64` handle, `proposition` is a trit,
`unit` vanishes. The categorical layers erase: the terminal object and
comprehension *proofs* compile to zero bits of payload, you pay for the
carrier, not for the discipline around it. (The honest footnote from the
development diary: "zero-bit" is verified at the representation level;
physical alloca-elimination in the final object code was not separately
measured.)

## Lifetime

There is no garbage collector, and deliberately so: slots are stable
for the life of the heap, the heap lives for the life of the process, and
deduplication means the heap grows with *distinct* content, not with
allocations. A hot loop that rebuilds the same values costs no new memory.

Across packages, lifetime is process lifetime: the first cross-Space call
spawns the server; shutdown cascades from the caller; a crashed server is
respawned on a virgin channel with the epoch advanced. Handles never cross, 
each process's heap is its own universe, which is what makes the model safe.

## Reclaiming a Space

Within a process the heap does not shrink, and that is the design. There is one
exception, and it is at the granularity of a whole Space: a Space keeps its
sections in its own heap arena, and that arena can be released in a single move
once the Space is finished with. Reclamation here is by *region*, never by
tracing individual values; there is no per-object bookkeeping and nothing to
scan.

You can state that point yourself. `drop X` is an assertion, checked at compile
time, that Space `X` is no longer needed here. Two things are verified, in order:
that `X` is a real Space (a directory named in a world's `spaces`; a typo is
rejected as an unknown Space), and that no arc toward `X` is reachable downstream
of the drop, no later `wire to space X`, no use of a symbol imported `from X`, no
call that reaches either transitively. An early `drop`, with such an arc still
ahead, is a compile error that names the offending arc. The keyword chapter gives
the full rule; the point here is that the check is over the *source*, static, with
no runtime watch.

You usually do not need to write it. The same analysis runs the other way: the
compiler finds each owned Space's last use on its own and inserts the release
there automatically, so a `drop` is only an explicit assertion of a point the
compiler would reach anyway. `drop X` earlier than that last use is the error
above; there is no way to reclaim a Space that is still spoken to.

The release itself is one call, `madvise(MADV_DONTNEED)` over the arena's live
bytes, page-aligned inward. The virtual mapping stays valid, so nothing dangles;
the physical pages are handed back. Because the arc analysis counts *every* way a
named Space's heap is touched, a wire, an import, a cross-Space call, a `new` at a
topos bound to that Space, an `awaits`, the release can never fall before a read
that still needs the pages.

<SpaceReclaim />

The whole point is that this needs no collector. The lifetime of a Space is a
fact about the communication graph, which the compiler already has, so releasing
its memory is a decision it can make, not a guess the runtime has to hedge.
