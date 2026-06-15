# Yon Data Structures

A map of every data structure in the Yon runtime: what it does, a one-line
example that captures its essence, how it allocates, what is left to close, and
what was dropped along the way.

## Allocation philosophy

There is no `malloc` in Yon. Everything stands on a four-level backing stack.

1. **`yon_mmap`** is the floor. mmap always, never `malloc`, never static
   arrays. Private anonymous and kernel-zeroed by default (`yon_map`); the sole
   exception is `yon_map_shared` (shm_open + MAP_SHARED) for state that crosses
   Space boundaries (the shared heap, wire stream and RPC rings).
2. **`yon_xheap`** (`g_yon_heap`, shared by every backend) is a content-addressed
   heap on mmap: 196560 sequential slots plus a content-index hash of 294913
   buckets. Identical content lands on the same slot, lookup is O(1), and a
   `slot_index` is stable for the life of the heap (no rehashing, no moves).
3. **`ds_arena`** sits on an xheap and is keyed by xcoord (point to repr/fusion).
4. **arena strips** are contiguous regions an arena hands out, on which the
   queue-like collections run.

### The two keys

When the table below names an *allocator key*, it is one of these two.

- **Leech 24**: the key is a point of the Leech lattice (an xcoord, or its MPHF
  index in `[0, 196560)`). Used by every geometric structure. Membership and
  identity are decided by *where the point sits*, not by its byte content.
- **FNV-1a**: the key is the 64-bit FNV-1a hash of the payload bytes
  (offset basis `0xcbf29ce484222325`, prime `0x100000001b3`), with content dedup
  on the xheap. Used by the general-purpose and fused collections. Identical
  payloads collapse to one slot, which is why `String.equal` is O(1) regardless
  of length: equal strings share a slot, so equality is a slot-id comparison.

## The structures

| Structure | What it does | Essence (one-line example) | Allocator key |
|---|---|---|---|
| **Level 0: geometric primitives** | | | |
| `yon_leech2_quantize` | R^24 to nearest type-2 | a bruised apple to the perfect sample apple it most resembles | Leech 24 (stack) |
| `yon_xcoord_to_int24` | index/point to 24 coordinates | from the serial number back to the apple's 24 traits | Leech 24 (stack) |
| `yon_leech2_signed_product` | similarity of two type-2 points | how alike two apples are | Leech 24 (stack) |
| `yon_mphf_index` / `_unindex` | type-2 to/from index `[0,196560)` | every apple has a unique serial, and the serial finds it back | Leech 24 (stack) |
| **Level 1: X\* collections (equivariant)** | | | |
| `XRel` | equivalence class under symmetry | every rotation/reflection of the same apple counts as one class | Leech 24 (arena) |
| `XRelMap` | map keyed by symmetry class | apple to price where the key is the *class*, not the specimen | Leech 24 (arena) |
| `XRelSet` | set of classes | the list of apple-classes already seen | Leech 24 (bitmap/arena) |
| `XTower` | classifier at increasing resolution | "fruit" (1) to "type" (3) to "variety" (12) to "specimen" (196560) | Leech 24 (stack, stateless) |
| `XSimplex` | classifies a *configuration* of points | not one apple but the shape of a whole basket together | Leech 24 (stack, stateless) |
| `XSet` | membership over all type-2 points | one checkbox for each of the 196560 possible apples | Leech 24 (private mmap) |
| `XMap` / `XTree` *(to do)* | map/tree keyed by an equivariant Co0/M24 code | a dictionary whose key is *anything* (a string, a record) projected onto the Leech | blocked: key to xcoord |
| **Level 2: general-purpose collections** | | | |
| `Vec` | mutable dynamic array | a row of apples you append to at the end | FNV-1a (arena strip) |
| `IndexedHeapMap` | insertion-ordered map (backs `map`) | apple to weight in the order you weighed them | FNV-1a (arena, no malloc) |
| `MemoTable` | memoization cache | you remember an apple's weight so you never reweigh it | FNV-1a (arena, no malloc) |
| `Deque` | double-ended queue | a row of apples you push/pop at both ends | FNV-1a (arena strip) |
| `PriorityQueue` | priority extraction | you always take the ripest apple first | FNV-1a (arena strip, no malloc) |
| `FrozenMap` | immutable map, O(1) worst-case lookup | a catalogue apple to info that never changes, any apple found in one shot | FNV-1a (arena, immutable) |
| **Robust storage** | | | |
| `VoyagerList` | list with built-in error correction | apples in crates that survive 3 dents: the crate gets damaged, the apple comes out intact | FNV-1a (pool + arena strip) |

## Usage examples

