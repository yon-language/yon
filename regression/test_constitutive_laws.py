"""A law in the body of a place with arms is constitutive: it generates a cell.

The arms are the 0-cells of a computad, each law a cell. A cell is an arrow with a name in
the house; the match wants a branch for each cell, and that branch is a path between what
the match gives at the two ends of the cell, which the kernel's conversion decides.

Layer/kind: frontend + native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

TOML = ('[package]\nname = "probe"\n\n[world.W]\nobjects = ["X"]\nspaces  = ["w"]\n\n'
        '[runtime]\nbackend = "memory"\n')


def _compile(tmp_path, entry, places):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text(TOML)
    (proj / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    for name, text in places.items():
        (proj / "w" / (name + ".yon")).write_text(text)
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    return r, exe


def _exit(tmp_path, entry, places):
    r, exe = _compile(tmp_path, entry, places)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, timeout=60).returncode


def _refused(tmp_path, entry, places, code, *words):
    r, _ = _compile(tmp_path, entry, places)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and code in out, out
    for w in words:
        assert w in out, out


CERCHIO = {"Cerchio": "place Cerchio { this > punto  law giro punto = punto }\n"}


def _uso(funs, main="return 42"):
    return "place Uso {\n" + funs + "}\n"


def test_a_cell_needs_a_branch_of_its_own(tmp_path):
    uso = {**CERCHIO, "Uso": _uso("fun f(s: Cerchio): Number { return match s { punto => 42 } }\n")}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso,
             "E2001", "missing branch(es) for giro")


def test_a_map_out_of_the_circle_respects_its_cell(tmp_path):
    uso = {**CERCHIO, "Uso": _uso(
        "fun f(s: Cerchio): Number { return match s { punto => 42, giro => plam i => 42 } }\n"
        "fun run: Number { return f(punto) }\n")}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", uso) == 42


def test_a_branch_whose_ends_miss_the_points_is_refused(tmp_path):
    uso = {**CERCHIO, "Uso": _uso(
        "fun f(s: Cerchio): Number { return match s { punto => 42, giro => plam i => 41 } }\n")}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso, "E2001", "mismatch")


def test_a_cell_is_a_path_between_its_ends(tmp_path):
    uso = {**CERCHIO, "Uso": _uso(
        "fun g: punto = punto { return giro }\n"
        "fun at0: Cerchio { return giro @ I0 }\n"
        "fun run: Number { return match at0 { punto => 42, giro => plam i => 42 } }\n")}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", uso) == 42


SOSPESO = {"Sospeso": "place Sospeso<A> { this > nord :U sud  law meridiano ∀a : A, nord = sud }\n"}


def test_a_quantified_cell_is_applied_like_an_arrow(tmp_path):
    uso = {**SOSPESO, "Uso": _uso(
        "fun m(x: Number): nord = sud { return x ↦ meridiano }\n"
        "fun run: Number { return 42 }\n")}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", uso) == 42


def test_the_branch_of_a_quantified_cell_binds_its_variable(tmp_path):
    uso = {**SOSPESO, "Uso": _uso(
        "fun f(s: Sospeso<Number>): Number {\n"
        "  return match s { nord => 1, sud => 1, meridiano as a => plam i => 1 }\n}\n"
        "fun run: Number { return f(nord) * 42 }\n")}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", uso) == 42


def test_a_meridian_between_two_different_values_is_refused(tmp_path):
    uso = {**SOSPESO, "Uso": _uso(
        "fun f(s: Sospeso<Number>): Number {\n"
        "  return match s { nord => 1, sud => 2, meridiano as a => plam i => 1 }\n}\n")}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso, "E2001", "mismatch")


def test_ends_of_two_types_are_refused(tmp_path):
    bad = {"Bad": "place Bad { this > a :U b  law storta a = 1 }\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", bad,
             "E2001", "law storta of Bad", "different types")


def test_a_law_that_is_no_equation_is_refused(tmp_path):
    bad = {"Bad": "place Bad { this > a :U b  law storta ∀x : Bad, x }\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", bad,
             "E2001", "source = target")


def test_a_cell_has_a_name_in_the_house(tmp_path):
    bad = {"Bad": "place Bad {\n  this > a :U b\n  law giro a = a\n"
                  "  fun giro(x: Number): Number { return x }\n}\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", bad,
             "E2005", "giro")


def test_a_law_with_is_given_is_an_axiom_and_no_cell(tmp_path):
    ok = {"Ax": "place Ax { this > a :U b  law assioma a = b is given }\n",
          "Uso": _uso("fun f(s: Ax): Number { return match s { a => 42, b => 42 } }\n"
                      "fun run: Number { return f(a) }\n")}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", ok) == 42


def test_a_path_arm_comes_back_as_a_law(tmp_path):
    # the slot for path arms in the clause is refused; the law is its form
    ok = {"Lista": "place Lista {\n  this > Vuota :U Testa Number Lista\n  law dup Vuota = Vuota\n}\n",
          "Uso": _uso("fun f(l: Lista): Number {\n"
                      "  return match l { Vuota => 42, Testa as (h, t) => 42, dup => plam i => 42 }\n}\n"
                      "fun run: Number { return f(Vuota) }\n")}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", ok) == 42
