"""Inside the house of a place `is internal <carrier>` the place is its
carrier; outside it the place is abstract.

Inside the house a value of the place and a value of its carrier convert in
both directions, and the arithmetic is the carrier's, the machine's, which
wraps (for i64, the ring Z/2^64). Outside the house the place takes no
arithmetic. The operators on bits (& | ^ ~) apply to 64-bit integers too,
on their two's complement.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = ('[package]\nname = "house"\n\n[world.W]\nobjects = ["Word"]\n\n'
         '[runtime]\nbackend = "memory"\n')


def _build(tmp_path: Path, house: str, main_expr: str):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Word.yon").write_text("place Word is internal i64 {\n" + house + "}\n")
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main(): Number {\n  return " + main_expr + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=180)
    return r.returncode, r.stdout + r.stderr, exe


def _value(tmp_path, house, main_expr):
    rc, out, exe = _build(tmp_path, house, main_expr)
    assert rc == 0, out
    return subprocess.run([str(exe)], timeout=30).returncode


_MAKE = "  fun make(n: Int64): Word { return n }\n"


def test_inside_the_house_the_place_and_its_carrier_convert_both_ways(tmp_path):
    house = (_MAKE + "  fun to_int(w: Word): Int64 { return w }\n")
    assert _value(tmp_path, house,
                  "if Word.to_int(Word.make(41)) + 1 == 42 then 42 else 1") == 42


def test_inside_the_house_the_sum_wraps(tmp_path):
    house = (_MAKE
             + "  fun wrap(): Word { return make(Int64.max_value()) + make(1) }\n"
             + "  fun is_min(w: Word): Boolean { return w == Int64.min_value() }\n")
    assert _value(tmp_path, house, "if Word.is_min(Word.wrap()) then 42 else 1") == 42


def test_inside_the_house_the_product_wraps(tmp_path):
    house = (_MAKE
             + "  fun sq(a: Word): Word { return a * a }\n"
             + "  fun is_zero(w: Word): Boolean { return w == 0 }\n")
    assert _value(tmp_path, house,
                  "if Word.is_zero(Word.sq(Word.make(4294967296))) then 42 else 1") == 42


def test_outside_the_house_the_place_takes_no_arithmetic(tmp_path):
    rc, out, _ = _build(tmp_path, _MAKE, "if Word.make(3) + Word.make(3) == Word.make(6) then 42 else 1")
    assert rc != 0 and "[E2001]" in out and "Fatal error" not in out, out
    assert "operator requires matching numeric/duration/money operands; got Word and Word" in out, out


def test_outside_the_house_a_carrier_value_is_not_the_place(tmp_path):
    rc, out, _ = _build(tmp_path, "  fun same(w: Word): Word { return w }\n",
                        "if Word.same(Int64.max_value()) == Word.same(Int64.max_value()) then 1 else 2")
    assert rc != 0 and "[E2001]" in out and "Fatal error" not in out, out


def test_the_bit_operators_apply_to_64_bit_integers(tmp_path):
    expr = ("if Int64.max_value() & 255 == 255 and ~(Int64.min_value()) == Int64.max_value()"
            " and (Int64.ipow_ok(2, 60) | 1) - 1 == Int64.ipow_ok(2, 60)"
            " and (Int64.ipow_ok(2, 40) ^ Int64.ipow_ok(2, 40)) == 0 then 42 else 1")
    assert _value(tmp_path, _MAKE, expr) == 42


def test_the_bit_operators_on_numbers_are_unchanged(tmp_path):
    assert _value(tmp_path, _MAKE, "(12 & 10) + (12 | 3) + (6 ^ 3)") == 8 + 15 + 5
