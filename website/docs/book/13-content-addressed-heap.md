---
id: content-addressed-heap
title: "13. The content-addressed heap"
sidebar_position: 13
---

import ContentAddress from '@site/src/components/ContentAddress';

# The content-addressed heap

Yon has **two heaps**, and every value that is not a bare number lives in one
of them. Most live in the **FNV heap**, **xleech2**, a content-addressed heap
whose contract is a single sentence: *the address of a value is (determined
by) its content*. The values that are points of the Leech lattice live in the
**Leech heap**, where the address is the point itself. This chapter is mostly
about the first; the table below sets the two side by side.

<ContentAddress />

`put(payload)` hashes the bytes; if that content is already in the heap, you
get the **existing** slot index back; if not, a fresh sequential slot is
allocated and recorded in the content index. `get(slot)` is strictly O(1),
and a slot index is stable for the life of the heap, nothing is ever moved
or rehashed under you. Deduplication is not an optimization pass; it is the
definition of allocation.

A **handle**, what your variables actually hold for strings, sections,
lists, trees, is that slot index, carried as an `f64`. This is why a *call*
between packages carries numbers only, and why a string or a place crosses by
copy on a `Wire<T>` (chapter 17): a handle is meaningless outside the heap that
minted it.

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
fun main(): Number {
  be a := "ab"
  be b := String.concat("a", "b")   // built by a different route
  be same := String.equal(a, b)     // 1.0: same content, same slot
  return if same then 42 else 0
}
```

## Two heaps

| | The FNV heap (xleech2) | The Leech heap |
|---|---|---|
| **Identity** | the content: an FNV-1a 64-bit hash, confirmed by a byte comparison | the point: one of the 196,560 type-2 vectors of Λ₂₄ |
| **Address** | a slot, allocated in sequence at the content's first appearance, carried as a HeapRef (8 bits of heap, 24 of slot) | the point's index under the minimal perfect hash, a bijection with `[0, 196560)` |
| **Collisions** | two hashes may collide; the byte comparison settles it, so distinct contents never share a slot | none: the minimal perfect hash is a bijection |
| **Geometry** | none: the lattice only fixes how many contents one heap holds (196,560), then the chain grows | M₂₄ orbits, relational classes under a frame, Co₀ canonical forms and transport |
| **Who lives there** | strings, lists, `HashMap`/`HashSet` tries, `MerkleTree`, sections of places, closures | `LatticePoint`, the nodes of `XRelMap`/`XRelSet`, `XSet`, `XSimplex` |
| **The test that proves it** | `test_unit_extensionality`: 300,000 distinct contents across two heaps, every one on its own reference, the same content on the same one | `test_mphf.c` and `test_unit_mphf_ext.c`: the bijection, over the whole shell; `test_leech_theta`: the shell has 196,560 points |

The FNV heap is one mapping that chains into the next when it fills. The
Leech heap is a sequence of generations, each a table over the shell: the
node store of `XRelMap`/`XRelSet` puts its k-th node in the place
(generation k div 196,560, point `at_index(k mod 196,560)`), written once;
`XSet` and `XSimplex` hold one table indexed by the shell. A point is the
address in every one of them. There is no index by content in the Leech
heap: two equal nodes are two places.

**Why the FNV heap is sized by the lattice.** One FNV heap holds exactly
**196,560 contents**, the kissing number of Λ₂₄. That is the only thing the
lattice does there: slots are allocated in sequence, never at a point, and
no value of the FNV heap is canonicalized under the lattice's symmetries.
One heap is a contiguous, mmap-relocatable block of ~70 MB (64 MB of payload
arena plus the content index), which is what lets a Space be backed by
private memory or POSIX shared memory interchangeably.

**Where the geometry lives.** In the Leech heap, through the vendored
mmgroup core: sign patterns canonical under the Golay-code stabilizer, M₂₄
orbit representatives, orbit ids. An `XRelMap` keyed by `LatticePoint`
routes each key by its index on the shell, and `LatticePoint.orbit` returns
the orbit of a point, so two
points that are "the same up to symmetry" are recognized as one by
`orbit(p) == orbit(q)`.

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

The practical ceiling of the FNV heap is therefore memory: 256 heaps ×
196,560 contents.
Measured behavior (Appendix D): one million map entries spread across
six heaps, every value read back exactly from whichever heap it landed
in; sixty thousand distinct string keys with zero collisions and exact
re-derivation through the chain.

The chain belongs to the FNV heap. The Leech heap does not chain: its
domain is the shell itself, fixed at 196,560 points, so a table on it never
fills and never needs a successor.
