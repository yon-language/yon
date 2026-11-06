"""meta-Yon: the kernel of Yon formalized in Yon.

The project meta/ is the proof: every theorem is a fun whose type states it, and if the compiler
refuses the proof the gate is red. A theorem has a twin that must be refused, so the proof cannot
pass for a reason other than the proof.

Layer/kind: frontend + native / end-to-end.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
META = ROOT / "meta"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _compile(proj, tmp_path):
    return subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                          capture_output=True, text=True, timeout=300)


def test_the_project_compiles_and_every_theorem_is_accepted(tmp_path):
    r = _compile(META, tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr


def _with_proofs(tmp_path, body):
    proj = tmp_path / "meta"
    shutil.copytree(META, proj)
    (proj / "kernel" / "Proofs.yon").write_text(
        "place Proofs {\n" + body + "}\n")
    return proj


def _refused(tmp_path, body):
    r = _compile(_with_proofs(tmp_path, body), tmp_path)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "mismatch" in out, out


def test_the_rule_of_the_if_is_not_a_rule_of_the_kernel(tmp_path):
    # without the match on b the kernel has nothing to compute: the proof is the two cases
    _refused(tmp_path, "  fun if_same(b: Boolean, x: Term): (if b then x else x) = x {\n"
                       "    return clear\n  }\n")


def test_the_two_cases_do_not_prove_a_false_statement(tmp_path):
    _refused(tmp_path, "  fun if_left(b: Boolean, x: Term, y: Term): (if b then x else y) = x {\n"
                       "    return match b { true => clear, false => clear }\n  }\n")


def _nat(tmp_path, proofs):
    proj = tmp_path / "nat"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "nat"\nkind = "proof"\n\n'
                                   '[world.W]\nobjects = ["Nat"]\nspaces = ["w"]\n\n'
                                   '[runtime]\nbackend = "memory"\n')
    (proj / "w").mkdir()
    (proj / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (proj / "w" / "Nat.yon").write_text("place Nat { this > zero :U succ Nat }\n")
    (proj / "Entry.yon").write_text(
        "place Entry {\n"
        "  fun plus(a: Nat, b: Nat): Nat {\n"
        "    return match a { zero => b, succ as n => (n, b) ↦ plus ↪ succ }\n  }\n"
        "  fun s_(n: Nat): Nat { return n ↪ succ }\n" + proofs +
        "  fun main: Number { return 0 }\n}\n")
    return subprocess.run([str(YONC), "--emit=mlir", str(proj), "-o", str(tmp_path / "o.mlir")],
                          capture_output=True, text=True, timeout=300)


STEP = ("  fun step(t: Term): Term {\n"
        "    return match t { yes => t, no => t, var as n => t,\n"
        "      ite as (c, u, v) => match c { yes => u, no => v, var as n => t, ite as (x, y, z) => t } }\n"
        "  }\n")


def test_a_step_computes_on_the_term_it_is_given(tmp_path):
    r = _compile(_with_proofs(tmp_path, STEP +
                 "  fun if_true(u: Term, v: Term): step((yes, u, v) ↪ ite) = u { return clear }\n"),
                 tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr


def test_a_step_does_not_compute_to_the_other_branch(tmp_path):
    _refused(tmp_path, STEP +
             "  fun if_true(u: Term, v: Term): step((yes, u, v) ↪ ite) = v { return clear }\n")


def test_induction_computes_under_a_constructor(tmp_path):
    r = _nat(tmp_path,
             "  fun zr(n: Nat): plus(n, zero) = n {\n"
             "    return match n { zero => clear, succ as m => (s_, zr(m)) ↦ ap }\n  }\n"
             "  fun sr(a: Nat, b: Nat): plus(a, b ↪ succ) = plus(a, b) ↪ succ {\n"
             "    return match a { zero => clear, succ as m => (s_, sr(m, b)) ↦ ap }\n  }\n")
    assert r.returncode == 0, r.stdout + r.stderr


def test_induction_does_not_prove_a_false_statement(tmp_path):
    r = _nat(tmp_path,
             "  fun bad(n: Nat): plus(n, zero) = zero {\n"
             "    return match n { zero => clear, succ as m => (s_, bad(m)) ↦ ap }\n  }\n")
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "mismatch" in out, out


def _rule(tmp_path, body, *words):
    r = _nat(tmp_path, body)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2010" in out, out
    for w in words:
        assert w in out, out


def test_a_proof_project_refuses_a_fun_that_does_not_terminate(tmp_path):
    _rule(tmp_path, "  fun giro(n: Nat): Nat { return giro(n) }\n", "termination check")


def test_a_proof_project_refuses_is_given(tmp_path):
    proj = _with_proofs(tmp_path, "")
    (proj / "kernel" / "Term.yon").write_text(
        "place Term { this > yes :U no :U var Number :U ite Term Term Term\n"
        "  law assioma ∀t : Term, t = t is given\n}\n")
    r = _compile(proj, tmp_path)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2010" in out and "is given" in out, out


def test_a_proof_project_refuses_forever(tmp_path):
    _rule(tmp_path, "  fun gira: Number {\n    forever { x := 1 }\n    return 0\n  }\n", "forever")


def test_a_proof_project_refuses_while(tmp_path):
    _rule(tmp_path, "  fun gira: Number {\n    while true do { x := 1 }\n    return 0\n  }\n", "while")


def test_a_project_declares_no_other_kind(tmp_path):
    proj = META
    copy = tmp_path / "meta"
    shutil.copytree(proj, copy)
    (copy / "yon.toml").write_text((proj / "yon.toml").read_text().replace('"proof"', '"altro"'))
    r = _compile(copy, tmp_path)
    assert r.returncode != 0 and 'the only kind' in r.stdout + r.stderr, r.stdout + r.stderr


def test_a_normal_project_keeps_what_a_proof_refuses(tmp_path):
    # the rule is the project's: a recursive fun without a certificate compiles elsewhere
    proj = tmp_path / "free"
    proj.mkdir()
    (proj / "Entry.yon").write_text(
        "place Entry {\n  fun giro(n: Number): Number { return giro(n) }\n"
        "  fun main: Number { return 0 }\n}\n")
    r = _compile(proj, tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr


def _line_of(text, marker):
    """La riga (da 1) della prima occorrenza di marker in text."""
    assert marker in text, marker
    return text[:text.index(marker)].count("\n") + 1


def _broken(tmp_path, file, old, new):
    proj = tmp_path / "meta"
    shutil.copytree(META, proj)
    p = proj / "kernel" / file
    text = p.read_text()
    assert old in text
    p.write_text(text.replace(old, new, 1))
    r = _compile(proj, tmp_path)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    return out, proj


def test_termination_is_refused_with_a_wrong_gap(tmp_path):
    # the theorem depends on the gap it states: a gap one too large does not hold
    _broken(tmp_path, "Proofs.yon", "ifFalse as (u, v) => size(u) ↪ succ,",
            "ifFalse as (u, v) => size(u) ↪ succ ↪ succ,")


def test_termination_is_refused_for_a_step_that_grows(tmp_path):
    # a rule that keeps the whole term does not go down
    _broken(tmp_path, "Step.yon", "ifFalse as (u, v) => v,", "ifFalse as (u, v) => (no, u, v) ↪ ite,")


def test_a_peak_with_a_wrong_source_is_refused(tmp_path):
    _broken(tmp_path, "Peak.yon", "rootT as u => (u, u) ↪ ifTrue,", "rootT as u => (u, u) ↪ ifFalse,")


def test_a_critical_pair_with_a_wrong_valley_is_refused(tmp_path):
    # the same_inU peak closes through two steps: one of them alone does not meet
    _broken(tmp_path, "Peak.yon",
            "sameU as (c, e) => (c, (e ↦ Step.tgt)) ↪ ifSame ↪ once,",
            "sameU as (c, e) => (c, e ↦ Step.tgt, e ↦ Step.src) ↪ ite ↪ still,")


def test_different_arms_are_distinct(tmp_path):
    _broken(tmp_path, "Proofs.yon", "fun absurd(p: true = false): Empty",
            "fun absurd(p: true = true): Empty")


def _with_theorem(tmp_path, theorem):
    proj = tmp_path / "meta"
    shutil.copytree(META, proj)
    proofs = proj / "kernel" / "Proofs.yon"
    proofs.write_text(proofs.read_text().replace("place Proofs {\n", "place Proofs {\n" + theorem, 1))
    return proj


def test_an_unannotated_parameter_does_not_prove_the_false(tmp_path):
    # the lambda's q is read by ite_injective at (yes, u, v) = (no, u, v): the q of bad is another
    # path, and one parameter has one type, so yes = no does not follow
    r = _compile(_with_theorem(tmp_path,
        "  fun bad(u: Term, v: Term, d2: Step, q: (yes, u, v) ↪ ite = (d2 ↦ Step.src)): Term.yes = Term.no {\n"
        "    k := fun(q) => ite_injective(yes, u, v, no, u, v, q)\n"
        "    return k(q)\n  }\n"), tmp_path)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "annotate the lambda parameter" in out, out


# Dependent elimination on the context: in a branch of a match on a variable, the arm stands for
# the variable in the type of every other variable of the context.

SRC_OF_ARM = {
    "ifTrue": ("u{i}, v{i}", "yes, u{i}, v{i}"),
    "ifFalse": ("u{i}, v{i}", "no, u{i}, v{i}"),
    "ifSame": ("c{i}, w{i}", "c{i}, w{i}, w{i}"),
    "inC": ("e{i}, u{i}, v{i}", "e{i} ↦ Step.src, u{i}, v{i}"),
    "inU": ("c{i}, e{i}, v{i}", "c{i}, e{i} ↦ Step.src, v{i}"),
    "inV": ("c{i}, u{i}, e{i}", "c{i}, u{i}, e{i} ↦ Step.src"),
}
TWO_STEPS = "d1: Step, d2: Step, q: (d1 ↦ Step.src) = (d2 ↦ Step.src)"
FORGET = "  fun forget(a: Term, b: Term, p: a = b): Number { return 0 }\n"


def _proof_rejected(tmp_path, theorem, *words):
    proj = _with_theorem(tmp_path, theorem)
    r = _compile(proj, tmp_path)
    out = r.stdout + r.stderr
    assert r.returncode != 0, out
    for w in words:
        assert w in out, out
    return out, proj


def _nested_match(leaf):
    def arms(i, inner):
        return ",\n".join(
            f"      {arm} as ({binders.format(i=i)}) => {inner(arm)}"
            for arm, (binders, _) in SRC_OF_ARM.items())
    body = arms(1, lambda a1: "match d2 {\n" + arms(2, lambda a2: leaf(a1, a2)) + "\n      }")
    return f"    return match d1 {{\n{body}\n    }}\n"


def _src(arm, i):
    return SRC_OF_ARM[arm][1].format(i=i)


def _call_injective(a1, a2):
    c1, u1, v1 = _src(a1, 1).split(", ")
    c2, u2, v2 = _src(a2, 2).split(", ")
    return f"forget({c1}, {c2}, ite_injective({c1}, {u1}, {v1}, {c2}, {u2}, {v2}, q))"


def test_a_nested_match_reads_q_at_the_arms_of_both_steps(tmp_path):
    r = _compile(_with_theorem(tmp_path, FORGET + f"  fun heads({TWO_STEPS}): Number {{\n"
                               + _nested_match(_call_injective) + "  }\n"), tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr


def test_a_branch_does_not_read_q_at_the_arm_of_another(tmp_path):
    # every branch reads q as if d1 were ifFalse: in the branch of ifTrue that is yes = no
    def leaf(a1, a2):
        return _call_injective("ifFalse" if a1 == "ifTrue" else a1, a2)
    _proof_rejected(tmp_path, FORGET + f"  fun heads({TWO_STEPS}): Number {{\n"
                    + _nested_match(leaf) + "  }\n", "E2001", "ite_injective")


def test_q_is_not_specialized_before_the_match(tmp_path):
    _proof_rejected(tmp_path, FORGET +
        f"  fun early(u: Term, v: Term, u2: Term, v2: Term, {TWO_STEPS}): Number {{\n"
        "    x := forget(yes, no, ite_injective(yes, u, v, no, u2, v2, q))\n"
        "    return match d1 { ifTrue as (a, b) => x, ifFalse as (a, b) => x, ifSame as (a, b) => x,\n"
        "      inC as (a, b, c) => x, inU as (a, b, c) => x, inV as (a, b, c) => x }\n  }\n",
        "E2001", "parameter p expects", "Step__src(d1)")


def test_a_scrutinee_that_is_not_a_variable_refines_nothing(tmp_path):
    _proof_rejected(tmp_path, FORGET +
        "  fun same(d: Step): Step { return d }\n"
        f"  fun not_var({TWO_STEPS}, u: Term, v: Term, u2: Term, v2: Term): Number {{\n"
        "    return match same(d1) { ifTrue as (a, b) => forget(yes, no, ite_injective(yes, a, b, no, u2, v2, q)),\n"
        "      ifFalse as (a, b) => 0, ifSame as (a, b) => 0,\n"
        "      inC as (a, b, c) => 0, inU as (a, b, c) => 0, inV as (a, b, c) => 0 }\n  }\n",
        "E2001", "parameter p expects", "Step__src(d1)")


def _descent(first, second):
    return (
        FORGET + f"  fun descend({TWO_STEPS}): Number {{\n"
        "    return match d1 {\n"
        "      inC as (e, u, v) => match d2 {\n"
        f"        inC as (e2, u2, v2) => descend({first}, {second}, "
        "ite_injective(e ↦ Step.src, u, v, e2 ↦ Step.src, u2, v2, q)),\n"
        "        ifTrue as (a, b) => 0, ifFalse as (a, b) => 0, ifSame as (a, b) => 0,\n"
        "        inU as (a, b, c) => 0, inV as (a, b, c) => 0\n      },\n"
        "      ifTrue as (a, b) => 0, ifFalse as (a, b) => 0, ifSame as (a, b) => 0,\n"
        "      inU as (a, b, c) => 0, inV as (a, b, c) => 0\n    }\n  }\n")


def test_direct_recursion_on_a_substep_passes_the_termination_check(tmp_path):
    r = _compile(_with_theorem(tmp_path, _descent("e", "e2")), tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr


def test_recursion_on_the_same_step_does_not_terminate(tmp_path):
    # the call on d1 and d2 does not go down: the termination check refuses it (and the path has
    # the type of the substeps, so the type check refuses it too)
    _proof_rejected(tmp_path, _descent("d1", "d2"), "E2010", "termination")


def test_a_cycle_through_a_helper_does_not_terminate(tmp_path):
    # peak_of recurses through peak_of_in_c/u/v: a cycle through a helper must not pass the check
    _rule(tmp_path, "  fun ping(n: Nat): Nat { return pong(n) }\n"
                    "  fun pong(n: Nat): Nat { return ping(n) }\n", "termination check")


def test_a_path_over_a_boolean_is_read_at_the_branch(tmp_path):
    r = _compile(_with_theorem(tmp_path,
        "  fun gone(e: Empty): Number { return 0 }\n"
        "  fun at_true(b: Boolean, q: b = true): Number {\n"
        "    return match b { true => 1, false => gone(absurd(inv(q))) }\n  }\n"), tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr


def _with_one_arm(tmp_path, theorem):
    proj = _with_theorem(tmp_path, theorem)
    toml = proj / "yon.toml"
    toml.write_text(toml.read_text().replace('objects = [', 'objects = ["W", ', 1))
    (proj / "kernel" / "W.yon").write_text(
        "place W {\n  this > only Term\n  fun inner(w: W): Term { return match w { only as t => t } }\n}\n")
    return proj


def test_a_binder_does_not_capture_a_name_of_the_statement(tmp_path):
    # the u of the statement is the outer one: this would prove that every term is every other
    r = _compile(_with_one_arm(tmp_path,
        "  fun captured(w: W, u: Term): (w ↦ W.inner) = u {\n"
        "    return match w { only as u => clear }\n  }\n"), tmp_path)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "mismatch" in out, out


def test_a_binder_does_not_capture_a_name_in_the_context(tmp_path):
    # the u of q is the outer one, and it stays so in the branch that hides it
    r = _compile(_with_one_arm(tmp_path,
        "  fun captured(w: W, u: Term, q: (w ↦ W.inner) = u): u = u {\n"
        "    return match w { only as u => inv(q) }\n  }\n"), tmp_path)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "mismatch" in out, out


def test_a_binder_that_hides_a_name_leaves_a_true_statement_true(tmp_path):
    r = _compile(_with_one_arm(tmp_path,
        "  fun kept(w: W, u: Term, q: (w ↦ W.inner) = u): (w ↦ W.inner) = u {\n"
        "    return match w { only as u => q }\n  }\n"), tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr


def _empty(tmp_path, funs):
    proj = tmp_path / "empty"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "empty"\nkind = "proof"\n\n'
                                    '[world.W]\nobjects = ["Empty"]\nspaces = ["w"]\n\n'
                                    '[runtime]\nbackend = "memory"\n')
    (proj / "w").mkdir()
    (proj / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (proj / "w" / "Empty.yon").write_text("place Empty { this > nessuno Empty }\n")
    (proj / "Entry.yon").write_text("place Entry {\n" + funs + "  fun main: Number { return 0 }\n}\n")
    return subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                          capture_output=True, text=True, timeout=300), proj


def test_exfalso_is_elimination_by_structural_recursion(tmp_path):
    # Empty has no base case: elimination recurses on the subterm carried by nessuno
    r, _ = _empty(tmp_path,
                  "  fun exfalso<T>(e: Empty): T { return match e { nessuno as x => x ↦ exfalso } }\n")
    assert r.returncode == 0, r.stdout + r.stderr


def test_exfalso_must_recurse_on_the_subterm(tmp_path):
    # a version that recurses on e instead of the subterm x does not terminate
    r, proj = _empty(tmp_path,
                     "  fun exfalso<T>(e: Empty): T { return match e { nessuno as x => e ↦ exfalso } }\n")
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2010" in out and "termination" in out and "exfalso" in out, out
    # fn_loc usa $startpos di una regola che comincia con boption(INTERNAL): riporta la riga del
    # token precedente la keyword, qui la `{` di `place Entry {`, una riga sopra `fun exfalso`.
    # Il `line - 1` vale perche' il test scrive quel testo.
    line = _line_of((proj / "Entry.yon").read_text(), "fun exfalso")
    assert f"[line {line - 1}," in out, out


def test_ite_injective_u_does_not_give_the_third_component(tmp_path):
    # the second component is u = x, not u = y: the equality of the other branch is refused
    out, proj = _broken(tmp_path, "Proofs.yon", ": u = x {", ": u = y {")
    assert "type mismatch" in out, out
    line = _line_of((proj / "kernel" / "Proofs.yon").read_text(), "return (then_of, p) ↦ ap")
    assert f"[line {line}," in out, out


def test_ite_injective_v_does_not_give_the_second_component(tmp_path):
    # the third component is v = y, not v = x
    out, proj = _broken(tmp_path, "Proofs.yon", ": v = y {", ": v = x {")
    assert "type mismatch" in out, out
    line = _line_of((proj / "kernel" / "Proofs.yon").read_text(), "return (else_of, p) ↦ ap")
    assert f"[line {line}," in out, out


def test_ite_is_not_no_is_not_ite_is_not_yes(tmp_path):
    # an ite is not no; the same proof under "= yes" is refused: the body calls absurd on
    # false = false, and only the body can name absurd
    out, proj = _broken(tmp_path, "Proofs.yon", "↪ ite = Term.no): Empty", "↪ ite = Term.yes): Empty")
    assert "Proofs__absurd" in out, out
    line = _line_of((proj / "kernel" / "Proofs.yon").read_text(), "return absurd(inv((is_no, p) ↦ ap))")
    assert f"[line {line}," in out, out


def test_src_not_yes_does_not_give_src_not_no(tmp_path):
    # the source of a step is never yes; claiming it is never no is refused in the body,
    # which passes the path to ite_is_not_yes
    out, proj = _broken(tmp_path, "Proofs.yon", "Step.src) = Term.yes): Empty", "Step.src) = Term.no): Empty")
    assert "Proofs__ite_is_not_yes" in out, out
    line = _line_of((proj / "kernel" / "Proofs.yon").read_text(), "ite_is_not_yes(yes, u, v, p)")
    assert f"[line {line}," in out, out


def test_src_not_no_does_not_give_src_not_yes(tmp_path):
    # the source of a step is never no; claiming it is never yes is refused in the body,
    # which passes the path to ite_is_not_no
    out, proj = _broken(tmp_path, "Proofs.yon", "Step.src) = Term.no): Empty", "Step.src) = Term.yes): Empty")
    assert "Proofs__ite_is_not_no" in out, out
    line = _line_of((proj / "kernel" / "Proofs.yon").read_text(), "ite_is_not_no(yes, u, v, p)")
    assert f"[line {line}," in out, out


def test_peak_of_refuses_a_path_between_different_terms(tmp_path):
    # peak_of asks q to link the two sources: a q from the source of d1 to the target of d2
    # is a different equality, and the call is refused before any peak is built
    out, proj = _proof_rejected(tmp_path,
        "  fun bad(d1: Step, d2: Step, q: (d1 ↦ Step.src) = (d2 ↦ Step.tgt)): Peak {\n"
        "    return peak_of(d1, d2, q)\n  }\n",
        "E2001", "Proofs__peak_of", "parameter q expects", "Step__src(d2)")
    line = _line_of((proj / "kernel" / "Proofs.yon").read_text(), "return peak_of(d1, d2, q)")
    assert f"[line {line}," in out, out
