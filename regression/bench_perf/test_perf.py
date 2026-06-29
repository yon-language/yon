"""Performance benchmarks, the proper way (pytest-benchmark on the native binaries).

Each operation is two tiny Yon programs: `<op>/` does N of the operation and exits,
and a shared baseline (`_read_base` / `_thru_base`) does the same loop WITHOUT the
operation. pytest-benchmark times each binary over many rounds (warm-up, median, IQR,
machine metadata); the per-op cost is the per-iteration difference:

    per_op = op_median / N_op  -  base_median / N_base

so process startup and loop overhead cancel and different N are handled.

These TIMINGS are machine-dependent: run them on the target machine, read the median
plus the recorded machine_info, and label the page accordingly. The build-invariant
CORRECTNESS gate lives in regression/test_benchmarks.py (the regression/bench/* in-Yon
benches whose result guards are asserted every build); this file only checks each perf
program's loop actually ran (nonzero guard) before timing it.

Run:  .venv/bin/python -m pytest regression/bench_perf/test_perf.py \
          --benchmark-json=/tmp/perf.json --benchmark-min-rounds=10 -q
Then: python regression/bench_perf/summarize.py /tmp/perf.json
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
YONC = ROOT / "toolchain" / "yonc"
HERE = Path(__file__).resolve().parent

# op -> (baseline, N_op)
OPS = {
    "equality": ("_read_base", 10_000_000),
    "merkle_equal": ("_read_base", 10_000_000),
    "golay_seal": ("_read_base", 10_000_000),
    "golay_open": ("_read_base", 10_000_000),
    "vec_get": ("_read_base", 10_000_000),
    "hashset_lookup": ("_read_base", 10_000_000),
    "list_head": ("_read_base", 10_000_000),
    "hashmap_get": ("_read_base", 10_000_000),
    # NOTE: the three Arena ops (put, get, same_orbit) are NOT measured here. Their loops
    # call Leech.point to generate the lattice address, which the shared baselines do not,
    # so (op - base) leaves Leech.point's cost in instead of subtracting it; and the first
    # Leech.point/Arena.put pays a one-time ~200 ms mmgroup table init that, at the small N
    # an arena allows (196,560 slots), dominates the subprocess median and a non-twin
    # baseline cannot remove (it surfaced as a ~31 us per-op artifact for put). They are
    # measured in-process with an EXACT Leech.point twin + min-over-reps in
    # regression/bench/arena_ops (put ~80 ns and O(1) in N, get ~41 ns, same_orbit ~1.1 us).
    "vec_push": ("_thru_base", 1_000_000),
    "hashset_insert": ("_thru_base", 1_000_000),
    # NOTE: list_cons and hashmap_set are NOT measured here. They put on the content-
    # addressed heap, so they pay a one-time g_yon_heap creation (ds_ensure_init ->
    # yon_xheap_create) that the Space-only _thru_base never pays; at the small N a cons
    # list allows (~196,560) that one-time cost smears into the per-op (it inflated cons to
    # ~204 ns). And set GROWS with the map (content-addressing each entry on the chaining
    # heap), which a single-N subprocess number hides. Both are measured in-process with an
    # exact twin at several N in regression/bench/ds_ops (cons ~70 ns flat; set ~130 ns at
    # 10k rising to ~340 ns by 1M; HashSet.add, inline, stays flat as the contrast).
    "merkle_construct": ("_read_base", 1_000_000),
    "equality_big": ("_read_base", 10_000_000),
}
BASE_N = {"_read_base": 10_000_000, "_thru_base": 1_000_000}
PROGRAMS = sorted(set(OPS) | set(BASE_N))


@pytest.fixture(scope="session")
def bins():
    out = {}
    for p in PROGRAMS:
        b = Path("/tmp") / f"bp_{p}"
        c = subprocess.run([str(YONC), str(HERE / p), "-o", str(b)],
                           capture_output=True, timeout=240)
        assert c.returncode == 0, f"{p}: compile failed\n{c.stderr.decode(errors='replace')[-300:]}"
        run = subprocess.run([str(b)], capture_output=True, timeout=180)
        toks = run.stdout.split()
        assert toks and int(toks[-1]) != 0, f"{p}: guard not nonzero (loop elided?)"
        out[p] = str(b)
    return out


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
@pytest.mark.parametrize("prog", PROGRAMS, ids=lambda p: p)
def test_perf(benchmark, bins, prog):
    binp = bins[prog]
    benchmark(lambda: subprocess.run([binp], capture_output=True))
