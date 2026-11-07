"""Algebras are places of the prelude: theories whose models are places.

An algebra (`place A is algebra`) declares its operations, the operator that
writes each (`as "+"`), and its laws, stated with the quantifiers and
connectives of mathematical logic over its own name. A place that `uses
algebra A` is a model of A: it gives each operation as its own fun, A's
operators write those funs on its values, and every law of A is certified on
it: exhaustively on a finite place of arms, by z3 over 64-bit words on a word
carried internally; a law refuted is E2101, one not decided is E2102.

Layer/kind: native / end-to-end.
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _build(tmp_path: Path, places: dict, main_body: str, objects=()):
    proj = tmp_path / "proj"
    proj.mkdir()
    objs = ", ".join(f'"{o}"' for o in objects)
    (proj / "yon.toml").write_text(
        '[package]\nname = "alg"\n\n'
        + (f"[world.W]\nobjects = [{objs}]\n\n" if objects else "")
        + '[runtime]\nbackend = "memory"\n')
    for name, src in places.items():
        (proj / f"{name}.yon").write_text(src)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main: Number {\n" + main_body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _run(exe):
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)


def test_an_operator_of_an_algebra_writes_the_models_fun(tmp_path):
    rc, out, exe = _build(tmp_path, {}, (
        "  w := Word64.from_int64(40) + Word64.from_int64(2)\n"
        "  v := w * Word64.one\n"
        "  return match Word64.to_signed(v) { Int64 as n => if n == 42 then 42 else 1, "
        "DomainError as d => 0 }"))
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_place_that_lists_no_algebra_takes_no_operator(tmp_path):
    rc, out, _ = _build(tmp_path, {}, (
        "  p := match LatticePoint.at_index(1) { LatticePoint as x => x, DomainError as d => 0 }\n"
        "  q := p + p\n"
        "  return 1"))
    assert rc != 0 and "E2001" in out, out


_COIN = ("place Coin uses algebra BooleanOr {\n"
         "  this > Heads :U Tails\n"
         "  fun op(a: Coin, b: Coin): Coin { return match a { Heads => Heads, Tails => b } }\n"
         "  fun unit: Coin { return Tails }\n"
         "}\n")


def test_the_laws_are_certified_on_a_finite_model(tmp_path):
    rc, out, exe = _build(tmp_path, {"Coin": _COIN}, "  return 42", objects=["Coin"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_law_false_on_the_model_is_refuted(tmp_path):
    wrong = _COIN.replace("Tails => b }", "Tails => Tails }")
    rc, out, _ = _build(tmp_path, {"Coin": wrong}, "  return 42", objects=["Coin"])
    assert rc != 0 and "E2101" in out and "Coin" in out and "BooleanOr" in out, out


def test_a_model_must_give_each_operation(tmp_path):
    src = _COIN.replace("  fun unit: Coin { return Tails }\n", "")
    rc, out, _ = _build(tmp_path, {"Coin": src}, "  return 42", objects=["Coin"])
    assert rc != 0 and "does not give its operation unit" in out, out


def test_an_unknown_algebra_is_refused(tmp_path):
    src = _COIN.replace("BooleanOr", "BooleanOrr")
    rc, out, _ = _build(tmp_path, {"Coin": src}, "  return 42", objects=["Coin"])
    assert rc != 0 and "which is no algebra" in out, out


_NAMES = ("place Or {\n"
          "  operation join(a: Number, b: Number): Number uses algebra NAME\n"
          "LAWS}\n")


def _names(algebra: str, laws: str = "") -> str:
    return _NAMES.replace("NAME", algebra).replace("LAWS", laws)


def test_an_operation_that_names_an_unknown_algebra_is_refused(tmp_path):
    rc, out, _ = _build(tmp_path, {"Or": _names("BooleanOrr")}, "  return 42", objects=["Or"])
    assert rc != 0 and "E2102" in out, out
    assert "BooleanOrr is no algebra" in out and "the operation join" in out, out


PRELUDE_ALGEBRAS = ["Magma", "Semigroup", "Monoid", "Group",
                    "Additive", "Multiplicative", "BooleanOr", "BooleanAnd",
                    "TropicalMax", "TropicalMin", "Gcd"]


@pytest.mark.parametrize("algebra", PRELUDE_ALGEBRAS)
def test_an_operation_that_names_an_algebra_of_the_prelude_passes(tmp_path, algebra):
    rc, out, exe = _build(tmp_path, {"Or": _names(algebra)}, "  return 42", objects=["Or"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_the_catalog_is_the_set_of_the_algebras_of_the_prelude():
    # an algebra is a root written `is algebra` or a place `this <` an algebra
    texts = {p.stem: p.read_text() for p in (ROOT / "prelude" / "alg").glob("*.yon")}
    declared = {n for n, t in texts.items()
                if re.search(rf"place {n}( carried by \w+( is given)?)? is algebra", t)}
    while True:
        below = {n for n, t in texts.items()
                 if n not in declared
                 and any(re.search(rf"^\s*this < {a}\s*$", t, re.M) for a in declared)}
        if not below:
            break
        declared |= below
    assert declared == set(PRELUDE_ALGEBRAS)
    assert "g_alg_catalog" not in (ROOT / "runtime" / "yon_rt_hsh.c").read_text()


def test_an_operation_may_name_an_algebra_the_program_declares(tmp_path):
    lub = ("place Lub is algebra {\n"
           "  operation join(a: Lub, b: Lub): Lub\n"
           "  law idempotent ∀a : Lub, join(a, a) = a\n"
           "}\n")
    rc, out, exe = _build(tmp_path, {"Lub": lub, "Or": _names("Lub", "  law idempotent\n")},
                          "  return 42", objects=["Lub", "Or"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_law_the_named_algebra_states_passes(tmp_path):
    src = _names("BooleanOr", "  law commutative\n  law associative\n")
    rc, out, exe = _build(tmp_path, {"Or": src}, "  return 42", objects=["Or"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_law_the_named_algebra_does_not_state_is_refused(tmp_path):
    src = _names("BooleanOr", "  law monotone\n")
    rc, out, _ = _build(tmp_path, {"Or": src}, "  return 42", objects=["Or"])
    assert rc != 0 and "E2102" in out, out
    assert "law monotone of algebra BooleanOr" in out and "BooleanOr does not state it" in out, out


def test_a_law_the_named_algebra_declares_by_name_alone_passes(tmp_path):
    lub = ("place Lub is algebra {\n"
           "  operation join(a: Lub, b: Lub): Lub\n"
           "  law sturdy\n"
           "}\n")
    rc, out, exe = _build(tmp_path, {"Lub": lub, "Or": _names("Lub", "  law sturdy\n")},
                          "  return 42", objects=["Lub", "Or"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_law_with_its_statement_is_not_asked_of_the_named_algebra(tmp_path):
    own = "  law own ∀a : Or, a = a\n"
    rc, out, exe = _build(tmp_path, {"Or": _names("BooleanOr", own)}, "  return 42", objects=["Or"])
    assert rc == 0, out
    assert "does not state it" not in out, out
    assert _run(exe).returncode == 42


def test_a_standalone_operation_that_names_an_unknown_algebra_is_refused(tmp_path):
    src = "operation twice(a: Number): Number uses algebra Additivee\n"
    rc, out, _ = _build(tmp_path, {"Twice": src}, "  return 42")
    assert rc != 0 and "E2102" in out and "Additivee is no algebra" in out, out


def test_a_standalone_operation_that_names_an_algebra_passes(tmp_path):
    src = "operation twice(a: Number): Number uses algebra Additive\n"
    rc, out, exe = _build(tmp_path, {"Twice": src}, "  return 42")
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_the_neutral_of_gcd_is_a_law_of_the_algebra(tmp_path):
    bit = ("place Bit uses algebra Gcd {\n"
           "  this > Naught :U Tick\n"
           "  fun op(a: Bit, b: Bit): Bit { return match a { Naught => b, Tick => Tick } }\n"
           "ZERO}\n")
    rc, out, exe = _build(tmp_path, {"Bit": bit.replace("ZERO", "  fun unit: Bit { return Naught }\n")},
                          "  return 42", objects=["Bit"])
    assert rc == 0, out
    assert _run(exe).returncode == 42
    (tmp_path / "wrong").mkdir()
    rc, out, _ = _build(tmp_path / "wrong",
                        {"Bit": bit.replace("ZERO", "  fun unit: Bit { return Tick }\n")},
                        "  return 42", objects=["Bit"])
    assert rc != 0 and "E2101" in out and "law neutral of algebra Gcd" in out, out


def _order(law: str, carrier: str = "i64") -> str:
    return (f"place Sum carried by {carrier} is algebra {{\n"
            '  operation add(a: Sum, b: Sum): Sum as "+"\n'
            '  operation zero: Sum as "0"\n'
            f"  {law}\n"
            "}\n")


_MONOTONE = "law monotone ∀a : Sum ∀b : Sum, a >= zero ∧ b >= zero → a + b >= a ∧ a + b >= b"


def test_monotonicity_is_refuted_on_the_word_that_wraps(tmp_path):
    rc, out, _ = _build(tmp_path, {"Sum": _order(_MONOTONE)}, "  return 42", objects=["Sum"])
    assert rc != 0 and "E2101" in out, out
    assert "law monotone of algebra Sum on the carrier i64 is refuted" in out, out
    assert "64-bit words" in out, out


def test_monotonicity_has_no_order_to_be_stated_with_on_the_double(tmp_path):
    rc, out, _ = _build(tmp_path, {"Sum": _order(_MONOTONE, "f64")}, "  return 42", objects=["Sum"])
    assert rc != 0 and "E2001" in out, out
    assert "comparison requires matching ordered operands; got Sum and Sum" in out, out


def test_a_signature_has_no_order_to_state_a_law_with(tmp_path):
    src = _order("law total ∀a : Sum ∀b : Sum, a <= b ∨ b < a").replace(
        "place Sum carried by i64 is algebra {", "place Sum is algebra {")
    rc, out, _ = _build(tmp_path, {"Sum": src}, "  return 42", objects=["Sum"])
    assert rc != 0 and "E2001" in out, out
    assert "comparison requires matching ordered operands; got Sum and Sum" in out, out


def test_an_instance_is_its_carrier_and_states_a_law_with_its_order(tmp_path):
    # carried by i64 in the header: the instance is a face of i64, whose order is
    # total, and the law is certified on the machine.
    src = _order("law total ∀a : Sum ∀b : Sum, a <= b ∨ b < a")
    rc, out, exe = _build(tmp_path, {"Sum": src}, "  return 42", objects=["Sum"])
    assert rc == 0, out
    assert _run(exe).returncode == 42
    false = _order("law strict ∀a : Sum ∀b : Sum, a < b ∨ b < a")
    rc, out, _ = _build(tmp_path / "f", {"Sum": false}, "  return 42", objects=["Sum"]) \
        if (tmp_path / "f").mkdir() is None else (0, "", None)
    assert rc != 0 and "E2101" in out and "law strict of algebra Sum on the carrier i64 is refuted" in out, out


def test_the_runtime_keeps_of_the_magma_only_the_bridge_of_the_verifier(tmp_path):
    rc, out, _ = _build(tmp_path, {}, "  m0 := Magma.empty(0)\n  return 42")
    assert rc != 0 and "E2001" in out and "Magma" in out, out
    src = (ROOT / "runtime" / "yon_rt_hsh.c").read_text()
    assert set(re.findall(r"yon_rt_magma_\w+", src)) == {"yon_rt_magma_from_algebra"}
    assert "alg_op_is_monotone" not in src and "yon_rt_land_" not in src


def test_a_place_that_names_an_algebra_makes_no_instance_function(tmp_path):
    rc, out, _ = _build(tmp_path, {"Or": _names("BooleanOr")},
                        "  m := Or_instantiate\n  return 42", objects=["Or"])
    assert rc != 0 and "E2001" in out and "Or_instantiate" in out, out
    assert "does not reference a valid function" not in out, out


def test_a_law_not_decided_is_not_certified(tmp_path):
    src = ("place Meter carried by number uses algebra Additive {\n"
           "  fun op(a: Meter, b: Meter): Meter { return a + b }\n"
           "  fun unit: Meter { return 0 }\n"
           "  fun inv(a: Meter): Meter { return 0 - a }\n"
           "}\n")
    rc, out, _ = _build(tmp_path, {"Meter": src}, "  return 42", objects=["Meter"])
    assert rc != 0 and "E2102" in out and "not certified" in out, out


def _sum(carrier: str, extra: str = "", given: str = "") -> str:
    return (f"place Sum carried by {carrier}{given} is algebra {{\n"
            '  operation add(a: Sum, b: Sum): Sum as "+"\n'
            '  operation zero: Sum as "0"\n'
            "  law associative ∀a : Sum ∀b : Sum ∀c : Sum, (a + b) + c = a + (b + c)\n"
            "  law commutative ∀a : Sum ∀b : Sum, a + b = b + a\n"
            "  law neutral ∀a : Sum, a + zero = a\n"
            + extra +
            "}\n")


def test_the_machine_sum_of_i64_is_a_model_certified_by_z3(tmp_path):
    rc, out, exe = _build(tmp_path, {"Sum": _sum("i64")}, "  return 42", objects=["Sum"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_law_false_on_the_carrier_is_refuted(tmp_path):
    src = _sum("i64", extra="  law doubles ∀a : Sum, a + a = a\n")
    rc, out, _ = _build(tmp_path, {"Sum": src}, "  return 42", objects=["Sum"])
    assert rc != 0 and "E2101" in out, out
    assert "law doubles of algebra Sum on the carrier i64 is refuted" in out, out


def test_the_ieee_sum_is_not_associative(tmp_path):
    rc, out, _ = _build(tmp_path, {"Sum": _sum("f64")}, "  return 42", objects=["Sum"])
    assert rc != 0 and "E2101" in out, out
    assert "law associative of algebra Sum on the carrier f64 is refuted" in out, out
    assert "IEEE doubles" in out, out


def test_a_carrier_the_solver_does_not_model_is_not_certified(tmp_path):
    rc, out, _ = _build(tmp_path, {"Sum": _sum("i32")}, "  return 42", objects=["Sum"])
    assert rc != 0 and "E2102" in out and "carried by i32 is given" in out, out


def test_an_axiom_is_declared_only_where_the_certification_does_not_decide(tmp_path):
    rc, out, exe = _build(tmp_path, {"Sum": _sum("i32", given=" is given")}, "  return 42",
                          objects=["Sum"])
    assert rc == 0, out
    rc, out, _ = _build(tmp_path / "decided", {"Sum": _sum("i64", given=" is given")}, "  return 42",
                        objects=["Sum"]) if (tmp_path / "decided").mkdir() is None else (0, "", None)
    assert rc != 0 and "E2001" in out and "the certification decides every one of its laws" in out, out


def test_a_place_takes_the_operations_it_does_not_give_from_its_carrier(tmp_path):
    word = ("internal place W carried by i64 uses algebra Additive, Multiplicative {\n"
            "  fun make(n: Int64): W { return n }\n"
            "  fun value(w: W): Int64 { return w }\n"
            "}\n")
    rc, out, exe = _build(tmp_path, {"W": word},
                          "  return if W.value(W.make(40) + W.make(2) * W.make(1)) == 42 then 42 else 1",
                          objects=["W"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_carried_by_is_not_written_in_the_body_of_a_place(tmp_path):
    src = "place Meter {\n  carried by i64\n}\n"
    rc, out, _ = _build(tmp_path, {"Meter": src}, "  return 42", objects=["Meter"])
    assert rc != 0 and "E1001" in out and "`carried by` is not written in the body of a place" in out, out


def test_carried_by_in_the_body_of_an_algebra_points_to_the_header(tmp_path):
    src = _sum("i64").replace("place Sum carried by i64 is algebra {\n", "place Sum is algebra {\n")
    src = src.replace("}\n", "  carried by i64\n}\n")
    rc, out, _ = _build(tmp_path, {"Sum": src}, "  return 42", objects=["Sum"])
    assert rc != 0 and "E1001" in out, out
    assert "the carrier of an instance of an algebra is in its header, `place Sum carried by C { this < A ... }`" in out, out


def test_carried_by_is_given_on_a_place_that_is_no_algebra_is_refused(tmp_path):
    src = "place Meter carried by i64 is given {\n}\n"
    rc, out, _ = _build(tmp_path, {"Meter": src}, "  return 42", objects=["Meter"])
    assert rc != 0 and "E2001" in out, out
    assert ("place Meter: `carried by i64 is given` declares the axioms of an algebra on its carrier, "
            "and Meter is no algebra: an instance is `this <` an algebra") in out, out


def test_is_given_makes_axioms_only_of_the_laws_not_decided(tmp_path):
    # twice has no symbol: its law is not decided on i64, so `is given` makes it
    # an axiom, while the sum's laws are still decided there.
    twice = ("  operation twice(a: Sum): Sum\n"
             "  law doubled ∀a : Sum, twice(a) = a + a\n")
    rc, out, exe = _build(tmp_path, {"Sum": _sum("i64", extra=twice, given=" is given")},
                          "  return 42", objects=["Sum"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_decided_law_that_is_false_is_refuted_even_with_is_given(tmp_path):
    twice = ("  operation twice(a: Sum): Sum\n"
             "  law doubled ∀a : Sum, twice(a) = a + a\n"
             "  law doubles ∀a : Sum, a + a = a\n")
    rc, out, _ = _build(tmp_path, {"Sum": _sum("i64", extra=twice, given=" is given")},
                        "  return 42", objects=["Sum"])
    assert rc != 0 and "E2101" in out, out
    assert "law doubles of algebra Sum on the carrier i64 is refuted; counterexample:" in out, out
    assert "law doubled" not in out, out


# a signature: a fun in its body is a derived operation, with an instance in
# each model (a fun in the body of an instance is a fun of its house instead)
_DERIVED = ("place Sum is algebra {\n"
            '  operation add(a: Sum, b: Sum): Sum as "+"\n'
            '  operation zero: Sum as "0"\n'
            "  law commutative ∀a : Sum ∀b : Sum, a + b = b + a\n"
            "  law neutral ∀a : Sum, a + zero = a\n"
            "  fun double(a: Sum): Sum { return a + a }\n"
            "  fun triple(a: Sum): Sum { return double(a) + a + zero }\n"
            "}\n")

_W = ("internal place W carried by i64 uses algebra Sum {\n"
      "  fun make(n: Int64): W { return n }\n"
      "  fun value(w: W): Int64 { return w }\n"
      "  fun add(a: W, b: W): W { return make(value(a) + value(b)) }\n"
      "  fun zero: W { return make(0) }\n"
      "EXTRA}\n")


def test_a_derived_operation_has_an_instance_in_each_model(tmp_path):
    rc, out, exe = _build(tmp_path, {"Sum": _DERIVED, "W": _W.replace("EXTRA", "")},
                          "  return if W.value(W.triple(W.make(14))) == 42 then 42 else 1",
                          objects=["Sum", "W"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_model_that_gives_a_derived_operation_keeps_its_own(tmp_path):
    own = "  fun double(a: W): W { return a }\n"
    rc, out, exe = _build(tmp_path, {"Sum": _DERIVED, "W": _W.replace("EXTRA", own)},
                          "  return if W.value(W.triple(W.make(21))) == 42 then 42 else 1",
                          objects=["Sum", "W"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_derived_operation_on_a_finite_model(tmp_path):
    alg = ("place Lub is algebra {\n"
           "  operation join(a: Lub, b: Lub): Lub\n"
           "  law idempotent ∀a : Lub, join(a, a) = a\n"
           "  fun join3(a: Lub, b: Lub, c: Lub): Lub { return join(join(a, b), c) }\n"
           "}\n")
    coin = ("place Coin uses algebra Lub {\n"
            "  this > Heads :U Tails\n"
            "  fun join(a: Coin, b: Coin): Coin { return match a { Heads => Heads, Tails => b } }\n"
            "}\n")
    rc, out, exe = _build(tmp_path, {"Lub": alg, "Coin": coin},
                          "  return match Coin.join3(Tails, Tails, Heads) { Heads => 42, Tails => 1 }",
                          objects=["Lub", "Coin"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


_INSTANCE = ("place Sum carried by i64 {\n"
             "  this < Monoid\n"
             '  operation op(a: Sum, b: Sum): Sum as "+"\n'
             '  operation unit: Sum as "0"\n'
             "  law commutative ∀a : Sum ∀b : Sum, a + b = b + a\n"
             "}\n")
_MODEL = ("internal place W carried by i64 uses algebra Sum {\n"
          "  fun make(n: Int64): W { return n }\n"
          "  fun value(w: W): Int64 { return w }\n"
          "GIVES}\n")
_FORTY_TWO = "  return if W.value(W.make(40) + W.make(2)) == 42 then 42 else 1"


def test_a_model_takes_the_operations_from_the_carrier_of_an_instance(tmp_path):
    rc, out, exe = _build(tmp_path, {"Sum": _INSTANCE, "W": _MODEL.replace("GIVES", "")},
                          _FORTY_TWO, objects=["Sum", "W"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_no_model_takes_the_operations_from_an_internal_instance(tmp_path):
    # W is a house of its own: there the carrier of Sum is opaque, so W gives
    # the operations itself (test_an_internal_instance_keeps_its_signature)
    rc, out, _ = _build(tmp_path, {"Sum": "internal " + _INSTANCE, "W": _MODEL.replace("GIVES", "")},
                        _FORTY_TWO, objects=["Sum", "W"])
    assert rc != 0 and "E2001" in out, out
    assert "place W uses algebra Sum but does not give its operation op" in out, out
    assert "(Sum is internal: outside its house its carrier is opaque, and no model takes the operations from it)" in out, out


def test_a_fun_in_the_body_of_an_instance_is_no_derived_operation(tmp_path):
    # a fun of the house of Sum: no model receives an instance of it
    double = "  fun double(a: Sum): Sum { return a + a }\n}\n"
    sum_ = _INSTANCE[:-2] + double
    rc, out, exe = _build(tmp_path, {"Sum": sum_, "W": _MODEL.replace("GIVES", "")},
                          "  return if W.value(W.double(W.make(21))) == 42 then 42 else 1",
                          objects=["Sum", "W"])
    assert rc != 0 and "E2001" in out, out
    assert "unknown function or operation: W__double" in out, out


def test_an_internal_instance_keeps_its_signature(tmp_path):
    gives = ("  fun op(a: W, b: W): W { return make(value(a) + value(b)) }\n"
             "  fun unit: W { return make(0) }\n")
    rc, out, exe = _build(tmp_path, {"Sum": "internal " + _INSTANCE, "W": _MODEL.replace("GIVES", gives)},
                          _FORTY_TWO, objects=["Sum", "W"])
    assert rc == 0, out
    assert _run(exe).returncode == 42
    false = gives.replace("make(value(a) + value(b))", "make(value(a) - value(b))")
    (tmp_path / "f").mkdir()
    rc, out, _ = _build(tmp_path / "f", {"Sum": "internal " + _INSTANCE, "W": _MODEL.replace("GIVES", false)},
                        _FORTY_TWO, objects=["Sum", "W"])
    assert rc != 0 and "E2101" in out and "law commutative of algebra Sum on place W is refuted" in out, out
