"""The fields of a place are a telescope: the type of a field may name the
fields before it. A point built with `.->` is checked with the values given in
place of those names; a field read off a point has the type that names the
fields of that same point; the parameters of a generic place are read from the
values of its fields. A field that names a field after it is refused."""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_ISO = """\
place Iso {
  forth Int64 -> Int64
  left Int64 -> Int64
  left_law Πx : Int64, left(forth(x)) = x
}
"""
_GENERIC = """\
place Iso<A, B> {
  forth A -> B
  left B -> A
  left_law Πx : A, left(forth(x)) = x
}
"""
_INT = """\
fun succ(n: Int64): Int64 { return n + 1 }
fun pred(n: Int64): Int64 { return n - 1 }
fun eta(x: Int64): pred(succ(x)) = x { return clear }
"""


def _build(tmp_path: Path, iso: str, top: str, body: str):
    proj = tmp_path / "proj"
    proj.mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "dep"\n\n[world.W]\nobjects = ["Iso", "Bool"]\n\n'
                                   '[runtime]\nbackend = "memory"\n')
    (proj / "Iso.yon").write_text(iso)
    (proj / "Bool.yon").write_text("place Bool { this > tt :U ff }\n")
    (proj / "Entry.yon").write_text("place Entry {\n" + top + "fun main: Number {\n" + body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _exit(tmp_path, iso, top, body):
    rc, out, exe = _build(tmp_path, iso, top, body)
    assert rc == 0, out
    return subprocess.run([str(exe)], capture_output=True, timeout=30).returncode


_USE = ("  e := .-> Iso { forth succ left pred left_law eta }\n"
        "  f := e.forth\n"
        "  return if (41 ↦ f) == 42 then 42 else 1")


def test_a_point_whose_proof_speaks_of_its_fields_is_built(tmp_path):
    # left_law is checked as Πx : Int64, pred(succ(x)) = x: the values of
    # forth and left in place of their names
    assert _exit(tmp_path, _ISO, _INT, _USE) == 42


def test_a_proof_of_another_statement_is_refused(tmp_path):
    # with left = succ the field asks succ(succ(x)) = x, and eta proves
    # pred(succ(x)) = x
    body = "  e := .-> Iso { forth succ left succ left_law eta }\n  return 42"
    rc, out, _ = _build(tmp_path, _ISO, _INT, body)
    assert rc != 0 and "E2001" in out, out
    assert "expected Pi(x : Int64). Id_Int64(succ(succ(x)), x), got Pi(x : Int64). Id_Int64(pred(succ(x)), x)" in out, out


def test_the_parameters_of_a_generic_place_are_read_from_its_fields(tmp_path):
    top = _INT + "fun keep(e: Iso<Int64, Int64>): Iso<Int64, Int64> { return e }\n"
    body = _USE.replace(".-> Iso { forth succ left pred left_law eta }",
                        "keep(.-> Iso { forth succ left pred left_law eta })")
    assert _exit(tmp_path, _GENERIC, top, body) == 42
    # read as Iso<Int64, Int64>, the point is no Iso<Int64, Bool>
    top = _INT + "fun keep(e: Iso<Int64, Bool>): Iso<Int64, Bool> { return e }\n"
    body = "  e := keep(.-> Iso { forth succ left pred left_law eta })\n  return 42"
    rc, out, _ = _build(tmp_path / "other", _GENERIC, top, body)
    assert rc != 0 and "E2001" in out, out
    assert "keep: parameter e expects Iso<Int64, Bool>, got Iso<Int64, Int64>" in out, out


def test_a_field_that_names_a_field_after_it_is_refused(tmp_path):
    iso = ("place Iso {\n"
           "  left_law Πx : Int64, left(forth(x)) = x\n"
           "  forth Int64 -> Int64\n"
           "  left Int64 -> Int64\n"
           "}\n")
    rc, out, _ = _build(tmp_path, iso, "", "  return 42")
    assert rc != 0 and "E2001" in out, out
    assert ("place Iso: the type of field left_law names field forth, written after it: "
            "the type of a field names only the fields before it") in out, out


_ROUND = ("fun round(e: Iso, x: Int64): (x ↦ e.forth ↦ e.left) = x {\n"
          "  return x ↦ e.left_law\n"
          "}\n")


def test_a_proof_read_off_a_field_proves_the_statement_of_that_field(tmp_path):
    # x ↦ e.left_law has type (x ↦ e.forth ↦ e.left) = x: the field's type
    # with its earlier fields read off e, at the argument x; in the code the
    # same arrow applies a field read off a point
    body = ("  e := .-> Iso { forth succ left pred left_law eta }\n"
            "  return if (41 ↦ e.forth ↦ e.left) == 41 then 42 else 1")
    assert _exit(tmp_path, _ISO, _INT + _ROUND, body) == 42


def test_a_proof_read_off_a_field_proves_no_other_statement(tmp_path):
    other = _ROUND.replace("(x ↦ e.forth ↦ e.left) = x", "(x ↦ e.forth) = x")
    rc, out, _ = _build(tmp_path, _ISO, _INT + other, "  return 42")
    assert rc != 0 and "E2001" in out, out
    assert ("type mismatch: expected Id_Int64((x ↦ e.forth), x), "
            "got Id_Int64((x ↦ e.forth ↦ e.left), x)") in out, out


def test_the_fields_before_are_read_all_at_once(tmp_path):
    # forth is given left and left is given forth: the law asks
    # forth(left(x)) = x, that is x + 1 = x, and a proof of
    # forth(forth(x)) = x is no proof of it; read one field after another,
    # the value of forth would be read again as the field left
    top = ("fun forth(n: Int64): Int64 { return n }\n"
           "fun left(n: Int64): Int64 { return n + 1 }\n"
           "fun bogus(x: Int64): forth(forth(x)) = x { return clear }\n")
    body = "  e := .-> Iso { forth left left forth left_law bogus }\n  return 42"
    rc, out, _ = _build(tmp_path, _ISO, top, body)
    assert rc != 0 and "E2001" in out, out
    assert ("expected Pi(x : Int64). Id_Int64(forth(left(x)), x), "
            "got Pi(x : Int64). Id_Int64(forth(forth(x)), x)") in out, out


def test_a_point_named_like_a_field_reads_its_own_fields(tmp_path):
    top = _INT + _ROUND.replace("e: Iso", "left: Iso").replace("e.", "left.")
    body = ("  e := .-> Iso { forth succ left pred left_law eta }\n"
            "  return if (41 ↦ e.forth ↦ e.left) == 41 then 42 else 1")
    assert _exit(tmp_path, _ISO, top, body) == 42


def test_a_point_gives_every_field(tmp_path):
    body = "  e := .-> Iso { forth succ left pred }\n  return 42"
    rc, out, _ = _build(tmp_path, _ISO, _INT, body)
    assert rc != 0 and "E2001" in out, out
    assert ("place Iso: field left_law is not given: "
            "a point gives a value to each field of its place") in out, out


def test_a_point_gives_each_field_once(tmp_path):
    body = "  e := .-> Iso { forth succ left pred left_law eta forth pred }\n  return 42"
    rc, out, _ = _build(tmp_path, _ISO, _INT, body)
    assert rc != 0 and "E2001" in out, out
    assert "place Iso: field forth is given twice: a point gives each field once" in out, out


def test_the_formatter_writes_a_field_applied_with_the_arrow(tmp_path):
    src = tmp_path / "Entry.yon"
    src.write_text("place Entry {\n" + _ROUND +
                   "fun two(e: Iso): Int64 { return 41 ↦ e.forth ↦ e.left }\n}\n")
    r = subprocess.run([str(ROOT / "toolchain" / "yon-fmt"), str(src)],
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "fun round(e: Iso, x: Int64): (x ↦ e.forth ↦ e.left) = x {" in r.stdout, r.stdout
    assert "return x ↦ e.left_law" in r.stdout, r.stdout
    assert "return 41 ↦ e.forth ↦ e.left" in r.stdout, r.stdout
