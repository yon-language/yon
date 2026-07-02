---
id: values-cells-lifetime
title: "13. Values, cells, and lifetime"
sidebar_position: 13
---

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
fun main(): number {
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

There is no garbage collector in 1.0, and deliberately so: slots are stable
for the life of the heap, the heap lives for the life of the process, and
deduplication means the heap grows with *distinct* content, not with
allocations. A hot loop that rebuilds the same values costs no new memory.

Across packages, lifetime is process lifetime: the first cross-Space call
spawns the server; shutdown cascades from the caller; a crashed server is
respawned on a virgin channel with the epoch advanced. Handles never cross, 
each process's heap is its own universe, which is what makes the model safe.
