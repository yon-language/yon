"""A conjunction of parenthesized paths in a type is the non-dependent product of the paths.

`(a = b) ∧ (c = d)` in a type is the meet read as a product (BHK): no new type, the values are
built with pair and read with fst and snd. In a law, `∧` is a value in Omega. In a type `∧` does not
stand bare among the endpoints of a path, and an operand of `∧` is a path in its parentheses:
`a = b ∧ c` is refused, an endpoint that is a meet is written `a = (b ∧ c)`.

Layer/kind: frontend + native / end-to-end.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

# a small peak, with its two projections: what the statement of peak_of asks of them
PEAK = """
place Peak {
  this > mk Number Number

  fun left(p: Peak): Number {
    return match p { mk as (l, r) => l }
  }

  fun right(p: Peak): Number {
    return match p { mk as (l, r) => r }
  }
}
"""


def _compile(tmp_path, src):
    f = tmp_path / "p.yon"
    f.write_text(src)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(f), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r, exe


def _entry(body):
    return "place Entry {\n" + body + "  fun main: Number { return 42 }\n}\n"


def _accepted(tmp_path, src):
    r, exe = _compile(tmp_path, src)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).returncode


def _refused(tmp_path, src, *words):
    r, _ = _compile(tmp_path, src)
    out = r.stdout + r.stderr
    assert r.returncode != 0, out
    for w in words:
        assert w in out, out
    return out


def test_a_parameter_is_a_pair_of_paths_read_with_fst_and_snd(tmp_path):
    assert _accepted(tmp_path, _entry(
        "  fun left_of(a: Number, q: (a = a) ∧ (a = a)): a = a { return fst(q) }\n"
        "  fun right_of(a: Number, q: (a = a) ∧ (a = a)): a = a { return snd(q) }\n")) == 42


def test_the_statement_of_a_sigma_with_a_conjunction_compiles(tmp_path):
    assert _accepted(tmp_path, _entry(
        "  fun witness(a: Number): Σp : Number, (p = a) ∧ (p = a) {\n"
        "    return pair(a, pair(refl(a), refl(a)))\n  }\n")) == 42


def test_the_statement_of_peak_of_is_proved_by_a_pair_of_paths(tmp_path):
    # the frontend only: a Sigma over a place, and an arm with payloads built inside a pair, do not
    # reach the native code yet, with or without a path in them
    f = tmp_path / "p.yon"
    f.write_text(PEAK + _entry(
        "  fun peak_of(d1: Number, d2: Number): Σp : Peak, (p ↦ Peak.left = d1) ∧ (p ↦ Peak.right = d2) {\n"
        "    return pair((d1, d2) ↪ mk, pair(refl(d1), refl(d2)))\n  }\n"))
    r = subprocess.run([str(YONC), "--emit=mlir", str(f)], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr


def test_the_statement_of_peak_of_compiles_as_a_parameter(tmp_path):
    # the frontend only, for the same reason: the project of the kernel below compiles it whole
    f = tmp_path / "p.yon"
    f.write_text(PEAK + _entry(
        "  fun takes(d1: Number, d2: Number, "
        "s: Σp : Peak, (p ↦ Peak.left = d1) ∧ (p ↦ Peak.right = d2)): Number { return 0 }\n"))
    r = subprocess.run([str(YONC), "--emit=mlir", str(f)], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr


def test_the_components_run_as_the_pair_they_are(tmp_path):
    assert _accepted(tmp_path,
        "place Entry {\n"
        "  fun witness(a: Number): Σp : Number, (p = a) ∧ (p = a) {\n"
        "    return pair(a, pair(refl(a), refl(a)))\n  }\n"
        "  fun main: Number {\n"
        "    w := witness(42)\n"
        "    return fst(w)\n  }\n}\n") == 42


def test_the_conjunction_is_left_associative_as_among_the_expressions(tmp_path):
    assert _accepted(tmp_path, _entry(
        "  fun three(a: Number): (a = a) ∧ (a = a) ∧ (a = a) {\n"
        "    return pair(pair(refl(a), refl(a)), refl(a))\n  }\n")) == 42
    _refused(tmp_path, _entry(
        "  fun three(a: Number): (a = a) ∧ (a = a) ∧ (a = a) {\n"
        "    return pair(refl(a), pair(refl(a), refl(a)))\n  }\n"), "E2001")


def test_an_endpoint_may_be_a_parenthesized_expression(tmp_path):
    assert _accepted(tmp_path, _entry(
        "  fun f(a: Number, q: ((a) = a) ∧ (a = (a))): a = a { return fst(q) }\n")) == 42


def test_the_conjunction_is_also_a_fibre_of_a_comprehension(tmp_path):
    assert _accepted(tmp_path, _entry(
        "  fun f(a: Number, s: { x : Number where (x = a) ∧ (x = a) }): Number { return fst(s) }\n")) == 42


# the components are checked: the product is no way around the type of a path

def test_a_wrong_component_is_refused(tmp_path):
    _refused(tmp_path, _entry(
        "  fun bad(a: Number, b: Number): (a = a) ∧ (b = a) {\n"
        "    return pair(refl(a), refl(a))\n  }\n"), "E2001")


def test_a_single_path_is_not_the_conjunction(tmp_path):
    _refused(tmp_path, _entry(
        "  fun bad(a: Number): (a = a) ∧ (a = a) {\n"
        "    return refl(a)\n  }\n"), "E2001")


def test_a_projection_gives_the_path_it_holds_and_no_other(tmp_path):
    _refused(tmp_path, _entry(
        "  fun bad(a: Number, b: Number, q: (a = a) ∧ (b = b)): a = a { return snd(q) }\n"), "E2001")


def test_a_conjunction_flows_only_into_the_same_conjunction(tmp_path):
    _refused(tmp_path, _entry(
        "  fun bad(a: Number, b: Number, q: (a = a) ∧ (a = a)): (a = a) ∧ (b = a) { return q }\n"),
        "E2001", "type mismatch")
    assert _accepted(tmp_path, _entry(
        "  fun same(a: Number, q: (a = a) ∧ (a = a)): (a = a) ∧ (a = a) { return q }\n")) == 42


def test_the_witness_stands_for_the_binder_in_the_fibre(tmp_path):
    _refused(tmp_path, _entry(
        "  fun bad(a: Number, b: Number): Σp : Number, (p = a) ∧ (p = a) {\n"
        "    return pair(b, pair(refl(a), refl(a)))\n  }\n"), "E2001")
    _refused(tmp_path, PEAK + _entry(
        "  fun bad(d1: Number, d2: Number): Σp : Peak, (p ↦ Peak.left = d1) ∧ (p ↦ Peak.right = d2) {\n"
        "    return pair((d2, d1) ↪ mk, pair(refl(d1), refl(d2)))\n  }\n"), "E2001")


def test_the_statement_compiles_on_the_peak_of_the_kernel(tmp_path):
    meta = ROOT / "meta"
    if not meta.exists():
        pytest.skip("meta/ missing")
    proj = tmp_path / "meta"
    shutil.copytree(meta, proj)
    proofs = proj / "kernel" / "Proofs.yon"
    source = proofs.read_text()
    assert "place Proofs {\n" in source
    proofs.write_text(source.replace(
        "place Proofs {\n",
        "place Proofs {\n"
        "  fun peak_of_statement(d1: Step, d2: Step, p: Peak, "
        "q: (p ↦ Peak.left = d1) ∧ (p ↦ Peak.right = d2)): "
        "Σr : Peak, (r ↦ Peak.left = d1) ∧ (r ↦ Peak.right = d2) {\n"
        "    return pair(p, q)\n  }\n", 1))
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr


# what has no reading stays refused, by code and by words

def test_without_parentheses_a_conjunction_of_paths_is_refused(tmp_path):
    _refused(tmp_path, _entry("  fun f(a: Number, q: a = a ∧ a = a): Number { return 0 }\n"),
             "E1001", "(a = b) ∧ (c = d)")


@pytest.mark.parametrize("ty", ["a = a ∧ b", "a ∧ b = a", "a = a ∧ b ∨ a", "a = a ∨ a ∧ b",
                                "a = a ∧ b → a", "a = a ∧ b => a", "a = a ∧ b ↔ a", "a = b ↔ a ∧ b",
                                "a = a && b ∧ a", "(a = a ∧ b) ∧ (a = a)"])
def test_in_a_type_a_bare_meet_among_the_endpoints_is_refused(tmp_path, ty):
    _refused(tmp_path, _entry(f"  fun f(a: Boolean, b: Boolean, q: {ty}): Number {{ return 0 }}\n"),
             "E1001", "bare among the endpoints", "(a = b) ∧ (c = d)", "a = (b ∧ c)")


# ↔ is the parser's meet of two implications: a ∧ of the source over two implications is not ↔

@pytest.mark.parametrize("ty", ["a = (a → b) ∧ (b → a)", "a = (a → b) ∧ (a → a)", "(a → b) ∧ (b → a) = a",
                                "a = __heyt_imp(a, b) ∧ __heyt_imp(b, a)",
                                "a = __heyt_imp(a, b) ∧ __heyt_imp(a, a)",
                                "__heyt_imp(a, b) ∧ __heyt_imp(b, a) = a"])
def test_an_explicit_meet_of_two_implications_is_a_bare_meet(tmp_path, ty):
    _refused(tmp_path, _entry(f"  fun f(a: Boolean, b: Boolean, q: {ty}): Number {{ return 0 }}\n"),
             "E1001", "bare among the endpoints", "(a = b) ∧ (c = d)")


def test_a_returned_path_type_reads_the_meet_the_same_way(tmp_path):
    _refused(tmp_path, _entry("  fun f(a: Boolean, b: Boolean): Type { return a = a ∧ b }\n"),
             "E1001", "bare among the endpoints")


def test_an_endpoint_that_is_a_meet_keeps_its_parentheses(tmp_path):
    assert _accepted(tmp_path, _entry(
        "  fun f(a: Boolean, b: Boolean, q: a = (a ∧ b)): Number { return 0 }\n"
        "  fun g(a: Boolean, b: Boolean, q: (a ∧ b) = a): Number { return 0 }\n"
        "  fun h(a: Boolean, b: Boolean, q: (a = (a ∧ b)) ∧ (a = (a ∧ b))): Number { return 0 }\n")) == 42


def test_a_meet_on_the_left_of_a_path_parses_inside_a_conjunction(tmp_path):
    # the frontend only: a path whose left end is a meet has no carrier yet, and a Sigma of it
    # does not reach the native code, with or without ∧ among the types
    f = tmp_path / "p.yon"
    f.write_text(_entry(
        "  fun h(a: Boolean, b: Boolean, q: ((a ∧ b) = a) ∧ (a = a)): Number { return 0 }\n"))
    r = subprocess.run([str(YONC), "--emit=mlir", str(f)], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr


def test_the_other_connectives_stay_among_the_endpoints(tmp_path):
    # the decision is on ∧: no other form changed
    assert _accepted(tmp_path, _entry(
        "  fun f(a: Boolean, b: Boolean, q: a = a ∨ b): Number { return 0 }\n"
        "  fun g(a: Boolean, b: Boolean, q: a = a → b): Number { return 0 }\n"
        "  fun h(a: Boolean, b: Boolean, q: a = a ↔ b): Number { return 0 }\n"
        "  fun i(a: Boolean, b: Boolean, q: a = a && b): Number { return 0 }\n"
        "  fun j(a: Boolean, b: Boolean, q: a = a => b): Number { return 0 }\n")) == 42


def test_a_path_has_two_ends_and_the_refusal_names_no_conjunction(tmp_path):
    out = _refused(tmp_path, _entry("  fun f(a: Number, q: a = a = a): Number { return 0 }\n"),
                   "E1001", "a path has two ends")
    assert "∧" not in out, out


@pytest.mark.parametrize("ty", ["(a = a) ∧ a", "a ∧ (a = a)", "(a = a) ∧ Number", "(a = a)",
                                "((a = a)) ∧ (a = a)"])
def test_only_parenthesized_paths_are_operands(tmp_path, ty):
    _refused(tmp_path, _entry(f"  fun f(a: Number, q: {ty}): Number {{ return 0 }}\n"), "E1001")


# in a law, ∧ is a value in Omega; the two readings agree on propositions

def _project(tmp_path, place, source):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(
        f'[package]\nname = "alg"\n\n[world.W]\nobjects = ["{place}"]\n\n[runtime]\nbackend = "memory"\n')
    (proj / f"{place}.yon").write_text(source)
    (proj / "Entry.yon").write_text("place Entry {\nfun main: Number {\n  return 42\n}\n}\n")
    return subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                          capture_output=True, text=True, timeout=300)


def _sum(law):
    return ("place Sum carried by i64 is algebra {\n"
            '  operation add(a: Sum, b: Sum): Sum as "+"\n'
            '  operation zero: Sum as "0"\n'
            f"  {law}\n"
            "}\n")


def test_in_a_law_of_an_algebra_the_conjunction_is_a_value_and_is_certified(tmp_path):
    r = _project(tmp_path, "Sum", _sum(
        "law both ∀a : Sum ∀b : Sum, (a + b = b + a) ∧ (a + zero = a)"))
    assert r.returncode == 0, r.stdout + r.stderr


def test_in_a_law_of_an_algebra_a_false_conjunct_is_refuted(tmp_path):
    r = _project(tmp_path, "Sum", _sum(
        "law both ∀a : Sum ∀b : Sum, (a + b = b + a) ∧ (a + zero = b)"))
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2101" in out and "law both of algebra Sum" in out, out


def test_in_a_law_of_a_place_with_arms_the_statement_is_a_cell(tmp_path):
    r = _project(tmp_path, "Coin",
                 "place Coin {\n  this > heads :U tails\n"
                 "  law both ∀a : Coin, (a = a) ∧ (a = a)\n}\n")
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    assert "a law of a place with arms is a cell" in out, out
