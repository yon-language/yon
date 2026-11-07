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
    src = _entry("fun f(s: S1): Number { return match s { base => 42, loop => walk i => 42 } }\n",
                 "return f(S1.base)")
    assert _exit(tmp_path, src) == 42


def test_the_sphere_has_a_true_two_cell(tmp_path):
    src = _entry("fun f(s: S2): Number {\n"
                 "  return match s { base => 42, surf => walk i => walk j => 42 }\n}\n",
                 "return f(S2.base)")
    assert _exit(tmp_path, src) == 42


def test_a_two_cell_is_a_path_between_paths(tmp_path):
    src = _entry("fun f(s: S2): Number {\n"
                 "  return match s { base => 42, surf => walk i => 42 }\n}\n")
    r, _ = _compile(tmp_path, src)
    assert r.returncode != 0 and "E2001" in r.stdout + r.stderr, r.stdout + r.stderr


def test_the_circle_has_no_two_cell_to_give(tmp_path):
    src = _entry("fun f(s: S1): Number {\n"
                 "  return match s { base => 42, loop => walk i => walk j => 42 }\n}\n")
    r, _ = _compile(tmp_path, src)
    assert r.returncode != 0 and "E2001" in r.stdout + r.stderr, r.stdout + r.stderr


def test_a_truncation_is_built_and_read(tmp_path):
    src = _entry("fun some(n: Number): PropTrunc<Number> { return n ↪ PropTrunc.incl }\n"
                 "fun set(n: Number): SetTrunc<Number> { return n ↪ SetTrunc.incl }\n",
                 "return 42")
    assert _exit(tmp_path, src) == 42


def _up_to_case(lowered):
    return {"TextUpToCase": "place TextUpToCase { this > inj Text\n"
            "  law quot ∀a : Text ∀b : Text, a ↦ lower = b ↦ lower → a ↪ inj = b ↪ inj\n"
            "  fun lower(s: Text): Text { return Text.lower(s) }\n}\n",
            "Uso": "place Uso {\n"
            "  fun domain_of(s: Text): Number {\n"
            "    return if Text.equal(s, \"abc\") then 3 else 0\n"
            "  }\n"
            "  fun domain(e: TextUpToCase): Number {\n"
            f"    return match e {{ inj as s => {lowered} ↦ domain_of,\n"
            "                     quot as (a, b, prova) => (domain_of, prova) ↦ ap }\n"
            "  }\n"
            "  fun run: Number { return domain(\"AbC\" ↪ inj) }\n}\n"}


def test_lower_lowers_ascii_letters(tmp_path):
    src = _entry("fun same(s: Text, t: Text): Boolean { return Text.equal(Text.lower(s), t) }\n",
                 "return if same(\"AbC\", \"abc\") && same(\"ABC\", \"abc\") && same(\"a1!Z\", \"a1!z\") "
                 "&& same(\"@[\", \"@[\") && same(\"\", \"\") && same(\"È\", \"È\") "
                 "then 42 else 1")
    assert _exit(tmp_path, src) == 42


def test_a_map_out_of_a_quotient_respects_the_relation(tmp_path):
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n",
                 _up_to_case("s ↦ TextUpToCase.lower")) == 3


def test_a_map_that_does_not_factor_through_the_relation_is_refused(tmp_path):
    # without lower the two ends differ: the relation says nothing about a and b themselves
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n",
             _up_to_case("s"), "mismatch")


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
           "    return match p { inl as c => 42, inr as u => 42, glue as k => walk i => 42 }\n  }\n"
           "  fun run: Number { return presente(.-> Cliente { nome 1 } ↪ inl) }\n}\n"}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", uso) == 42


