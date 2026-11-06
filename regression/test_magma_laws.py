"""Generated<V>, a presentation written in Yon: an operation and its generators.

The closure takes no law for granted, the laws are decided on the whole closure,
and a closure past the declared limit is a DomainError that names the limit. Land
composes disjoint generators by pairs, which holds with no law of the operation.
A generic field is instantiated through an applied type and a product domain.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_OPS = (
    "fun plus(a: Number, b: Number): Number { return a + b }\n"
    "fun minus(a: Number, b: Number): Number { return a - b }\n"
    "fun lub(a: Number, b: Number): Number { return if a > b then a else b }\n"
    "fun minus5(a: Number, b: Number): Number { return Math.modulo(a - b + 5, 5) }\n"
    "fun left(a: Number, b: Number): Number { return a }\n"
    "fun is3(a: Number): Boolean { return a == 3 }\n"
    "fun is5(a: Number): Boolean { return a == 5 }\n"
    "fun report(d: DomainError): Number {\n"
    '  return if d.message == "the closure holds more than 512 elements" then 2 else 3\n'
    "}\n"
)


def _on(op: str, *gens) -> str:
    """The expression of a presentation over the given generators."""
    m = f"Generated.generated_by({op}, HashSet.empty)"
    for g in gens:
        m = f"Generated.gen({m}, {g})"
    return m


def _build(tmp_path: Path, body: str, places: dict = None):
    proj = tmp_path / "proj"
    proj.mkdir()
    objs = ", ".join(f'"{p}"' for p in (places or {}))
    (proj / "yon.toml").write_text(
        '[package]\nname = "mag"\n\n'
        + (f"[world.W]\nobjects = [{objs}]\n\n" if places else "")
        + '[runtime]\nbackend = "memory"\n')
    for name, src in (places or {}).items():
        (proj / f"{name}.yon").write_text(src)
    (proj / "Entry.yon").write_text(
        "place Entry {\n" + _OPS + "fun main: Number {\n" + body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _value(tmp_path: Path, body: str) -> int:
    rc, out, exe = _build(tmp_path, body)
    assert rc == 0, out
    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
    assert "error:" not in r.stderr, r.stderr
    return r.returncode


def _size(m: str) -> str:
    return (f"  return match Generated.closure({m}) {{\n"
            "    Value as c => HashSet.size(c),\n"
            "    DomainError as d => 99\n  }")


def _law(fun: str, m: str) -> str:
    return (f"  return match Generated.{fun}({m}) {{\n"
            "    Boolean as b => if b then 1 else 0,\n"
            "    DomainError as d => 2\n  }")


def _refusal(fun: str, m: str, case: str) -> str:
    return (f"  return match Generated.{fun}({m}) {{\n    {case} => 1,\n"
            "    DomainError as d => report(d)\n  }")


# --- the closure -----------------------------------------------------------------------


def test_the_closure_is_the_least_closed_set(tmp_path):
    assert _value(tmp_path, _size(_on("lub", 3, 5))) == 2


def test_subtraction_modulo_5_on_one_generator_closes_on_five_elements(tmp_path):
    # the one generator commutes with itself: a closure that skipped (b, a) would stop short
    assert _value(tmp_path, _size(_on("minus5", 1))) == 5


def test_the_closure_is_a_set_of_the_elements_it_reaches(tmp_path):
    body = ("  return match Generated.closure(" + _on("minus5", 1) + ") {\n"
            "    Value as c => if HashSet.contains(c, 4) and not HashSet.contains(c, 5) then 1 else 0,\n"
            "    DomainError as d => 2\n  }")
    assert _value(tmp_path, body) == 1


def test_the_closure_of_no_generator_is_empty(tmp_path):
    assert _value(tmp_path, _size(_on("plus"))) == 0


def test_a_closure_past_the_limit_is_refused_and_names_the_limit(tmp_path):
    assert _value(tmp_path, _refusal("closure", _on("plus", 1), "Value as c")) == 2


def test_a_closure_up_to_the_limit_is_given_whole(tmp_path):
    # lub on the limit's generators holds exactly the limit, nothing is cut
    gens = ("  mut m := " + _on("lub") + "\n  mut i := 0\n"
            "  while i < Generated.closure_limit do {\n"
            "    m <- Generated.gen(m, i)\n    i <- i + 1\n  }\n")
    body = gens + ("  return match Generated.closure(m) {\n"
                   "    Value as c => if HashSet.size(c) == 512 then 1 else 0,\n"
                   "    DomainError as d => 2\n  }")
    assert _value(tmp_path, body) == 1


def test_a_set_lists_every_element_zero_among_them(tmp_path):
    body = ("  s := HashSet.add(HashSet.add(HashSet.empty, 0), 7)\n"
            "  return List.length(HashSet.to_stream(s)) * 10 + List.fold_left(HashSet.to_stream(s), 0, plus)")
    assert _value(tmp_path, body) == 27


def test_subtraction_on_three_has_no_finite_closure(tmp_path):
    # in C it was 2, without (0, 3): the generator commutes with itself and the pair was skipped
    assert _value(tmp_path, _refusal("closure", _on("minus", 3), "Value as c")) == 2


_BIT = ("place Bit {\n"
        "  this > Naught :U Tick\n"
        "  fun flip(a: Bit, b: Bit): Bit {\n"
        "    return match a { Naught => b, Tick => match b { Naught => Tick, Tick => Naught } }\n"
        "  }\n"
        "}\n")


@pytest.mark.xfail(strict=True, raises=AssertionError,
                   reason="a value of a place with arms reaches the generic fun as a double: "
                          "the MLIR of the section conversion does not verify")
def test_the_elements_may_be_the_values_of_a_place(tmp_path):
    rc, out, exe = _build(tmp_path, (
        "  return match Generated.closure(Generated.gen(Generated.generated_by("
        "fun(a: Bit, b: Bit) => Bit.flip(a, b), HashSet.empty), Tick)) {\n"
        "    Value as c => HashSet.size(c),\n    DomainError as d => 99\n  }"), {"Bit": _BIT})
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 2


# --- the laws, decided on the closure --------------------------------------------------


def test_the_laws_hold_on_the_least_upper_bound(tmp_path):
    assert _value(tmp_path, _law("is_commutative", _on("lub", 3, 5))) == 1
    (tmp_path / "a").mkdir()
    assert _value(tmp_path / "a", _law("is_associative", _on("lub", 3, 5))) == 1


def test_subtraction_modulo_5_is_not_commutative_though_its_generator_commutes(tmp_path):
    assert _value(tmp_path, _law("is_commutative", _on("minus5", 1))) == 0


def test_subtraction_modulo_5_is_not_associative(tmp_path):
    assert _value(tmp_path, _law("is_associative", _on("minus5", 1))) == 0


def test_the_left_projection_is_associative_and_not_commutative(tmp_path):
    assert _value(tmp_path, _law("is_associative", _on("left", 1, 2))) == 1
    (tmp_path / "a").mkdir()
    assert _value(tmp_path / "a", _law("is_commutative", _on("left", 1, 2))) == 0


@pytest.mark.parametrize("fun", ["is_commutative", "is_associative"])
def test_a_law_on_an_infinite_closure_is_refused_and_names_the_limit(tmp_path, fun):
    assert _value(tmp_path, _refusal(fun, _on("minus", 3), "Boolean as b")) == 2


# --- the identity ----------------------------------------------------------------------


def test_the_identity_is_the_generator_neutral_on_the_generators(tmp_path):
    body = ("  return match Generated.identity(" + _on("plus", 0, 4) + ") {\n"
            "    Absent => 9,\n    Found as e => e + 1\n  }")
    assert _value(tmp_path, body) == 1


def test_no_generator_neutral_means_no_identity(tmp_path):
    body = ("  return match Generated.identity(" + _on("plus", 3, 4) + ") {\n"
            "    Absent => 9,\n    Found as e => e + 1\n  }")
    assert _value(tmp_path, body) == 9


# --- Land ------------------------------------------------------------------------------


def _reach(m: str, target) -> str:
    return f"  return if Land.reach({m}, {target}) then 1 else 0"


def test_land_reaches_by_disjoint_generators(tmp_path):
    assert _value(tmp_path, _reach(_on("plus", 3, 5, 7), 15)) == 1


def test_land_uses_each_generator_at_most_once(tmp_path):
    assert _value(tmp_path, _reach(_on("plus", 3, 5, 7), 9)) == 0


def test_land_composes_by_pairs_with_no_associativity(tmp_path):
    # 10 - (5 - 2) = 7 is no left fold of the generators
    assert _value(tmp_path, _reach(_on("minus", 10, 5, 2), 7)) == 1


def test_land_does_not_use_a_generator_twice_under_subtraction(tmp_path):
    assert _value(tmp_path, _reach(_on("minus", 3), 0)) == 0


def test_land_ends_on_an_infinite_closure(tmp_path):
    assert _value(tmp_path, _reach(_on("plus", 1, 2), 100)) == 0


@pytest.mark.parametrize("target,shape", [(8, 211), (10, 210)])
def test_the_witness_is_the_generators_used(tmp_path, target, shape):
    """100 per element of the witness, 10 per 3 in it, 1 per 5 in it: a witness of
    the right sum and of other elements, [8] or [1, 7], gives another number."""
    body = ("  return match Land.witness(" + _on("plus", 3, 5, 7) + f", {target}) {{\n"
            "    Absent => 0,\n"
            "    Found as w => List.length(w) * 100\n"
            "      + List.length(List.filter(w, is3)) * 10\n"
            "      + List.length(List.filter(w, is5))\n  }")
    assert _value(tmp_path, body) == shape


def test_no_witness_where_the_target_is_not_reached(tmp_path):
    body = ("  return match Land.witness(" + _on("plus", 3, 5, 7) + ", 9) {\n"
            "    Absent => 1,\n    Found as w => 0\n  }")
    assert _value(tmp_path, body) == 1


# --- a generic field through an applied type and a product domain ----------------------


_BOX = ("place Box<V> {\n"
        "  items List<V>\n"
        "  fun make<V>(items: List<V>): Box<V> { return .-> Box { items items } }\n"
        "  fun first<V>(b: Box<V>): Lookup<V> { return List.head(b.items) }\n"
        "}\n")


def test_a_field_of_an_applied_type_is_instantiated(tmp_path):
    rc, out, exe = _build(tmp_path, (
        "  return match Box.first(Box.make(List.cons(41, List.empty))) {\n"
        "    Absent => 0,\n    Found as x => x + 1\n  }"), {"Box": _BOX})
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


def test_a_field_of_an_applied_type_refuses_another_argument(tmp_path):
    # the parameter stands for the argument of this box: a list of Number is no list of String
    rc, out, _ = _build(tmp_path, (
        "  b := Box.make(List.cons(41, List.empty))\n"
        "  return String.length(List.head(b.items))"), {"Box": _BOX})
    assert rc != 0 and "E2001" in out, out
    assert "Lookup<number>" in out, out


_FOLDER = ("place Folder<V> {\n"
           "  step (V, V) -> V\n"
           "  fun with_step<V>(s: (V, V) -> V): Folder<V> { return .-> Folder { step s } }\n"
           "  fun twice<V>(f: Folder<V>, x: V): V { g := f.step  return g(x, x) }\n"
           "}\n")


def test_a_field_of_a_product_domain_is_instantiated(tmp_path):
    rc, out, exe = _build(tmp_path, "  return Folder.twice(Folder.with_step(plus), 21)",
                          {"Folder": _FOLDER})
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


def test_a_field_of_a_product_domain_refuses_another_argument(tmp_path):
    rc, out, _ = _build(tmp_path, (
        "  f := Folder.with_step(plus)\n"
        "  g := f.step\n"
        "  return g(\"a\", \"b\")"), {"Folder": _FOLDER})
    assert rc != 0 and "E2001" in out, out
    assert "parameter expects number, got text" in out, out
