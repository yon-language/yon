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
  v := 7
  c1 := Space.make(v)            // a cell holding 7
  c2 := Space.make(v)            // ANOTHER cell holding 7
  _s := Space.set(c1, 40)
  x := Space.get(c1)             // 40
  y := Space.get(c2)             // still 7: cells have identity
  return x + y - 5                     // 42
}
```

Two cells with the same content are *different cells*, exactly the opposite
of values, where same content is the same thing. A `mut` binding (chapter 3)
is surface sugar over precisely this: `mut c := e` **is** a cell, and `c <- e`
writes it.

A cell belongs to the call that made it: when that call returns, its cells are
freed and their slots reused. So a cell, and a lambda that mentions one, never
leaves its call: returning it, storing it in another cell, or sending it to
another Space is a compile-time error. Read the value out first; the value is
free to go anywhere.

## Types at runtime

Types are a compile-time discipline; at the IR level the world is spartan:
`Number` is an `f64`, a section is an `f64` handle, a value of Ω is a trit,
`Unit` vanishes. The categorical layers erase: comprehension *proofs* compile
to zero bits of payload, you pay for the carrier, not for the discipline around
it. "Zero-bit" is verified at the representation level; the elimination of the
corresponding allocas in the final object code was not separately measured.

## Lifetime

There is no garbage collector, and deliberately so. Memory is reclaimed by
**regions**, and the region is the Space. Every Space owns two heaps, and
every value lives in the heaps of the Space whose code made it:

| | the Space's FNV heap | the Space's Leech heap |
|---|---|---|
| **Identity** | by content | by point |
| **Who lives there** | sections of places, `Text`, lists, `HashMap` / `HashSet` nodes, closures | `XRelMap` / `XRelSet` nodes |
| **A name** | a HeapRef: the heap (which belongs to one Space) and the slot | (Space, name) as one exact integer: read in another Space it is an error |
| **Freed** | with its Space's region, whole | with its Space's region, whole |

There is no process-wide heap for values. `main` is a Space too, the entry
Space. A value that leaves its Space is **copied**: a call into another
Space of the same binary copies its arguments into the callee's heaps and its
result back, by the codec of the wire, in memory. A call between processes
and a `Wire<T>` copy the same way. So no name of one Space is ever held by
another, and a region can end without asking anyone (chapter 17).

The cells (`mut c := e`, `Space.make`) are not in the heaps: they belong to the
call that made them and end with it (above).

Across packages, a Space is a process: the first cross-Space call spawns the
server, shutdown cascades from the caller, a crashed server is respawned on a
virgin channel with the epoch advanced.

## Reclaiming a Space

A region ends in one of two ways.

**With the Space.** `drop X` is an assertion, checked at compile time, that
Space `X` is no longer needed here. Two things are verified, in order: that `X`
is a real Space (a directory named in a world's `spaces`; a typo is rejected as
an unknown Space), and that no arc toward `X` is reachable downstream of the
drop: no later `wire to space X`, no use of a symbol imported `from X`, no
call into `X`, no call that reaches one of these transitively. An early `drop`,
with such an arc still ahead, is a compile error that names the offending arc.
You usually do not need to write it: the compiler finds each Space's last use
on its own and inserts the release there, and the death-watch releases a Space
whose incoming wires have all closed.

**With every call, for a Space without state.** A Space whose code keeps
nothing past a call, no stream, no wire, no pool of the runtime, is
**stateless**, and the compiler knows it. Each call into it is a region of its
own. When the call returns and its result has been copied out, both heaps of
the Space are emptied (Turbak ch. 18, `letregion`: the region of a scope is
freed whole when the scope ends, and what survives it was copied out). A
Space with state keeps its heaps for as long as it lives.

The release is the same in both cases. Both heaps of the Space are emptied:
the sections, the FNV chain, the Leech store. Their pages are replaced by
fresh zero pages, so the memory goes back to the system at once. Nothing
dangles: every value that left the Space was copied out.

Measured (Apple M1, 2026-10-22) on a Space that builds a `HashMap` and an
`XRelMap` of 10<sup>5</sup> entries and returns their sizes: the resident
memory of the process goes from 16&nbsp;MB to 254&nbsp;MB during the call, and
back to 14&nbsp;MB when it returns.

**The idiom: one Space per unit of work.** Collections are persistent: every
`set` makes new nodes and keeps the old ones, and nothing frees a node one at a
time. Work that builds and updates collections belongs in a Space, called for
that work, whose region ends with it. A program that does the same work in one
long-lived Space, `main` or a Space with state, **grows for as long as that
Space lives**: its heaps grow by the same amount on every round, about
12&nbsp;MB per round of 2·10<sup>4</sup> updates of a `HashMap` and an
`XRelMap` in the regression probe. The FNV heap grows only with
contents it has not seen, so a round that rebuilds the same values costs no
new memory there. The Leech heap remakes every node.

<SpaceReclaim />

The whole point is that this needs no collector. The lifetime of a Space is a
fact about the communication graph, which the compiler already has, and a value
that outlives its Space has been copied out of it. Releasing the memory is a
decision the compiler can make, not a guess the runtime has to hedge.
