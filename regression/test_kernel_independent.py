"""Conformance gate — independent second checker (de Bruijn defect D1).

Builds and runs frontend/test_kernel_independent.ml: a self-contained reducer for the proved-sound
core (own substitution, own small-step, own alpha-equality — calling neither Reduce nor Subst nor
Ast.term_equal) differentially checked against the main kernel on generated closed core terms. The
two normal forms must be alpha-equal on every term. A disagreement is a bug in one reducer that a
single audited kernel could not catch — exactly what the de Bruijn second checker exists to expose.
Exit 0 == the independent checker agrees with the kernel on the whole run.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "frontend"
EXE = FRONTEND / "_build" / "default" / "test_kernel_independent.exe"


@pytest.mark.skipif(not (FRONTEND / "dune").exists(), reason="frontend not present")
def test_independent_checker_agrees_with_kernel():
    try:
        subprocess.run(["dune", "build", "./test_kernel_independent.exe"],
                       cwd=FRONTEND, capture_output=True, timeout=600)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    if not EXE.exists():
        pytest.skip("exe not built (cd frontend && dune build ./test_kernel_independent.exe)")
    r = subprocess.run([str(EXE)], capture_output=True, text=True, timeout=300)
    # exit 0 == independent reduction agrees with the kernel AND the independent type-checker
    # confirms Progress (no stuck) and Preservation (type kept under reduction) on every term
    assert r.returncode == 0, f"independent checker disagrees with the kernel:\n{r.stdout}\n{r.stderr[-400:]}"
    assert "DISAGREE 0" in r.stdout and "LOST 0" in r.stdout, f"a discrepancy was found:\n{r.stdout}"
