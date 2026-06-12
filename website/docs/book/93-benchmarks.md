---
id: benchmarks
title: "Appendix D. Benchmarks"
sidebar_position: 93
slug: /book/benchmarks
description: "Measured benchmarks for the Yon language: O(1) structural equality on the content-addressed heap, state-space exploration, Merkle diff, and cross-process RPC, with method and sources."
---

# Appendix D, Benchmarks

Numbers before claims. Everything below was produced by Yon programs
compiled through the standard `yonc` pipeline and run where this book was
written.

**Environment, stated plainly:** a Linux container (virtualized x86-64),
single run per figure, timed with `Time.now_ms` (1 ms resolution), no
statistical treatment, no warm/cold separation beyond the noted warmup.
These are **honest orders of magnitude**, not publishable performance
claims; results on your hardware will differ in the constants, not in the
shapes. The benchmark sources ship with the repository.

## The shapes that matter

| What is measured | Load | Time | Per-op |
|---|---|---|---|
| `String.equal`, 1-char strings | 2M comparisons | 33 ms | ~17 ns |
| `String.equal`, 4,096-char strings (length verified in-bench) | 2M | 34 ms | ~17 ns |
| `String.equal`, 32,768-char strings (length verified in-bench) | 2M | 34 ms | ~17 ns |
| Allocation, identical content (dedup hit) | 100k | 12 ms | ~120 ns |
| Allocation, distinct content (fresh slots) | 100k ×2 allocs | 29 ms | ~145 ns/alloc |
| `HashMap.set`, 50k distinct keys (4 rehashes included) | 50k | 11 ms | ~220 ns |
| `HashMap.get` | 50k | 2 ms | ~40 ns |
| `HashMap`, 300k entries across **two heaps** | 300k | 119 ms | ~397 ns |
| `HashMap`, 500k entries across **three heaps** | 500k | 258 ms | ~516 ns |
| `HashMap`, 1M entries across **six heaps** | 1M | 1,380 ms | ~1.4 µs amortized |
| `VoyagerList.get` (Golay open + correct on every read) | 1M | 27 ms | ~27 ns |
| Space cell set+get pair (the cost of `becomes`) | 2M pairs | 25 ms | ~12.5 ns |
| Merkle build, 4,096 leaves (fresh) | 1 tree | 2 ms |  |
| Merkle build, identical tree (all dedup hits) | 1 tree | 1 ms |  |
| `MerkleTree.equal`, two 4,096-leaf trees | 1 comparison | &lt;1 ms | O(1) |

## What the shapes mean

**Equality is flat.** Three orders of magnitude of string size, the same
per-comparison time: the O(1) equality of chapter 11, measured rather
than asserted. The benchmark prints and checks the string lengths before
timing, an earlier version of this suite was silently comparing invalid
handles above a since-removed 1,024-character cap, and the table was
corrected. Trust numbers that verify their own inputs.

**Deduplication is not about allocation speed.** A dedup hit (~120 ns)
costs the same order as a fresh slot (~145 ns). What dedup buys is space
, and the flat equality above. The claim is narrow on purpose.

**The chain is no longer the variable.** Global deduplication is one
O(1) probe of a process-wide content index, however many heaps exist, 
six heaps at the million-entry mark cost five lines on stderr and
nothing in the lookup.

**The million-entry figure includes a rehash, on purpose.** Directories
hold one invariant, load ≤ 0.7, hence expected O(1) probes at every
size, and pay for it by doubling with a rehash when growth demands it.
Just short of a million entries the directory doubles from 2²⁰ to 2²¹
slots, re-placing ~734k entries; at the 1M measuring point that cost is
not yet amortized, and the table shows it honestly. The alternative, a
size cap, looked faster at exactly this point and was a defect: at the
cap the directory reaches 100% load and begins discarding writes. No
knob, no cliff; the spike amortizes, the cliff does not. Exactness held
at every scale tested.

**Self-healing is a factor of two.** A sealed VoyagerList read, decode
the Golay codeword, correct up to three flipped bits, lands at ~27 ns
against ~12.5 ns for a raw cell pair. Error correction in the hot path
for a 2× constant.

## Correctness under load

The same suite checks exactness, not just speed: 500,000 map entries
across three heaps read back exactly on every side of every boundary;
60,000 distinct string keys produce 60,000 entries (no false
deduplication) with zero errors over re-derivation; 10,000
same-content/neighbour pairs show zero equality mistakes. The heap's
content addressing held under everything we threw at it.
