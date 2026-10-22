---
id: data-structures-on-the-lattice
title: "15. Data structures on the lattice"
sidebar_position: 15
---

# Data structures on the lattice

The collections of both heaps (chapter 13) are *persistent* structures:
none of them mutates, every operation returns a new handle, and sharing
makes that cheap. The maps and sets come in two families with the same
semantics and two stores: `HashMap`/`HashSet` in the FNV heap,
`XRelMap`/`XRelSet` in the Leech heap. `Vec` is a cell on a strip of the
heap's arena. All of them are below.

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

The structures of the FNV heap allocate through the heap chain (chapter 13),
so none of them has a hard size ceiling of its own, the budget is memory; a
structure of the Leech heap spans the shell, 196,560 points, by
construction.
What distinguishes them is what they make cheap:

- **List**, the workhorse: an immutable cons list of `f64`. Use it for
  pipelines, accumulation, anything sequential. Structural sharing is
  automatic: two lists with the same tail *are* the same tail.
- **Vec**, a dynamic array indexed by position, stored on an arena strip
  (no `malloc`). `push` appends in place into spare capacity, or reallocates
  a doubled strip past capacity, returning a new handle and handing the old
  strip's whole pages back to the OS via `madvise`; `get`/`set` are O(1).
  It is the building block for an indexed map.
- **`HashMap<K, V>`**, keys and values of any type (a string key is its
  handle, a number). A binary trie on the 32-bit hash of the key:
  a `get` or a `set` walks at most one level per hash bit, and a `set`
  copies that path; bounded only by memory, its nodes spill across heaps
  transparently. A key is identified by its bits, the identity of the heap:
  `-0.0` and `0.0` are two keys, a NaN key finds itself. Use it as the
  general key→value store. `HashSet.union` and `HashSet.intersect` merge
  the two tries rather than adding one element at a time: a subtree the two
  sets share is reused whole, and the result is the same node the elements
  would have built one by one.
- **VoyagerList**, the small, precious store: every element is sealed in
  a Golay codeword and healed on read. Use it where corruption is worse
  than cost, configuration, ledger heads, calibration constants.
- **MerkleTree**, trees whose identity is their content. Use it for
  expression DAGs, audit trails, snapshots: building the same tree twice
  costs almost nothing (every node is a dedup hit), and comparing two
  4,096-leaf trees is one comparison.
- **Cells**, not a collection: the one mechanism with identity
  (chapter 14). The `=` assignment and every loop are built on them; 1,024 per
  process.
- **`XRelMap<K, V>`, `XRelSet<T>`**, the same map and set as `HashMap` and
  `HashSet` (`set`, `has`, `get`, `size`; `add`, `contains`, `union`,
  `intersect`), on another store: their trie is the same code, and its
  nodes live only in the Leech heap, the k-th in the place (generation
  k div 196,560, point `at_index(k mod 196,560)`), written once. A
  `LatticePoint` key routes by its index on the shell, exactly, 18 bits: a
  lookup walks at most 18 levels and two points never share a path. Any
  other key routes by the 64-bit hash of its bits, written in base 196,560:
  the first digit is a point, the rest follow, and only keys whose whole
  hash agrees share a chain. For a key that is not a point the difference
  from `HashMap` is the store, not the geometry. There is no index by
  content in the Leech heap: two maps with the same entries have the same
  shape, node for node, but not the same handle.

**Choosing between the two families.** Measured on the same keys (Appendix D,
"Two maps on the same keys"): every write, union and intersection costs
less on the Leech heap, from about 2× at a thousand keys to 10× at 400,000
`Text` keys, because its store writes the next place where the FNV heap
first looks the content up; a read that finds its key costs about the same
on both up to tens of thousands of keys. What the FNV heap buys with that
lookup is identity by content: two equal collections are one handle,
comparing them is one comparison, a union of two equal sets returns at
once, and building the same map again makes no new node, where the Leech
heap makes every node again. So: `HashMap`/`HashSet` when collections are
compared or their contents recur (memory); `XRelMap`/`XRelSet` when they
are written, merged, or large (time).

