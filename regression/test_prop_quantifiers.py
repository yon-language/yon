"""A quantifier of a prop carries its type: `∀x : T` or `∀x ∈ T`.

A prop is a proposition the program computes. Over a place of nullary arms a
quantifier is the finite meet (∀) or join (∃) of the statement at each arm,
in Omega, so the prop decides exactly; over any other type there is no such
value, and the prop is refused with the reason, at compile time.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_MAIN = ("place Entry {\n  fun main(): Number {\n"
         "    a := match decide(some_other(Heads)) { Present => 40, Absent => 0, Unknown => 1 }\n"
         "    b := match decide(all_same(Heads)) { Present => 0, Absent => 2, Unknown => 1 }\n"
         "    return a + b\n  }\n}\n")


def _build(tmp_path: Path, props: str):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "pq"\n\n[world.W]\nspaces = ["w"]\n\n'
                                   '[runtime]\nbackend = "memory"\n')
    (proj / "w" / "Coin.yon").write_text("place Coin { this > Heads :U Tails }\n")
    (proj / "w" / "Topos.yon").write_text("topos where {\n" + props + "}\n")
    (proj / "Entry.yon").write_text(_MAIN)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


@pytest.mark.parametrize("colon, elem", [(":", ":"), ("∈", "∈"), (":", "∈")])
def test_a_quantifier_over_a_finite_place_decides(tmp_path, colon, elem):
    rc, out, exe = _build(tmp_path,
                          f"  prop some_other(x: Coin) = ∃y {colon} Coin (x ≠ y)\n"
                          f"  prop all_same(x: Coin) = ∀y {elem} Coin (x = y)\n")
    assert rc == 0, out
    assert subprocess.run([str(exe)], capture_output=True, timeout=30).returncode == 42


def test_a_quantifier_over_an_infinite_type_is_refused(tmp_path):
    rc, out, _ = _build(tmp_path,
                        "  prop some_other(x: Coin) = ∃y : Coin (x ≠ y)\n"
                        "  prop all_same(x: Coin) = ∀n ∈ Int64 (n = n)\n")
    assert rc != 0 and "E2001" in out, out
    assert "prop all_same quantifies n over Int64, which is not a place of nullary arms" in out, out
