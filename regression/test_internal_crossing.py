"""A value of an internal place crosses a Space as its carrier.

A place whose representation is internal and whose carrier is a mobile
scalar (a 64-bit word or a double) crosses a Space boundary as that carrier,
its eight bytes as they are, under its own type root: Word64 and LatticePoint
go to another Space and come back, alone or inside a collection. A place
whose carrier means nothing in another process (XRelFrame, the address of
its tables) is refused at compile time, never at run time.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_OTHER = (
    "place Other {\n"
    "  fun bump(w: Word64): Word64 { return w + Word64.one }\n"
    "  fun next(p: LatticePoint): LatticePoint {\n"
    "    return match LatticePoint.at_index(LatticePoint.index(p) + 1) {\n"
    "      LatticePoint as q => q, DomainError as d => p }\n"
    "  }\n"
    "  fun grow(s: XRelSet<LatticePoint>, p: LatticePoint): XRelSet<LatticePoint> {\n"
    "    return XRelSet.add(s, p)\n"
    "  }\n"
    "  fun keep(f: XRelFrame): XRelFrame { return f }\n"
    "}\n")


def _build(tmp_path: Path, main_body: str):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "cross"\n\n[world.W]\nspaces = ["w"]\n\n'
                                   '[runtime]\nbackend = "memory"\n')
    (proj / "w" / "Topos.yon").write_text("topos where {\n}\n")
    (proj / "w" / "Other.yon").write_text(_OTHER)
    (proj / "Entry.yon").write_text("place Entry {\n  fun main: Number {\n" + main_body
                                    + "\n  }\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _value(tmp_path, body):
    rc, out, exe = _build(tmp_path, body)
    assert rc == 0, out
    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
    return run.returncode, run.stderr


def test_a_word_goes_to_another_space_and_comes_back(tmp_path):
    rc, err = _value(tmp_path, (
        "    w := Other.bump(Word64.from_int64(41))\n"
        "    return match Word64.to_signed(w) { Int64 as n => if n == 42 then 42 else 1, "
        "DomainError as d => 2 }"))
    assert rc == 42, err


def test_a_lattice_point_goes_to_another_space_and_comes_back(tmp_path):
    rc, err = _value(tmp_path, (
        "    return match LatticePoint.at_index(41) { "
        "LatticePoint as q => LatticePoint.index(Other.next(q)), DomainError as d => 0 }"))
    assert rc == 42, err


def test_a_set_of_lattice_points_goes_and_comes_back(tmp_path):
    rc, err = _value(tmp_path, (
        "    return match LatticePoint.at_index(7) { LatticePoint as q => "
        "(if XRelSet.contains(Other.grow(XRelSet.empty, q), q) then 42 else 1), "
        "DomainError as d => 0 }"))
    assert rc == 42, err


def test_a_frame_is_refused_at_compile_time(tmp_path):
    rc, out, _ = _build(tmp_path, "    f := Other.keep(XRelFrame.whole)\n    return 42")
    assert rc != 0 and "E2001" in out, out
    assert "argument 1 of Other__keep of type XRelFrame crosses into another Space" in out, out
