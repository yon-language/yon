"""`carried by` declares a representation, not an identity.

Int64 is the place of the prelude represented by i64, and its values convert
through the representation everywhere. A place of the program carried by i64
converts through it inside its house, and there it meets Int64 too; outside it
is not Int64, and no place is another place on the same carrier. Its values
convert only through what its house exports. A public place has the
literals of its carrier and the arithmetic among its own values; an internal
one closes them outside its house (test_internal_house.py)."""
import subprocess
from pathlib import Path

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_CELSIUS = """\
place Celsius carried by i64 {
  fun degrees(n: Int64): Celsius { return n }
  fun reading(c: Celsius): Int64 { return c }
  fun to_kelvin(c: Celsius): Kelvin { return Kelvin.degrees(c + 273) }
  fun from_kelvin(k: Kelvin): Celsius { return Kelvin.reading(k) - 273 }
EXTRA}
"""
_KELVIN = program("test_face_equality/module_1.yon")


def _build(tmp_path: Path, body: str, top: str = "", extra: str = ""):
    proj = tmp_path / "proj"
    proj.mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "faces"\n\n[world.W]\n'
                                   'objects = ["Celsius", "Kelvin"]\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Celsius.yon").write_text(_CELSIUS.replace("EXTRA", extra))
    (proj / "Kelvin.yon").write_text(_KELVIN)
    (proj / "Entry.yon").write_text("place Entry {\n" + top + "fun main: Number {\n" + body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _exit(tmp_path, body, top="", extra=""):
    rc, out, exe = _build(tmp_path, body, top, extra)
    assert rc == 0, out
    return subprocess.run([str(exe)], capture_output=True, timeout=30).returncode


def test_zero_celsius_is_273_kelvin_through_the_equivalence_of_the_house(tmp_path):
    # the house of Celsius exports the two ways; their equivalence carries
    # 0 °C to 273 K and back
    top = (program("test_face_equality/test_zero_celsius_is_273_kelvin_through_the_equivalence_of_the_house_1.yon"))
    body = ("  scale := up <=> down\n"
            "  k := Celsius.degrees(0) ↦ scale\n"
            "  c := Kelvin.degrees(300) ↦ scale\n"
            "  return if Kelvin.reading(k) == 273 and Celsius.reading(c) == 27 then 42 else 1")
    assert _exit(tmp_path, body, top) == 42


@pytest.mark.parametrize("name,top,body,words", [
    ("a Celsius returned as a Kelvin",
     program("test_face_equality/test_zero_celsius_does_not_become_zero_kelvin_by_any_implicit_way_1.yon"), "  return 42",
     "type mismatch: expected Kelvin, got Celsius"),
    ("a Celsius passed as a Kelvin",
     "", "  k := Kelvin.reading(Celsius.degrees(0))\n  return 42",
     "parameter k expects Kelvin, got Celsius"),
    ("a Celsius passed as an Int64",
     program("test_face_equality/test_zero_celsius_does_not_become_zero_kelvin_by_any_implicit_way_2.yon"),
     "  n := twice(Celsius.degrees(0))\n  return 42",
     "parameter n expects Int64, got Celsius"),
    ("an Int64 returned as a Celsius",
     program("test_face_equality/test_zero_celsius_does_not_become_zero_kelvin_by_any_implicit_way_3.yon"), "  return 42",
     "type mismatch: expected Celsius, got Int64"),
    ("a Celsius added to a Kelvin",
     "", "  x := Celsius.degrees(0) + Kelvin.degrees(0)\n  return 42",
     "got Celsius and Kelvin"),
    ("a Celsius compared to a Kelvin",
     "", "  return if Celsius.degrees(0) == Kelvin.degrees(0) then 1 else 42",
     "equality requires matching operand types; got Celsius and Kelvin"),
])
def test_zero_celsius_does_not_become_zero_kelvin_by_any_implicit_way(tmp_path, name, top, body, words):
    rc, out, _ = _build(tmp_path, body, top)
    assert rc != 0 and "E2001" in out, (name, out)
    assert words in out, (name, out)


def test_inside_its_house_a_place_converts_through_its_carrier_and_meets_int64_but_no_other_place(tmp_path):
    # in its house a Celsius converts through i64, so with Int64, both ways;
    # Kelvin stays Kelvin there
    rc, out, _ = _build(tmp_path, "  return 42",
                        extra=program("test_face_equality/test_inside_its_house_a_place_converts_through_its_carrier_and_meets_int64_but_no_other_place_1.yon"))
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Kelvin, got Celsius" in out, out
    assert _exit(tmp_path / "ok", "  return if Celsius.reading(Celsius.degrees(42)) == 42 then 42 else 1") == 42


def test_a_public_place_has_the_literals_and_the_arithmetic_of_its_own_values(tmp_path):
    top = program("test_face_equality/test_a_public_place_has_the_literals_and_the_arithmetic_of_its_own_values_1.yon")
    body = ("  a := Celsius.degrees(10)\n"
            "  b := a + a + five - 3\n"
            "  return if Celsius.reading(b) == 22 and b > five then 42 else 1")
    assert _exit(tmp_path, body, top) == 42


def test_int64_converts_through_i64_everywhere(tmp_path):
    # the place of the prelude for i64: its literals, the arithmetic of the
    # machine, the funs of the prelude on it
    body = "  n := Int64.max_value - Int64.max_value + 42\n  return if n == 42 then 42 else 1"
    assert _exit(tmp_path, body) == 42


def _faces(tmp_path: Path, places: dict, body: str, top: str = ""):
    proj = tmp_path / "proj"
    proj.mkdir(parents=True)
    objs = ", ".join(f'"{n}"' for n in places)
    (proj / "yon.toml").write_text(f'[package]\nname = "faces"\n\n[world.W]\nobjects = [{objs}]\n\n'
                                   '[runtime]\nbackend = "memory"\n')
    for n, src in places.items():
        (proj / f"{n}.yon").write_text(src)
    (proj / "Entry.yon").write_text("place Entry {\n" + top + "fun main: Number {\n" + body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


_METER = {"Meter": program("test_face_equality/module_2.yon")}
_NAME = {"Name": program("test_face_equality/module_3.yon")}


def test_a_place_on_number_has_its_literals_its_arithmetic_and_its_order(tmp_path):
    top = (program("test_face_equality/test_a_place_on_number_has_its_literals_its_arithmetic_and_its_order_1.yon"))
    body = ("  m := step + step / 2 - 0.375\n"
            "  return if Meter.reading(m) == 3.0 and m > step and Meter.reading(sum) == 3.0 then 42 else 1")
    rc, out, exe = _faces(tmp_path, _METER, body, top)
    assert rc == 0, out
    assert subprocess.run([str(exe)], capture_output=True, timeout=30).returncode == 42


def test_a_place_on_text_has_its_literals_and_its_concatenation(tmp_path):
    # two Names concatenate to a Name, at run time
    top = (program("test_face_equality/test_a_place_on_text_has_its_literals_and_its_concatenation_1.yon"))
    body = ('  both := hello + hello\n'
            '  return if Text.equal(Name.spelled(both), "hellohello")'
            ' and Text.equal(Name.spelled(twice(hello)), "hellohello") then 42 else 1')
    rc, out, exe = _faces(tmp_path, _NAME, body, top)
    assert rc == 0, out
    assert subprocess.run([str(exe)], capture_output=True, timeout=30).returncode == 42


@pytest.mark.parametrize("places,top,body,words", [
    (_METER, program("test_face_equality/test_a_place_on_number_or_text_does_not_convert_outside_its_house_1.yon"),
     "  x := lit + far(1.0)\n  return 42", "got Meter and Number"),
    (_METER, program("test_face_equality/test_a_place_on_number_or_text_does_not_convert_outside_its_house_2.yon"),
     "  return 42", "type mismatch: expected Number, got Meter"),
    (_NAME, program("test_face_equality/test_a_place_on_number_or_text_does_not_convert_outside_its_house_3.yon"), '  x := lit + Text.concat("b", "c")\n  return 42',
     "got Name and Text"),
])
def test_a_place_on_number_or_text_does_not_convert_outside_its_house(tmp_path, places, top, body, words):
    rc, out, _ = _faces(tmp_path, places, body, top)
    assert rc != 0 and "E2001" in out, out
    assert words in out, out


def test_no_place_of_the_program_is_the_place_of_a_carrier(tmp_path):
    # i16 has no place of the prelude: the first place on it does not become
    # one, and a Celsius is no Kelvin in the house of Kelvin either
    places = {"Celsius": program("test_face_equality/test_no_place_of_the_program_is_the_place_of_a_carrier_1.yon"),
              "Kelvin": program("test_face_equality/test_no_place_of_the_program_is_the_place_of_a_carrier_2.yon")}
    rc, out, _ = _faces(tmp_path, places, "  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Kelvin, got Celsius" in out, out


def test_an_instance_of_an_algebra_on_i64_is_no_int64_outside_its_house(tmp_path):
    rc, out, _ = _faces(tmp_path, _METER, "  return 42",
                        program("test_face_equality/test_an_instance_of_an_algebra_on_i64_is_no_int64_outside_its_house_1.yon"))
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Int64, got Additive" in out, out


def test_the_identity_equivalence_of_a_place_is_on_the_place_not_on_its_carrier(tmp_path):
    body = ("  c := transport(idEquiv(Celsius), Celsius.degrees(5))\n"
            "  return if Celsius.reading(c) == 5 then 42 else 1")
    assert _exit(tmp_path, body) == 42
