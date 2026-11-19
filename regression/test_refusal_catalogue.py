"""The catalogue of refusals and the refusal proofs agree, both ways (regression/refusals/catalogue.py).

Every entry has its proof (a reject_clean folder of regression/canonical_forms/ with the code of the
entry, or the code its proof gives until its step aligns it), a draft, or the reason its proof cannot
be written yet; every reject_clean folder belongs to an entry; every code of an entry is registered in
frontend/error_codes.ml; CATALOGUE.md and the drafts are current.
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
CAT = ROOT / "regression" / "refusals" / "catalogue.py"


@pytest.fixture
def cat():
    spec = importlib.util.spec_from_file_location("refusal_catalogue", CAT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_the_catalogue_and_its_proofs_match():
    r = subprocess.run([sys.executable, str(CAT), "--check"], capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, (r.stdout + r.stderr).strip()


def test_an_unregistered_code_is_a_problem(cat):
    bad = "E2999"
    cat.ENTRIES[0]["code"] = bad
    problems = cat.check_proofs(cat.error_codes())
    assert any(bad in p and "not registered" in p for p in problems), problems


def test_a_refusal_proof_without_entry_is_a_problem(cat):
    owner = next(e for e in cat.ENTRIES if e["proofs"])
    owner["proofs"] = []
    owner["proof_pending"] = "removed by the test"
    problems = cat.check_proofs(cat.error_codes())
    assert any("belongs to no entry" in p for p in problems), problems


def test_an_entry_without_proof_is_a_problem(cat):
    e = next(e for e in cat.ENTRIES if "draft" in e)
    del e["draft"]
    problems = cat.check_proofs(cat.error_codes())
    assert any(e["id"] in p and "no proof" in p for p in problems), problems
