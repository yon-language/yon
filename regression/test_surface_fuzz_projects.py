"""Conformance gate — project-level surface fuzzer.

Runs regression/surface_fuzz_projects.py: it generates whole Yon PROJECTS (yon.toml
worlds, space directories, place files, `Topos.yon`, and the arrows declared in the
body of the place they touch) plus malformed variants, and runs the real project
pipeline (`yoner_emit_mlir <projdir>`), asserting the frontend never CRASHES: it
accepts (emits) or rejects cleanly (parse / type / manifest / layout diagnostic),
but never a Fatal uncaught exception, signal, or hang. This is the multi-file /
filesystem / arrow surface that the in-process test_surface_fuzz.ml (single-file
inline programs) cannot reach.

A non-zero BUGS count is a real frontend crash on a project. Exit 0 == zero crashes.

The fixed seeds keep the gate reproducible; one more node runs a ROTATING seed
(the date, or YON_FUZZ_SEED when set), named in its failure message. The frontend
is built once by gate.sh tier 0, never here: a missing executable fails.
"""
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FUZZ = ROOT / "regression" / "surface_fuzz_projects.py"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

SEEDS = ["20260701", "1"]
CASES = "500"
# accepted share of the cases: measured 2026-10-10 at 25-27% on seeds 20260701,
# 1 and 7 (it was 0% before the generator learned `Number` and arrows-in-the-body:
# the gate had been fuzzing the rejection path only). Below the floor, the
# generator has drifted from the language again.
MIN_ACCEPT_SHARE = 0.10


def rotating_seed():
    """YON_FUZZ_SEED if set, else today's date as YYYYMMDD."""
    env = os.environ.get("YON_FUZZ_SEED")
    return env if env else datetime.date.today().strftime("%Y%m%d")


def _fuzz(seed, cases, timeout):
    assert EMIT.exists(), f"{EMIT} is missing: build first (dune build --root frontend)"
    where = f"seed {seed} (reproduce: YON_FUZZ_SEED={seed}, {cases} cases)"
    try:
        r = subprocess.run([sys.executable, str(FUZZ), seed, cases],
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        pytest.fail(f"project fuzzer did not finish within {timeout} s, {where}")
    assert r.returncode == 0, (
        f"project fuzzer found a frontend crash, {where}:\n{r.stdout[-3000:]}\n{r.stderr[-400:]}")
    m = re.search(r"accept=(\d+) reject=(\d+) BUGS=(\d+)", r.stdout)
    assert m and m.group(3) == "0", f"project fuzzer found a crash, {where}:\n{r.stdout[-3000:]}"
    acc = int(m.group(1))
    assert acc >= int(MIN_ACCEPT_SHARE * int(cases)), (
        f"only {acc} of {cases} generated projects were accepted, {where}: the "
        f"generator has drifted from the language.\n{r.stdout[-1500:]}")


@pytest.mark.stretchable
def test_project_fuzz_no_crashes(stretch):
    cases = str(max(1, int(int(CASES) * stretch)))
    per_seed_timeout = int(600 * max(1.0, stretch))
    for seed in SEEDS:
        _fuzz(seed, cases, per_seed_timeout)


@pytest.mark.stretchable
def test_project_fuzz_rotating_seed(stretch):
    cases = str(max(1, int(int(CASES) * stretch)))
    _fuzz(rotating_seed(), cases, int(600 * max(1.0, stretch)))
