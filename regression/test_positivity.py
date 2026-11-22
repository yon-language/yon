"""A recursive place is strictly positive (E2020).

Within a group of places that name one another, no member occurs left of an arrow in a field of a
member: `place Bad { f Bad -> Number }` gives Bad = not Bad, and so does a pair that crosses
(`place A { f B -> Number }`, `place B { g A }`). A recursive place right of every arrow (a list,
a tree with a function to it) is accepted. A parametric place carries the polarity of its
parameters: an argument of `F<T>` stands left of an arrow when T does in a field of F, so
`place Bad { x F<Bad> }` with `place F<T> { g T -> Number }` is refused, also through a place in
between.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not EMIT.exists(), reason="frontend not built")


def _emit(tmp_path, places):
    objs = ", ".join(f'"{n}"' for n in places)
    (tmp_path / "yon.toml").write_text(f'[package]\nname = "pos"\n\n[world.W]\nobjects = [{objs}]\n\n'
                                       '[runtime]\nbackend = "memory"\n')
    for n, src in places.items():
        (tmp_path / f"{n}.yon").write_text(src)
    (tmp_path / "Entry.yon").write_text("place Entry { fun main: Number { return 0 } }\n")
    r = subprocess.run([str(EMIT), str(tmp_path)], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def test_a_place_left_of_an_arrow_in_its_own_field_is_refused(tmp_path):
    rc, out = _emit(tmp_path, {"Bad": "place Bad { f Bad -> Number }\n"})
    assert rc != 0 and "[E2020]" in out, out[-600:]
    assert "Bad appears left of an arrow in the field f of Bad" in out, out[-600:]


def test_two_places_that_cross_left_of_an_arrow_are_refused(tmp_path):
    rc, out = _emit(tmp_path, {"A": "place A { f B -> Number }\n", "B": "place B { g A }\n"})
    assert rc != 0 and "[E2020]" in out, out[-600:]
    assert "a recursive place is not strictly positive" in out, out[-600:]


def test_a_recursive_place_right_of_every_arrow_is_accepted(tmp_path):
    rc, out = _emit(tmp_path, {"Tree": "place Tree { kid Number -> Tree }\n"})
    assert rc == 0, out[-600:]


def test_a_place_left_of_an_arrow_that_is_not_recursive_is_accepted(tmp_path):
    rc, out = _emit(tmp_path, {"Probe": "place Probe { f Number -> Number }\n"})
    assert rc == 0, out[-600:]


_F_LEFT = "place F<T> { g T -> Number }\n"


def test_a_place_left_of_an_arrow_through_a_parametric_place_is_refused(tmp_path):
    rc, out = _emit(tmp_path, {"F": _F_LEFT, "Bad": "place Bad { x F<Bad> }\n"})
    assert rc != 0 and "[E2020]" in out, out[-600:]
    assert "Bad appears left of an arrow in the field x of Bad" in out, out[-600:]


def test_a_place_left_of_an_arrow_through_two_parametric_places_is_refused(tmp_path):
    rc, out = _emit(tmp_path, {"F": _F_LEFT, "G": "place G<U> { h F<U> }\n",
                               "Bad": "place Bad { x G<Bad> }\n"})
    assert rc != 0 and "[E2020]" in out, out[-600:]
    assert "Bad appears left of an arrow in the field x of Bad" in out, out[-600:]


def test_a_place_right_of_the_arrow_of_a_parametric_place_is_accepted(tmp_path):
    rc, out = _emit(tmp_path, {"F": "place F<T> { g Number -> T }\n", "Good": "place Good { x F<Good> }\n"})
    assert rc == 0, out[-600:]
