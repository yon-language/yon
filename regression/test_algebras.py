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
