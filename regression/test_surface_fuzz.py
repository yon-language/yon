"""Conformance gate — surface-level frontend fuzzer.

Builds and runs frontend/test_surface_fuzz.ml: it generates Yon SOURCE programs
(grammar-guided + corpus mutation + token salad) and runs the REAL frontend
pipeline (lex -> parse -> tycheck -> infer_place_worlds -> desugar -> type_erase
-> emit), asserting the robustness invariant:

    the frontend TERMINATES and either ACCEPTS (emits MLIR) or REJECTS CLEANLY
    (a parse/lex error, a tycheck diagnostic, an intended compile-time rejection).
    It NEVER CRASHES. In particular, once tycheck has ACCEPTED a program the later
    stages must lower without raising -- an accepted program that fails to lower is
    a broken tycheck->emit contract (the produce-= / nested-Lambda / type-as-value
    bug class).

A non-zero BUGS count is a real frontend bug the fuzzer caught: a stray character
that Fatal-crashes instead of a clean diagnostic, or an accepted-then-Fatal. This
gate keeps the tycheck->emit contract from silently regressing. Exit 0 == zero
crashes across the seeds below.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "frontend"
EXE = FRONTEND / "_build" / "default" / "test_surface_fuzz.exe"

SEEDS = ["20260701", "1", "42"]
CASES = "4000"


@pytest.mark.stretchable
@pytest.mark.skipif(not (FRONTEND / "dune").exists(), reason="frontend not present")
def test_surface_fuzz_no_crashes(stretch):
    try:
        subprocess.run(["dune", "build", "./test_surface_fuzz.exe"],
                       cwd=FRONTEND, capture_output=True, timeout=600)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    if not EXE.exists():
        pytest.skip("exe not built (cd frontend && dune build ./test_surface_fuzz.exe)")
    cases = str(max(1, int(int(CASES) * stretch)))
    per_seed_timeout = int(300 * max(1.0, stretch))
    for seed in SEEDS:
        r = subprocess.run([str(EXE), seed, cases],
                           capture_output=True, text=True, timeout=per_seed_timeout)
        assert r.returncode == 0, (
            f"surface fuzzer found a frontend crash (seed {seed}):\n{r.stdout}\n{r.stderr[-400:]}")
        assert "BUGS=0" in r.stdout, f"surface fuzzer found a crash (seed {seed}):\n{r.stdout}"
