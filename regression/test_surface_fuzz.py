"""Conformance gate — surface-level frontend fuzzer.

Runs frontend/test_surface_fuzz.ml: it generates Yon SOURCE programs
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

The fixed seeds keep the gate reproducible; one more node runs a ROTATING seed
(the date, or YON_FUZZ_SEED when set) so the suite keeps exploring new inputs.
Its failure message names the seed: rerun with YON_FUZZ_SEED=<seed> to reproduce.
The executable is built once by gate.sh tier 0, never here: a missing one fails.
"""
import datetime
import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "frontend" / "_build" / "default" / "test_surface_fuzz.exe"

SEEDS = ["20260701", "1", "42"]
CASES = "4000"
# accepted share of the cases: measured 2026-10-10 at 2.6-2.8% on the fixed seeds
# (106-111 of 4000). The accept-then-lower contract is only exercised by accepted
# programs, so a generator that drifts to rejection-only would make this gate vacuous.
MIN_ACCEPT_SHARE = 0.01


def rotating_seed():
    """YON_FUZZ_SEED if set, else today's date as YYYYMMDD."""
    env = os.environ.get("YON_FUZZ_SEED")
    return env if env else datetime.date.today().strftime("%Y%m%d")


def _fuzz(seed, cases, timeout):
    assert EXE.exists(), f"{EXE} is missing: build first (dune build --root frontend)"
    try:
        r = subprocess.run([str(EXE), seed, cases], capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        pytest.fail(f"surface fuzzer did not finish within {timeout} s "
                    f"(reproduce: YON_FUZZ_SEED={seed}, {cases} cases)")
    where = f"seed {seed} (reproduce: YON_FUZZ_SEED={seed}, {cases} cases)"
    assert r.returncode == 0, (
        f"surface fuzzer found a frontend crash, {where}:\n{r.stdout}\n{r.stderr[-400:]}")
    m = re.search(r"accept=(\d+) reject=(\d+) BUGS=(\d+)", r.stdout)
    assert m and m.group(3) == "0", f"surface fuzzer found a crash, {where}:\n{r.stdout}"
    acc = int(m.group(1))
    assert acc >= int(MIN_ACCEPT_SHARE * int(cases)), (
        f"only {acc} of {cases} generated programs were accepted, {where}: the "
        "generator has drifted from the language and no longer reaches the "
        f"accept-then-lower path.\n{r.stdout}")


@pytest.mark.stretchable
def test_surface_fuzz_no_crashes(stretch):
    cases = str(max(1, int(int(CASES) * stretch)))
    per_seed_timeout = int(300 * max(1.0, stretch))
    for seed in SEEDS:
        _fuzz(seed, cases, per_seed_timeout)


@pytest.mark.stretchable
def test_surface_fuzz_rotating_seed(stretch):
    cases = str(max(1, int(int(CASES) * stretch)))
    _fuzz(rotating_seed(), cases, int(300 * max(1.0, stretch)))
