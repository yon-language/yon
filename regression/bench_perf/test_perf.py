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
benches whose result guards are asserted every build). Before timing, this file checks
that each perf program computes what it claims: every program sums a known per-op
value over its loop and prints the total, so the total has a known value (CHECKSUM).

Run:  .venv/bin/python -m pytest regression/bench_perf/test_perf.py \
          --benchmark-json=/tmp/perf.json --benchmark-min-rounds=10 -q
Then: python regression/bench_perf/summarize.py /tmp/perf.json
"""
import re
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
    # NOTE: the Arena ops (put, get, the orbit comparison) are NOT measured here.
    # Their loops make a lattice point to address the slot, which the shared baselines
    # do not, so (op - base) leaves that cost in instead of subtracting it; and the
    # first point/Arena.put pays a one-time ~200 ms mmgroup table init that, at the
    # small N an arena allows (196,560 slots), dominates the subprocess median and a
    # non-twin baseline cannot remove. They are measured in-process with an EXACT twin
    # (the same point made the same way) + min-over-reps in regression/bench/arena_ops.
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

# What each program prints, read off its source: ("sum", v) = the loop adds the
# per-op value v each iteration and prints the total, N * v; ("count", None) =
# it prints the size of what the loop built (or the counter), N.
#   v = 1445: the payload the program stores and reads back (Vec.get, List.head,
#             HashMap.get, MerkleTree.label of node2(1445, ...)), or the data
#             word VoyagerList.open recovers from a codeword with 2 bit errors;
#   v = 7:    equality_big adds 7 per String.equal(big, big);
#   v = 1:    an equality/lookup that holds adds 1;
#   golay_seal: VoyagerList.seal(1445), the extended-Golay codeword of 1445.
# Pinned as measured; a sanity anchor independent of the encoder basis: it is 24
# bits wide with Hamming weight 12, a weight extended-Golay codewords can have
# (0, 8, 12, 16, 24).
GOLAY_SEAL_1445 = 0xD4D4B2   # = 13948082
CHECKSUM = {
    "_read_base": ("count", None), "_thru_base": ("count", None),
    "equality": ("sum", 1), "merkle_equal": ("sum", 1), "hashset_lookup": ("sum", 1),
    "equality_big": ("sum", 7),
    "golay_open": ("sum", 1445), "vec_get": ("sum", 1445), "list_head": ("sum", 1445),
    "hashmap_get": ("sum", 1445), "merkle_construct": ("sum", 1445),
    "golay_seal": ("sum", GOLAY_SEAL_1445),
    "vec_push": ("count", None), "hashset_insert": ("count", None),
}
# String.from_int converts through a C `int`, so a total above 2**31 - 1 does not
# print as itself (it saturates on arm64). Five timed programs overflow that
# (10_000_000 * 1445): for them the exact checksum is taken on a TWIN, the same
# source with the loop count replaced by TWIN_N, small enough to print exactly.
INT32_MAX = 2**31 - 1
TWIN_N = 100
_ITER = re.compile(r"\biter (\d+) do\b")


def _expected(prog, n):
    kind, v = CHECKSUM[prog]
    return n if kind == "count" else n * v


def _compile_run(src_dir, binp):
    c = subprocess.run([str(YONC), str(src_dir), "-o", str(binp)],
                       capture_output=True, timeout=240)
    assert c.returncode == 0, f"{src_dir.name}: compile failed\n{c.stderr.decode(errors='replace')[-300:]}"
    run = subprocess.run([str(binp)], capture_output=True, timeout=180)
    assert run.returncode == 0, f"{binp.name}: exited {run.returncode}, expected 0"
    toks = run.stdout.split()
    assert toks, f"{binp.name}: printed nothing"
    return int(toks[-1])


def _check_program(prog, src_dir, binp, twin_dir):
    """Run the timed program and check its checksum; when its total cannot
    print exactly, check the TWIN's instead. Returns nothing; fails the node."""
    src = (src_dir / "Entry.yon").read_text()
    loops = _ITER.findall(src)
    assert len(loops) == 1, f"{prog}: expected exactly one `iter <N> do` loop, found {loops}"
    n = int(loops[0])
    assert n == (BASE_N[prog] if prog in BASE_N else OPS[prog][1]), (
        f"{prog}: the source loops {n} times, the per-op arithmetic assumes "
        f"{BASE_N.get(prog) or OPS[prog][1]}")
    got = _compile_run(src_dir, binp)
    want = _expected(prog, n)
    if want <= INT32_MAX:
        assert got == want, f"{prog}: printed {got}, expected {want} ({CHECKSUM[prog]} over {n})"
        return
    twin_dir.mkdir()
    for f in src_dir.iterdir():
        if f.is_file():
            text = f.read_text()
            (twin_dir / f.name).write_text(
                _ITER.sub(f"iter {TWIN_N} do", text) if f.name == "Entry.yon" else text)
    got = _compile_run(twin_dir, binp.with_name(binp.name + "_twin"))
    want = _expected(prog, TWIN_N)
    assert got == want, (
        f"{prog}: the twin (loop count {TWIN_N}) printed {got}, expected {want}")


@pytest.fixture(scope="session")
def bins(tmp_path_factory):
    out = {}
    tmp = tmp_path_factory.mktemp("bench_perf")
    for p in PROGRAMS:
        b = tmp / f"bp_{p}"
        _check_program(p, HERE / p, b, tmp / f"twin_{p}")
        out[p] = str(b)
    return out


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
@pytest.mark.parametrize("prog", PROGRAMS, ids=lambda p: p)
def test_perf(benchmark, bins, prog):
    binp = bins[prog]
    benchmark(lambda: subprocess.run([binp], capture_output=True))
