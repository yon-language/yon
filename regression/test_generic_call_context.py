"""At a generic call, a type parameter the arguments do not fix is fixed by the context of use: the
expected type, an annotation, the unifications with the uses. Left free the call is ambiguous and is
refused, asking to annotate. It is never the placeholder unknown.

The cell has the type of its content, and `Space.make`, `Space.get`, `Space.set` are gone. `==` on a
value of an abstract type is refused in a body; in the statement of a law it states.

Layer/kind: frontend + native / end-to-end.
"""
import shutil
import subprocess
from pathlib import Path

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
META = ROOT / "meta"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _compile(proj, tmp_path):
    return subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                          capture_output=True, text=True, timeout=300)


def _entry(tmp_path, entry):
    proj = tmp_path / "p"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "p"\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text("place Entry {\n" + entry + "\n}\n")
    return _compile(proj, tmp_path)


def _refused(r, *words):
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    for w in words:
        assert w in out, out


def _line_of(text, marker):
    """La riga (da 1) della prima occorrenza di marker in text."""
    assert marker in text, marker
    return text[:text.index(marker)].count("\n") + 1


def _exits(tmp_path, r, code):
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(tmp_path / "exe")], capture_output=True, timeout=60).returncode == code


def _proof(tmp_path, theorems):
    proj = tmp_path / "meta"
    shutil.copytree(META, proj)
    proofs = proj / "kernel" / "Proofs.yon"
    proofs.write_text(proofs.read_text().replace("place Proofs {\n", "place Proofs {\n" + theorems, 1))
    return _compile(proj, tmp_path), proj


def test_exfalso_takes_the_type_the_context_expects(tmp_path):
    r, _ = _proof(tmp_path, program("test_generic_call_context/test_exfalso_takes_the_type_the_context_expects_1.yon"))
    assert r.returncode == 0, r.stdout + r.stderr


def test_one_result_does_not_have_two_types(tmp_path):
    r, proj = _proof(tmp_path, program("test_generic_call_context/test_one_result_does_not_have_two_types_1.yon"))
    _refused(r, "parameter")
    out = r.stdout + r.stderr
    assert "expects Nat, got Term" in out or "expects Term, got Nat" in out, out
    assert "as_nat" in out or "as_term" in out, out
    line = _line_of((proj / "kernel" / "Proofs.yon").read_text(), "return as_term(x) + as_nat(x)")
    assert f"[line {line}," in out, out


def test_a_call_nothing_fixes_is_ambiguous(tmp_path):
    r, proj = _proof(tmp_path, program("test_generic_call_context/test_a_call_nothing_fixes_is_ambiguous_1.yon"))
    _refused(r, "ambiguous call of", "exfalso", "type parameter T", "annotate")
    out = r.stdout + r.stderr
    line = _line_of((proj / "kernel" / "Proofs.yon").read_text(), "x := exfalso(e)")
    assert f"[line {line}," in out, out


def test_the_expected_type_of_a_later_use_fixes_the_call(tmp_path):
    r, _ = _proof(tmp_path, program("test_generic_call_context/test_the_expected_type_of_a_later_use_fixes_the_call_1.yon"))
    assert r.returncode == 0, r.stdout + r.stderr


def test_a_cell_has_the_type_of_what_is_written(tmp_path):
    _exits(tmp_path, _entry(tmp_path, program("test_generic_call_context/test_a_cell_has_the_type_of_what_is_written_1.yon")), 42)


def test_a_write_of_another_type_is_refused(tmp_path):
    _refused(_entry(tmp_path, program("test_generic_call_context/test_a_write_of_another_type_is_refused_1.yon")), "List__cons")


def test_a_cell_never_written_leaves_its_list_ambiguous(tmp_path):
    _refused(_entry(tmp_path, program("test_generic_call_context/test_a_cell_never_written_leaves_its_list_ambiguous_1.yon")),
             "ambiguous call of", "List__empty", "annotate")


@pytest.mark.parametrize("form,name", [
    ("x := Space.make(1)", "Space.make"), ("x := Space.new(1)", "Space.new"),
    ("mut c := 1\n  x := Space.get(c)", "Space.get"), ("mut c := 1\n  x := Space.set(c, 2)", "Space.set"),
])
def test_the_space_cell_forms_are_gone(tmp_path, form, name):
    _refused(_entry(tmp_path, f"fun main: Number {{\n  {form}\n  return 0\n}}"),
             f"`{name}` is gone", "`mut c := e`", "`c <- e`")


@pytest.mark.parametrize("decl", [program("test_generic_call_context/test_equality_on_an_abstract_type_is_refused_1.yon"),
                                  program("test_generic_call_context/test_equality_on_an_abstract_type_is_refused_2.yon")])
def test_equality_on_an_abstract_type_is_refused(tmp_path, decl):
    _refused(_entry(tmp_path, decl + "\nfun main: Number { return 0 }"),
             "abstract type T admits no operation")


def test_equality_with_a_type_the_body_fixes_is_accepted(tmp_path):
    _exits(tmp_path, _entry(tmp_path, program("test_generic_call_context/test_equality_with_a_type_the_body_fixes_is_accepted_1.yon")), 42)


def test_a_space_is_not_a_type(tmp_path):
    _refused(_entry(tmp_path, program("test_generic_call_context/test_a_space_is_not_a_type_1.yon")),
             "`Space` is not a type", "a Space is a package")


@pytest.mark.parametrize("name", ["__cell_make", "__cell_get", "__cell_set"])
def test_the_primitives_of_a_cell_are_not_reachable(tmp_path, name):
    _refused(_entry(tmp_path, f"fun main: Number {{\n  x := {name}(1)\n  return 0\n}}"),
             f"unknown function or operation: {name}")


def test_an_xset_has_its_own_type(tmp_path):
    _exits(tmp_path, _entry(tmp_path, program("test_generic_call_context/test_an_xset_has_its_own_type_1.yon")), 42)


def test_an_xset_is_not_an_xrelset(tmp_path):
    _refused(_entry(tmp_path, program("test_generic_call_context/test_an_xset_is_not_an_xrelset_1.yon")),
             "XRelSet__size")
