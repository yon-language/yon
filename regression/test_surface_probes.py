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
from yon_programs import program

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
    "w/Topos.yon": program("test_surface_probes/module_1.yon"),
    "w/Asset.yon": program("test_surface_probes/module_2.yon"),
    "w/Opened.yon": program("test_surface_probes/module_3.yon"),
    "w/Closed.yon": program("test_surface_probes/module_4.yon"),
    "w/Account.yon": program("test_surface_probes/module_5.yon"),
}


def _compile(tmp_path, entry, extra=None):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(TOML)
    (proj / "w").mkdir()
    for name, text in (extra or {"w/Topos.yon": program("test_surface_probes/_compile_1.yon")}).items():
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
    return before + "place Entry {\nfun main: Number {\n" + body + "\n}\n}\n"


OPENED = ".-> Opened { initial 7 balance 42 }"


def test_a_coproduct_inherits_its_fields_as_an_obligation_on_the_arms(tmp_path):
    assert _exit(tmp_path, _main("  return 42"), ACCOUNT) == 42


def test_an_inherited_field_missing_from_an_arm_is_refused(tmp_path):
    bad = dict(ACCOUNT)
    bad["w/Closed.yon"] = program("test_surface_probes/test_an_inherited_field_missing_from_an_arm_is_refused_1.yon")
    r, _ = _compile(tmp_path, _main("  return 0"), bad)
    assert r.returncode != 0
    assert "balance" in r.stdout + r.stderr and "obligation" in r.stdout + r.stderr


def _uso(tmp_path, funs, account=ACCOUNT):
    # a place outside the house of Account, in the same Space
    extra = dict(account)
    extra["w/Uso.yon"] = "place Uso {\n" + funs + "}\n"
    return _exit(tmp_path, _main("  return Uso.run"), extra)


def test_a_field_guaranteed_on_every_arm_reads_on_the_coproduct(tmp_path):
    assert _uso(tmp_path, program("test_surface_probes/test_a_field_guaranteed_on_every_arm_reads_on_the_coproduct_1.yon")) == 2


def test_an_arm_that_is_a_place_is_read_by_the_names_of_its_fields(tmp_path):
    assert _uso(tmp_path,
                program("test_surface_probes/test_an_arm_that_is_a_place_is_read_by_the_names_of_its_fields_1.yon")) == 1


def test_a_pipe_accepts_the_qualified_name_of_a_fun(tmp_path):
    assert _uso(tmp_path, program("test_surface_probes/test_a_pipe_accepts_the_qualified_name_of_a_fun_1.yon")) == 2


def test_a_qualified_fun_in_the_house_of_a_coproduct_is_called(tmp_path):
    assert _uso(tmp_path, program("test_surface_probes/test_a_qualified_fun_in_the_house_of_a_coproduct_is_called_1.yon")) == 5


BOTH_ARMS = (program("test_surface_probes/module_6.yon"))


def test_a_field_on_a_coproduct_reads_the_arm_the_value_is_in(tmp_path):
    assert _uso(tmp_path, program("test_surface_probes/test_a_field_on_a_coproduct_reads_the_arm_the_value_is_in_1.yon")) == 24


def test_a_match_on_arms_that_are_places_takes_the_arm_of_the_value(tmp_path):
    assert _uso(tmp_path, program("test_surface_probes/test_a_match_on_arms_that_are_places_takes_the_arm_of_the_value_1.yon")) == 136


