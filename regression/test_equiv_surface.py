"""The symbols of equality: an equivalence is `f <=> g`, with its laws closed by
computation or given after `by`; the transport is its application, `x ↦ e`, the
way chosen by the type of x; where a path between types is asked, an
equivalence is that path (univalence). `ua(…)`, `equiv(…)` and `carry … along`
are primitives of the kernel, not written."""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = ('[package]\nname = "equiv"\n\n[world.W]\nobjects = ["Bool", "Bit", "Tri", "Ter"]\n\n'
         '[runtime]\nbackend = "memory"\n')
LSP = ROOT / "frontend" / "_build" / "default" / "yon_lsp.exe"

_BOOL_BIT = """\
fun b2bit(b: Bool): Bit { return match b { tt => one, ff => zero } }
fun bit2b(x: Bit): Bool { return match x { one => tt, zero => ff } }
fun eta(a: Bool): bit2b(b2bit(a)) = a { return match a { tt => clear tt, ff => clear ff } }
fun eps(b: Bit): b2bit(bit2b(b)) = b { return match b { one => clear one, zero => clear zero } }
"""

_SUCC_PRED = """\
fun succ(n: Int64): Int64 { return n + 1 }
fun pred(n: Int64): Int64 { return n - 1 }
"""


def _build(tmp_path: Path, top: str, body: str):
    proj = tmp_path / "proj"
    proj.mkdir(parents=True)
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Bool.yon").write_text("place Bool { this > tt :U ff }\n")
    (proj / "Bit.yon").write_text("place Bit { this > one :U zero }\n")
    (proj / "Tri.yon").write_text("place Tri { this > ta :U tb :U tc }\n")
    (proj / "Ter.yon").write_text("place Ter { this > xa :U xb :U xc }\n")
    (proj / "Entry.yon").write_text(
        "place Entry {\n" + top + "fun main: Number {\n" + body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _exit(tmp_path, top, body):
    rc, out, exe = _build(tmp_path, top, body)
    assert rc == 0, out
    return subprocess.run([str(exe)], capture_output=True, timeout=30).returncode


def test_the_transport_runs_forth_from_the_source_and_back_from_the_target(tmp_path):
    # Bool ≃ Bit by two funs of proof: tt goes to one, and zero comes back to ff
    body = ("  bridge := b2bit <=> bit2b by eta, eps\n"
            "  far := tt ↦ bridge\n"
            "  near := zero ↦ bridge\n"
            "  a := match far { one => 40, zero => 0 }\n"
            "  b := match near { tt => 0, ff => 2 }\n"
            "  return a + b")
    assert _exit(tmp_path, _BOOL_BIT, body) == 42


def test_on_an_equivalence_of_a_type_with_itself_the_transport_runs_forth_and_undo_runs_back(tmp_path):
    body = ("  bridge := succ <=> pred\n"
            "  y := 41 ↦ bridge\n"
            "  undone := undo(bridge)\n"
            "  z := y ↦ undone\n"
            "  return if y == 42 and z == 41 then 42 else 1")
    assert _exit(tmp_path, _SUCC_PRED, body) == 42


def test_an_equivalence_is_the_path_between_its_types_where_a_path_is_asked(tmp_path):
    # univalence: transport takes the equivalence in the place of its path (a
    # fun whose type is a path between types returns one: the suspension of
    # Boolean is the circle, test_hits_in_the_prelude.py)
    top = _BOOL_BIT
    body = ("  y := transport((b2bit <=> bit2b by eta, eps), tt)\n"
            "  return match y { one => 42, zero => 1 }")
    assert _exit(tmp_path, top, body) == 42


def test_without_by_the_laws_are_closed_by_computation_or_the_equivalence_is_refused(tmp_path):
    # succ and succ undo nothing: the law g(f(a)) = a does not close
    rc, out, _ = _build(tmp_path, _SUCC_PRED, "  bridge := succ <=> succ\n  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch" in out, out


def test_a_value_of_neither_end_is_not_carried(tmp_path):
    body = "  bridge := b2bit <=> bit2b by eta, eps\n  y := 5 ↦ bridge\n  return 42"
    rc, out, _ = _build(tmp_path, _BOOL_BIT, body)
    assert rc != 0 and "E2001" in out, out
    assert "bridge is an equivalence between Bool and Bit, and the value carried along it has type" in out, out


@pytest.mark.parametrize("body,words", [
    ("  y := transport(ua(succ <=> pred), 41)\n  return 42",
     "ua(e) is not written: by univalence an equivalence is the path between its types"),
    ("  bridge := equiv(succ, pred, fun(a) => clear a, fun(b) => clear b)\n  return 42",
     "equiv(f, g, eta, eps) is not written: an equivalence is f <=> g by eta, eps"),
    ("  bridge := succ <=> pred\n  y := carry 41 along bridge\n  return 42",
     "carry x along e is not written: the transport is the application of the equivalence"),
])
def test_the_primitives_of_the_kernel_are_not_written(tmp_path, body, words):
    rc, out, _ = _build(tmp_path, _SUCC_PRED, body)
    assert rc != 0 and "E1001" in out, out
    assert words in out, out


# a turn of three points: forth is not its own inverse, so forth and back tell
# apart what they give
_TURN = """\
fun f(t: Tri): Ter { return match t { ta => xb, tb => xc, tc => xa } }
fun g(x: Ter): Tri { return match x { xa => tc, xb => ta, xc => tb } }
fun eta(a: Tri): g(f(a)) = a { return match a { ta => clear ta, tb => clear tb, tc => clear tc } }
fun eps(b: Ter): f(g(b)) = b { return match b { xa => clear xa, xb => clear xb, xc => clear xc } }
"""


def test_back_from_the_target_is_the_undo_and_not_the_forth(tmp_path):
    # xa comes back to tc (forth would give xb); ta goes to xb
    body = ("  turn := f <=> g by eta, eps\n"
            "  near := xa ↦ turn\n"
            "  far := ta ↦ turn\n"
            "  a := match near { ta => 1, tb => 2, tc => 40 }\n"
            "  b := match far { xa => 0, xb => 2, xc => 7 }\n"
            "  return a + b")
    assert _exit(tmp_path, _TURN, body) == 42


def test_a_fun_of_the_program_named_undo_is_called_once_as_a_fun(tmp_path):
    # undo is the reverse of an equivalence only where no fun has the name: a
    # fun undo is checked as a fun, and its call is not copied where it is used
    top = 'fun undo(n: Int64): Int64 {\n  _ := Text.print("undone")\n  return n + 1\n}\n'
    rc, out, exe = _build(tmp_path, top, "  u := undo(41)\n  return if u == 42 and u + 0 == 42 then 42 else 1")
    assert rc == 0, out
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 42 and r.stdout.count("undone") == 1, r.stdout


def test_a_fun_of_the_program_named_undo_leaves_the_transport_back_to_the_equivalence(tmp_path):
    top = _BOOL_BIT + "fun undo(n: Int64): Int64 { return n + 1 }\n"
    body = ("  bridge := b2bit <=> bit2b by eta, eps\n"
            "  near := zero ↦ bridge\n"
            "  return match near { tt => 1, ff => 42 }")
    assert _exit(tmp_path, top, body) == 42


def _types(tmp_path: Path, top: str) -> str:
    proj = tmp_path / "proj"
    proj.mkdir(parents=True)
    (proj / "yon.toml").write_text(_TOML)
    for n, arms in (("Bool", "tt :U ff"), ("Bit", "one :U zero"), ("Tri", "ta :U tb :U tc"), ("Ter", "xa :U xb :U xc")):
        (proj / f"{n}.yon").write_text(f"place {n} {{ this > {arms} }}\n")
    (proj / "Entry.yon").write_text("place Entry {\n" + top + "fun main: Number { return 42 }\n}\n")
    r = subprocess.run([str(LSP), "--check", str(proj / "Entry.yon")],
                       capture_output=True, text=True, timeout=120)
    return r.stdout + r.stderr


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp missing")
def test_an_equivalence_is_a_path_returned_or_passed_where_one_is_asked(tmp_path):
    # univalence against the declared type of a return and of a parameter: the
    # types check; a path received as a parameter has no line known at compile
    # time to transport along (test_audit_probes.py)
    top = (_SUCC_PRED
           + "fun line: Int64 = Int64 {\n  return succ <=> pred\n}\n"
           + "fun go(p: Int64 = Int64, v: Int64): Int64 { return transport(p, v) }\n"
           + "fun used: Int64 { return go(succ <=> pred, 10) }\n")
    out = _types(tmp_path, top)
    # the server ran (it lints the fun nothing calls) and found no error
    assert "function 'line' is never used" in out and "error" not in out, out
