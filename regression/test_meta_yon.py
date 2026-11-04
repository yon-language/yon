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


@pytest.mark.xfail(strict=True, reason="the kernel does not reduce a fun on an arm with a payload")
def test_a_step_computes_on_the_term_it_is_given(tmp_path):
    r = _compile(_with_proofs(tmp_path,
                 "  fun step(t: Term): Term {\n"
                 "    return match t { yes => t, no => t, var as n => t,\n"
                 "      ite as (c, u, v) => match c { yes => u, no => v, var as n => t, ite as (x, y, z) => t } }\n"
                 "  }\n"
                 "  fun if_true(u: Term, v: Term): step((Term.yes, u, v) ↪ ite) = u { return clear }\n"),
                 tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
