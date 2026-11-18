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
from yon_programs import program

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


_ENTRY = program("test_shell_order/module_1.yon")


def test_every_point_is_in_the_interval_of_its_orbit_and_of_its_shape(tmp_path):
    r = _run(tmp_path, _ENTRY)
    assert r.returncode == 42, r.stderr


def test_the_orbits_tile_the_shapes_in_order(tmp_path):
    # Octadic [0, 97152), Golay [97152, 195456), Axial [195456, 196560); each
    # orbit starts where the one before it in its shape ends
    entry = program("test_shell_order/test_the_orbits_tile_the_shapes_in_order_1.yon")
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