**A lattice point is made only where it is one.** `LatticePoint` is an
abstract type over its representation, a 25-bit coordinate carried as an
`i64` (`place LatticePoint is internal i64`): outside its house no literal is
a point, no arithmetic applies (the sum of two points is not a point), and it
is not an `Int64`. A point is made by `LatticePoint.of_coordinate(n)`, the
characteristic map of the type-2 shell, which answers a point or a
`DomainError` (a fraction, a negative, a coordinate off the shell), or by
`LatticePoint.at_index(i)`, the i-th of the 196,560 points (a `DomainError`
outside `[0, 196560)`). It is read through `LatticePoint.index(p)`, its place
on the shell, and `LatticePoint.orbit(p)`, its M₂₄ orbit: an orbit belongs to
the point, so two points are the same up to symmetry when
`orbit(p) == orbit(q)`.

**A frame is a quotient.** An `XRelFrame` is a partition of the 196,560
points, an equivalence relation, and it is represented by its canonical
projection: `XRelFrame.canon(f, p)` is the representative of p's class, the
member with the smallest index, so `canon(f, canon(f, p))` is
`canon(f, p)`. The frames form a lattice of partitions:

- `XRelFrame.discrete()` is the finest, each point its own class: `canon` is
  the identity.
- `XRelFrame.whole()` is the coarsest, a single class.
- `XRelFrame.refine(f, r)` splits each class of `f` by the type of `v ^ r`
  (the meet of `f` with the partition that `r` draws); refining `discrete`
  leaves it `discrete`. There is no bound on the number of references.
- `XRelFrame.curtis()` is the frame of the 26 Curtis octads, refined from
  `whole` octad by octad: 98,260 classes.

A frame made from references never separates a point from its negative: the
sign never changes the type of a vector (checked on all 2²⁵ values), so `v`
and `-v` have the same type against every reference and fall in the same
class. Such a frame is at best as fine as ±v, and Curtis reaches about that
far (98,280 pairs, 98,260 classes); only `discrete` tells `v` from `-v`. A
map on the classes is an ordinary map whose key goes through the projection
first: key it by `canon(f, p)`, not by `p`. The laws above are checked on
every point of every frame the runtime builds
(`runtime/test_unit_xrel_frame.c`).

**What a node of the Leech heap holds.** `XRelMap<K, V>` and `XRelSet<T>`
keep their keys and values as 64 bits in the nodes of their trie, in the
Leech heap (chapter 13), never in the FNV heap. Which types fit is derived
from their carrier: a scalar of 32 or 64 bits (`Int32`; `Int64`, `Number`,
a `LatticePoint`), or a content-addressed handle (a `Text`, whose bits name
its content in the FNV heap, so two equal strings are one key); a type that
does not fit (a `Boolean`, a place, a function) is a type error, never
truncated. A key or a value enters as its bits and comes back the same bits:
identity in a node is identity of bits, the criterion of the whole runtime,
so `-0.0` and `0.0` are two keys and a `NaN` equals itself (arithmetic on
the values read back stays IEEE). A key the map does not hold answers
`Absent`, and no stored value ever means "empty".

## MerkleTree: content addressing made visible

A Merkle tree is what the heap already does, surfaced as an API, every node
is addressed by the content of its children:

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be l1 := MerkleTree.leaf(7)
  be l2 := MerkleTree.leaf(9)
  be t := MerkleTree.node2(1, l1, l2)
  be t2 := MerkleTree.node2(1, MerkleTree.leaf(7), MerkleTree.leaf(9))
  be same := MerkleTree.equal(t, t2)    // same content, same tree, same slot
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
  be vl := VoyagerList.empty()
  be vl2 := VoyagerList.append(vl, 42)
  be damaged := VoyagerList.corrupt_at(vl2, 0, 3)  // flip 3 bits in storage
  be healed := VoyagerList.get(damaged, 0)         // Golay (24,12,8) corrects
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
