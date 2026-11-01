"""`and` and `or` read their right side only when it decides.

a and b is `if a then b else false`, a or b is `if a then true else b`: the
right side of an `and` whose left side is false, or of an `or` whose left
side is true, is never evaluated, so it can be a guard of the left.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _run(tmp_path: Path, entry: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)


def test_a_guard_on_the_left_of_and_keeps_the_division_out(tmp_path):
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number { return if guarded(0) then 1 else 42 }\n"
        "fun guarded(x: Number): Boolean { return x != 0 and 10 / x > 1 }\n"
        "}\n"))
    assert r.returncode == 42, r.stderr


_SEEN = (
    "fun seen(b: Boolean): Boolean {\n"
    "  _ := SystemOs.write_output(\"read\\n\")\n"
    "  return b\n"
    "}\n")


@pytest.mark.parametrize("expr,value,reads", [
    ("1 == 2 and seen(true)", False, 0),
    ("1 == 1 and seen(true)", True, 1),
    ("1 == 1 and seen(false)", False, 1),
    ("1 == 1 or seen(false)", True, 0),
    ("1 == 2 or seen(true)", True, 1),
    ("1 == 2 or seen(false)", False, 1),
])
def test_the_right_side_is_read_only_when_it_decides(tmp_path, expr, value, reads):
    r = _run(tmp_path, (
        "place Entry {\n"
        f"fun main(): Number {{ return if {expr} then 42 else 7 }}\n"
        + _SEEN + "}\n"))
    assert r.returncode == (42 if value else 7), r.stderr
    assert r.stdout.count("read") == reads, r.stdout


def test_a_chain_stops_at_the_first_side_that_decides(tmp_path):
    r = _run(tmp_path, (
        "place Entry {\n"
        "fun main(): Number {\n"
        "  return if seen(true) and seen(false) and seen(true) then 7 else 42\n"
        "}\n" + _SEEN + "}\n"))
    assert r.returncode == 42, r.stderr
    assert r.stdout.count("read") == 2, r.stdout
