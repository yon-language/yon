---
id: benchmarks
title: "Appendix D. Benchmarks"
sidebar_position: 93
slug: /book/benchmarks
description: "Per-operation timings for Yon's data structures on Apple M1, baseline-subtracted under pytest-benchmark, with the anomalous numbers explained from the runtime source before publication."
---

# Appendix D, Benchmarks

A timing without its method is not a benchmark, it is a number someone saw once. This appendix
states the method first, explains the two surprising numbers from the source before publishing
them, and shows the one result that is asymptotic rather than a constant.

## Method

> Measured on Apple M1, runtime `-O2`, median of at least 15 rounds (at least 30 for the scaling
> result), pytest-benchmark 5.2.3, commit `1c44e79`, 2026-06-29. The correctness gate (`bench_*`)
> is re-derived every build; the timings are this dated measurement.

Each operation is two tiny Yon programs: one that does N of the operation and exits, and a
baseline twin that runs the identical loop with the single operation removed and nothing else
changed. pytest-benchmark times both native binaries over many rounds, and the per-operation cost
is the per-iteration difference, `op_median / N` minus `base_median / N_base`. Process startup,
loop overhead, and the cost of `String.from_int` all sit in both binaries and cancel; what remains
is the operation. A guard value (a size, a recovered gene, a sum) is printed so dead-code
elimination cannot quietly drop the work, and the summary flags any operation whose net is not
positive, which would mean the op was elided or the baseline does not mirror it. Sources are under
`regression/bench_perf/` (timings) and `regression/bench/` (the build-time correctness gate).

Two rules, learned the hard way in this suite, keep the per-op numbers honest. First, the baseline
must be an **exact twin**: everything the op does except the single operation, including any address
generation. A baseline that omits a step the op performs leaves that step's cost inside the result.
Second, separate a **one-time cost from a per-operation cost**. Many operations touch a structure
with a lazy first-call initialization, the mmgroup tables behind the lattice, the heap created on
first use, and that init is paid once per process. Divided by a small N it masquerades as a large
per-op cost, and divided by a large N it vanishes, so the same operation can look heavy or free
depending only on the loop length. Anything timed at small N, or in a fresh subprocess, must warm the
init away (or measure the first iteration apart from the rest) or it will report a per-op number that
is really a constant in disguise. Both faults appear by name in the stories below; both are now
checked.

This is a different category from the rest of the book, and it is marked so. The book's other
numbers are theorems re-derived on every build; a timing cannot be. So the **correctness** here is
re-derived (the guards run every build and prove each operation does the right thing), and the
**nanoseconds** are a measurement, dated and pinned to a commit, that will differ on your hardware
in the constants and not in the shapes.

## Two heavy numbers, run through the same protocol, and where they landed

Two operations came out far slower than their neighbours in the subprocess harness: `List.cons` at
about 204 ns and `HashMap.set` at about 525 ns, against a `Vec.push` and a `HashSet.add` that are
nearly free. Both put their payload on the content-addressed (FNV) heap, where `Vec` and `HashSet`
store inline, so content-addressing is obviously part of the story. But a structural cause read from
the source is a hypothesis, not a measurement, and the rule from the `Arena.put` story below is now
law: read the code to form the hypothesis, then measure with an exact twin at several N, then publish
according to the outcome. The two ran through the same protocol and landed in different places.

**`List.cons` is real but flat, about 70 ns, and the 204 was a warmup smear.** `yon_rt_list_cons`
(`runtime/yon_rt.c:6299`) builds a cons cell and inserts it with `yon_xheap_put_chain`, the
content-addressed heap: every cons hashes the cell and shares identical tails, a hash-cons rather
than allocate-and-point. But it also pays, on the first call in a process, the one-time creation of
the heap itself (`ds_ensure_init` builds `g_yon_heap`), which the Space-only baseline never pays.
Over a cons list, which one heap generation caps near 196,560, that one-time cost smears into the
per-op and inflated it to 204 ns. Measured in-process net of an exact twin, with the init warmed away,
`List.cons` is about 70 ns and flat from 10k to 100k cells: the real price of the hash-cons, no more.

