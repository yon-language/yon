"""C runtime line coverage (gcov) as an opt-in gate under pytest.

Heavy and mutating: regression/gcov_c.sh rebuilds the runtime instrumented, runs the
C unit tests linked with --coverage, gcov's, then restores the normal build. Skipped
unless --gcov is passed, so it never runs in the default inner loop.

    pytest regression/test_c_coverage.py --gcov

Asserts a per-module floor (unit layer, measured 2026-07-15). A module below its floor
is a coverage regression; a deliberate drop lands with a lowered floor plus a rationale
in AUDIT.md. Layer/kind/speed are assigned centrally in conftest: c / unit / slow.
"""
import re
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent / "gcov_c.sh"

# per-module line-coverage floors (unit layer, gcov, vendor excluded). yon_rt.c is
# low here because its execution paths are integration-covered (corpus binaries run
# the runtime), not unit-covered; see AUDIT.md.
FLOORS = {
    "yon_rt.c": 30.0,
    "xleech2_heap.c": 55.0,
    "xleech2_mphf.c": 90.0,
    "xleech2_coord.c": 95.0,
    "yon_arena.c": 90.0,
    "leech_orbits.c": 90.0,
    "yon_mmap.c": 70.0,
}


def test_c_runtime_coverage_floor(request):
    if not request.config.getoption("--gcov"):
        pytest.skip("C gcov is opt-in and mutates the runtime build; pass --gcov")
    r = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, timeout=900)
    cov = {f: float(p) for f, p in re.findall(r"COV (\S+) ([\d.]+)", r.stdout)}
    assert cov, f"gcov produced no coverage:\n{r.stdout}\n{r.stderr[-1500:]}"
    below = {f: (cov.get(f, 0.0), fl) for f, fl in FLOORS.items() if cov.get(f, 0.0) < fl}
    assert not below, f"C coverage below floor (got, floor): {below}\nfull: {cov}"
