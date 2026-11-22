"""The index of a type is a value: it does not read a variable (Landin; Harper ch. 34).

A variable can change under the type that names it: a path `walk i => c` on a variable c carried
the endpoint c, and after `c <- 6` the type still said 5 while the point read 6. The rule is in
one point of the checker, where an expression of the program becomes an index of a type (an
endpoint of a path, the term argument of a place): the endpoints of `clear`, of `walk`, of
`through` (the application of a function to a path), and the indices of a type written on a
parameter of a lambda. Each refusal is E2021 with the words of its reason; each twin binds the value
first and compiles.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not EMIT.exists(), reason="the frontend is not built")

_TOML = '[package]\nname = "index"\n\n[runtime]\nbackend = "memory"\n'
_WORLD_TOML = ('[package]\nname = "index"\n\n[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n\n'
               '[runtime]\nbackend = "memory"\n')


def _emit(tmp_path, entry, places=None):
    (tmp_path / "yon.toml").write_text(_WORLD_TOML if places else _TOML)
    if places:
        (tmp_path / "w").mkdir()
        (tmp_path / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
        for name, text in places.items():
            (tmp_path / "w" / (name + ".yon")).write_text(text)
    (tmp_path / "Entry.yon").write_text(entry)
    r = subprocess.run([str(EMIT), str(tmp_path)], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def _refused(rc, out, code, words):
    assert rc != 0 and f"[{code}]" in out and words in out, out[-600:]


def _main(body):
    return "place Entry {\n  fun main: Number {\n" + body + "    return 7\n  }\n}\n"


def test_the_endpoints_of_a_walk_on_a_variable_are_refused(tmp_path):
    rc, out = _emit(tmp_path, _main("    mut c := 5\n    p := walk i => c\n    c <- 6\n"))
    _refused(rc, out, "E2021", "the index of a type reads the variable `c`: the index of a type is a value")


def test_the_endpoints_of_a_walk_on_a_bound_value_are_accepted(tmp_path):
    rc, out = _emit(tmp_path, _main("    mut c := 5\n    v := c\n    p := walk i => v\n    c <- 6\n"))
    assert rc == 0, out[-600:]


def test_a_path_on_a_variable_in_the_type_of_a_lambda_parameter_is_refused(tmp_path):
    rc, out = _emit(tmp_path, _main("    mut c := 5\n    f := fun(q: c = c) => 7\n    c <- 6\n"))
    _refused(rc, out, "E2021", "the index of a type reads the variable `c`: the index of a type is a value")


def test_a_path_on_a_bound_value_in_the_type_of_a_lambda_parameter_is_accepted(tmp_path):
    rc, out = _emit(tmp_path, _main("    mut c := 5\n    v := c\n    f := fun(q: v = v) => 7\n    c <- 6\n"))
    assert rc == 0, out[-600:]


_UNO_DUE = ("  fun uno(x: Number): Number { return 1 }\n"
            "  fun due(x: Number): Number { return 2 }\n")


def test_the_application_of_a_variable_to_a_path_is_refused(tmp_path):
    rc, out = _emit(tmp_path, "place Entry {\n" + _UNO_DUE +
                    "  fun main: Number {\n    mut c := uno\n    v := 5\n    p := walk i => v\n"
                    "    q := p through c\n    c <- due\n    return 7\n  }\n}\n")
    _refused(rc, out, "E2021", "the index of a type reads the variable `c`: the index of a type is a value")


def test_the_application_of_a_bound_function_to_a_path_is_accepted(tmp_path):
    rc, out = _emit(tmp_path, "place Entry {\n" + _UNO_DUE +
                    "  fun main: Number {\n    g := uno\n    v := 5\n    p := walk i => v\n"
                    "    q := p through g\n    return 7\n  }\n}\n")
    assert rc == 0, out[-600:]


_SCATOLA = ("place V<r : Number -> Number> { this > piena Number\n"
            "  fun leggi(x: Number): Number { return x }\n}\n")


def test_a_variable_as_the_term_argument_of_a_place_is_refused(tmp_path):
    rc, out = _emit(tmp_path, "place Entry {\n" + _UNO_DUE +
                    "  fun main: Number {\n    mut c := uno\n    f := fun(b: V<c>) => 7\n"
                    "    c <- due\n    return 7\n  }\n}\n", {"V": _SCATOLA})
    _refused(rc, out, "E2021", "the index of a type reads the variable `c`: the index of a type is a value")


def test_a_fun_as_the_term_argument_of_a_place_is_accepted(tmp_path):
    rc, out = _emit(tmp_path, "place Entry {\n" + _UNO_DUE +
                    "  fun main: Number {\n    f := fun(b: V<uno>) => 7\n    return 7\n  }\n}\n",
                    {"V": _SCATOLA})
    assert rc == 0, out[-600:]