**`HashMap.set` is real and it grows with the map, from about 130 ns to about 340 ns.**
`yon_rt_map_put` (`yon_rt.c:3207`) content-addresses the whole `(key, value)` entry on the heap
(line 3227), then probes the directory, where each probe step resolves an entry's heapref back across
heap generations (`yon_xheap_payload_chain`, line 3247) to compare keys. `HashSet.add`
(`yon_rt.c:3421`) skips all of it, storing the element inline, `keys[idx] = elem`. Measured the same
way, the contrast is the proof: `HashSet.add` stays flat near 70 ns as it grows, while `HashMap.set`
rises, ~130 ns at 10k entries, ~240 ns at 100k, ~340 ns by a million. The growth is not an artifact;
it is the content-addressed-entry path, the heap chaining into more generations and the probe
resolving heaprefs across them, plus the larger working set. So `set` is named with its curve, not a
single number, and with the optimization it implies: a map that never needs its entries shared could
store them inline like `HashSet.add` and stay flat. That is a real debt, named, not a defect.

So the protocol separated them honestly. `cons` was partly a measurement artifact and corrected
*down*, to a clean flat number. `set` was real and corrected into a *curve*, heavier at scale than
the subprocess single point even suggested. Neither was assumed; each was read, measured, and
published according to what it turned out to be. (`regression/bench/ds_ops`.)

## Per-operation timings

| Operation | Apple M1 | What it does |
|---|---|---|
| `String.equal`, 1-char | below floor | one integer compare on the heap address |
| `String.equal`, 32,768-char | below floor | same, **flat in the size of the value** |
| `MerkleTree.equal` (built trees) | below floor | one integer compare on the content address, O(1) in tree size |
| `VoyagerList.seal` | below floor | Golay encode |
| `Vec.push` | below floor | array append |
| `Vec.get` | ~1.4 ns | indexed read |
| `HashSet.contains` | ~6 ns | hash plus probe |
| `HashMap.get` | ~7 ns | hash plus probe plus read |
| `List.head` | ~8 ns | read one cons cell |
| `VoyagerList.open` (corrected) | ~10 ns | Golay decode and correct up to 3 bit flips, every read |
| `Arena.get` | ~41 ns | find a value at a lattice address (exact twin) |
| `HashSet.add` | ~69 ns | hash, inline store, amortized resize, flat in N |
| `List.cons` | ~70 ns | content-addressed cell (hash-cons), flat in N; see below |
| `Arena.put` | ~80 ns | certified insert, O(1) in fill; see below |
| `MerkleTree.node2` (repeated build) | ~138 ns | a deduplicated rebuild, see below |
| `HashMap.set` | ~130 to ~340 ns | content-addressed entry, **grows with the map**; see below |
| `Arena.same_orbit` | ~1.17 µs | recomputes the M24 orbit class, not a lookup |

**The fastest operations are below the harness floor, and the suite says so.** The five marked
"below floor", string and Merkle equality, the Golay seal, and the vector push, came out with a
*negative* per-operation difference: the operation costs less than the run-to-run variance of its
baseline, so subprocess timing cannot resolve it. The summary flags exactly this case, a net at or
below zero, rather than printing a meaningless small or negative number. These operations are
sub-nanosecond. The in-Yon timing of the correctness gate, which times inside one process with
`Time.now_ns`, is finer and does resolve them: it puts `String.equal` at about 1 ns and, crucially,
the same 1 ns at 1 and at 32,768 characters. Equality is flat in the size of the value; it is just
faster than this harness can see from outside.

`Arena.get` is about 41 ns while `Arena.same_orbit` is about 1.17 µs: the roughly 1,130 ns between
them is the M24 orbit recomputation, the symmetry-group calculation made visible. The heavy number is
not slowness, it is the certificate doing real work, and the gap measures exactly how much. The three
arena operations are measured in-process net of an exact `Leech.point` twin, because the arena is
addressed by lattice points and the address generation has to be subtracted, not left in the number.

