"""Probes of the surface of coproducts, laws and paths, written in the forms decided.

Each probe states the outcome the language owes. Until the work that gives it is
done, the probe stands as xfail(strict=True): the day it passes, the test XPASSes
and the marker comes off. A refusal is checked by its code and by the words of its
reason, never by the failure alone.

Layer/kind: frontend + native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

TOML = '''[package]
name = "probe"

[world.W]
objects = ["X", "Chain", "Box", "Sum", "Tree", "L", "B"]
spaces  = ["w"]

[runtime]
backend = "memory"
'''

ACCOUNT = {
    "w/Topos.yon": "topos WTopos where {\n}\n",
    "w/Asset.yon": "place Asset { balance Number }\n",
    "w/Opened.yon": "place Opened { initial Number balance Number }\n",
    "w/Closed.yon": "place Closed { moment Number balance Number }\n",
    "w/Account.yon": "place Account {\n  this < Asset\n  this > Opened :U Closed\n"
                     "  fun stato(a: Account): Number { return 5 }\n"
                     "  fun saldo(a: Opened): Number { return a.balance }\n"
                     "  fun prova(): Opened { return .-> Opened { initial 1 balance 2 } }\n}\n",
}


def _compile(tmp_path, entry, extra=None):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(TOML)
    (proj / "w").mkdir()
    for name, text in (extra or {"w/Topos.yon": "topos WTopos where {\n}\n"}).items():
        (proj / name).write_text(text)
    (proj / "Entry.yon").write_text(entry)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    return r, exe


def _exit(tmp_path, entry, extra=None):
    r, exe = _compile(tmp_path, entry, extra)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, timeout=60).returncode


def _refused(tmp_path, entry, code, *words):
    r, _ = _compile(tmp_path, entry)
    out = r.stdout + r.stderr
    assert r.returncode != 0, out
    assert code in out, out
    for w in words:
        assert w in out, out


def _main(body, before=""):
    return before + "place Entry {\nfun main(): Number {\n" + body + "\n}\n}\n"


OPENED = ".-> Opened { initial 7 balance 42 }"


def test_a_coproduct_inherits_its_fields_as_an_obligation_on_the_arms(tmp_path):
    assert _exit(tmp_path, _main("  return 42"), ACCOUNT) == 42


def test_an_inherited_field_missing_from_an_arm_is_refused(tmp_path):
    bad = dict(ACCOUNT)
    bad["w/Closed.yon"] = "place Closed { moment Number }\n"
    r, _ = _compile(tmp_path, _main("  return 0"), bad)
    assert r.returncode != 0
    assert "balance" in r.stdout + r.stderr and "obligation" in r.stdout + r.stderr


def _uso(tmp_path, funs, account=ACCOUNT):
    # a place outside the house of Account, in the same Space
    extra = dict(account)
    extra["w/Uso.yon"] = "place Uso {\n" + funs + "}\n"
    return _exit(tmp_path, _main("  return Uso.run()"), extra)


def test_a_field_guaranteed_on_every_arm_reads_on_the_coproduct(tmp_path):
    assert _uso(tmp_path, "fun leggi(a: Account): Number { return a.balance }\n"
                          "fun run(): Number { return leggi(Account.prova()) }\n") == 2


def test_an_arm_that_is_a_place_is_read_by_the_names_of_its_fields(tmp_path):
    assert _uso(tmp_path,
                "fun leggi(a: Account): Number {\n"
                "  return match a { Opened { initial as i } => i, Closed { moment as m } => m }\n"
                "}\n"
                "fun run(): Number { return leggi(Account.prova()) }\n") == 1


def test_a_pipe_accepts_the_qualified_name_of_a_fun(tmp_path):
    assert _uso(tmp_path, "fun run(): Number {\n  o := Account.prova()\n"
                          "  return o ↦ Account.saldo\n}\n") == 2


def test_a_qualified_fun_in_the_house_of_a_coproduct_is_called(tmp_path):
    assert _uso(tmp_path, "fun run(): Number {\n  o := Account.prova()\n"
                          "  return Account.stato(o)\n}\n") == 5


BOTH_ARMS = ("fun apri(): Account { return .-> Opened { initial 1 balance 2 } }\n"
             "fun chiudi(): Account { return .-> Closed { moment 3 balance 4 } }\n")


def test_a_field_on_a_coproduct_reads_the_arm_the_value_is_in(tmp_path):
    assert _uso(tmp_path, BOTH_ARMS + "fun b(a: Account): Number { return a.balance }\n"
                "fun run(): Number { return b(apri()) * 10 + b(chiudi()) }\n") == 24


def test_a_match_on_arms_that_are_places_takes_the_arm_of_the_value(tmp_path):
    assert _uso(tmp_path, BOTH_ARMS +
                "fun leggi(a: Account): Number {\n"
                "  return match a { Opened { initial as i } => i, Closed { moment as m } => m }\n"
                "}\n"
                "fun tag(a: Account): Number { return match a { Opened => 5, Closed => 6 } }\n"
                "fun run(): Number {\n"
                "  return leggi(apri()) * 100 + leggi(chiudi()) * 10 + tag(chiudi())\n}\n") == 136


def _uso_refused(tmp_path, funs, *words, account=ACCOUNT):
    extra = dict(account)
    extra["w/Uso.yon"] = "place Uso {\n" + funs + "}\n"
    r, _ = _compile(tmp_path, _main("  return Uso.run()"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    for w in words:
        assert w in out, out


def test_a_field_missing_from_an_arm_does_not_read_on_the_coproduct(tmp_path):
    _uso_refused(tmp_path, "fun run(): Number { return 0 }\n"
                 "fun b(a: Account): Number { return a.initial }\n",
                 "no field initial", "arm Closed")


def test_a_pattern_naming_no_field_of_the_arm_is_refused(tmp_path):
    _uso_refused(tmp_path, "fun run(): Number { return 0 }\n"
                 "fun b(a: Account): Number {\n"
                 "  return match a { Opened { nope as i } => i, Closed { moment as m } => m }\n}\n",
                 "no field named 'nope'")


MIXED = {
    "w/Topos.yon": "topos WTopos where {\n}\n",
    "w/Opened.yon": "place Opened { initial Number balance Number }\n",
    "w/Stato.yon": "place Stato { this > Opened :U Pending Number :U Spento }\n",
}


def test_a_mixed_coproduct_is_read_arm_by_arm(tmp_path):
    assert _uso(tmp_path,
                "fun a(): Stato { return .-> Opened { initial 1 balance 2 } }\n"
                "fun b(): Stato { return 3 ↪ Pending }\n"
                "fun c(): Stato { return Spento }\n"
                "fun leggi(s: Stato): Number {\n"
                "  return match s { Opened { initial as i } => i, Pending as n => n, Spento => 4 }\n}\n"
                "fun run(): Number { return leggi(a()) * 100 + leggi(b()) * 10 + leggi(c()) }\n",
                MIXED) == 134


def test_a_field_declared_on_a_coproduct_names_the_payload_arm_that_lacks_it(tmp_path):
    extra = dict(MIXED)
    extra["w/Stato.yon"] = "place Stato {\n  this > Opened :U Pending Number\n  balance Number\n}\n"
    r, _ = _compile(tmp_path, _main("  return 0"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "arm Pending" in out and "obligation" in out, out


def test_a_field_declared_on_a_coproduct_names_the_nullary_arm_that_lacks_it(tmp_path):
    extra = dict(MIXED)
    extra["w/Stato.yon"] = "place Stato {\n  this > Opened :U Spento\n  balance Number\n}\n"
    r, _ = _compile(tmp_path, _main("  return 0"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "arm Spento" in out and "obligation" in out, out


def test_a_field_does_not_read_on_a_coproduct_with_a_payload_arm(tmp_path):
    _uso_refused(tmp_path, "fun run(): Number { return 0 }\n"
                 "fun b(s: Stato): Number { return s.balance }\n",
                 "no field balance", "arm Pending", account=MIXED)


def test_payload_arms_go_past_the_slots_of_one_heap(tmp_path):
    # the arms live on the FNV chain, and the chain has no limit of one heap
    src = ("place Chain { this > End :U Link Number Chain }\n"
           "place Entry {\n"
           "fun build(i: Number, acc: Chain): Chain {\n"
           "  return if i == 0 then acc else build(i - 1, (i, acc) ↪ Link)\n}\n"
           "fun len(c: Chain, n: Number): Number {\n"
           "  return match c { End => n, Link as (h, t) => len(t, n + 1) }\n}\n"
           "fun main(): Number { return if len(build(200000, End), 0) == 200000 then 42 else 1 }\n}\n")
    extra = {"w/Topos.yon": "topos WTopos where {\n}\n"}
    r, exe = _compile(tmp_path, src, extra)
    assert r.returncode == 0, r.stdout + r.stderr
    p = subprocess.run(f"ulimit -s 65520; {exe}", shell=True, capture_output=True, timeout=60)
    assert p.returncode == 42, p.stderr


def test_two_arms_with_the_same_content_are_one_value(tmp_path):
    src = ("place Box { this > Full Number Number :U Empty }\n"
           "place Entry {\n"
           "fun mk(a: Number): Box { return (a, 2) ↪ Full }\n"
           "fun main(): Number { return if mk(1) == mk(1) then 42 else 1 }\n}\n")
    assert _exit(tmp_path, src) == 42


@pytest.mark.xfail(strict=True, reason="a nullary fun is a point")
def test_a_nullary_fun_is_a_point(tmp_path):
    extra = dict(ACCOUNT)
    extra["w/Account.yon"] = extra["w/Account.yon"].replace("fun prova()", "fun prova")
    assert _uso(tmp_path, "fun run(): Number {\n  o := Account.prova\n"
                          "  return Account.saldo(o)\n}\n", extra) == 2


GENERIC = {"w/Topos.yon": "topos WTopos where {\n}\n",
           "w/Box.yon": "place Box<V> { this > Full V :U Empty }\n"}


def test_a_generic_arm_is_built_from_a_context_that_is_not_generic(tmp_path):
    src = ("place Entry {\n"
           "fun some(x: Number): Lookup<Number> { return x ↪ Found }\n"
           "fun leggi(l: Lookup<Number>): Number {\n"
           "  return match l { Found as p => p, Absent => 0 }\n}\n"
           "fun main(): Number { return leggi(some(42)) }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_generic_arm_is_built_inside_a_generic(tmp_path):
    src = ("place Entry {\n"
           "fun some<V>(x: V): Lookup<V> { return x ↪ Found }\n"
           "fun leggi(l: Lookup<Number>): Number {\n"
           "  return match l { Found as p => p, Absent => 0 }\n}\n"
           "fun main(): Number { return leggi(some(42)) }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_users_generic_arm_takes_its_parameter_from_the_payload(tmp_path):
    src = ("place Entry {\n"
           "fun wrap<T>(x: T): Box<T> { return x ↪ Full }\n"
           "fun leggi(b: Box<Number>): Number {\n"
           "  return match b { Full as p => p, Empty => 0 }\n}\n"
           "fun main(): Number { return leggi(40 ↪ Full) + leggi(wrap(2)) }\n}\n")
    assert _exit(tmp_path, src, GENERIC) == 42


def test_a_payload_of_the_wrong_type_for_the_expected_parameter_is_refused(tmp_path):
    src = ("place Entry {\n"
           "fun some(x: Number): Lookup<Text> { return x ↪ Found }\n"
           "fun main(): Number { return 0 }\n}\n")
    _refused(tmp_path, src, "E2001", "expected")


def test_a_parameter_nothing_fixes_is_refused(tmp_path):
    extra = dict(GENERIC)
    extra["w/Box.yon"] = "place Box<V> { this > Full Number :U Empty }\n"
    src = ("place Entry {\n"
           "fun main(): Number {\n"
           "  x := 1 ↪ Full\n"
           "  return 0\n}\n}\n")
    r, _ = _compile(tmp_path, src, extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "parameter V of Box" in out, out


def test_an_injection_has_the_type_of_its_coproduct(tmp_path):
    src = ("place Sum { this > A :U B Number :U C Number }\n"
           "place Entry {\n"
           "fun pick(n: Number): Sum { return if n > 0 then n ↪ B else n ↪ C }\n"
           "fun main(): Number {\n"
           "  x := match (40 ↪ B) { A => 0, B as p => p, C as q => q }\n"
           "  return x + (match pick(2) { A => 0, B as p => p, C as q => 0 })\n}\n}\n")
    assert _exit(tmp_path, src) == 42


def test_get_of_a_hashmap_answers_found_and_absent(tmp_path):
    src = ("place Entry {\n"
           "fun leggi(l: Lookup<Number>): Number {\n"
           "  return match l { Found as p => p, Absent => 2 }\n}\n"
           "fun main(): Number {\n"
           "  m := HashMap.set(HashMap.empty(), 1, 40)\n"
           "  return leggi(HashMap.get(m, 1)) + leggi(HashMap.get(m, 9))\n}\n}\n")
    assert _exit(tmp_path, src) == 42


def test_injection_by_pipe_into_a_generic_arm(tmp_path):
    src = ("place Entry {\n"
           "fun concreto(x: Number): Lookup<Number> { return x ↪ Found }\n"
           "fun generico<V>(x: V): Lookup<V> { return x ↪ Found }\n"
           "fun leggi(l: Lookup<Number>): Number {\n"
           "  return match l { Found as p => p, Absent => 0 }\n"
           "}\n"
           "fun main(): Number { return leggi(concreto(40)) + leggi(generico(2)) }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_users_generic_coproduct_is_built_and_read(tmp_path):
    extra = {"w/Topos.yon": "topos WTopos where {\n}\n",
             "w/Box.yon": "place Box<V> { this > Full V :U Empty }\n"}
    src = ("place Entry {\n"
           "fun leggi(b: Box<Number>): Number {\n"
           "  return match b { Full as p => p, Empty => 0 }\n"
           "}\n"
           "fun main(): Number { return leggi(42 ↪ Full) }\n}\n")
    assert _exit(tmp_path, src, extra) == 42


def test_a_generic_fun_takes_a_fun(tmp_path):
    src = ("place Entry {\n"
           "fun inc(x: Number): Number { return x + 1 }\n"
           "fun apply<V>(g: V -> V, x: V): V { return g(x) }\n"
           "fun main(): Number { return apply(inc, 41) }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_pipe_into_a_name(tmp_path):
    src = ("place Entry {\n"
           "fun inc(x: Number): Number { return x + 1 }\n"
           "fun main(): Number { return 41 ↦ inc }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_an_arm_with_parentheses_is_refused_and_the_form_shown(tmp_path):
    _refused(tmp_path, "place Tree { this > Leaf :U Node(Tree, Tree) }\n" + _main("  return 0"),
             "E1001", "this > Node Tree Tree")


def test_a_field_on_the_next_line_is_not_a_payload(tmp_path):
    extra = dict(ACCOUNT)
    extra["w/Account.yon"] = ("place Account {\n  this > Opened :U Closed\n  balance Number\n"
                              "  fun saldo(a: Opened): Number { return a.balance }\n"
                              "  fun prova(): Opened { return .-> Opened { initial 1 balance 2 } }\n}\n")
    assert _exit(tmp_path, _main("  return 42"), extra) == 42


def test_a_clause_goes_on_across_lines_at_its_separators(tmp_path):
    src = ("place Tree {\n  this > Leaf Number\n    :U Node Tree Tree :U\n    Nil\n}\n"
           "place Entry {\n"
           "fun count(t: Tree): Number {\n"
           "  return match t { Leaf as x => x, Node as (a, b) => count(a) + count(b), Nil => 0 }\n}\n"
           "fun main(): Number {\n"
           "  return count((40 ↪ Leaf, 2 ↪ Leaf) ↪ Node)\n}\n}\n")
    assert _exit(tmp_path, src) == 42


def test_the_old_injection_is_refused_and_the_new_one_shown(tmp_path):
    _refused(tmp_path, "place Box { this > Full Number :U Empty }\n"
             "place Entry {\nfun mk(): Box { return .-> Full { _1 1 } }\n"
             "fun main(): Number { return 0 }\n}\n", "E2001", "written x ↪ Full")


def test_the_old_injection_with_two_payloads_shows_the_tuple(tmp_path):
    _refused(tmp_path, "place Box { this > Pair Number Number :U Empty }\n"
             "place Entry {\nfun mk(): Box { return .-> Pair { _1 1 _2 2 } }\n"
             "fun main(): Number { return 0 }\n}\n", "E2001", "written (x1, x2) ↪ Pair")


def test_a_fun_with_the_name_of_an_arm_is_the_fun(tmp_path):
    src = ("place Box { this > Full Number :U Empty }\n"
           "place Entry {\n"
           "fun main(): Number { return 2 ↦ dbl }\n"
           "fun dbl(x: Number): Number { return x * 21 }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_name_that_is_no_fun_and_no_arm_is_refused(tmp_path):
    src = "place Entry {\nfun main(): Number { return 2 ↦ nessuno }\n}\n"
    r, _ = _compile(tmp_path, src)
    assert r.returncode != 0 and "nessuno" in r.stdout + r.stderr


def test_a_pattern_with_parentheses_is_refused_and_the_form_shown(tmp_path):
    _refused(tmp_path, "place L { this > Nil :U Cons Number L }\n"
             "place Entry {\nfun h(l: L): Number { return match l { Nil => 0, Cons(h, t) => h } }\n"
             "fun main(): Number { return 0 }\n}\n", "E1001", "Cons as (h, t)")


def test_a_pattern_on_a_projection_is_refused_and_the_form_shown(tmp_path):
    _refused(tmp_path, "place B { this > Full Number :U Empty }\n"
             "place Entry {\nfun h(l: B): Number { return match l { Full { _1 as p } => p, Empty => 0 } }\n"
             "fun main(): Number { return 0 }\n}\n", "E1001", "Full as x")


def test_binders_are_a_tuple_and_underscore_discards(tmp_path):
    src = ("place L { this > Nil :U Cons Number L }\n"
           "place Entry {\nfun h(l: L): Number { return match l { Nil => 0, Cons as (h, _) => h } }\n"
           "fun main(): Number { return (42, Nil) ↪ Cons ↦ h }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_the_ascii_arrows_are_the_same_tokens(tmp_path):
    src = ("place Box { this > Full Number :U Empty }\n"
           "place Entry {\n"
           "fun inc(x: Number): Number { return x + 1 }\n"
           "fun get(b: Box): Number { return match b { Full as p => p, Empty => 0 } }\n"
           "fun main(): Number { return 41 |-> inc >-> Full |-> get }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_the_old_pipe_into_an_arm_proposes_the_injection(tmp_path):
    _refused(tmp_path, "place Box { this > Full Number :U Empty }\n"
             "place Entry {\nfun mk(): Box { return 1 |> Full }\n"
             "fun main(): Number { return 0 }\n}\n", "E2001", "the pipe |> is gone: write x ↪ Full")


def test_the_old_pipe_into_a_fun_proposes_the_application(tmp_path):
    src = ("place Entry {\nfun inc(x: Number): Number { return x + 1 }\n"
           "fun main(): Number { return 1 |> inc }\n}\n")
    _refused(tmp_path, src, "E2001", "the pipe |> is gone: write x ↦ inc")


def test_an_application_to_an_arm_proposes_the_injection(tmp_path):
    _refused(tmp_path, "place Box { this > Full Number :U Empty }\n"
             "place Entry {\nfun mk(): Box { return 1 ↦ Full }\n"
             "fun main(): Number { return 0 }\n}\n", "E2001", "x ↪ Full")


def test_an_injection_to_a_fun_proposes_the_application(tmp_path):
    src = ("place Entry {\nfun inc(x: Number): Number { return x + 1 }\n"
           "fun main(): Number { return 1 ↪ inc }\n}\n")
    _refused(tmp_path, src, "E2001", "x ↦ inc")


def test_a_qualified_arm_is_injected_with_the_arrow(tmp_path):
    src = ("place Entry {\n"
           "fun main(): Number { return match (42 ↪ Lookup.Found) { Found as v => v, Absent => 0 } }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_qualified_call_of_an_arm_is_refused_and_the_form_shown(tmp_path):
    src = ("place Entry {\n"
           "fun main(): Number { return match Lookup.Found(42) { Found as v => v, Absent => 0 } }\n}\n")
    _refused(tmp_path, src, "E2001", "x ↪ Lookup.Found")


def test_a_qualified_nullary_arm_stays_bare(tmp_path):
    src = ("place Entry {\n"
           "fun main(): Number { return match Decision.Absent { Present => 1, Absent => 42, Unknown => 3 } }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_the_type_of_a_path_is_written_with_its_endpoints(tmp_path):
    src = ("place Entry {\n"
           "fun twice(x: Number): Number { return x + x }\n"
           "fun proof(a: Number): twice(a) = a + a { return clear }\n"
           "fun main(): Number { return 42 }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_the_carrier_of_a_path_is_read_off_a_parameter(tmp_path):
    src = ("place Entry {\n"
           "fun use(p: 1 = 1): Number { return 42 }\n"
           "fun main(): Number { return 42 }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_false_path_is_refused(tmp_path):
    src = ("place Entry {\n"
           "fun bad(a: Number): a = a + 1 { return clear }\n"
           "fun main(): Number { return 0 }\n}\n")
    r, _ = _compile(tmp_path, src)
    assert r.returncode != 0 and "E2001" in r.stdout + r.stderr


def test_id_is_refused_and_the_endpoints_shown(tmp_path):
    src = ("place Entry {\n"
           "fun bad(): Id(Number, 1, 1) { return clear }\n"
           "fun main(): Number { return 0 }\n}\n")
    _refused(tmp_path, src, "E1001", "written x = y")


def test_same_is_refused_and_the_endpoints_shown(tmp_path):
    src = ("place Entry {\n"
           "fun bad(): Same(1, 1) { return clear }\n"
           "fun main(): Number { return 0 }\n}\n")
    _refused(tmp_path, src, "E1001", "written x = y")


FUNS = ("fun inc(x: Number): Number { return x + 1 }\n"
        "fun add(a: Number, b: Number): Number { return a + b }\n"
        "fun add3(a: Number, b: Number, c: Number): Number { return a + b + c }\n")


def test_arithmetic_binds_tighter_than_a_pipe(tmp_path):
    src = "place Entry {\n" + FUNS + "fun main(): Number { return 40 + 1 ↦ inc }\n}\n"
    assert _exit(tmp_path, src) == 42


def test_a_pipe_binds_tighter_than_an_equality(tmp_path):
    src = ("place Entry {\n" + FUNS +
           "fun main(): Number { return if 1 ↦ inc == 2 ↦ inc then 1 else 42 }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_tuple_spreads_into_the_arguments_of_a_pipe(tmp_path):
    src = ("place Entry {\n" + FUNS +
           "fun main(): Number { return (40, 2) ↦ add }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_tuple_of_three_spreads_too(tmp_path):
    src = ("place Entry {\n" + FUNS +
           "fun main(): Number { return (39, 2, 1) ↦ add3 }\n}\n")
    assert _exit(tmp_path, src) == 42


def test_a_call_with_arguments_stays(tmp_path):
    src = "place Entry {\n" + FUNS + "fun main(): Number { return add(40, 2) }\n}\n"
    assert _exit(tmp_path, src) == 42


def test_the_path_application_takes_the_whole_pipe(tmp_path):
    src = ("place Entry {\n"
           "fun road(x: Number): x = x { return clear x }\n"
           "fun main(): Number { return 42 ↦ road @ I0 }\n}\n")
    assert _exit(tmp_path, src) == 42


ALGEBRA = {
    "w/Topos.yon": "topos WTopos where {\n}\n",
    "w/Somma.yon": "place Somma is algebra {\n  operation add(a: Somma, b: Somma): Somma as \"+\"\n"
                   "  %s\n  carried by i64\n}\n",
}


def test_a_typed_quantifier_in_an_algebra(tmp_path):
    extra = dict(ALGEBRA)
    extra["w/Somma.yon"] %= "law commutativa ∀a : Somma ∀b : Somma, a + b = b + a"
    assert _exit(tmp_path, _main("  return 42"), extra) == 42


def test_a_quantifier_over_another_type_in_an_algebra_is_refused(tmp_path):
    extra = dict(ALGEBRA)
    extra["w/Somma.yon"] %= "law strana ∀a : Number, a = a"
    r, _ = _compile(tmp_path, _main("  return 42"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "ranges over the carrier" in out, out


def test_a_law_without_quantifiers_follows_its_name(tmp_path):
    extra = dict(ALGEBRA)
    extra["w/Somma.yon"] = extra["w/Somma.yon"].replace(
        "  carried by i64", "  operation zero(): Somma as \"0\"\n  carried by i64")
    extra["w/Somma.yon"] %= "law nulla zero() + zero() = zero()"
    assert _exit(tmp_path, _main("  return 42"), extra) == 42


def test_a_statement_in_parentheses_is_refused(tmp_path):
    extra = dict(ALGEBRA)
    extra["w/Somma.yon"] = extra["w/Somma.yon"].replace(
        "  carried by i64", "  operation zero(): Somma as \"0\"\n  carried by i64")
    extra["w/Somma.yon"] %= "law nulla (zero() = zero())"
    r, _ = _compile(tmp_path, _main("  return 42"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E1001" in out and "without parentheses" in out, out


def test_a_statement_stops_at_the_end_of_the_line(tmp_path):
    extra = dict(ALGEBRA)
    extra["w/Somma.yon"] %= "law uno ∀a : Somma ∀b : Somma, a + b = b + a\n  law due ∀a : Somma, a = a"
    assert _exit(tmp_path, _main("  return 42"), extra) == 42


def test_an_untyped_quantifier_is_refused_and_the_typed_form_proposed(tmp_path):
    extra = dict(ALGEBRA)
    extra["w/Somma.yon"] %= "law commutativa ∀a ∀b (a + b = b + a)"
    r, _ = _compile(tmp_path, _main("  return 42"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E1001" in out and "∀a : T ∀b : T," in out, out


S1 = {"w/Topos.yon": "topos WTopos where {\n}\n",
      "w/S1.yon": "place S1 { this > base  law loop base = base }\n"}


@pytest.mark.xfail(strict=True, reason="constitutive laws")
def test_a_law_in_a_coproduct_generates_a_cell(tmp_path):
    src = ("place Entry {\n"
           "fun f(s: S1): Number {\n"
           "  return match s { base => 42, loop => plam i => 42 }\n"
           "}\n"
           "fun main(): Number { return f(base) }\n}\n")
    assert _exit(tmp_path, src, S1) == 42


@pytest.mark.xfail(strict=True, reason="constitutive laws")
def test_a_match_on_a_hit_without_the_branch_of_a_cell_is_refused(tmp_path):
    src = ("place Entry {\n"
           "fun f(s: S1): Number {\n"
           "  return match s { base => 42 }\n"
           "}\n"
           "fun main(): Number { return f(base) }\n}\n")
    r, _ = _compile(tmp_path, src, S1)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "loop" in out, out
    assert "not yet enabled" not in out, out


@pytest.mark.xfail(strict=True, reason="hit leaves the surface")
def test_hit_on_the_surface_is_refused(tmp_path):
    _refused(tmp_path, "place Coin { this > Heads :U Tails }\n"
             + _main("  z := hit(Heads)\n  return 0"), "E1001", "hit")
