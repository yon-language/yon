# Benchmark artifacts, Jurassic Park in Yon

Raw measurement run behind Appendix D (`manuscript/chapters/93-benchmarks.md`). These are a dated
snapshot, not re-derived each build. The build-time correctness gate that IS re-derived lives in
`regression/test_benchmarks.py` over `regression/bench/*`.

## Provenance

| | |
|---|---|
| Machine | Apple M1, Darwin arm64 |
| Build | runtime `-O2`, warm cache |
| Tool | pytest-benchmark 5.2.3 |
| Rounds | per-op >= 15, scaling = median of 9 runs |
| Commit | `1c44e79` |
| Date | 2026-06-29 |

## Files

- `perf-1c44e79-20260629.json` — raw pytest-benchmark output, with full `machine_info`. The source of
  every subprocess per-op number. (This raw run still contains the three retired arena_* binaries;
  they are filtered out by `summarize.py` and explained below.)
- `per-op-summary-1c44e79-20260629.json` — baseline-subtracted per-op nanoseconds derived from the
  raw run by `regression/bench_perf/summarize.py` (the same file copied to
  `website/src/data/bench-perf.json` for the page). The three arena ops are NOT here, see below.
- `arena_ops-1c44e79-20260629.json` — the three Arena ops, measured IN-PROCESS net of an exact
  `Leech.point` twin (the subprocess harness cannot, see below). Schema:
  `put@2k, put@5k, put@10k, put@20k, get@20k, same_orbit@20k` in ns/op. The four put points show
  put is O(1) in the arena's fill (~80 ns, flat); get ~41 ns; same_orbit ~1.17 µs.
- `xset_scaling-1c44e79-20260629.json` — XSet vs HashSet intersect/union, median over 9 runs at
  N = 100, 1000, 10000, 100000. `median_ns` is 16 values: per N, the four are
  `[XSet_int, Hash_int, XSet_uni, Hash_uni]` in nanoseconds per operation.
- `spawn_scaling-1c44e79-20260629.json` — `spawn in N parallel` wall-time for N = 1, 2, 4, 8, 16
  replicas, each running a fixed 8M-iteration task (`regression/book/jp/bench/spawn_scaling`, an
  IPC-gated project; the design property is checked by `regression/test_spawn_scaling.py`, which
  skips without fork+SHM). Shows real multicore: 8 replicas (8x the work) finish in ~1.1x the serial
  wall-time on the 8-core M1.
- `heap_expand-1c44e79-20260629.json` — content-addressed (FNV) heap interning: distinct content
  ns/intern at 100k (one generation) and 1M (chains ~5 generations, amortized O(1)), and identical
  content (dedup, one slot). Source `regression/bench/heap_expand`, gated by `test_benchmarks.py`.
- `ds_ops-1c44e79-20260629.json` — `List.cons`, `HashMap.set`, `HashSet.add` net of an exact
  Space-threading twin, in-process. `cons` ~70 ns flat; `set` grows with the map (~130 ns at 10k to
  ~340 ns by 1M); `add` flat (the inline contrast). Source `regression/bench/ds_ops`, gated by
  `test_benchmarks.py`.
- `wire_throughput-1c44e79-20260629.json` — cross-process shared-memory `Wire` throughput: a producer
  (sensor.yon) pushes 200,000 messages, a consumer (dash.yon) drains them and times itself. ~1.1 us
  per message, ~900,000 messages/sec end to end. Source `regression/book/jp/bench/wire_throughput`,
  design property gated by `regression/test_wire_throughput.py` (IPC-guarded, skips without fork+SHM).
  Method note: a single in-process stream cannot be timed at high volume, the optimizer (structural
  value numbering) collapses a loop of identical `emit`s to one; the cross-process wire, whose messages
  genuinely differ and cross a real boundary, is the honest measurement of the stream machinery.

## Reproduce

```
.venv/bin/python -m pytest regression/bench_perf/test_perf.py \
    --benchmark-json=/tmp/perf.json --benchmark-min-rounds=15 -q
.venv/bin/python regression/bench_perf/summarize.py /tmp/perf.json
./toolchain/yonc regression/bench/arena_ops   -o /tmp/ao && /tmp/ao   # arena ops, exact twin
./toolchain/yonc regression/bench/xset_scaling -o /tmp/xs && /tmp/xs  # one curve point per run
```

## Reading notes (carried into Appendix D)

- The summary flags any op whose baseline-subtracted net is <= 0. At this commit that is
  `equality`, `merkle_equal`, `golay_seal`, `vec_push`, `equality_big`: sub-nanosecond ops below the
  subprocess timing floor, NOT failures. The in-process gate (`regression/bench/eq_constant`)
  resolves `String.equal` at ~1 ns, flat from 1 to 32,768 chars.
- The three Arena ops (put/get/same_orbit) are measured in-process (`regression/bench/arena_ops`),
  NOT by the subprocess harness. Their loops call `Leech.point` to generate the lattice address,
  which the shared baselines do not, and the FIRST `Leech.point`/`Arena.put` pays a one-time ~200 ms
  mmgroup table init (measured: first put 198 ms, every later put 105 ns). At the small N an arena of
  196,560 slots allows, that one-time cost smears to ~20 us/op and a non-twin baseline cannot remove
  it; that is the ~31 us "super-linear" artifact an earlier run showed. With an exact `Leech.point`
  twin + min-over-reps, `Arena.put` is O(1) in the fill (~80 ns, flat across N), `get` ~41 ns,
  `same_orbit` ~1.17 us. Root cause read from `runtime/yon_arena.c:60`: `yon_arena_put_repr` is a
  perfect-hash index + four slot writes, no resize/probing, orbit sealed per point.
- `List.cons` and `HashMap.set` are likewise measured in-process (`regression/bench/ds_ops`), not by
  the subprocess harness: both put on the content-addressed heap and pay a one-time `g_yon_heap`
  creation the Space-only baseline never pays. Run through the same protocol (read code, exact twin,
  several N) they landed differently: `cons` is real but FLAT at ~70 ns (the subprocess ~204 ns was
  the one-time init smearing over the small N a cons list allows); `set` is real and GROWS with the
  map (~130 ns to ~340 ns), content-addressing each entry on the chaining heap while `HashSet.add`,
  storing inline, stays flat. THE RULE: separate a one-time cost from a per-op cost. An op touching a
  lazily-initialized structure (mmgroup tables, the heap) pays the init once; over small N it looks
  like a huge per-op, over large N it vanishes. Warm it away or measure iteration 1 apart.
- `merkle_construct` (~138 ns) rebuilds one identical tree, so it measures the dedup-hit path, not a
  fresh content-address insert.
