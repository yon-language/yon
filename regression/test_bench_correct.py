"""The benchmarks compute what they claim: checked on a small run, every gate.

The measurements (regression/test_benchmarks.py, regression/bench_perf,
marked `bench`) run on their own, in the measurement tier of gate.sh, on a
quiet machine. What the gate keeps is this: every benchmark still compiles,
runs, and produces its guard values, on a run whose work is divided by
YON_BENCH_DIV (regression/_bench_guards.py gives the guards at that size);
every perf program, on a twin whose loop runs TWIN_N times, prints its
checksum. No timing is asserted here.
"""
import importlib.util
import os
import re
import subprocess
from pathlib import Path

import pytest

from _bench_guards import guards

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
BENCH = ROOT / "regression" / "bench"
PERF = ROOT / "regression" / "bench_perf"
DIV = 100

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_RT_FAILURE = re.compile(
    r"^\[YON-[^\]]*\][^\n]*\b(?:exhausted|full|FULL|overflow|failed|FATAL|out of range)\b",
    re.MULTILINE)

BENCHES = sorted(p.name for p in BENCH.iterdir() if p.is_dir())


def _ints(s):
    return [int(t) for t in s.split() if t.lstrip("-").isdigit()]


@pytest.mark.parametrize("name", BENCHES)
def test_benchmark_computes_its_guards(name, tmp_path):
    binp = tmp_path / name
    c = subprocess.run([str(YONC), str(BENCH / name), "-o", str(binp)],
                       capture_output=True, timeout=240)
    assert c.returncode == 0, c.stderr.decode(errors="replace")[-2000:]
    r = subprocess.run([str(binp)], capture_output=True, timeout=180,
                       env=dict(os.environ, YON_BENCH_DIV=str(DIV)))
    err = r.stderr.decode(errors="replace")
    assert r.returncode == 0, err[-2000:]
    nums = _ints(r.stdout.decode(errors="replace"))
    assert nums, f"{name}: printed no numbers"
    for idx, want in guards(DIV).get(name, []):
        assert nums[idx] == want, f"{name}: guard[{idx}] = {nums[idx]}, expected {want}: {nums}"
    assert not _RT_FAILURE.findall(err), f"{name}: the runtime reported a failed operation"


def _perf():
    spec = importlib.util.spec_from_file_location("perf_programs", PERF / "test_perf.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_P = _perf()


@pytest.mark.parametrize("prog", _P.PROGRAMS)
def test_perf_program_prints_its_checksum(prog, tmp_path):
    src = PERF / prog
    loops = _P._ITER.findall((src / "Entry.yon").read_text())
    assert len(loops) == 1, f"{prog}: expected one `iter <N> do` loop, found {loops}"
    twin = tmp_path / "twin"
    twin.mkdir()
    for f in src.iterdir():
        if f.is_file():
            text = f.read_text()
            (twin / f.name).write_text(
                _P._ITER.sub(f"iter {_P.TWIN_N} do", text) if f.name == "Entry.yon" else text)
    got = _P._compile_run(twin, tmp_path / prog)
    assert got == _P._expected(prog, _P.TWIN_N), (
        f"{prog}: the twin (loop count {_P.TWIN_N}) printed {got}, "
        f"expected {_P._expected(prog, _P.TWIN_N)}")