def _uso_refused(tmp_path, funs, *words, account=ACCOUNT):
    extra = dict(account)
    extra["w/Uso.yon"] = "place Uso {\n" + funs + "}\n"
    r, _ = _compile(tmp_path, _main("  return Uso.run"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    for w in words:
        assert w in out, out


def test_a_field_missing_from_an_arm_does_not_read_on_the_coproduct(tmp_path):
    _uso_refused(tmp_path, program("test_surface_probes/test_a_field_missing_from_an_arm_does_not_read_on_the_coproduct_1.yon"),
                 "no field initial", "arm Closed")


def test_a_pattern_naming_no_field_of_the_arm_is_refused(tmp_path):
    _uso_refused(tmp_path, program("test_surface_probes/test_a_pattern_naming_no_field_of_the_arm_is_refused_1.yon"),
                 "no field named 'nope'")


MIXED = {
    "w/Topos.yon": program("test_surface_probes/module_7.yon"),
    "w/Opened.yon": program("test_surface_probes/module_8.yon"),
    "w/Stato.yon": program("test_surface_probes/module_9.yon"),
}


def test_a_pure_nullary_called_with_parentheses_is_refused(tmp_path):
    src = (program("test_surface_probes/test_a_pure_nullary_called_with_parentheses_is_refused_1.yon"))
    _refused(tmp_path, src, "E2001", "answer is a point: it is named answer, without ()")


def test_a_pure_nullary_declared_with_parentheses_is_refused(tmp_path):
    src = (program("test_surface_probes/test_a_pure_nullary_declared_with_parentheses_is_refused_1.yon"))
    _refused(tmp_path, src, "E2001", "fun answer is a point: it is declared without ()")


def test_a_nullary_that_acts_named_without_parentheses_is_refused(tmp_path):
    src = (program("test_surface_probes/test_a_nullary_that_acts_named_without_parentheses_is_refused_1.yon"))
    _refused(tmp_path, src, "E2001", "tick acts: it is called tick()")


def test_a_nullary_that_acts_declared_without_parentheses_is_refused(tmp_path):
    src = (program("test_surface_probes/test_a_nullary_that_acts_declared_without_parentheses_is_refused_1.yon"))
    _refused(tmp_path, src, "E2001", "fun tick acts: it is declared with ()")


def test_a_pure_library_nullary_is_named_and_one_that_acts_is_called(tmp_path):
    src = (program("test_surface_probes/test_a_pure_library_nullary_is_named_and_one_that_acts_is_called_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_constant_of_an_algebra_with_parentheses_is_refused(tmp_path):
    extra = dict(ALGEBRA)
    extra["w/Somma.yon"] = extra["w/Somma.yon"].replace(
        "  %s\n", "  operation zero(): Somma as \"0\"\n  %s\n")
    extra["w/Somma.yon"] %= "law nulla zero + zero = zero"
    r, _ = _compile(tmp_path, _main("  return 42"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E1001" in out and "operation zero: T" in out, out


def test_a_mixed_coproduct_is_read_arm_by_arm(tmp_path):
    assert _uso(tmp_path,
                program("test_surface_probes/test_a_mixed_coproduct_is_read_arm_by_arm_1.yon"),
                MIXED) == 134


def test_a_field_declared_on_a_coproduct_names_the_payload_arm_that_lacks_it(tmp_path):
    extra = dict(MIXED)
    extra["w/Stato.yon"] = program("test_surface_probes/test_a_field_declared_on_a_coproduct_names_the_payload_arm_that_lacks_it_1.yon")
    r, _ = _compile(tmp_path, _main("  return 0"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "arm Pending" in out and "obligation" in out, out


def test_a_field_declared_on_a_coproduct_names_the_nullary_arm_that_lacks_it(tmp_path):
    extra = dict(MIXED)
    extra["w/Stato.yon"] = program("test_surface_probes/test_a_field_declared_on_a_coproduct_names_the_nullary_arm_that_lacks_it_1.yon")
    r, _ = _compile(tmp_path, _main("  return 0"), extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "arm Spento" in out and "obligation" in out, out


def test_a_field_does_not_read_on_a_coproduct_with_a_payload_arm(tmp_path):
    _uso_refused(tmp_path, program("test_surface_probes/test_a_field_does_not_read_on_a_coproduct_with_a_payload_arm_1.yon"),
                 "no field balance", "arm Pending", account=MIXED)


def test_payload_arms_go_past_the_slots_of_one_heap(tmp_path):
    # the arms live on the FNV chain, and the chain has no limit of one heap
    src = (program("test_surface_probes/test_payload_arms_go_past_the_slots_of_one_heap_1.yon"))
    extra = {"w/Topos.yon": program("test_surface_probes/test_payload_arms_go_past_the_slots_of_one_heap_2.yon")}
    r, exe = _compile(tmp_path, src, extra)
    assert r.returncode == 0, r.stdout + r.stderr
    p = subprocess.run(f"ulimit -s 65520; {exe}", shell=True, capture_output=True, timeout=60)
    assert p.returncode == 42, p.stderr


def test_two_arms_with_the_same_content_are_one_value(tmp_path):
    src = (program("test_surface_probes/test_two_arms_with_the_same_content_are_one_value_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_nullary_fun_is_a_point(tmp_path):
    extra = dict(ACCOUNT)
    extra["w/Account.yon"] = extra["w/Account.yon"].replace("fun prova", "fun prova")
    assert _uso(tmp_path, program("test_surface_probes/test_a_nullary_fun_is_a_point_1.yon"), extra) == 2


GENERIC = {"w/Topos.yon": program("test_surface_probes/module_10.yon"),
           "w/Box.yon": program("test_surface_probes/module_11.yon")}


def test_a_generic_arm_is_built_from_a_context_that_is_not_generic(tmp_path):
    src = (program("test_surface_probes/test_a_generic_arm_is_built_from_a_context_that_is_not_generic_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_generic_arm_is_built_inside_a_generic(tmp_path):
    src = (program("test_surface_probes/test_a_generic_arm_is_built_inside_a_generic_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_users_generic_arm_takes_its_parameter_from_the_payload(tmp_path):
    src = (program("test_surface_probes/test_a_users_generic_arm_takes_its_parameter_from_the_payload_1.yon"))
    assert _exit(tmp_path, src, GENERIC) == 42


def test_a_payload_of_the_wrong_type_for_the_expected_parameter_is_refused(tmp_path):
    src = (program("test_surface_probes/test_a_payload_of_the_wrong_type_for_the_expected_parameter_is_refused_1.yon"))
    _refused(tmp_path, src, "E2001", "expected")


def test_a_parameter_nothing_fixes_is_refused(tmp_path):
    extra = dict(GENERIC)
    extra["w/Box.yon"] = program("test_surface_probes/test_a_parameter_nothing_fixes_is_refused_1.yon")
    src = (program("test_surface_probes/test_a_parameter_nothing_fixes_is_refused_2.yon"))
    r, _ = _compile(tmp_path, src, extra)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "parameter V of Box" in out, out


def test_an_injection_has_the_type_of_its_coproduct(tmp_path):
    src = (program("test_surface_probes/test_an_injection_has_the_type_of_its_coproduct_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_get_of_a_hashmap_answers_found_and_absent(tmp_path):
    src = (program("test_surface_probes/test_get_of_a_hashmap_answers_found_and_absent_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_injection_by_pipe_into_a_generic_arm(tmp_path):
    src = (program("test_surface_probes/test_injection_by_pipe_into_a_generic_arm_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_users_generic_coproduct_is_built_and_read(tmp_path):
    extra = {"w/Topos.yon": program("test_surface_probes/test_a_users_generic_coproduct_is_built_and_read_1.yon"),
             "w/Box.yon": program("test_surface_probes/test_a_users_generic_coproduct_is_built_and_read_2.yon")}
    src = (program("test_surface_probes/test_a_users_generic_coproduct_is_built_and_read_3.yon"))
    assert _exit(tmp_path, src, extra) == 42


def test_a_generic_fun_takes_a_fun(tmp_path):
    src = (program("test_surface_probes/test_a_generic_fun_takes_a_fun_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_pipe_into_a_name(tmp_path):
    src = (program("test_surface_probes/test_a_pipe_into_a_name_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_an_arm_with_parentheses_is_refused_and_the_form_shown(tmp_path):
    _refused(tmp_path, "place Tree { this > Leaf :U Node(Tree, Tree) }\n" + _main("  return 0"),
             "E1003", "this > Node Tree Tree")


def test_a_field_on_the_next_line_is_not_a_payload(tmp_path):
    extra = dict(ACCOUNT)
    extra["w/Account.yon"] = (program("test_surface_probes/test_a_field_on_the_next_line_is_not_a_payload_1.yon"))
    assert _exit(tmp_path, _main("  return 42"), extra) == 42


def test_a_clause_goes_on_across_lines_at_its_separators(tmp_path):
    src = (program("test_surface_probes/test_a_clause_goes_on_across_lines_at_its_separators_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_the_old_injection_is_refused_and_the_new_one_shown(tmp_path):
    _refused(tmp_path, program("test_surface_probes/test_the_old_injection_is_refused_and_the_new_one_shown_1.yon"), "E2001", "written x ↪ Full")


def test_the_old_injection_with_two_payloads_shows_the_tuple(tmp_path):
    _refused(tmp_path, program("test_surface_probes/test_the_old_injection_with_two_payloads_shows_the_tuple_1.yon"), "E2001", "written (x1, x2) ↪ Pair")


def test_a_fun_with_the_name_of_an_arm_is_the_fun(tmp_path):
    src = (program("test_surface_probes/test_a_fun_with_the_name_of_an_arm_is_the_fun_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_name_that_is_no_fun_and_no_arm_is_refused(tmp_path):
    src = program("test_surface_probes/test_a_name_that_is_no_fun_and_no_arm_is_refused_1.yon")
    r, _ = _compile(tmp_path, src)
    assert r.returncode != 0 and "nessuno" in r.stdout + r.stderr


def test_a_pattern_with_parentheses_is_refused_and_the_form_shown(tmp_path):
    _refused(tmp_path, "place L { this > Nil :U Cons Number L }\n"
             "place Entry {\nfun h(l: L): Number { return match l { Nil => 0, Cons(h, t) => h } }\n"
             "fun main: Number { return 0 }\n}\n", "E1003", "Cons as (h, t)")


def test_a_pattern_on_a_projection_is_refused_and_the_form_shown(tmp_path):
    _refused(tmp_path, "place B { this > Full Number :U Empty }\n"
             "place Entry {\nfun h(l: B): Number { return match l { Full { _1 as p } => p, Empty => 0 } }\n"
             "fun main: Number { return 0 }\n}\n", "E1001", "Full as x")


def test_binders_are_a_tuple_and_underscore_discards(tmp_path):
    src = (program("test_surface_probes/test_binders_are_a_tuple_and_underscore_discards_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_the_ascii_arrows_are_the_same_tokens(tmp_path):
    src = (program("test_surface_probes/test_the_ascii_arrows_are_the_same_tokens_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_the_old_pipe_into_an_arm_proposes_the_injection(tmp_path):
    _refused(tmp_path, program("test_surface_probes/test_the_old_pipe_into_an_arm_proposes_the_injection_1.yon"), "E2001", "the pipe |> is gone: write x ↪ Full")


def test_the_old_pipe_into_a_fun_proposes_the_application(tmp_path):
    src = (program("test_surface_probes/test_the_old_pipe_into_a_fun_proposes_the_application_1.yon"))
    _refused(tmp_path, src, "E2001", "the pipe |> is gone: write x ↦ inc")


def test_an_application_to_an_arm_proposes_the_injection(tmp_path):
    _refused(tmp_path, program("test_surface_probes/test_an_application_to_an_arm_proposes_the_injection_1.yon"), "E2001", "x ↪ Full")


def test_an_injection_to_a_fun_proposes_the_application(tmp_path):
    src = (program("test_surface_probes/test_an_injection_to_a_fun_proposes_the_application_1.yon"))
    _refused(tmp_path, src, "E2001", "x ↦ inc")


def test_a_qualified_arm_is_injected_with_the_arrow(tmp_path):
    src = (program("test_surface_probes/test_a_qualified_arm_is_injected_with_the_arrow_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_qualified_call_of_an_arm_is_refused_and_the_form_shown(tmp_path):
    src = (program("test_surface_probes/test_a_qualified_call_of_an_arm_is_refused_and_the_form_shown_1.yon"))
    _refused(tmp_path, src, "E2001", "x ↪ Lookup.Found")


def test_a_qualified_nullary_arm_stays_bare(tmp_path):
    src = (program("test_surface_probes/test_a_qualified_nullary_arm_stays_bare_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_the_type_of_a_path_is_written_with_its_endpoints(tmp_path):
    src = (program("test_surface_probes/test_the_type_of_a_path_is_written_with_its_endpoints_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_the_carrier_of_a_path_is_read_off_a_parameter(tmp_path):
    src = (program("test_surface_probes/test_the_carrier_of_a_path_is_read_off_a_parameter_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_false_path_is_refused(tmp_path):
    src = (program("test_surface_probes/test_a_false_path_is_refused_1.yon"))
    r, _ = _compile(tmp_path, src)
    assert r.returncode != 0 and "E2001" in r.stdout + r.stderr


def test_id_is_refused_and_the_endpoints_shown(tmp_path):
    src = ("place Entry {\n"
           "fun bad: Id(Number, 1, 1) { return clear }\n"
           "fun main: Number { return 0 }\n}\n")
    _refused(tmp_path, src, "E1003", "written x = y")


def test_same_is_refused_and_the_endpoints_shown(tmp_path):
    src = ("place Entry {\n"
           "fun bad: Same(1, 1) { return clear }\n"
           "fun main: Number { return 0 }\n}\n")
    _refused(tmp_path, src, "E1003", "written x = y")


def test_hit_elim_on_the_surface_is_refused_and_match_shown(tmp_path):
    _refused(tmp_path, "place Coin { this > Heads :U Tails }\n"
             "place Entry {\nfun mot(c: Coin): Number { return 0 }\n"
             "fun f(c: Coin): Number { return hit_elim(mot, [Heads => 1, Tails => 0], c) }\n"
             "fun main: Number { return 0 }\n}\n", "E1003", "written match x")


def test_a_dependent_type_is_written_with_its_symbol_or_its_word(tmp_path):
    for i, t in enumerate(("Σx : Number, Number", "Sigma x : Number, Number",
                           "Πx : Number, Number", "Pi x : Number, Number")):
        src = ("place Entry {\nfun f(p: " + t + ", k: Number): Number { return k }\n"
               "fun main: Number { return 42 }\n}\n")
        (tmp_path / str(i)).mkdir()
        assert _exit(tmp_path / str(i), src) == 42


def test_the_body_of_a_dependent_type_may_be_a_path(tmp_path):
    src = (program("test_surface_probes/test_the_body_of_a_dependent_type_may_be_a_path_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_plam_is_refused_and_walk_shown(tmp_path):
    src = ("place Entry {\nfun main: Number {\n"
           "  return match S1.base { base => 42, loop => plam i => 42 }\n}\n}\n")
    _refused(tmp_path, src, "E1003", "written walk i => e")


def test_plam_on_a_face_is_refused_too(tmp_path):
    src = ("place Entry {\nfun main: Number {\n"
           "  return hcomp Number [ i = I0 => plam j => 1 ] 1\n}\n}\n")
    _refused(tmp_path, src, "E1003", "written walk i => e")


def test_an_arrow_into_a_call_is_refused_and_the_tuple_shown(tmp_path):
    src = ("place Entry {\nfun add(a: Number, b: Number): Number { return a + b }\n"
           "fun main: Number { return 40 ↦ add(2) }\n}\n")
    _refused(tmp_path, src, "E1001", "(a, y) ↦ add")


FUNS = (program("test_surface_probes/module_12.yon"))


def test_arithmetic_binds_tighter_than_a_pipe(tmp_path):
    src = program("test_surface_probes/test_arithmetic_binds_tighter_than_a_pipe_1.yon")
    assert _exit(tmp_path, src) == 42


def test_a_pipe_binds_tighter_than_an_equality(tmp_path):
    src = (program("test_surface_probes/test_a_pipe_binds_tighter_than_an_equality_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_tuple_spreads_into_the_arguments_of_a_pipe(tmp_path):
    src = (program("test_surface_probes/test_a_tuple_spreads_into_the_arguments_of_a_pipe_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_tuple_of_three_spreads_too(tmp_path):
    src = (program("test_surface_probes/test_a_tuple_of_three_spreads_too_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_call_with_arguments_stays(tmp_path):
    src = program("test_surface_probes/test_a_call_with_arguments_stays_1.yon")
    assert _exit(tmp_path, src) == 42


def test_the_path_application_takes_the_whole_pipe(tmp_path):
    src = (program("test_surface_probes/test_the_path_application_takes_the_whole_pipe_1.yon"))
    assert _exit(tmp_path, src) == 42


ALGEBRA = {
    "w/Topos.yon": program("test_surface_probes/module_13.yon"),
    "w/Somma.yon": "place Somma carried by i64 is algebra {\n  operation add(a: Somma, b: Somma): Somma as \"+\"\n"
                   "  %s\n}\n",
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
        "  %s\n", "  operation zero: Somma as \"0\"\n  %s\n")
    extra["w/Somma.yon"] %= "law nulla zero + zero = zero"
    assert _exit(tmp_path, _main("  return 42"), extra) == 42


def test_a_statement_in_parentheses_is_refused(tmp_path):
    extra = dict(ALGEBRA)
    extra["w/Somma.yon"] = extra["w/Somma.yon"].replace(
        "  %s\n", "  operation zero: Somma as \"0\"\n  %s\n")
    extra["w/Somma.yon"] %= "law nulla (zero = zero)"
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
    assert r.returncode != 0 and "[E1003]" in out and "∀a : T ∀b : T," in out, out


def test_a_law_in_a_coproduct_generates_a_cell(tmp_path):
    src = (program("test_surface_probes/test_a_law_in_a_coproduct_generates_a_cell_1.yon"))
    assert _exit(tmp_path, src) == 42


def test_a_match_on_a_hit_without_the_branch_of_a_cell_is_refused(tmp_path):
    src = (program("test_surface_probes/test_a_match_on_a_hit_without_the_branch_of_a_cell_is_refused_1.yon"))
    r, _ = _compile(tmp_path, src)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "loop" in out, out
    assert "not yet enabled" not in out, out


def test_hit_on_the_surface_is_refused(tmp_path):
    _refused(tmp_path, "place Coin { this > Heads :U Tails }\n"
             + _main("  z := hit(Heads)\n  return 0"), "E1003", "hit is a form of the kernel")
