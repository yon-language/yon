"""An unannotated lambda parameter has one type (Hindley-Milner): one unknown, unified with the
expected type of the lambda and with every use of the parameter. Left open, or given two
incompatible types, the program is refused, and the refusal asks to annotate the parameter.

Layer/kind: frontend + native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _build(tmp_path, entry):
    proj = tmp_path / "p"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "p"\n\n[world.W]\nobjects = ["P"]\n'
                                    'spaces = ["w"]\n\n[runtime]\nbackend = "memory"\n')
    (proj / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (proj / "w" / "P.yon").write_text("place P { a Number }\n")
    (proj / "Entry.yon").write_text("place Entry {\n" + entry + "\n}\n")
    exe = tmp_path / "exe"
    return exe, subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                               capture_output=True, text=True, timeout=300)


def _refused(tmp_path, entry, *words):
    _, r = _build(tmp_path, entry)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    for w in ("annotate", *words):
        assert w in out, out


def _exits(tmp_path, entry, code):
    exe, r = _build(tmp_path, entry)
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(exe)], capture_output=True, timeout=60).returncode == code


def test_a_parameter_nothing_types_is_refused(tmp_path):
    _refused(tmp_path, "fun main: Number {\n  k := fun(x) => 0\n  return 2\n}",
             "lambda parameter x", "gives it a type")


def test_a_parameter_with_a_block_body_nothing_types_is_refused(tmp_path):
    _refused(tmp_path, "fun main: Number {\n  k := fun(x) => { return 1 }\n  return 2\n}",
             "lambda parameter x", "gives it a type")


def test_two_uses_of_different_types_are_refused(tmp_path):
    _refused(tmp_path, "fun n(a: Number): Number { return a }\n"
                       "fun u(a: Text): Number { return 0 }\n"
                       "fun main: Number {\n  k := fun(x) => n(x) + u(x)\n  return k(1)\n}",
             "expects Text, got number", "x was read as number")


def test_one_lambda_does_not_take_two_types(tmp_path):
    # no generalization: the unknown is one, whoever applies the lambda
    _refused(tmp_path, 'fun main: Number {\n  id := fun(x) => x\n  a := id(5)\n'
                       '  b := id("h")\n  return a\n}',
             "expects number, got Text", "x was read as number")


def test_the_expected_type_and_the_uses_must_agree(tmp_path):
    _refused(tmp_path, "fun app(f: Text -> Number, x: Text): Number { return f(x) }\n"
                       'fun main: Number {\n  return app(fun(y) => y + 1, "a")\n}',
             "got Text and number", "y was read as Text")


def test_a_field_of_a_parameter_with_no_type_yet_is_refused(tmp_path):
    _refused(tmp_path, "fun main: Number {\n  k := fun(x) => x.a\n  return 1\n}",
             "field access requires a place", "x has no type yet")


def test_a_use_types_the_parameter(tmp_path):
    _exits(tmp_path, "fun main: Number {\n  k := fun(x) => x + 1\n  return k(41)\n}", 42)


def test_an_application_types_the_parameter(tmp_path):
    _exits(tmp_path, "fun main: Number {\n  k := fun(x) => 42\n  return k(1)\n}", 42)


def test_the_expected_type_types_the_parameter(tmp_path):
    _exits(tmp_path, "fun app(f: Number -> Number, x: Number): Number { return f(x) }\n"
                     "fun main: Number {\n  return app(fun(y) => y + 1, 41)\n}", 42)


def test_a_block_body_is_a_lambda_too(tmp_path):
    _exits(tmp_path, "fun main: Number {\n  f := fun(x) => { y := x + 1 return y }\n"
                     "  return f(41)\n}", 42)


def test_an_annotated_parameter_needs_no_use(tmp_path):
    _exits(tmp_path, "fun main: Number {\n  k := fun(x: Number) => 0\n  return 42\n}", 42)
