"""Conformance gate — kernel operational-semantics fuzzer (ladder items 4 + 5).

Builds and runs frontend/test_metatheory_fuzz.ml, the property-based / differential tester
over the kernel reducer (core via Reduce.step, cubical via the Cubical engine bridge):

  P1  no-stuck for the CORE        — Progress / SN, the empirical complement of the SN proof
  P3  determinism / confluence     — order-stability of the normal form
  P2  the cubical O2 hunt          — known-open canonicity gap, reported not failed

The exe exits 1 ONLY on a CORE stuck/timeout or a confluence mismatch — a real soundness
regression. Cubical stucks are the recorded-open O2 (metatheory.md), reported, not failed.
This makes core soundness a standing CI guard.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FRONTEND = ROOT / "frontend"
EXE = FRONTEND / "_build" / "default" / "test_metatheory_fuzz.exe"


@pytest.mark.skipif(not (FRONTEND / "dune").exists(), reason="frontend not present")
def test_core_soundness_fuzz():
    # build (best-effort); skip cleanly if the OCaml toolchain is unavailable here
    try:
        subprocess.run(["dune", "build", "./test_metatheory_fuzz.exe"],
                       cwd=FRONTEND, capture_output=True, timeout=600)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    if not EXE.exists():
        pytest.skip("fuzzer exe not built (run: cd frontend && dune build ./test_metatheory_fuzz.exe)")

    r = subprocess.run([str(EXE)], capture_output=True, text=True, timeout=300)
    out = r.stdout

    # exit 0 == no CORE stuck/timeout and no confluence mismatch
    assert r.returncode == 0, f"core soundness / confluence VIOLATED:\n{out}\n{r.stderr[-400:]}"

    # belt and suspenders: the P1 core line must be clean
    p1 = next((l for l in out.splitlines() if l.startswith("P1 core")), "")
    assert "0 STUCK" in p1 and "0 timeout" in p1, f"P1 core not clean:\n{p1}\n{out}"
