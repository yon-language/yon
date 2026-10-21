"""Conformance gate — independent second checker (de Bruijn criterion).

Runs frontend/test_kernel_independent.ml: a self-contained reducer for the proved-sound
core (own substitution, own small-step, own alpha-equality — calling neither Reduce nor Subst nor
Ast.term_equal) differentially checked against the main kernel on generated closed core terms. The
two normal forms must be alpha-equal on every term. A disagreement is a bug in one reducer that a
single audited kernel could not catch — exactly what the de Bruijn second checker exists to expose.
Exit 0 == the independent checker agrees with the kernel on the whole run.

The executable seeds itself (Random.init 20260701) and takes no seed argument, so this
gate has no rotating-seed node. It is built once by gate.sh tier 0, never here: a
missing executable fails.
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "frontend" / "_build" / "default" / "test_kernel_independent.exe"


def test_independent_checker_agrees_with_kernel():
    assert EXE.exists(), f"{EXE} is missing: build first (dune build --root frontend)"
    try:
        r = subprocess.run([str(EXE)], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        pytest.fail(f"{EXE.name} did not finish within 300 s")
    # exit 0 == independent reduction agrees with the kernel AND the independent type-checker
    # confirms Progress (no stuck) and Preservation (type kept under reduction) on every term
    assert r.returncode == 0, f"independent checker disagrees with the kernel:\n{r.stdout}\n{r.stderr[-400:]}"
    assert re.search(r"\bDISAGREE 0\b", r.stdout) and re.search(r"\bLOST 0\b", r.stdout), (
        f"a discrepancy was found:\n{r.stdout}")
    # and it did check terms: the preservation tally counts them
    m = re.search(r"type preserved under reduction (\d+)", r.stdout)
    assert m and int(m.group(1)) > 0, f"the independent checker ran no terms:\n{r.stdout}"