def test_a_map_out_of_a_pushout_that_tears_the_glue_is_refused(tmp_path):
    uso = {**PERSONA, "Uso": "place Uso {\n"
           "  fun presente(p: Persona): Number {\n"
           "    return match p { inl as c => 42, inr as u => 41, glue as k => walk i => 42 }\n  }\n}\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso, "mismatch")


TO_CIRCLE = ("fun to_circle(s: Suspension<Boolean>): S1 {\n"
             "  return match s { north => S1.base, south => S1.base,\n"
             "    merid as b => match b { true => walk i => loop @ i,\n"
             "                            false => walk i => S1.base } }\n}\n")


def test_suspension_of_boolean_maps_to_the_circle(tmp_path):
    assert _exit(tmp_path, _entry(TO_CIRCLE)) == 42


def test_an_if_with_two_equal_ends_is_no_rule_of_the_kernel(tmp_path):
    # the two ends of the cell are proved by a match on b, not by a rule on the if
    src = _entry("fun to_circle(s: Suspension<Boolean>): S1 {\n"
                 "  return match s { north => S1.base, south => S1.base,\n"
                 "    merid as b => walk i => if b then loop @ i else S1.base }\n}\n")
    _refused(tmp_path, src, None, "mismatch")


def test_the_map_back_from_the_circle(tmp_path):
    src = _entry("fun from_circle(s: S1): Suspension<Boolean> {\n"
                 "  return match s { base => north,\n"
                 "    loop => walk i => ((true ↦ merid) ++ inv(false ↦ merid)) @ i }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_there_is_no_map_to_boolean_that_sends_the_poles_apart(tmp_path):
    src = _entry("fun e_polo_nord(s: Suspension<S1>): Boolean {\n"
                 "  return match s { north => true, south => false,\n"
                 "    merid as x => walk i => true }\n}\n")
    _refused(tmp_path, src, None, "mismatch")


@pytest.mark.xfail(strict=True, reason="the kernel does not reduce the eliminator on a composite "
                   "path and has no dependent rule over a cell: the round trip needs a square")
def test_the_suspension_of_boolean_is_the_circle_by_univalence(tmp_path):
    src = _entry(TO_CIRCLE +
                 "fun from_circle(s: S1): Suspension<Boolean> {\n"
                 "  return match s { base => north,\n"
                 "    loop => walk i => ((true ↦ merid) ++ inv(false ↦ merid)) @ i }\n}\n"
                 "fun eta(x: Suspension<Boolean>): from_circle(to_circle(x)) = x {\n"
                 "  return match x { north => clear, south => false ↦ merid,\n"
                 "    merid as b => walk i => walk j => clear }\n}\n"
                 "fun eps(x: S1): to_circle(from_circle(x)) = x {\n"
                 "  return match x { base => clear, loop => walk i => walk j => loop @ i }\n}\n"
                 "fun path: Suspension<Boolean> = S1 {\n"
                 "  return to_circle <=> from_circle by eta, eps\n}\n")
    assert _exit(tmp_path, src) == 42


CODICE = {"Cliente": PERSONA["Cliente"], "Utente": PERSONA["Utente"], "Codice": PERSONA["Codice"]}
GLUED = "Pushout<Codice, Cliente, Utente, Codice.cliente_di, Codice.utente_di>"


ARROWS = {"Frecce": "place Frecce {\n"
          "  fun uno(x: Number): Number { return x + 1 }\n"
          "  fun ancora_uno(x: Number): Number { return x + 1 }\n"
          "  fun due(x: Number): Number { return x + 2 }\n}\n"}


def _pushout(g):
    glued = f"Pushout<Number, Number, Number, Frecce.uno, Frecce.{g}>"
    return {**ARROWS, "Uso": "place Uso {\n"
            f"  fun piano(p: {glued}): Number {{\n"
            "    return match p { inl as b => b, inr as c => c,\n"
            "                     glue as k => walk i => k + 1 }\n  }\n"
            f"  fun dentro(x: Number): {glued} {{ return x ↪ inl }}\n"
            "  fun run: Number { return piano(dentro(7)) }\n}\n"}


def test_the_generic_pushout_takes_its_two_arrows_as_terms(tmp_path):
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n",
                 _pushout("ancora_uno")) == 7


def test_the_ends_of_the_glue_are_those_of_the_arrows_it_is_given(tmp_path):
    # the same match, given another arrow: the glue goes from k + 1 to k + 2
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n",
             _pushout("due"), "mismatch")


