"""Per-CHECK unit nodes — the true measurable base of the pyramid.

Each OCaml oracle (frontend/_build/default/test_*.exe) prints one `[PASS]` /
`[FAIL]` line per internal assertion and exits 0 iff all pass. The coarse node
in test_yon_pipeline (test_ocaml_oracle) reports one result per *executable*,
which UNDER-counts the unit layer: a single oracle bundles ~10-15 assertions.

This module runs each oracle ONCE (at collection) and emits one pytest node per
`[PASS]/[FAIL]` line, so the unit count reflects assertion granularity. It is the
"program with the right numbers": `pytest -m unit` now measures real unit checks,
not exe-sized buckets.

Layer/kind: ocaml / unit (every oracle is an isolated module-level assertion).
"""

import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ORACLE_DIR = ROOT / "frontend" / "_build" / "default"
_MARK = re.compile(r"\[(PASS|FAIL)\]")

pytestmark = [pytest.mark.ocaml, pytest.mark.unit]


def _collect():
    """Run every oracle once; return (cases, exit_codes).

    cases: list of (stem, idx, name, passed) — one per [PASS]/[FAIL] line.
    exit_codes: {stem: returncode} — for a per-exe 'clean exit' node.
    """
    cases, codes = [], {}
    if not ORACLE_DIR.exists():
        return cases, codes
    for exe in sorted(ORACLE_DIR.glob("test_*.exe")):
        try:
            r = subprocess.run([str(exe)], capture_output=True, timeout=120)
        except Exception:
            continue
        codes[exe.stem] = r.returncode
        out = r.stdout.decode(errors="replace") + r.stderr.decode(errors="replace")
        idx = 0
        for line in out.splitlines():
            m = _MARK.search(line)
            if not m:
                continue
            idx += 1
            name = _MARK.sub("", line).strip(" .:|\t")[:70] or f"check{idx}"
            passed = (m.group(1) == "PASS") and ("[FAIL]" not in line)
            cases.append((exe.stem, idx, name, passed))
    return cases, codes


_CASES, _CODES = _collect()


def _safe(s):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s)[:50]


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not _CODES:
        pytest.skip("OCaml oracles not built (run `dune build` in frontend/)")


@pytest.mark.parametrize(
    "stem,idx,name,passed", _CASES,
    ids=[f"{s}-{i:02d}-{_safe(n)}" for (s, i, n, _) in _CASES],
)
def test_oracle_check(stem, idx, name, passed):
    # The per-exe 'exit clean' backstop lives in test_yon_pipeline::test_ocaml_oracle
    # (one node per oracle); here we report each internal assertion as its own node.
    assert passed, f"{stem}: assertion #{idx} '{name}' reported [FAIL]"
