"""The stable-diagnostic-code catalog gate.

The catalog (frontend/error_codes.ml) is the single registry of stable diagnostic
codes. The compiler renders every error as "<PREFIX> [<id>]: <message>", so a tool
grabs the code (E3001), not the fragile prose. Two invariants the registry must
keep, both checked here from the source:

  1. Every assigned code is UNIQUE. Hand-numbering invites a collision, and two
     diagnostics sharing one code silently break the tool that keys on it.
  2. The CLI output actually carries a code: a real DROP error renders with its
     stable id, additively, the historical prefix preserved.

Exhaustiveness of the variant is enforced by the OCaml build (the `id`/`title`
matches have no wildcard, so a new code fails compilation until it is registered).
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "frontend" / "error_codes.ml"
YONC = ROOT / "toolchain" / "yonc"
FIXTURE = ROOT / "regression" / "keyword_coverage" / "drop_reclaim"

_ILLEGAL = """\
import svc::d_op from D
place Entry { }
fun main(): Number {
  drop D
  be r holds d_op(5)
  return r - r
}
"""


def _ids() -> list[str]:
    return re.findall(r'->\s*"(E\d{4}|W\d{3})"', SRC.read_text())


@pytest.mark.skipif(not SRC.exists(), reason="error_codes.ml missing")
def test_codes_are_unique():
    ids = _ids()
    assert ids, "no stable codes found in the registry"
    dupes = sorted({c for c in ids if ids.count(c) > 1})
    assert not dupes, f"duplicate stable codes (one code, two meanings): {dupes}"


@pytest.mark.skipif(not SRC.exists(), reason="error_codes.ml missing")
def test_codes_are_well_formed():
    for c in _ids():
        assert re.fullmatch(r"E[1-4]\d{3}|W\d{3}", c), f"code out of the assigned ranges: {c}"


@pytest.mark.skipif(not YONC.exists() or not FIXTURE.exists(),
                    reason="yonc or fixture missing")
def test_cli_carries_the_code(tmp_path):
    """A real diagnostic renders with its stable code and its historical prefix."""
    proj = tmp_path / "proj"
    shutil.copytree(FIXTURE, proj)
    (proj / "Entry.yon").write_text(_ILLEGAL)
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "out")],
                       capture_output=True, text=True, timeout=120)
    combined = r.stdout + r.stderr
    assert "DROP ERROR [E3001]:" in combined, combined
