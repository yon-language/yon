"""Benchmark suite, gated like the rest.

Each bench under regression/bench/<name>/ is a Yon project that times an operation
(internally: warm-up, min-of-K, baseline-subtracted, DCE-guarded) and prints a line
of integers: some are CORRECTNESS GUARDS (the DCE-guard / result-shape values), the
rest are timings in ns.

pytest's job here is NOT to assert wall-clock numbers (those are machine-dependent)
but to assert that:
  (1) every bench still compiles and runs (`toolchain/yonc <dir>` -> native, exit 0),
  (2) its correctness guards hold exactly (so a benchmark cannot silently rot into
      measuring nothing, and a regression that breaks the structure is caught), and
  (3) a few machine-independent DESIGN PROPERTIES hold with generous margins
      (equality is O(1) in size; XSet set-algebra beats HashSet).

As a side effect, the per-position median across K runs is written to
website/src/data/bench-raw.json, the source the benchmarks page renders from.
Run:  pytest regression/test_benchmarks.py   (set BENCH_K to change the run count)
"""

import json
import os
import statistics
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
BENCH = ROOT / "regression" / "bench"
OUT = ROOT / "website" / "src" / "data" / "bench-raw.json"
K = int(os.environ.get("BENCH_K", "3"))

# bench -> [(output_index, expected_value)] : correctness guards that MUST hold.
GUARDS = {
    "eq_constant": [(0, 1), (1, 1024), (2, 32768)],
    "hashset": [(0, 100000), (2, 1)],
    "hashmap": [(0, 100000), (2, 43)],
    "vec": [(0, 100000), (2, 42)],
    "list": [(0, 100000), (2, 99999)],
    "merkle": [(0, 1), (1, 0)],
    "arena": [(0, 1), (1, 1), (5, 200000)],
    "xset": [(0, 1000), (1, 3000)],
    "golay": [(0, 1445)],
    "heap_expand": [(0, 1000000)],
}

BENCHES = sorted(p.name for p in BENCH.iterdir() if p.is_dir()) if BENCH.exists() else []
_results = {}


def _ints(s):
    return [int(t) for t in s.split() if t.lstrip("-").isdigit()]


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
@pytest.mark.parametrize("name", BENCHES)
def test_benchmark(name, tmp_path):
    binp = tmp_path / name
    comp = subprocess.run(
        [str(YONC), str(BENCH / name), "-o", str(binp)],
        capture_output=True, timeout=240,
    )
    assert comp.returncode == 0, f"{name}: compile failed\n{comp.stderr.decode(errors='replace')[-800:]}"
    runs = []
    for _ in range(K):
        r = subprocess.run([str(binp)], capture_output=True, timeout=180)
        nums = _ints(r.stdout.decode(errors="replace"))
        assert nums, f"{name}: produced no numeric output"
        runs.append(nums)
    L = min(len(r) for r in runs)
    median = [int(statistics.median(r[i] for r in runs)) for i in range(L)]

    # (2) correctness guards
    for idx, expected in GUARDS.get(name, []):
        assert median[idx] == expected, (
            f"{name}: guard[{idx}] = {median[idx]}, expected {expected} "
            f"(benchmark invalid or the structure regressed). full median={median}"
        )

    # (3) design properties (lenient, machine-independent)
    if name == "eq_constant":
        net_1, net_32k = median[3], median[5]
        # O(1) in size: a 32768x larger string must not cost meaningfully more.
        assert net_32k <= max(net_1, 1) * 8, (
            f"eq_constant: equality not O(1) in size? net(1)={net_1} net(32768)={net_32k}"
        )
    if name == "xset":
        xset_inter, hash_inter = median[2], median[4]
        # the bit-parallel intersect must beat the O(N) hash intersect.
        assert xset_inter < hash_inter, (
            f"xset: bit-parallel intersect not faster than hash? xset={xset_inter} hash={hash_inter}"
        )
    if name == "arena_ops":
        put_2k, put_20k, get_20k, so_20k = median[0], median[3], median[4], median[5]
        # the exact-twin nets must all be positive (twin mirrors the op; a <=0 net
        # would mean the baseline does not mirror it, the bug that hid the put cost).
        assert min(median) > 0, f"arena_ops: a net per-op is <= 0 (baseline not an exact twin)? {median}"
        # Arena.put is O(1) in the arena's fill (perfect-hash index + slot writes, no
        # resize/probing): a 10x larger N must not cost meaningfully more per op.
        assert put_20k <= max(put_2k, 1) * 3, (
            f"arena_ops: put not O(1) in N? put@2k={put_2k} put@20k={put_20k}"
        )
        # same_orbit recomputes the M24 orbit relation; it must cost more than a get.
        assert so_20k > get_20k, (
            f"arena_ops: same_orbit (M24 work) not heavier than get? so={so_20k} get={get_20k}"
        )
    if name == "ds_ops":
        cons_10k, cons_100k, set_10k, set_100k, add_100k = (
            median[0], median[1], median[2], median[3], median[4])
        assert min(median) > 0, f"ds_ops: a net per-op is <= 0 (baseline not an exact twin)? {median}"
        # cons content-addresses one cell each: roughly O(1) in list length.
        assert cons_100k < max(cons_10k, 1) * 3, (
            f"ds_ops: cons not ~flat in N? cons@10k={cons_10k} cons@100k={cons_100k}"
        )
        # set content-addresses each entry on the chaining heap and probes it back, so it
        # GROWS with the map; add stores inline and stays flat. The growth and the contrast
        # are the point: set must grow with N, and must be heavier than the inline add.
        assert set_100k > set_10k, f"ds_ops: set not growing with map size? @10k={set_10k} @100k={set_100k}"
        assert set_100k > add_100k, (
            f"ds_ops: content-addressed set not heavier than inline add? set={set_100k} add={add_100k}"
        )
    if name == "heap_expand":
        d_100k, d_1m, s_1m = median[1], median[2], median[3]
        # identical content dedups to one slot, so it must be cheaper than interning
        # distinct content (a fresh slot, and across generations a chained heap).
        assert s_1m < d_1m, f"heap_expand: dedup not cheaper than distinct intern? same={s_1m} distinct={d_1m}"
        # heap expansion is amortized O(1): interning 1M distinct (which chains ~5
        # generations) must not cost dramatically more per item than 100k (one generation).
        assert d_1m < max(d_100k, 1) * 3, (
            f"heap_expand: expansion not amortized O(1)? distinct@100k={d_100k} distinct@1M={d_1m}"
        )

    _results[name] = {"runs": K, "median": median, "all": runs}


def test_zz_write_results():
    """Side effect (runs last): persist the timing medians for the page to render."""
    if not _results:
        pytest.skip("no benchmark results collected")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    json.dump(dict(sorted(_results.items())), open(OUT, "w"), indent=2)
