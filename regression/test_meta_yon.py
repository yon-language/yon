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
        "place Proofs {\n  statement Term\n" + body + "}\n")
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
    return out


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
