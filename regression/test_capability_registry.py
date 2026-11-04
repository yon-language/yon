"""The runtime registry of capability tokens: a token is held at most once.

Granting a token already held answers its entry, even when a revoke has left a
hole before it, so one revoke takes the token away.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _exit(tmp_path: Path, body: str) -> int:
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text("place Entry {\nfun main: Number {\n" + body + "}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, timeout=60).returncode


def test_a_revoke_takes_away_a_token_granted_again_after_a_hole(tmp_path):
    # the inventory's probe cap_revoke
    assert _exit(tmp_path, "  _a := Cap.grant(11)\n  _b := Cap.grant(22)\n  _r := Cap.revoke(11)\n"
                           "  _b2 := Cap.grant(22)\n  _r2 := Cap.revoke(22)\n"
                           "  return Cap.check(22)\n") == 0


def test_a_token_granted_again_after_a_hole_keeps_its_entry(tmp_path):
    assert _exit(tmp_path, "  _a := Cap.grant(11)\n  b := Cap.grant(22)\n  _r := Cap.revoke(11)\n"
                           "  b2 := Cap.grant(22)\n"
                           "  return if b == b2 then 42 else 1\n") == 42


def test_a_hole_is_taken_by_the_next_new_token(tmp_path):
    assert _exit(tmp_path, "  a := Cap.grant(11)\n  _b := Cap.grant(22)\n  _r := Cap.revoke(11)\n"
                           "  c := Cap.grant(33)\n"
                           "  return if a == c and Cap.check(11) == 0 and Cap.check(22) == 1\n"
                           "            and Cap.check(33) == 1 then 42 else 1\n") == 42


def test_a_revoke_of_a_token_not_held_grants_nothing(tmp_path):
    # control: without the hole, grant, revoke, check
    assert _exit(tmp_path, "  _a := Cap.grant(11)\n  _r := Cap.revoke(11)\n"
                           "  return Cap.check(11)\n") == 0
