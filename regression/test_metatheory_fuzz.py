"""Conformance gate — kernel operational-semantics fuzzer (ladder items 4 + 5).

Runs frontend/test_metatheory_fuzz.ml, the property-based / differential tester
over the kernel reducer (core via Reduce.step, cubical via the Cubical engine bridge):

  P1  no-stuck for the CORE        — Progress / SN, the empirical complement of the SN proof
  P3  determinism / confluence     — order-stability of the normal form
  P2  the cubical O2 hunt          — known-open canonicity gap, reported not failed

The exe exits 1 ONLY on a CORE stuck/timeout or a confluence mismatch — a real soundness
regression. Cubical stucks are the recorded-open O2 (metatheory.md), reported, not failed.
This makes core soundness a standing CI guard.

The fixed seed keeps the gate reproducible; one more node runs a ROTATING seed (the
date, or YON_FUZZ_SEED when set), named in its failure message. The executable is
built once by gate.sh tier 0, never here: a missing one fails.
"""
import datetime
import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "frontend" / "_build" / "default" / "test_metatheory_fuzz.exe"
DEPTH = "4"


def rotating_seed():
    """YON_FUZZ_SEED if set, else today's date as YYYYMMDD."""
    env = os.environ.get("YON_FUZZ_SEED")
    return env if env else datetime.date.today().strftime("%Y%m%d")


def _fuzz(seed, scale):
    assert EXE.exists(), f"{EXE} is missing: build first (dune build --root frontend)"
    where = f"seed {seed} (reproduce: YON_FUZZ_SEED={seed}, or {EXE.name} {seed} {DEPTH} {scale})"
    try:
        r = subprocess.run([str(EXE), seed, DEPTH, str(scale)],
                           capture_output=True, text=True, timeout=int(300 * scale))
    except subprocess.TimeoutExpired:
        pytest.fail(f"metatheory fuzzer did not finish within {300 * scale} s, {where}")
    out = r.stdout

    # exit 0 == no CORE stuck/timeout and no confluence mismatch
    assert r.returncode == 0, (
        f"core soundness / confluence VIOLATED, {where}:\n{out}\n{r.stderr[-400:]}")

    # belt and suspenders: the P1 core line must be clean, and must have run terms
    p1 = next((l for l in out.splitlines() if l.startswith("P1 core")), "")
    # (\b: a bare substring test would read "10 STUCK" as clean)
    assert re.search(r"\b0 STUCK\b", p1) and re.search(r"\b0 timeout\b", p1), (
        f"P1 core not clean, {where}:\n{p1}\n{out}")
    m = re.search(r"\(n=(\d+)\)", p1)
    assert m and int(m.group(1)) > 0, f"P1 core ran no terms, {where}:\n{out}"


@pytest.mark.stretchable
def test_core_soundness_fuzz(stretch):
    _fuzz("20260701", max(1, int(stretch)))


@pytest.mark.stretchable
def test_core_soundness_fuzz_rotating_seed(stretch):
    _fuzz(rotating_seed(), max(1, int(stretch)))
