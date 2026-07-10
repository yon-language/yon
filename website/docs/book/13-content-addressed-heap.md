---
id: content-addressed-heap
title: "13. The content-addressed heap"
sidebar_position: 13
---

import ContentAddress from '@site/src/components/ContentAddress';

# The content-addressed heap

Everything you have built so far, numbers aside, lives in one structure:
**xleech2**, a content-addressed heap. Its contract is a single sentence:
*the address of a value is (determined by) its content*.

<ContentAddress />

`put(payload)` hashes the bytes; if that content is already in the heap, you
get the **existing** slot index back; if not, a fresh sequential slot is
allocated and recorded in the content index. `get(slot)` is strictly O(1),
and a slot index is stable for the life of the heap, nothing is ever moved
or rehashed under you. Deduplication is not an optimization pass; it is the
definition of allocation.

A **handle**, what your variables actually hold for strings, sections,
lists, trees, is that slot index, carried as an `f64`. This is why the wire
between packages is "numbers only": a handle is meaningless outside the heap
that minted it.

## Equality for free

The consequence that pays for itself: **same content ⟺ same slot**. Equality
of arbitrarily large values is one number comparison. This is the entire
implementation of `String.equal` in the runtime:

```c
double yon_rt_string_equal(double a_id_d, double b_id_d) {
    uint32_t sa = (uint32_t)a_id_d, sb = (uint32_t)b_id_d;
    /* Content-addressed: same slot <=> same bytes. */
    return (sa == sb) ? 1.0 : 0.0;
}
```

And it holds *by construction*, whatever route built the value:

<!-- yon-gate: exit 42 -->
```yon
fun main(): number {
  be a holds "ab"
  be b holds String.concat("a", "b")   // built by a different route
  be same holds String.equal(a, b)     // 1.0: same content, same slot
  return if same then 42 else 0
}
```

## Why "leech"

The heap's geometry is taken from the **Leech lattice** Λ₂₄: the arena has
exactly **196,560 slots**, the number of type-2 vectors of Λ₂₄, its kissing
number. One heap is a contiguous, mmap-relocatable block of ~70 MB (64 MB of
payload arena plus the content index), which is what lets a Space be backed
by private memory or POSIX shared memory interchangeably.

The lattice is not just sizing. Through the vendored mmgroup core, the runtime exposes
**canonicalization under the lattice symmetries**: sign patterns canonical
under the Golay-code stabilizer, M₂₄ orbit representatives, orbit ids. The
**Arena** surfaces them directly, `Arena.orbit` returns the orbit id of a
content and `Arena.same_orbit` tests two contents for equivalence under the
symmetry group, so contents that are "the same up to symmetry" can be
recognized as one. Content addressing, extended from bytes to orbits.

## The heap chain (HeapRef)

A single heap holds 196,560 distinct contents. That is not the ceiling, 
it is the *unit*. The allocator keeps a **registry** of heaps (up to 256
per process), and every reference handed out is a global **HeapRef**: a
32-bit word whose top 8 bits name the heap and whose low 24 bits name the
slot inside it. For heap 0 the encoding coincides with the bare slot
index, so the chain is invisible until you need it.

Allocation walks a **chain** of heaps in two phases:

1. **Global deduplication first.** A process-wide **content index** maps
   (chain, content hash) to a HeapRef, with the payload verified against
   the owning heap, one O(1) lookup, however many heaps the chain has
   grown to. If the content exists anywhere, its existing reference is
   returned. This is the load-bearing rule: the same content yields the
   same HeapRef wherever it lives, so this chapter's one-comparison
   equality survives the heap boundary untouched.
2. **Insert at the hint.** New content goes to the last heap known to have
   room (a cached hint, so full heaps are not retried on every
   allocation). If that heap is full too, the chain walks forward, and
   when it runs out, **a new heap is created and linked automatically**.
   Nothing in the program changes; a line on stderr records the extension.

The practical ceiling is therefore memory: 256 heaps × 196,560 contents.
Measured behavior (Appendix D): one million map entries spread across
six heaps, every value read back exactly from whichever heap it landed
in; sixty thousand distinct string keys with zero collisions and exact
re-derivation through the chain.

One asymmetry to know about: orbit canonicalization (the vendored mmgroup
machinery below) operates on heap 0, where the lattice indexing lives.
The Arena's orbit operations are a heap-0 feature; plain content addressing
spans the whole chain.
