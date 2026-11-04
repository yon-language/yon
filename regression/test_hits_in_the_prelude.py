"""The seven HITs read from prelude/hit/, and the coherence of their eliminators.

A map out of a HIT respects its cells: the kernel's conversion decides it. The tests are
the coherences a true cell owes, in place of examples with a constant result.

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


def _compile(tmp_path, entry, places=None):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text(TOML)
    (proj / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    for name, text in (places or {}).items():
        (proj / "w" / (name + ".yon")).write_text(text)
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    return r, exe


def _exit(tmp_path, entry, places=None):
    r, exe = _compile(tmp_path, entry, places)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, timeout=60).returncode


def _entry(funs, main="return 42"):
    return f"place Entry {{\n{funs}fun main: Number {{ {main} }}\n}}\n"


def _refused(tmp_path, entry, places, *words):
    r, _ = _compile(tmp_path, entry, places)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    for w in words:
        assert w in out, out


def test_the_circle_is_read_from_the_prelude(tmp_path):
    src = _entry("fun f(s: S1): Number { return match s { base => 42, loop => plam i => 42 } }\n",
                 "return f(S1.base)")
    assert _exit(tmp_path, src) == 42


def test_the_sphere_has_a_true_two_cell(tmp_path):
    src = _entry("fun f(s: S2): Number {\n"
                 "  return match s { base => 42, surf => plam i => plam j => 42 }\n}\n",
                 "return f(S2.base)")
    assert _exit(tmp_path, src) == 42


def test_a_two_cell_is_a_path_between_paths(tmp_path):
    src = _entry("fun f(s: S2): Number {\n"
                 "  return match s { base => 42, surf => plam i => 42 }\n}\n")
    r, _ = _compile(tmp_path, src)
    assert r.returncode != 0 and "E2001" in r.stdout + r.stderr, r.stdout + r.stderr


def test_the_circle_has_no_two_cell_to_give(tmp_path):
    src = _entry("fun f(s: S1): Number {\n"
                 "  return match s { base => 42, loop => plam i => plam j => 42 }\n}\n")
    r, _ = _compile(tmp_path, src)
    assert r.returncode != 0 and "E2001" in r.stdout + r.stderr, r.stdout + r.stderr


def test_a_truncation_is_built_and_read(tmp_path):
    src = _entry("fun some(n: Number): PropTrunc<Number> { return n ↪ PropTrunc.incl }\n"
                 "fun set(n: Number): SetTrunc<Number> { return n ↪ SetTrunc.incl }\n",
                 "return 42")
    assert _exit(tmp_path, src) == 42


def _email(lowered):
    return {"Email": "place Email { this > inj String\n"
            "  law quot ∀a : String ∀b : String, a ↦ lower = b ↦ lower → a ↪ inj = b ↪ inj\n"
            "  fun lower(s: String): String { return String.concat(s, \"\") }\n}\n",
            "Uso": "place Uso {\n"
            "  fun domain_of(s: String): Number { return String.length(s) }\n"
            "  fun domain(e: Email): Number {\n"
            f"    return match e {{ inj as s => {lowered} ↦ domain_of,\n"
            "                     quot as (a, b, r) => (domain_of, r) ↦ ap }\n"
            "  }\n"
            "  fun run: Number { return domain(\"abc\" ↪ inj) }\n}\n"}


def test_a_map_out_of_a_quotient_respects_the_relation(tmp_path):
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n",
                 _email("s ↦ Email.lower")) == 3


def test_a_map_that_does_not_factor_through_the_relation_is_refused(tmp_path):
    # without lower the two ends differ: the relation says nothing about a and b themselves
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n",
             _email("s"), "mismatch")


PERSONA = {"Cliente": "place Cliente { nome Number }\n",
           "Utente": "place Utente { nome Number }\n",
           "Codice": "place Codice { n Number\n"
           "  fun cliente_di(c: Codice): Cliente { return .-> Cliente { nome c.n } }\n"
           "  fun utente_di(c: Codice): Utente { return .-> Utente { nome c.n } }\n}\n",
           "Persona": "place Persona { this > inl Cliente :U inr Utente\n"
           "  law glue ∀c : Codice, c ↦ Codice.cliente_di ↪ inl = c ↦ Codice.utente_di ↪ inr }\n"}


def test_a_concrete_pushout_is_a_place_with_a_glue(tmp_path):
    uso = {**PERSONA, "Uso": "place Uso {\n"
           "  fun presente(p: Persona): Number {\n"
           "    return match p { inl as c => 42, inr as u => 42, glue as k => plam i => 42 }\n  }\n"
           "  fun run: Number { return presente(.-> Cliente { nome 1 } ↪ inl) }\n}\n"}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", uso) == 42


def test_a_map_out_of_a_pushout_that_tears_the_glue_is_refused(tmp_path):
    uso = {**PERSONA, "Uso": "place Uso {\n"
           "  fun presente(p: Persona): Number {\n"
           "    return match p { inl as c => 42, inr as u => 41, glue as k => plam i => 42 }\n  }\n}\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso, "mismatch")


TO_CIRCLE = ("fun to_circle(s: Suspension<Boolean>): S1 {\n"
             "  return match s { north => S1.base, south => S1.base,\n"
             "    merid as b => plam i => if b then loop @ i else S1.base }\n}\n")


def test_suspension_of_boolean_maps_to_the_circle(tmp_path):
    assert _exit(tmp_path, _entry(TO_CIRCLE)) == 42


def test_the_map_back_from_the_circle(tmp_path):
    src = _entry("fun from_circle(s: S1): Suspension<Boolean> {\n"
                 "  return match s { base => north,\n"
                 "    loop => plam i => ((true ↦ merid) ++ inv(false ↦ merid)) @ i }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_there_is_no_map_to_boolean_that_sends_the_poles_apart(tmp_path):
    src = _entry("fun e_polo_nord(s: Suspension<S1>): Boolean {\n"
                 "  return match s { north => true, south => false,\n"
                 "    merid as x => plam i => true }\n}\n")
    _refused(tmp_path, src, None, "mismatch")


@pytest.mark.xfail(strict=True, reason="the kernel does not reduce the eliminator on a composite "
                   "path and has no dependent rule over a cell: the round trip needs a square")
def test_the_suspension_of_boolean_is_the_circle_by_univalence(tmp_path):
    src = _entry(TO_CIRCLE +
                 "fun from_circle(s: S1): Suspension<Boolean> {\n"
                 "  return match s { base => north,\n"
                 "    loop => plam i => ((true ↦ merid) ++ inv(false ↦ merid)) @ i }\n}\n"
                 "fun eta(x: Suspension<Boolean>): from_circle(to_circle(x)) = x {\n"
                 "  return match x { north => clear, south => false ↦ merid,\n"
                 "    merid as b => plam i => plam j => clear }\n}\n"
                 "fun eps(x: S1): to_circle(from_circle(x)) = x {\n"
                 "  return match x { base => clear, loop => plam i => plam j => loop @ i }\n}\n"
                 "fun path: Suspension<Boolean> = S1 {\n"
                 "  return ua(equiv(to_circle, from_circle, eta, eps))\n}\n")
    assert _exit(tmp_path, src) == 42