Level 0 is the bridge R^24 <-> Lambda_2 <-> index, O(1) and allocation-free:

```c
double q[24] = { /* a noisy measurement */ };
yon_xcoord_t v = yon_leech2_quantize(q);   /* snap to nearest type-2 */
uint32_t id = yon_mphf_index(v);           /* its address in [0,196560) */
int16_t coords[24];
yon_xcoord_to_int24(v, coords);            /* decode back to integers */
int sim = yon_leech2_signed_product(v, w); /* how close v and w are */
```

XTower is a nested-resolution classifier along Co0 > N > M24 > id:

```c
double cls = yon_rt_xtower_class(point, level);   /* level 0..3 -> 1/3/12/196560 classes */
double same = yon_rt_xtower_same_branch(a, b, 2); /* do a,b share their M24 orbit? */
```

The fused collections are reached through f64 handles from the frontend:

```c
double m = yon_rt_map_empty();
m = yon_rt_map_put(m, key, value);
double v = yon_rt_map_get(m, key);

double s = yon_rt_space_make(0.0);  /* a mutable Space cell */
yon_rt_space_set(s, 42.0);          /* becomes 42 */
double now = yon_rt_space_get(s);
```

VoyagerList seals each element with Golay (24,12,8) on store and corrects on read:

```c
double cw = yon_rt_voyagerlist_seal(data12);      /* 12 bits -> 24-bit codeword */
double back = yon_rt_voyagerlist_open(corrupted); /* syndrome-decode, fix up to 3 bits */
```

## Benchmarks

All numbers below were measured in this environment: a Linux container, `gcc -O2`,
single thread, one fresh process per test (so the heap never saturates across
tests). Absolute values move with hardware and compiler; the orders of magnitude
and the ratios are what carry. Load is the number of operations timed.

| Benchmark | Load | Time | Per-op |
|---|---|---|---|
| `String.equal`, 1-char | 2,000,000 | 12.0 ms | 6.0 ns |
| `String.equal`, 4,096-char | 2,000,000 | 12.7 ms | 6.3 ns |
| `String.equal`, 32,768-char | 2,000,000 | 7.9 ms | 3.9 ns |
| Allocation, dedup hit (identical content) | 100,000 | 7.6 ms | 75.8 ns |
| Allocation, distinct content (fresh slots) | 100,000 | 28.8 ms | 288.2 ns |
| `HashMap.set`, 50k distinct keys | 50,000 | 18.8 ms | 375.0 ns |
| `HashMap.get` | 50,000 | 2.3 ms | 45.4 ns |
| `Set.add`, 50k | 50,000 | 5.0 ms | 100.4 ns |
| `Set.contains` | 50,000 | 2.0 ms | 39.5 ns |
| `Vec.push`, 100k | 100,000 | 1.4 ms | 13.6 ns |
| `Vec.get` | 100,000 | 0.4 ms | 4.3 ns |
| `VoyagerList.get` (Golay open + correct every read) | 1,000,000 | 11.0 ms | 11.0 ns |
| Merkle build, 4,096 leaves | 4,096 | 2.5 ms | 615.9 ns/leaf |
| `MerkleTree.equal` (identical, dedup) | 100,000 | 0.3 ms | 3.1 ns |
| Space cell set+get (the cost of `becomes`) | 2,000,000 | 9.9 ms | 5.0 ns |
| `XTower.class` | 2,000,000 | 243.7 ms | 121.8 ns |
| `Arena.put`, 100k | 100,000 | 174.8 ms | 1,747.9 ns |
| `Arena.get` | 100,000 | 1.9 ms | 19.1 ns |
| `mphf` index + unindex (round trip) | 2,000,000 | 123.6 ms | 61.8 ns |
| `signed_product` | 2,000,000 | 180.6 ms | 90.3 ns |
| `xcoord_to_int24` (decode) | 2,000,000 | 45.5 ms | 22.7 ns |
| `yon_leech2_quantize` (dense query) | per query | | ~720,000 ns |

The shapes that matter:

- **`String.equal` is flat in length**, 6.0 ns at 1 char and 3.9 ns at 32,768
  chars. Equality is a slot-id comparison on the FNV-1a heap, so content size
  does not enter. The same reason makes `MerkleTree.equal` 3.1 ns (O(1)) and the
  dedup-hit allocation (75.8 ns) cheaper than a fresh distinct allocation
  (288.2 ns).
- **The fused collections are tens to low hundreds of ns**: HashMap get 45 ns,
  set 375 ns (with rehashes), Set contains 40 ns, Vec push/get 14/4 ns,
  VoyagerList get 11 ns *including* a full Golay syndrome-decode on every read,
  `becomes` 5 ns.
