"""The index of the shell is ordered by structure.

By shape under N (Octadic, Golay, Axial), within a shape by orbit under M24,
within an orbit by the raw order: every shape and every orbit is an interval
of indices, and LatticePoint gives the intervals as constants. Checked here
on every index, from Yon; the C side (the tower's classes, the raw order) is
test_unit_shell_order.c in test_runtime_units.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'


def _run(tmp_path: Path, entry: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)


_ENTRY = """place Entry {
fun main: Number {
  mut bad := 0
  mut i := 0
  while i < 196560 do {
    bad <- bad + check(i)
    i <- i + 1
  }
  return if bad == 0 then 42 else 1
}
/* 0 when the point of index i reads back index i, lies in the interval of
   its orbit, and the orbit in the interval of its shape */
fun check(i: Number): Number {
  return match LatticePoint.at_index(i) {
    LatticePoint as p => (if LatticePoint.index(p) == i then within(i, LatticePoint.orbit(p)) else 1),
    DomainError as d => 1 }
}
fun within(i: Number, o: Number): Number {
  f := first(o)
  return if i >= f and i < f + count(o) then in_shape(i, shape_of(o)) else 1
}
fun first(o: Number): Number {
  return match LatticePoint.orbit_first(o) { Number as f => f, DomainError as d => 0 - 1 }
}
fun count(o: Number): Number {
  return match LatticePoint.orbit_count(o) { Number as c => c, DomainError as d => 0 - 1 }
}
/* the shape of an orbit, by the structure the C side verifies: orbits 0 to 3
   are Axial, 4 to 6 Octadic, 7 to 11 Golay */
fun shape_of(o: Number): Number {
  return if o < 4 then 0 else if o < 7 then 2 else 1
}
fun in_shape(i: Number, s: Number): Number {
  f := sfirst(s)
  return if i >= f and i < f + scount(s) then 0 else 1
}
fun sfirst(s: Number): Number {
  return match LatticePoint.shape_first(s) { Number as f => f, DomainError as d => 0 - 1 }
}
fun scount(s: Number): Number {
  return match LatticePoint.shape_count(s) { Number as c => c, DomainError as d => 0 - 1 }
}
}
"""


def test_every_point_is_in_the_interval_of_its_orbit_and_of_its_shape(tmp_path):
    r = _run(tmp_path, _ENTRY)
    assert r.returncode == 42, r.stderr


def test_the_orbits_tile_the_shapes_in_order(tmp_path):
    # Octadic [0, 97152), Golay [97152, 195456), Axial [195456, 196560); each
    # orbit starts where the one before it in its shape ends
    entry = """place Entry {
fun main: Number {
  return if ends(4) == first(5) and ends(5) == first(6) and ends(6) == first(7)
            and ends(7) == first(8) and ends(8) == first(9) and ends(9) == first(10)
            and ends(10) == first(11) and ends(11) == first(0) and ends(0) == first(1)
            and ends(1) == first(2) and ends(2) == first(3) and ends(3) == 196560
            and first(4) == 0 and sfirst(1) == 97152 and sfirst(0) == 195456
            then 42 else 1
}
fun first(o: Number): Number {
  return match LatticePoint.orbit_first(o) { Number as f => f, DomainError as d => 0 - 1 }
}
fun ends(o: Number): Number {
  return match LatticePoint.orbit_count(o) { Number as c => first(o) + c, DomainError as d => 0 - 1 }
}
fun sfirst(s: Number): Number {
  return match LatticePoint.shape_first(s) { Number as f => f, DomainError as d => 0 - 1 }
}
}
"""
    assert _run(tmp_path, entry).returncode == 42


@pytest.mark.parametrize("call,words", [
    ("LatticePoint.orbit_first(12)", "not an orbit of the shell under M24, an integer in [0, 12)"),
    ("LatticePoint.shape_count(3)", "not a shape of the shell under N, an integer in [0, 3)"),
])
def test_an_interval_off_the_order_is_a_domain_error(tmp_path, call, words):
    entry = ("place Entry {\nfun main: Number {\n"
             f"  return match {call} {{\n"
             "    Number as n => 1,\n"
             f"    DomainError as d => (if d.message == \"{words}\" then 42 else 2) }}\n"
             "}\n}\n")
    assert _run(tmp_path, entry).returncode == 42