def _arg_refused(tmp_path, arg, *words):
    uso = {**CODICE, "Uso": "place Uso {\n"
           f"  fun f(p: Pushout<Codice, Cliente, Utente, {arg}, Codice.utente_di>): Number "
           "{ return 0 }\n}\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso, *words)


def test_a_term_parameter_names_a_fun(tmp_path):
    _arg_refused(tmp_path, "Codice.nessuna", "stands for a term", "names no fun")


def test_a_term_parameter_has_the_declared_type(tmp_path):
    _arg_refused(tmp_path, "Codice.utente_di", "stands for a term", "has type")


def test_a_term_parameter_is_not_a_type(tmp_path):
    _arg_refused(tmp_path, "Number", "stands for a term", "not the name of a fun")


def test_a_place_with_term_parameters_takes_all_of_them(tmp_path):
    uso = {**CODICE, "Uso": "place Uso {\n"
           "  fun f(p: Pushout<Codice, Cliente, Utente>): Number { return 0 }\n}\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso, "takes 5")


def test_two_arrows_of_different_names_make_two_types(tmp_path):
    # the identity of a term parameter is its name
    uso = {**CODICE, "Altro": "place Altro {\n"
           "  fun cliente_di(c: Codice): Cliente { return .-> Cliente { nome c.n } }\n}\n",
           "Uso": "place Uso {\n"
           f"  fun f(p: {GLUED}): Number {{ return 0 }}\n"
           "  fun g(p: Pushout<Codice, Cliente, Utente, Altro.cliente_di, Codice.utente_di>): Number "
           "{ return f(p) }\n}\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso, "expects", "Altro__cliente_di")


RELATED = {"Rel": "place Rel {\n"
           "  fun qualsiasi(a: Number, b: Number): Type { return Number }\n}\n"}
CLASSES = "Quotient<Number, Rel.qualsiasi>"


def test_the_generic_quotient_takes_its_relation_as_a_term(tmp_path):
    uso = {**RELATED, "Uso": "place Uso {\n"
           f"  fun costante(q: {CLASSES}): Number {{\n"
           "    return match q { inj as x => 5, quot as (a, b, w) => walk i => 5 }\n  }\n"
           f"  fun dentro(x: Number): {CLASSES} {{ return x ↪ inj }}\n"
           "  fun run: Number { return costante(dentro(3)) }\n}\n"}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return Uso.run }\n}\n", uso) == 5


def test_a_map_out_of_the_generic_quotient_owes_the_relation_a_path(tmp_path):
    uso = {**RELATED, "Uso": "place Uso {\n"
           f"  fun id_(q: {CLASSES}): Number {{\n"
           "    return match q { inj as x => x, quot as (a, b, w) => walk i => a }\n  }\n}\n"}
    _refused(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", uso, "mismatch")


def test_a_term_parameter_is_read_in_a_law_not_at_run_time(tmp_path):
    # a fun of the place would need the arrow as a value, which erasure does not carry
    places = {"Scatola": "place Scatola<r : Number -> Number> { this > piena Number\n"
              "  fun leggi(x: Number): Number { return x ↦ r }\n}\n"}
    r, _ = _compile(tmp_path, "place Entry {\nfun main: Number { return 0 }\n}\n", places)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    assert "`r`" in out or " r" in out, out


def test_a_term_parameter_may_name_a_fun_of_a_place_read_later(tmp_path):
    # the check waits for every signature: the order of the places does not matter
    uso = {"Aaa": "place Aaa {\n"
           "  fun f(p: Quotient<Number, Zeta.ogni>): Number { return 0 }\n}\n",
           "Zeta": "place Zeta {\n"
           "  fun ogni(a: Number, b: Number): Type { return Number }\n}\n"}
    assert _exit(tmp_path, "place Entry {\nfun main: Number { return 42 }\n}\n", uso) == 42


def _generic_up_to_case(lowered):
    return ("place Entry {\n"
            "  fun lower(s: Text): Text { return Text.lower(s) }\n"
            "  fun same_case(a: Text, b: Text): Type { return a ↦ lower = b ↦ lower }\n"
            "  fun domain_of(s: Text): Number {\n"
            "    return if Text.equal(s, \"abc\") then 3 else 0\n"
            "  }\n"
            "  fun domain(e: Quotient<Text, same_case>): Number {\n"
            f"    return match e {{ inj as s => {lowered} ↦ domain_of,\n"
            "                     quot as (a, b, prova) => (domain_of, prova) ↦ ap }\n"
            "  }\n"
            "  fun dentro(s: Text): Quotient<Text, same_case> { return s ↪ inj }\n"
            "  fun main: Number { return domain(dentro(\"AbC\")) }\n}\n")


def test_the_generic_quotient_carries_a_true_relation(tmp_path):
    assert _exit(tmp_path, _generic_up_to_case("s ↦ lower")) == 3


def test_a_map_out_of_the_generic_quotient_without_lower_is_refused(tmp_path):
    _refused(tmp_path, _generic_up_to_case("s"), None, "mismatch")


def test_a_relation_that_is_no_path_of_one_type_is_refused(tmp_path):
    src = _entry("fun storta(a: Text, b: Number): Type { return a = b }\n")
    _refused(tmp_path, src, None, "different types")
