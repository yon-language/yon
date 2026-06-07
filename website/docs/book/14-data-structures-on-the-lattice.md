---
id: data-structures-on-the-lattice
title: "14. Data structures on the lattice"
sidebar_position: 14
---

# Data structures on the lattice

Every collection in the stdlib is a *persistent* structure over the
content-addressed heap. None of them mutates; every operation returns a new
handle, and sharing makes that cheap.

**List** is the classic cons chain: `List.cons(x, rest)` puts one new node;
the rest is shared by address. **HashMap / HashSet** are persistent maps
with the orbital variants from chapter 11 (`orbital_set`/`orbital_get`
canonicalize keys to their lattice-orbit representative before storing).

## Choosing a structure

Every structure below allocates through the heap chain (chapter 11), so
none of them has a hard size ceiling of its own, the budget is memory.
What distinguishes them is what they make cheap:

- **List**, the workhorse: an immutable cons list of `f64`. Use it for
  pipelines, accumulation, anything sequential. Structural sharing is
  automatic: two lists with the same tail *are* the same tail.
- **HashMap**, `f64 → f64`, with string handles as keys when you need
  them (a handle is a number). The directory starts at 4,096 slots and
  doubles with a rehash at 70% load, up to 2²⁰; entries spill across
  heaps transparently. Use it as the general key→value store; measured at
  half a million entries with exact recall.
- **VoyagerList**, the small, precious store: every element is sealed in
  a Golay codeword and healed on read. Use it where corruption is worse
  than cost, configuration, ledger heads, calibration constants. The
  seal costs roughly a factor of two over a raw cell read (Appendix D),
  which is nothing for what it buys.
- **Merkle**, trees whose identity is their content. Use it for
  expression DAGs, audit trails, snapshots: building the same tree twice
  costs almost nothing (every node is a dedup hit), and comparing two
  4,096-leaf trees is one comparison.
- **Cells**, not a collection: the one mechanism with identity
  (chapter 12). `becomes` and every loop are built on them; ~12 ns per
  set+get pair, 1,024 per process.
- **Orbital variants**, `HashMap.orbital_set` and friends store the M₂₄
  orbit representative of the key: equality up to symmetry as storage
  semantics (chapter 18 shows it collapsing).

## Merkle: content addressing made visible

A Merkle tree is what the heap already does, surfaced as an API, every node
is addressed by the content of its children:

```yon
fun main(): number {
  be l1 holds Merkle.leaf(7)
  be l2 holds Merkle.leaf(9)
  be t holds Merkle.child(l1, l2)
  be t2 holds Merkle.child(Merkle.leaf(7), Merkle.leaf(9))
  be same holds Merkle.equal(t, t2)    // same content, same tree, same slot
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

```yon
fun main(): number {
  be vl holds VoyagerList.empty()
  be vl2 holds VoyagerList.append(vl, 42)
  be _z holds VoyagerList.corrupt_at(vl2, 0, 3)   // flip 3 bits in storage
  be healed holds VoyagerList.get(vl2, 0)         // Golay (24,12,8) corrects
  return healed                                   // 42, healed
}
```

It is the à-la-Voyager bet: don't detect corruption, *outlive* it.

## Cells across processes

The Space-cell story of chapter 12 extends across process boundaries by
swapping the heap's backing: `YON_BACKEND=shm` places a Space's heap in
POSIX shared memory (`/yon_space_<name>`), and cross-process updates are
serialized with an exclusive `flock` around the critical section. Shared
folds are written so that concurrent writers **converge**, the
fold-as-merge discipline (CRDT-flavoured) that the multi-process test suite
verifies empirically: same final state, whatever the interleaving.
