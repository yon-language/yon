"""(K, V) in a type is the non-dependent product, the Sigma that already exists.

The parentheses are syntax for Sigma with a fibre that ignores its point: no new type and no place
behind them. A value is built with pair and read with fst and snd, a value written with one form
flows into the other, and a wrong component is refused by the check that a Sigma already has. Before
an arrow the same parentheses stay the arguments of a fun. Three components have no reading in a type
and the refusal shows the nested form.

Layer/kind: frontend + native / end-to-end.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
YONFMT = ROOT / "frontend" / "_build" / "default" / "yonfmt.exe"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _compile(tmp_path, src):
    f = tmp_path / "p.yon"
    f.write_text(src)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(f), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r, exe


def _entry(body, main):
    return "place Entry {\n" + body + "  fun main: Number { " + main + " }\n}\n"


def _runs(tmp_path, body, main):
    r, exe = _compile(tmp_path, _entry(body, main))
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).returncode


def _refused(tmp_path, body, main, *words):
    r, _ = _compile(tmp_path, _entry(body, main))
    out = r.stdout + r.stderr
    assert r.returncode != 0, out
    assert "Fatal error" not in out, out
    assert "exception" not in out.lower(), out
    for w in words:
        assert w in out, out
    return out


def _mlir(tmp_path, name, src):
    """The MLIR of a source. Every program is called p.yon, in a directory of its own: the name of a
    file does not enter the comparison."""
    d = tmp_path / name
    d.mkdir()
    (d / "p.yon").write_text(src)
    r = subprocess.run([str(YONC), "--emit=mlir", "p.yon"], cwd=d,
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return (d / "p.topos.mlir").read_text()


# the three examples shown to Antonio, written with the parentheses

def test_a_product_swaps_its_components(tmp_path):
    body = "  fun swap(p: (Number, Boolean)): (Boolean, Number) { return pair(snd(p), fst(p)) }\n"
    assert _runs(tmp_path, body, "return snd(swap(pair(7, true)))") == 7


def test_a_generic_reads_its_parameters_from_a_product(tmp_path):
    body = "  fun first<K, V>(p: (K, V)): K { return fst(p) }\n"
    assert _runs(tmp_path, body, "return first(pair(42, 7))") == 42


def test_a_list_holds_products(tmp_path):
    body = "  fun keys<K, V>(xs: List<(K, V)>): Number { return List.length(xs) }\n"
    assert _runs(tmp_path, body, "return keys(List.cons(pair(1, 2), List.empty))") == 1


# nesting, the other component and the other positions of a type

def test_a_product_nests(tmp_path):
    body = "  fun mid(p: (Number, (Number, Number))): Number { return fst(snd(p)) }\n"
    assert _runs(tmp_path, body, "return mid(pair(1, pair(42, 3)))") == 42


def test_the_second_component(tmp_path):
    body = "  fun second<K, V>(p: (K, V)): V { return snd(p) }\n"
    assert _runs(tmp_path, body, "return second(pair(42, 7))") == 7


def test_a_product_as_a_result(tmp_path):
    body = "  fun twin(x: Number): (Number, Number) { return pair(x, x + 1) }\n"
    assert _runs(tmp_path, body, "return snd(twin(41))") == 42


def test_a_product_nests_on_the_left(tmp_path):
    body = "  fun head(p: ((Number, Number), Number)): Number { return snd(fst(p)) }\n"
    assert _runs(tmp_path, body, "return head(pair(pair(1, 42), 3))") == 42


def test_a_product_with_components_of_different_types(tmp_path):
    body = "  fun size(p: (Text, Number)): Number { return snd(p) }\n"
    assert _runs(tmp_path, body, 'return size(pair("a", 42))') == 42


# no new type: the parentheses, Sigma and the meet of two paths are one product

def test_a_product_flows_into_its_sigma(tmp_path):
    body = ("  fun up(p: (Number, Number)): Σx : Number, Number { return p }\n"
            "  fun down(p: Σx : Number, Number): (Number, Number) { return p }\n")
    assert _runs(tmp_path, body, "return fst(down(up(pair(42, 7))))") == 42


def test_the_parentheses_compile_to_the_sigma_they_stand_for(tmp_path):
    main = "  fun main: Number { return f(pair(42, 7)) }\n}\n"
    parens = "place Entry {\n  fun f(p: (Number, Number)): Number { return fst(p) }\n" + main
    sigma = "place Entry {\n  fun f(p: Σ_ : Number, Number): Number { return fst(p) }\n" + main
    assert _mlir(tmp_path, "a", parens) == _mlir(tmp_path, "b", sigma)


def test_a_meet_of_paths_is_the_product_of_the_paths(tmp_path):
    body = ("  fun first_of(a: Number, q: (a = a) ∧ (a = a)): a = a { return fst(q) }\n"
            "  fun both(a: Number): (a = a) ∧ (a = a) { return pair(refl(a), refl(a)) }\n")
    assert _runs(tmp_path, body, "first_of(42, both(42))\n  return 42") == 42


def test_no_place_stands_behind_the_parentheses(tmp_path):
    body = "  fun f(p: Pair): Number { return 0 }\n"
    _refused(tmp_path, body, "return 0", "E2001", "unknown user type: Pair")


def test_a_wrong_component_is_refused(tmp_path):
    body = "  fun f(p: (Number, Text)): Number { return 0 }\n"
    _refused(tmp_path, body, "return f(pair(1, 2))", "E2001", "parameter p expects")


def test_a_component_read_at_the_wrong_type_is_refused(tmp_path):
    body = "  fun f(p: (Number, Text)): Number { return snd(p) }\n"
    _refused(tmp_path, body, 'return f(pair(1, "a"))', "E2001", "type mismatch")


# before an arrow the parentheses are the arguments of a fun

ADD = "  fun add(x: Number, y: Number): Number { return x + y }\n"


def test_before_an_arrow_they_are_two_arguments(tmp_path):
    body = ADD + "  fun apply(f: (Number, Number) -> Number): Number { return f(40, 2) }\n"
    assert _runs(tmp_path, body, "return apply(add)") == 42


def test_before_an_arrow_the_two_arguments_are_not_a_pair(tmp_path):
    body = ADD + "  fun apply(f: (Number, Number) -> Number): Number { return f(pair(40, 2)) }\n"
    _refused(tmp_path, body, "return apply(add)", "E2001", "HOF f: parameter expects Number")


def test_three_arguments_before_an_arrow_stay_arguments(tmp_path):
    body = ("  fun add3(x: Number, y: Number, z: Number): Number { return x + y + z }\n"
            "  fun apply(f: (Number, Number, Number) -> Number): Number { return f(40, 1, 1) }\n")
    assert _runs(tmp_path, body, "return apply(add3)") == 42


def test_a_product_as_one_argument_is_written_in_its_own_parentheses(tmp_path):
    body = ("  fun left(p: (Number, Number)): Number { return fst(p) }\n"
            "  fun apply(f: ((Number, Number)) -> Number): Number { return f(pair(42, 7)) }\n")
    assert _runs(tmp_path, body, "return apply(left)") == 42


def test_a_product_as_one_of_two_arguments(tmp_path):
    body = ("  fun plus(p: (Number, Number), z: Number): Number { return fst(p) + z }\n"
            "  fun apply(f: ((Number, Number), Number) -> Number): Number { return f(pair(40, 7), 2) }\n")
    assert _runs(tmp_path, body, "return apply(plus)") == 42


def test_a_product_after_an_arrow(tmp_path):
    body = ("  fun twin(x: Number): (Number, Number) { return pair(x, x) }\n"
            "  fun apply(f: Number -> (Number, Number)): Number { return fst(f(42)) }\n")
    assert _runs(tmp_path, body, "return apply(twin)") == 42


# three components have no reading

@pytest.mark.parametrize("ty", [
    "(Number, Number, Number)",
    "(Number, Number, Number, Number)",
    "List<(Number, Number, Number)>",
    "(Number, (Number, Number, Number))",
])
def test_three_components_are_refused_with_the_nested_form(tmp_path, ty):
    body = f"  fun f(p: {ty}): Number {{ return 0 }}\n"
    _refused(tmp_path, body, "return 0",
             "E1001", "a product has two components", "(A, (B, C))")


def test_three_components_as_a_result_are_refused(tmp_path):
    body = "  fun f: (Number, Number, Number) { return 0 }\n"
    _refused(tmp_path, body, "return 0",
             "E1001", "a product has two components", "(A, (B, C))")


def test_the_nested_form_of_the_refusal_compiles(tmp_path):
    body = "  fun last(p: (Number, (Number, Number))): Number { return snd(snd(p)) }\n"
    assert _runs(tmp_path, body, "return last(pair(1, pair(2, 42)))") == 42


# a path is a component of a product through the meet: without a ∧ its `=` stays out of the parentheses

def test_a_path_in_the_parentheses_is_a_parse_error(tmp_path):
    body = "  fun f(a: Number, q: (a = a, a = a)): Number { return 0 }\n"
    _refused(tmp_path, body, "return 0", "PARSE ERROR", "E1001")


# the grammar decides the parentheses before an arrow without a conflict

@pytest.mark.skipif(not shutil.which("menhir"), reason="menhir missing")
def test_the_grammar_has_no_conflict(tmp_path):
    shutil.copy(ROOT / "frontend" / "parser.mly", tmp_path / "parser.mly")
    r = subprocess.run(["menhir", "--interpret", "parser.mly"], cwd=tmp_path, stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=300)
    out = r.stdout + r.stderr
    assert r.returncode == 0, out
    assert "conflict" not in out, out
    assert "Warning" not in out, out


# what the formatter writes is the same program

def _formatted_is_the_same_program(tmp_path, fun):
    src = _entry(fun, "return 0")
    f = tmp_path / "p.yon"
    f.write_text(src)
    r = subprocess.run([str(YONFMT), str(f)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
    assert _mlir(tmp_path, "before", src) == _mlir(tmp_path, "after", r.stdout), r.stdout


@pytest.mark.skipif(not YONFMT.exists(), reason="yonfmt missing")
@pytest.mark.parametrize("fun", [
    "  fun f(p: (Number, (Number, Number))): Number { return fst(snd(p)) }\n",
    "  fun g(k: (Number, Number) -> Number): Number { return k(1, 2) }\n",
])
def test_the_formatter_keeps_the_program(tmp_path, fun):
    _formatted_is_the_same_program(tmp_path, fun)


# the formatter writes a Sigma domain without its parentheses, and the arrow enters the fibre
@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="a Sigma as the only domain of an arrow is formatted as a Sigma of an arrow")
@pytest.mark.skipif(not YONFMT.exists(), reason="yonfmt missing")
@pytest.mark.parametrize("fun", [
    "  fun h(k: ((Number, Number)) -> Number): Number { return k(pair(1, 2)) }\n",
    "  fun s(k: (Σx : Number, Number) -> Number): Number { return k(pair(1, 2)) }\n",
])
def test_the_formatter_keeps_a_sigma_domain(tmp_path, fun):
    _formatted_is_the_same_program(tmp_path, fun)


# a field of a place

def _project(tmp_path, places, main):  # one place Holder beside the Entry, in a world of its own
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(
        '[package]\nname = "holder"\n\n[world.W]\nobjects = ["Holder"]\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Holder.yon").write_text(places)
    (proj / "Entry.yon").write_text(main)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).returncode


FORMS = ["(Number, Number)", "Σx : Number, Number"]
FIELD = ("place Entry {\n  fun main: Number {\n"
         "    h := .-> Holder { both pair(40, 2) }\n"
         "    return %s(h.both)\n  }\n}\n")


@pytest.mark.parametrize("ty", FORMS)
def test_the_first_component_of_a_field(tmp_path, ty):
    assert _project(tmp_path, f"place Holder {{\n  both {ty}\n}}\n", FIELD % "fst") == 40


# the field declares the size of one word for a value of two: the same with Σ and with the parentheses
@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="the second component of a Sigma field reads 0, not what was stored")
@pytest.mark.parametrize("ty", FORMS)
def test_the_second_component_of_a_field(tmp_path, ty):
    assert _project(tmp_path, f"place Holder {{\n  both {ty}\n}}\n", FIELD % "snd") == 2
