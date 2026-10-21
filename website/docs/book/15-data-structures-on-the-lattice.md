---
id: data-structures-on-the-lattice
title: "15. Data structures on the lattice"
sidebar_position: 15
---

# Data structures on the lattice

Every collection in the stdlib is a *persistent* structure over the
content-addressed heap. None of them mutates; every operation returns a new
handle, and sharing makes that cheap.

**List** is the classic cons chain: `List.cons(x, rest)` puts one new node;
the rest is shared by address. **HashMap / HashSet** are persistent maps,
hash tries of immutable nodes in the content-addressed heap: every
`set`/`add` copies the path to its key and shares the rest by address, and
the map it was given stays what it was. The heap deduplicates every node, so
two maps with the same entries are the same nodes, the same handle, and a
node may be shared by maps that know nothing of each other: no write ever
happens on a node, and nothing is reused in place. A collection that has to
change in place is not a value but a cell, declared in a Space's arena. **Vec** is a dynamic array on an arena strip (no `malloc`): `push` appends in
place or reallocates a doubled strip on growth, and `get`/`set` are O(1) with
`set` mutating in place.

## Choosing a structure

Every structure below allocates through the heap chain (chapter 13), so
none of them has a hard size ceiling of its own, the budget is memory.
What distinguishes them is what they make cheap:

- **List**, the workhorse: an immutable cons list of `f64`. Use it for
  pipelines, accumulation, anything sequential. Structural sharing is
  automatic: two lists with the same tail *are* the same tail.
- **Vec**, a dynamic array indexed by position, stored on an arena strip
  (no `malloc`). `push` appends in place into spare capacity, or reallocates
  a doubled strip past capacity, returning a new handle and handing the old
  strip's whole pages back to the OS via `madvise`; `get`/`set` are O(1).
  It is the building block for an indexed map.
- **HashMap**, `f64 → f64`, with string handles as keys when you need
  them (a handle is a number). A binary trie on the 32-bit hash of the key:
  a `get` or a `set` walks at most one level per hash bit, and a `set`
  copies that path; bounded only by memory, its nodes spill across heaps
  transparently. A key is identified by its bits, the identity of the heap:
  `-0.0` and `0.0` are two keys, a NaN key finds itself. Use it as the
  general key→value store.
- **VoyagerList**, the small, precious store: every element is sealed in
  a Golay codeword and healed on read. Use it where corruption is worse
  than cost, configuration, ledger heads, calibration constants. The
  seal costs roughly a factor of two over a raw cell read (Appendix D),
  which is nothing for what it buys.
- **MerkleTree**, trees whose identity is their content. Use it for
  expression DAGs, audit trails, snapshots: building the same tree twice
  costs almost nothing (every node is a dedup hit), and comparing two
  4,096-leaf trees is one comparison.
- **Cells**, not a collection: the one mechanism with identity
  (chapter 14). The `=` assignment and every loop are built on them; ~12 ns per
  set+get pair, 1,024 per process.
- **`Arena<V>`**, the Leech-indexed pool: one slot per type-2 lattice point.
  `Arena.orbit` returns the M₂₄ orbit id of a point and `Arena.same_orbit`
  tests two points for equivalence under the symmetry group, equality up to
  symmetry made explicit. `Arena.get` answers `Found(v)` or `Absent`.

**What a lattice slot holds.** `Arena<V>` and `XRelMap<K, V>` keep their
values inline, in the slots of the lattice, never in the heap. Which values
fit a slot is derived from their carrier: a scalar of 32 or 64 bits
(`Int32`; `Int64` and `Number`); a value that does not fit (a `Boolean`, a
place, a function) is a type error, never truncated. A value enters as its
bits and comes back the same bits: identity inside a slot is identity of
bits, the criterion of the whole runtime, so `-0.0` and `0.0` are two values
and a `NaN` equals itself (arithmetic on the values read back stays
IEEE). An empty slot is its own occupancy bit: reading it answers `Absent`,
and no stored value ever means "empty".

## MerkleTree: content addressing made visible

A Merkle tree is what the heap already does, surfaced as an API, every node
is addressed by the content of its children:

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be l1 holds MerkleTree.leaf(7)
  be l2 holds MerkleTree.leaf(9)
  be t holds MerkleTree.node2(1, l1, l2)
  be t2 holds MerkleTree.node2(1, MerkleTree.leaf(7), MerkleTree.leaf(9))
  be same holds MerkleTree.equal(t, t2)    // same content, same tree, same slot
  return if same then 42 else 0
}
```

Equality of whole trees is one comparison, the same trick as
`String.equal`, at any depth.

## VoyagerList: storage that heals

`VoyagerList` seals every element with the **binary Golay code (24,12,8)**
(via the vendored mat24 machinery): 12 data bits become a 24-bit codeword
with minimum distance 8, which corrects up to **3 arbitrary bit flips**.
The module ships a fault injector so you can watch it work:

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be vl holds VoyagerList.empty()
  be vl2 holds VoyagerList.append(vl, 42)
  be damaged holds VoyagerList.corrupt_at(vl2, 0, 3)  // flip 3 bits in storage
  be healed holds VoyagerList.get(damaged, 0)         // Golay (24,12,8) corrects
  return healed                                       // 42, healed
}
```

It is the à-la-Voyager bet: don't detect corruption, *outlive* it.

## Cells across processes

The Space-cell story of chapter 14 extends across process boundaries by
swapping the heap's backing: `YON_BACKEND=shm` places a Space's heap in
POSIX shared memory, named after the Space, and cross-process updates are
serialized with an exclusive `flock` around the critical section. Shared
folds are written so that concurrent writers **converge**, the
fold-as-merge discipline (CRDT-flavoured) that the multi-process test suite
verifies empirically: same final state, whatever the interleaving.