`MerkleTree.node2` at ~138 ns is given with a caveat: it is a *repeated* build of the same tree, so
after the first it is a deduplication hit, not a fresh content-address insertion; a genuinely fresh
tree pays the full insert, in the `List.cons` range.

## A benchmark that lied, and how it was caught

An earlier run put `Arena.put` at about 31 µs and, worse, made it look super-linear: roughly 1 µs at
N=2,000 against 31 µs at N=10,000. A 31-fold jump in per-op cost while N grows 5-fold is not a
constant mismeasured, it is the per-operation getting worse as the structure fills, and that would be
a real defect. The number was kept out of the book until it was understood. It turned out to be two
methodological faults stacked, neither of them in Yon.

First, the baseline was not an exact twin. The put loop calls `Leech.point` to turn a counter into a
lattice address, then puts; the baseline did the loop without either. So the subtraction left
`Leech.point`'s cost inside the result instead of removing it. The rule, stated plainly: the baseline
must do everything the op does except the single operation under test. Second, and this is what the
broken baseline hid, the very first `Leech.point` or `Arena.put` in a process pays a one-time
mmgroup table initialization of about 200 ms (measured: the first put takes 198 ms, every following
put 105 ns). Over a put loop of only N=10,000, which is all an arena of 196,560 slots invites, that
one-time 200 ms smears to about 20 µs per operation, and a baseline that never calls `Leech.point`
cannot subtract it. The "super-linearity" was this fixed cost divided by a growing-but-small N, an
artifact of arithmetic, not a property of the store.

The runtime says as much. `yon_arena_put_repr` (`runtime/yon_arena.c:60`) is a perfect-hash index
(`yon_mphf_index`, O(1), no search) followed by four slot writes, with the M24 orbit sealed per point
at allocation. There is no resize, no collision chain, no state-dependent certificate: nothing that
could make the N-th insert cost more than the first. Measured in-process net of an exact `Leech.point`
twin, with min-over-reps to exclude the one-time init, the per-op is flat in the fill:

| N | 2,000 | 5,000 | 10,000 | 20,000 |
|---|---|---|---|---|
| `Arena.put` ns/op | 65 | 75 | 79 | 81 |

About 80 ns, O(1) in the fill, the same order as `Arena.get`. The gentle rise from 65 to 81 across a
ten-fold N is a cache and TLB effect as the scattered working set grows, sub-linear and expected of a
3 MB sparse arena, not the algorithmic blow-up the bad number implied. The 31 µs was named and
removed, not published. The wrong number was still useful: it pointed straight at the address-twin
rule and the mmgroup warmup, and at the fact that the arena really does index by perfect hash, as the
design claims. That is the value of refusing to print a number you cannot explain.

## The lattice's set algebra is asymptotic, not a constant

The one result that is a shape rather than a number is `XSet` set algebra. An `XSet` is a fixed
196,560-bit bitmap over the type-2 lattice points, so `intersect` and `union` are a machine-word AND
or OR over about 3,072 words, independent of how many elements the sets hold. A `HashSet` must
iterate, so its cost is O(N). Median over nine runs at four set sizes:

| Set size N | `XSet.intersect` | `HashSet.intersect` | ratio |
|---|---|---|---|
| 100 | 4.5 µs | 16 µs | 4× |
| 1,000 | 4.9 µs | 43 µs | 9× |
| 10,000 | 4.5 µs | 768 µs | 169× |
| 100,000 | 4.6 µs | 47.7 ms | **10,454×** |

`union` is the same story, from 6× at N=100 to **33,776×** at N=100,000, where the `HashSet` union
reaches about 168 ms against the same flat `XSet` cost. The XSet line is **flat** across three orders
of magnitude of set size, 4.5 to 5.0 µs throughout; the HashSet line rises with N. So the advantage
is not a fixed multiplier that happens to be large, it is asymptotic: one side is O(1) in the
cardinality, the other is O(N), and the gap widens without bound.

Read it honestly in both directions. For small sets the fixed bitmap is pure overhead, and at N
around a hundred the lattice barely wins; a hash set is the right tool there. The bitmap earns its
keep as the sets grow, which is exactly when a constant-time set operation is worth most. That is
the shape of the lattice's set algebra, and it is the reason these structures live on the lattice
at all.

