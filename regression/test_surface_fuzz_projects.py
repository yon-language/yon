"""Conformance gate — project-level surface fuzzer.

Runs regression/surface_fuzz_projects.py: it generates whole Yon PROJECTS (yon.toml
worlds, space directories, place files, `Topos.yon`, and the seven arrows) plus
malformed variants, and runs the real project pipeline (`yoner_emit_mlir <projdir>`),
asserting the frontend never CRASHES: it accepts (emits) or rejects cleanly (parse /
type / manifest / layout diagnostic), but never a Fatal uncaught exception, signal, or
hang. This is the multi-file / filesystem / arrow surface that the in-process
test_surface_fuzz.ml (single-file inline programs) cannot reach.

A non-zero BUGS count is a real frontend crash on a project. Exit 0 == zero crashes.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FUZZ = ROOT / "regression" / "surface_fuzz_projects.py"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

SEEDS = ["20260701", "1"]
CASES = "500"


@pytest.mark.stretchable
@pytest.mark.skipif(not (ROOT / "frontend" / "dune").exists(), reason="frontend not present")
def test_project_fuzz_no_crashes(stretch):
    try:
        subprocess.run(["dune", "build", "./yoner_emit_mlir.exe"],
                       cwd=ROOT / "frontend", capture_output=True, timeout=600)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    if not EMIT.exists():
        pytest.skip("emit exe not built (cd frontend && dune build ./yoner_emit_mlir.exe)")
    cases = str(max(1, int(int(CASES) * stretch)))
    per_seed_timeout = int(600 * max(1.0, stretch))
    for seed in SEEDS:
        r = subprocess.run(["python3", str(FUZZ), seed, cases],
                           capture_output=True, text=True, timeout=per_seed_timeout)
        assert r.returncode == 0, (
            f"project fuzzer found a frontend crash (seed {seed}):\n{r.stdout[-3000:]}\n{r.stderr[-400:]}")
        assert "BUGS=0" in r.stdout, f"project fuzzer found a crash (seed {seed}):\n{r.stdout[-3000:]}"
