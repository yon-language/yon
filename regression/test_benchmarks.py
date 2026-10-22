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
      (equality is O(1) in size; XSet set-algebra beats HashSet), and
  (4) the runtime never reports a capacity failure while the bench runs (a
      "pool exhausted" / "directory full" line on stderr means the operation
      being timed failed, and its timing measures the failure path).

The per-position median across K runs is the source the benchmarks page renders
from (website/src/data/bench-raw.json), but a test run never writes it: timings are
machine- and load-dependent, and the suite runs alongside other work. Publishing is
an explicit act, on a quiet machine:
  pytest regression/test_benchmarks.py --bench-publish   (BENCH_K changes the run count)
"""

import hashlib
import json
import os
import re
import statistics
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
BENCH = ROOT / "regression" / "bench"
OUT = ROOT / "website" / "src" / "data" / "bench-raw.json"
K = int(os.environ.get("BENCH_K", "3"))


def _digest(path: Path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


# The site's data as it stood before this module ran: the suite must leave it so.
_OUT_BEFORE = _digest(OUT)

# bench -> [(output_index, expected_value)] : correctness guards that MUST hold,
# at the full size (the gate checks them at a small one: test_bench_correct).
from _bench_guards import guards  # noqa: E402
GUARDS = guards(1)

BENCHES = sorted(p.name for p in BENCH.iterdir() if p.is_dir()) if BENCH.exists() else []
_results = {}

# A runtime diagnostic that says an operation did not happen (a pool, arena,
# directory or table ran out, an allocation or a lock failed). The runtime
# prints these and carries on with a sentinel, so the exit code stays 0.
_RT_FAILURE = re.compile(
    r"^\[YON-[^\]]*\][^\n]*\b(?:exhausted|full|FULL|overflow|failed|FATAL|out of range)\b",
    re.MULTILINE)


class RuntimeCapacityError(AssertionError):
    """A bench ran into a runtime capacity limit (see _RT_FAILURE). Its own
    type so a known capacity defect can be xfail'd with `raises=` without
    absorbing a compile, exit-code, guard or property failure."""


# A bench that runs into a known runtime capacity limit is xfail'd here, strict
# and narrowed to RuntimeCapacityError, so no other failure hides behind it.
# None: the HashSet is a persistent trie with no directory to exhaust.
_CAPACITY_XFAIL = {}

# Benchmarks measured but NOT published: their numbers would say something
# false. The page says so in place of the chart (book ch. 93). An entry belongs
# here only while its numbers do not measure what they claim to.
WITHDRAWN = {
    "xset_scaling": "its published HashSet timings do not measure the "
                    "persistent HashSet",
}


def _bench_params():
    out = []
    for b in BENCHES:
        marks = ()
        if b in _CAPACITY_XFAIL:
            marks = pytest.mark.xfail(strict=True, raises=RuntimeCapacityError,
                                      reason=_CAPACITY_XFAIL[b])
        out.append(pytest.param(b, marks=marks, id=b))
    return out


def _ints(s):
    return [int(t) for t in s.split() if t.lstrip("-").isdigit()]


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
@pytest.mark.parametrize("name", _bench_params())
def test_benchmark(name, tmp_path):
    binp = tmp_path / name
    comp = subprocess.run(
        [str(YONC), str(BENCH / name), "-o", str(binp)],
        capture_output=True, timeout=240,
    )
    assert comp.returncode == 0, (
        f"{name}: compile failed (returncode={comp.returncode})\n"
        f"--- stderr ---\n{comp.stderr.decode(errors='replace')[-4000:]}\n"
        f"--- stdout ---\n{comp.stdout.decode(errors='replace')[-1000:]}"
    )
    runs = []
    rt_failures = []
    for _ in range(K):
        r = subprocess.run([str(binp)], capture_output=True, timeout=180)
        assert r.returncode == 0, (
            f"{name}: the bench binary exited {r.returncode}, expected 0\n"
            f"--- stderr ---\n{r.stderr.decode(errors='replace')[-2000:]}")
        nums = _ints(r.stdout.decode(errors="replace"))
        assert nums, f"{name}: produced no numeric output"
        runs.append(nums)
        rt_failures += _RT_FAILURE.findall(r.stderr.decode(errors="replace"))
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
        # The address-compare's true cost is ~0 ns/call, so BOTH nets are timer
        # jitter (tens of us, sometimes negative): a purely multiplicative bound
        # divides noise by noise and flakes. The absolute floor is the real
        # separator — a genuine O(N) compare at 32KB is ~1 us/call = 1e9 ns per
        # 1e6 calls, 50x the floor; observed jitter stays 20x below it.
        NOISE_FLOOR_NS = 20_000_000  # 20 ms per 1e6 calls = 20 ns/call
        assert net_32k <= max(max(net_1, 1) * 8, NOISE_FLOOR_NS), (
            f"eq_constant: equality not O(1) in size? net(1)={net_1} net(32768)={net_32k}\n"
            f"raw runs={runs}"
        )
    if name == "xset_scaling":
        # 4 groups (N = 100, 1000, 10000, 100000) of
        #   xset_inter  hash_inter  xset_union  hash_union   (ns per op)
        assert len(median) == 16 and min(median) > 0, (
            f"xset_scaling: expected 16 positive timings, got {median}")
        g = [median[4 * i:4 * i + 4] for i in range(4)]
        xi100, hi100 = g[0][0], g[0][1]
        xi10k, hi10k = g[2][0], g[2][1]
        # the point of the bench: XSet algebra is a fixed-width AND/OR, flat in
        # N, while HashSet's is O(N). Compared at N=100 vs 10000 (the N=100000
        # group is the capacity defect above). A 100x larger N: XSet stays
        # within 3x (plus a 20 us floor for timer noise on a ~5 us op), HashSet
        # grows more than 5x (measured ~45x), and XSet wins at 10000.
        assert xi10k <= max(xi100 * 3, xi100 + 20_000), (
            f"xset_scaling: XSet intersect not flat in N? @100={xi100} @10000={xi10k}")
        assert hi10k > hi100 * 5, (
            f"xset_scaling: HashSet intersect not growing with N? @100={hi100} @10000={hi10k}")
        assert xi10k < hi10k, (
            f"xset_scaling: XSet intersect not faster at N=10000? xset={xi10k} hash={hi10k}")
    if name == "xset":
        xset_inter, hash_inter = median[2], median[4]
        # the bit-parallel intersect must beat the O(N) hash intersect.
        assert xset_inter < hash_inter, (
            f"xset: bit-parallel intersect not faster than hash? xset={xset_inter} hash={hash_inter}"
        )
    if name == "xrel_ops":
        put_2k, put_20k = median[0], median[3]
        # the exact-twin nets must all be positive (twin mirrors the op; a <=0 net
        # would mean the baseline does not mirror it, the bug that hid the put cost).
        assert min(median) > 0, f"xrel_ops: a net per-op is <= 0 (baseline not an exact twin)? {median}"
        # XRelMap.set on a LatticePoint key copies at most 18 nodes (the route of a
        # point is its 18-bit index): a 10x larger N must not cost meaningfully more.
        assert put_20k <= max(put_2k, 1) * 3, (
            f"xrel_ops: set not bounded in N? set@2k={put_2k} set@20k={put_20k}"
        )
    if name == "ds_ops":
        cons_10k, cons_100k, set_10k, set_100k, add_100k = (
            median[0], median[1], median[2], median[3], median[4])
        assert min(median) > 0, f"ds_ops: a net per-op is <= 0 (baseline not an exact twin)? {median}"
        # cons content-addresses one cell each: roughly O(1) in list length.
        assert cons_100k < max(cons_10k, 1) * 3, (
            f"ds_ops: cons not ~flat in N? cons@10k={cons_10k} cons@100k={cons_100k}"
        )
        # a set copies the path to its key in a hash trie, one node per level, so
        # it GROWS (logarithmically) with the map. HashSet.add is the same trie:
        # there is no inline store to contrast it with.
        assert set_100k > set_10k, f"ds_ops: set not growing with map size? @10k={set_10k} @100k={set_100k}"
        _ = add_100k
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

    # (4) last, so every other check above has already run on this bench
    if rt_failures:
        counts = {m: rt_failures.count(m) for m in sorted(set(rt_failures))}
        raise RuntimeCapacityError(
            f"{name}: the runtime reported failed operations while the bench ran "
            f"(its timings measure the failure path): {counts}")


def test_zz_write_results(pytestconfig):
    """Explicit publication only (--bench-publish): persist the medians for the
    page, and check what was published. A publication holds every benchmark
    except the WITHDRAWN ones, all measured in THIS process: under xdist
    each worker sees only its own share of _results, and a partial file would
    silently drop rows from the page. The file is read back and must parse to
    exactly what was measured."""
    if not pytestconfig.getoption("--bench-publish"):
        pytest.skip("site data is written only with --bench-publish")
    published_set = sorted(set(BENCHES) - set(WITHDRAWN))
    missing = sorted(set(published_set) - set(_results))
    assert not missing, (
        f"--bench-publish: no result for {missing} in this process (run it alone, "
        f"without -n, and with every benchmark passing); nothing written")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w") as f:
        json.dump({k: _results[k] for k in published_set}, f, indent=2)
    with open(OUT) as f:
        published = json.load(f)
    assert sorted(published) == published_set, (
        f"{OUT}: published {sorted(published)}, expected {published_set}")
    assert not set(published) & set(WITHDRAWN), f"{OUT}: a withdrawn benchmark was published"
    for name, row in published.items():
        assert row["median"] == _results[name]["median"] and row["runs"] == K, (
            f"{OUT}: {name} does not read back as measured: {row}")
        assert len(row["all"]) == K, f"{OUT}: {name} has {len(row['all'])} runs, expected {K}"


def test_zzz_site_data_untouched(pytestconfig):
    """The suite never writes the site: bench-raw.json changes only on an explicit
    --bench-publish run (the book: timings are measured, not re-derived each build)."""
    if pytestconfig.getoption("--bench-publish"):
        pytest.skip("--bench-publish: this run is the explicit publication")
    assert _digest(OUT) == _OUT_BEFORE, f"{OUT} was rewritten by a plain test run"


BOOK_PAGE = ROOT / "website" / "docs" / "book" / "93-benchmarks.mdx"


@pytest.mark.parametrize("name", sorted(WITHDRAWN))
def test_withdrawn_benchmark_is_not_on_the_site(name):
    """A withdrawn benchmark is absent from the published data, and the page
    says it is withdrawn, where its numbers were."""
    with open(OUT) as f:
        assert name not in json.load(f), f"{OUT} still publishes {name}"
    page = BOOK_PAGE.read_text()
    assert f"regression/bench/{name}" in page and "withdrawn" in page.lower(), (
        f"{BOOK_PAGE.name} does not say that {name} is withdrawn")