## Parallelism is multicore, for free

`spawn in N parallel { ... }` forks N isolated process replicas over a shared-memory collection
stream; each replica runs the body, `promote`s its result, and the parent folds the collection. The
replicas are real OS processes, so they run on real cores at once. The test: each replica does the
same fixed CPU-bound task, and we watch the wall-clock as N grows, on the 8-core M1 (4 performance,
4 efficiency):

| Replicas N | wall time | total work | speedup |
|---|---|---|---|
| 1 | 255 ms | 1x | 1.0x |
| 2 | 263 ms | 2x | 1.9x |
| 4 | 266 ms | 4x | 3.8x |
| 8 | 283 ms | 8x | **7.2x** |
| 16 | 349 ms | 16x | 11.7x |

The wall-clock is nearly flat from one replica to eight: eight replicas do eight times the total work
in about 1.1 times the time, a 7.2-fold speedup on eight cores. The speedup tracks N almost exactly
until it meets the core count, the textbook shape of a workload that actually parallelizes. Past
eight, sixteen replicas oversubscribe the cores and the wall-clock rises, yet the efficiency cores
still carry enough that the throughput keeps climbing to 11.7x. The numbers are a dated measurement;
the shape, speedup rising with N up to the core count then bending, is the property. (Source
`regression/book/jp/bench/spawn_scaling`, design property gated by `regression/test_spawn_scaling.py`,
which skips cleanly where fork and shared memory are unavailable.)

The same shared memory is the wire between Spaces. Two separate processes, a producer that pushes
messages onto a shared-memory `Wire` and a consumer that drains them, move a message across the
process boundary in about **1.1 µs**, roughly **900,000 messages a second** end to end, on the same
M1 (the consumer times itself draining 200,000 messages). That is the cost of a real inter-process
hop, not a function call, and it is what lets a Space talk to another Space without a socket or a
serializer in the path. (Source `regression/book/jp/bench/wire_throughput`, gated by
`regression/test_wire_throughput.py`, IPC-guarded like the spawn bench. A note on method: the
in-process stream is a bounded prototype, a fixed 64-slot ring that silently drops past capacity
(`yon_rt.h` `YON_STREAM_MAX_SLOTS`), so it cannot be timed at high volume; the cross-process wire,
with a real buffer and blocking back-pressure, is the honest measurement of the stream machinery.)

## Content addressing, in memory and in time

The content-addressed (FNV) heap holds one generation of slots; distinct content past a generation
chains into a successor heap, so interning is unbounded. The property shows up twice, in time and in
space. In time, interning strings (`String.from_int(k)`) costs, per item:

| | ns / intern |
|---|---|
| distinct content, 100k (one generation) | ~234 |
| distinct content, 1M (chains ~5 generations) | ~290 |
| identical content, 1M (dedup to one slot) | ~98 |

Interning a million distinct strings chains the heap about five times (a million over the 196,560
slots of a generation) and still costs about 290 ns each, only modestly above the 234 ns of a single
generation: expansion is amortized O(1), not a cliff. Identical content dedups to a single slot and
costs about 98 ns, roughly a third, the hash finding the existing entry instead of writing a new one.

In space, the same property is the memory. Interning two million strings, by the operating system's
resident set (`/usr/bin/time -l`):

| Two million interns of… | resident memory |
|---|---|
| the **same** content | ~8 MB (one slot, deduplicated) |
| **distinct** content | ~175 MB (about 87 bytes each) |

Identical content costs one slot however many times it is written; distinct content grows the heap
linearly, with no garbage collector and no collection pause. Beyond a generation's 196,560 slots the
heap chains into a successor, so there is no fixed ceiling, only real memory, mapped a generation at
a time.

Sources: `regression/bench/xset_scaling` (the two set-algebra curves), `regression/bench/heap_expand`
(interning and expansion), `regression/book/jp/bench/spawn_scaling` (the parallel scaling),
`regression/bench_perf/*` (every per-operation timing), `regression/bench/*` and
`regression/bench/arena_ops` (the build-time correctness and design gates).
