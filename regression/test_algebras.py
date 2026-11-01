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
        "place Entry {\nfun main(): Number {\n" + main_body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _run(exe):
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)


def test_an_operator_of_an_algebra_writes_the_models_fun(tmp_path):
    rc, out, exe = _build(tmp_path, {}, (
        "  w := Word64.from_int64(40) + Word64.from_int64(2)\n"
        "  v := w * Word64.one()\n"
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
         "  fun join(a: Coin, b: Coin): Coin { return match a { Heads => Heads, Tails => b } }\n"
         "  fun bottom(): Coin { return Tails }\n"
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
    src = _COIN.replace("  fun bottom(): Coin { return Tails }\n", "")
    rc, out, _ = _build(tmp_path, {"Coin": src}, "  return 42", objects=["Coin"])
    assert rc != 0 and "does not give its operation bottom" in out, out


def test_an_unknown_algebra_is_refused(tmp_path):
    src = _COIN.replace("BooleanOr", "BooleanOrr")
    rc, out, _ = _build(tmp_path, {"Coin": src}, "  return 42", objects=["Coin"])
    assert rc != 0 and "which is no algebra" in out, out


def test_a_law_not_decided_is_not_certified(tmp_path):
    src = ("place Meter carried by number uses algebra Additive {\n"
           "  fun add(a: Meter, b: Meter): Meter { return a + b }\n"
           "  fun zero(): Meter { return 0 }\n"
           "}\n")
    rc, out, _ = _build(tmp_path, {"Meter": src}, "  return 42", objects=["Meter"])
    assert rc != 0 and "E2102" in out and "not certified" in out, out


def _sum(carrier: str, extra: str = "", given: str = "") -> str:
    return ("place Sum is algebra {\n"
            '  operation add(a: Sum, b: Sum): Sum as "+"\n'
            '  operation zero(): Sum as "0"\n'
            "  law associative ∀a ∀b ∀c ((a + b) + c = a + (b + c))\n"
            "  law commutative ∀a ∀b (a + b = b + a)\n"
            "  law neutral ∀a (a + zero() = a)\n"
            + extra +
            f"  carried by {carrier}{given}\n"
            "}\n")


def test_the_machine_sum_of_i64_is_a_model_certified_by_z3(tmp_path):
    rc, out, exe = _build(tmp_path, {"Sum": _sum("i64")}, "  return 42", objects=["Sum"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_a_law_false_on_the_carrier_is_refuted(tmp_path):
    src = _sum("i64", extra="  law doubles ∀a (a + a = a)\n")
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
    assert rc != 0 and "E2001" in out and "the certification decides it" in out, out


def test_a_place_takes_the_operations_it_does_not_give_from_its_carrier(tmp_path):
    word = ("internal place W carried by i64 uses algebra Additive, Multiplicative {\n"
            "  fun make(n: Int64): W { return n }\n"
            "  fun value(w: W): Int64 { return w }\n"
            "}\n")
    rc, out, exe = _build(tmp_path, {"W": word},
                          "  return if W.value(W.make(40) + W.make(2) * W.one()) == 42 then 42 else 1",
                          objects=["W"])
    assert rc == 0, out
    assert _run(exe).returncode == 42


def test_body_carried_by_is_only_for_an_algebra(tmp_path):
    src = "place Meter {\n  carried by i64\n}\n"
    rc, out, _ = _build(tmp_path, {"Meter": src}, "  return 42", objects=["Meter"])
    assert rc != 0 and "E1001" in out and "declares a carrier model of an algebra" in out, out


_DERIVED = ("place Sum is algebra {\n"
            '  operation add(a: Sum, b: Sum): Sum as "+"\n'
            '  operation zero(): Sum as "0"\n'
            "  law commutative ∀a ∀b (a + b = b + a)\n"
            "  law neutral ∀a (a + zero() = a)\n"
            "  carried by i64\n"
            "  fun double(a: Sum): Sum { return a + a }\n"
            "  fun triple(a: Sum): Sum { return double(a) + a + zero() }\n"
            "}\n")

_W = ("internal place W carried by i64 uses algebra Sum {\n"
      "  fun make(n: Int64): W { return n }\n"
      "  fun value(w: W): Int64 { return w }\n"
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
           "  law idempotent ∀a (join(a, a) = a)\n"
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