- **The geometric layer is the slow one**, and it is the honest cost of the
  lattice: `signed_product` 90 ns, decode 23 ns, mphf round-trip 62 ns,
  `XTower.class` 122 ns, `Arena.put` ~1.75 us (it computes orbit/fusion on
  insert; `Arena.get` is 19 ns). The quantizer is ~720 us per query, dominated
  by the 4,096-codeword Golay scan in the 3.1^23 branch.

### Error-correction quality (measured this session)

Leech type-2 decode vs a random spherical code of equal cardinality on the same
shell, word error rate by noise sigma. The Leech decode is O(1); the random code
needs an O(196560) scan.

| sigma | Leech WER (O(1)) | random-code WER (O(N)) |
|---|---|---|
| 0.6 | 0.0% | 1.3% |
| 0.9 | 31.3% | 38.0% |
| 1.2 | 73.3% | 76.0% |

The quality margin is modest at this cardinality (24-D leaves room around 196560
points); the speed margin is structural and grows with the codebook.

### What was not benchmarked, and why

- **HashMap beyond one heap.** A single xheap holds 196560 slots, so the
  measured HashMap is single-heap at 50k. Spilling to 300k / 500k / 1M entries
  needs multiple Spaces; that multi-heap walk (where per-op drifts toward the
  microsecond) is not reproduced in this isolated harness.
- **`FrozenMap`, `MemoTable`, `Deque`, `PriorityQueue`, and `XRel`/`XRelMap`/
  `XRelSet`/`XSimplex`/`XSet`** have no frontend-exposed handle API; they are
  internal backends. `HashMap.set/get` exercises the `IndexedHeapMap` backend
  indirectly, but the others are not callable in isolation and are left
  unmeasured rather than guessed.

## What is missing to close the open ones

**`XMap` / `XTree` (Level 1, the last level on the Leech).** These are maps and
trees whose keys are encoded equivariantly on the real Co0/M24 orbits, so that
*arbitrary* external keys (a string, a record), not just given type-2 points,
can index into the Leech. The blocker is not code, it is the encoding
`key -> Leech xcoord` that is Co0/M24-equivariant. This is a research
prerequisite, and it is exactly the "semantic half" of the bridge: the map from
data to geometry.

What the experiments this session established about that map:
- It requires *block structure* (functional dependencies where a group of
  attributes determines others, the 5->8 of a Steiner octad), not mere pairwise
  correlation.
- `psi` (the precision-matrix diagnostic) and a column-shuffle null model tell
  *a priori* whether a domain has that structure.
- The discipline is a permutation test on the *optimization gain*: optimize the
  layout on the real data and on many shuffles, and accept structure only when
  the real gain sits well outside the shuffle gains. A raw score lift of a few
  sigma proves nothing; the optimizer imposes ~3 sigma even on noise. A high gain
  also means "structure exists", not "structure is useful": on digits the gain is
  large yet the addressing does not help classification.
- Natural tabular data (Iris, digits) rarely carries octad structure: Iris has a
  global factor, digits has diffuse local correlation. The win regime is the
  Leech's native domain (codes, signals, spherical quantization, error
  correction), not generic data analysis.

So `XMap`/`XTree` are not blocked on engineering but on a domain that actually
carries Co0/M24 symmetry, with `psi` as the gate that decides whether a given
domain qualifies.

**`FrozenTrie` (Level 2).** Not needed. The mutable `Vec` already gives
amortized O(1) push; a persistent trie is only worth building if an immutable
`Vec` is ever wanted.

## What happened to the rest

**`XVoyager`** (the geometric *navigator*) was dropped, for a one-line reason
recorded in the TODO: navigation is not collapse. Walking the lattice is a
different operation from snapping a point to its class, and conflating them did
not earn its place.

**`VoyagerList`** is alive and is a different thing entirely: not a navigator but
a self-correcting *list*. Each element is sealed into a Golay (24,12,8) codeword
on store and syndrome-decoded on read, recovering the original even after up to
3 bit flips. It is the error-correction code of the session's experiment made
into a concrete robust-memory structure, and it reads in ~11 ns per element with
the correction on every read.

## Status at a glance

- **Level 0** closed: the R^24 <-> Lambda_2 <-> index bridge is O(1) and
  allocation-free, quantizer included.
- **Level 1** has one open hole, `XMap`/`XTree`, which is the semantic-map
  research problem, not code.
- **Level 2** complete except `FrozenTrie`, which is deliberately not built.
- The iron rule holds everywhere: no `malloc`. Everything is
  mmap -> content-addressed xheap (FNV-1a) -> arena, with the geometric
  structures keyed on the Leech 24 lattice instead.
