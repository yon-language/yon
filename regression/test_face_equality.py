"""A place carried by a primitive is a representation, not the primitive.

Int64 is i64 everywhere: the prelude's face owns its primitive. A place of the
program carried by i64 is its carrier inside its house, and there it is Int64
too; outside it is neither i64 nor Int64, and no face is another face. Its
values convert only through what its house exports. A public place has the
literals of its carrier and the arithmetic among its own values; an internal
one closes them outside its house (test_internal_house.py)."""
import subprocess
from pathlib import Path

import pytest

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
_KELVIN = """\
place Kelvin carried by i64 {
  fun degrees(n: Int64): Kelvin { return n }
  fun reading(k: Kelvin): Int64 { return k }
}
"""


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
    top = ("fun up(c: Celsius): Kelvin { return Celsius.to_kelvin(c) }\n"
           "fun down(k: Kelvin): Celsius { return Celsius.from_kelvin(k) }\n")
    body = ("  scale := up <=> down\n"
            "  k := Celsius.degrees(0) ↦ scale\n"
            "  c := Kelvin.degrees(300) ↦ scale\n"
            "  return if Kelvin.reading(k) == 273 and Celsius.reading(c) == 27 then 42 else 1")
    assert _exit(tmp_path, body, top) == 42


@pytest.mark.parametrize("name,top,body,words", [
    ("a Celsius returned as a Kelvin",
     "fun same(c: Celsius): Kelvin { return c }\n", "  return 42",
     "type mismatch: expected Kelvin, got Celsius"),
    ("a Celsius passed as a Kelvin",
     "", "  k := Kelvin.reading(Celsius.degrees(0))\n  return 42",
     "parameter k expects Kelvin, got Celsius"),
    ("a Celsius passed as an Int64",
     "fun twice(n: Int64): Int64 { return n + n }\n",
     "  n := twice(Celsius.degrees(0))\n  return 42",
     "parameter n expects Int64, got Celsius"),
    ("an Int64 returned as a Celsius",
     "fun warm(n: Int64): Celsius { return n }\n", "  return 42",
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


def test_inside_its_house_a_place_is_its_carrier_and_int64_but_no_other_face(tmp_path):
    # Celsius ≡ i64 ≡ Int64 in its house, both ways; Kelvin stays Kelvin there
    rc, out, _ = _build(tmp_path, "  return 42",
                        extra="  fun cold(c: Celsius): Kelvin { return c }\n")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Kelvin, got Celsius" in out, out
    assert _exit(tmp_path / "ok", "  return if Celsius.reading(Celsius.degrees(42)) == 42 then 42 else 1") == 42


def test_a_public_place_has_the_literals_and_the_arithmetic_of_its_own_values(tmp_path):
    top = "fun five: Celsius { return 5 }\n"
    body = ("  a := Celsius.degrees(10)\n"
            "  b := a + a + five - 3\n"
            "  return if Celsius.reading(b) == 22 and b > five then 42 else 1")
    assert _exit(tmp_path, body, top) == 42


def test_int64_is_i64_everywhere(tmp_path):
    # the face of the prelude owns its primitive: its literals, its machine
    # arithmetic, the funs of the prelude on it
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


_METER = {"Meter": "place Meter carried by number {\n  fun reading(m: Meter): Number { return m }\n}\n"}
_NAME = {"Name": "place Name carried by text {\n  fun spelled(n: Name): String { return n }\n}\n"}


def test_a_place_on_number_has_its_literals_its_arithmetic_and_its_order(tmp_path):
    top = ("fun step: Meter { return 2.25 }\n"
           "fun sum: Meter { return 1.0 + 2.0 }\n")
    body = ("  m := step + step / 2 - 0.375\n"
            "  return if Meter.reading(m) == 3.0 and m > step and Meter.reading(sum) == 3.0 then 42 else 1")
    rc, out, exe = _faces(tmp_path, _METER, body, top)
    assert rc == 0, out
    assert subprocess.run([str(exe)], capture_output=True, timeout=30).returncode == 42


def test_a_place_on_text_has_its_literals_and_its_concatenation(tmp_path):
    # two Names concatenate to a Name; the value is read on the concatenation
    # of the literals, which the compiler computes
    top = ('fun hello: Name { return "hel" + "lo" }\n'
           "fun twice(n: Name): Name { return n + n }\n")
    body = ('  both := hello + hello\n'
            '  return if String.equal(Name.spelled(hello), "hello") then 42 else 1')
    rc, out, exe = _faces(tmp_path, _NAME, body, top)
    assert rc == 0, out
    assert subprocess.run([str(exe)], capture_output=True, timeout=30).returncode == 42


@pytest.mark.parametrize("places,top,body,words", [
    (_METER, "fun lit: Meter { return 1.5 }\nfun far(n: Number): Number { return n }\n",
     "  x := lit + far(1.0)\n  return 42", "got Meter and number"),
    (_METER, "fun lit: Meter { return 1.5 }\nfun as_number(m: Meter): Number { return m }\n",
     "  return 42", "type mismatch: expected number, got Meter"),
    (_NAME, 'fun lit: Name { return "a" }\n', '  x := lit + String.concat("b", "c")\n  return 42',
     "got Name and String"),
])
def test_a_place_on_number_or_text_is_not_its_primitive_outside_its_house(tmp_path, places, top, body, words):
    rc, out, _ = _faces(tmp_path, places, body, top)
    assert rc != 0 and "E2001" in out, out
    assert words in out, out


def test_no_place_of_the_program_owns_a_primitive_the_prelude_does_not_fuse(tmp_path):
    # on i16 there is no face of the prelude: the first place on it is no
    # owner, and a Celsius is no Kelvin in the house of Kelvin either
    places = {"Celsius": "place Celsius carried by i16 {\n  fun zero: Celsius { return 0 }\n}\n",
              "Kelvin": "place Kelvin carried by i16 {\n  fun from_c(c: Celsius): Kelvin { return c }\n}\n"}
    rc, out, _ = _faces(tmp_path, places, "  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Kelvin, got Celsius" in out, out


def test_an_instance_of_an_algebra_on_i64_is_no_int64_outside_its_house(tmp_path):
    rc, out, _ = _faces(tmp_path, _METER, "  return 42",
                        "fun plain(a: Additive): Int64 { return a }\n")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Int64, got Additive" in out, out


def test_the_identity_equivalence_of_a_place_is_on_the_place_not_on_its_carrier(tmp_path):
    body = ("  c := transport(idEquiv(Celsius), Celsius.degrees(5))\n"
            "  return if Celsius.reading(c) == 5 then 42 else 1")
    assert _exit(tmp_path, body) == 42
