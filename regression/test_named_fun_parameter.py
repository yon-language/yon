"""A parameter of a named fun without annotation has a type variable. The uses in the body fix it,
and uses that do not agree are refused; left free it generalizes, and the fun is generic exactly as
if written with <T>. Inside its own group of mutually recursive funs a fun has one type. It is never
the placeholder unknown.

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


def _project(tmp_path, entry, name="p"):
    proj = tmp_path / name
    proj.mkdir()
    (proj / "yon.toml").write_text(f'[package]\nname = "{name}"\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text("place Entry {\n" + entry + "\n}\n")
    return proj


def _compile(proj, tmp_path, *flags, out="exe"):
    return subprocess.run([str(YONC), *flags, str(proj), "-o", str(tmp_path / out)],
                          capture_output=True, text=True, timeout=300)


def _refused(tmp_path, entry, *words):
    r = _compile(_project(tmp_path, entry), tmp_path)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out, out
    for w in words:
        assert w in out, out


def _exits(tmp_path, entry, code):
    r = _compile(_project(tmp_path, entry), tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(tmp_path / "exe")], capture_output=True, timeout=60).returncode == code


HELPER = ("  fun helper(u: Term, v: Term, q): Term.yes = Term.no {\n"
          "    return ite_injective(yes, u, v, no, u, v, q)\n  }\n")


def _proof(tmp_path, theorems):
    proj = tmp_path / "meta"
    shutil.copytree(META, proj)
    proofs = proj / "kernel" / "Proofs.yon"
    proofs.write_text(proofs.read_text().replace("place Proofs {\n", "place Proofs {\n" + theorems, 1))
    return _compile(proj, tmp_path)


def test_a_parameter_without_annotation_does_not_prove_the_false(tmp_path):
    # q is fixed by ite_injective as (yes, u, v) = (no, u, v): the q of bad is another path
    r = _proof(tmp_path, HELPER +
               "  fun bad(u: Term, v: Term, d2: Step, q: (yes, u, v) ↪ ite = (d2 ↦ Step.src)): Term.yes = Term.no {\n"
               "    return helper(u, v, q)\n  }\n")
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "parameter q expects" in out, out


def test_the_helper_alone_is_the_lemma_its_uses_fix(tmp_path):
    # the twin: given the path between the two ites, yes = no does follow; nothing false in it
    r = _proof(tmp_path, HELPER)
    assert r.returncode == 0, r.stdout + r.stderr


def test_two_uses_of_different_types_are_refused(tmp_path):
    _refused(tmp_path, "fun n(a: Number): Number { return a }\n"
                       "fun t(a: Text): Number { return 0 }\n"
                       "fun f(x): Number { return n(x) + t(x) }\n"
                       "fun main: Number { return f(1) }",
             "do not agree", "annotate the parameter", "(x)")


def test_a_parameter_used_with_one_type_is_accepted(tmp_path):
    _exits(tmp_path, "fun n(a: Number): Number { return a }\n"
                     "fun f(x): Number { return n(x) + n(x) }\n"
                     "fun main: Number { return f(21) }", 42)


def test_a_free_parameter_is_generic(tmp_path):
    _exits(tmp_path, 'fun id(x) { return x }\n'
                     'fun main: Number {\n  a := id(42)\n  b := id("h")\n  return a\n}', 42)


def test_a_generic_result_keeps_the_type_of_its_call(tmp_path):
    # generic means the instance is checked: id("h") is a Text, not a Number
    _refused(tmp_path, 'fun id(x) { return x }\nfun main: Number { return id("h") }', "mismatch")


def test_a_generic_parameter_admits_no_operation(tmp_path):
    # what a body does not fix stays abstract, as in fun f<T>(x: T): a field of it is refused
    _refused(tmp_path, "fun f(x) { return x.a }\nfun main: Number { return 0 }",
             "abstract type T admits no operation")


def test_a_parameter_fixed_by_the_body_has_that_type(tmp_path):
    _exits(tmp_path, "fun f(x): Number { return x + 1 }\nfun main: Number { return f(41) }", 42)


def test_a_call_of_another_type_is_refused(tmp_path):
    _refused(tmp_path, 'fun f(x): Number { return x + 1 }\nfun main: Number { return f("a") }',
             "parameter x expects number, got Text")


def test_the_call_sites_do_not_type_a_parameter(tmp_path):
    # the old pre-pass read the type off the calls: now they are checked against the generic type
    _exits(tmp_path, 'fun f(x) { return 42 }\nfun main: Number {\n  a := f(1)\n  b := f("a")\n  return a\n}', 42)


def test_a_recursive_fun_has_one_type_in_its_body(tmp_path):
    _refused(tmp_path, 'fun r(x): Number { return r(1) + r("a") }\nfun main: Number { return 0 }',
             "do not agree", "annotate the parameter")


def test_a_recursive_fun_with_one_type_is_accepted(tmp_path):
    _exits(tmp_path, "fun cd(n): Number { return if n >= 1 then cd(n - 1) else 42 }\n"
                     "fun main: Number { return cd(3) }", 42)


def test_mutually_recursive_funs_share_their_types_in_the_group(tmp_path):
    _refused(tmp_path, 'fun a(x): Number { return b(1) }\nfun b(y): Number { return a("h") + b(y) + a(y) }\n'
                       "fun main: Number { return 0 }",
             "do not agree", "annotate the parameter")


def test_outside_its_group_a_generic_fun_takes_any_instance(tmp_path):
    # g is generalized before h reads it, whatever order they are written in
    _exits(tmp_path, 'fun h: Number {\n  a := g(1)\n  b := g("x")\n  return 42\n}\n'
                     "fun g(x) { return x }\nfun main: Number { return h }", 42)


def test_a_generalized_fun_is_the_fun_written_with_a_type_parameter(tmp_path):
    use = 'fun main: Number {\n  a := id(42)\n  b := id("h")\n  return a\n}'
    left = _project(tmp_path, "fun id(x) { return x }\n" + use, "same")
    (tmp_path / "w").mkdir()
    right = _project(tmp_path / "w", "fun id<T>(x: T): T { return x }\n" + use, "same")
    for proj, out in ((left, "l.mlir"), (right, "r.mlir")):
        r = _compile(proj, tmp_path, "--emit=mlir", out=out)
        assert r.returncode == 0, r.stdout + r.stderr
    def mlir(name):
        return (tmp_path / name).read_text().replace(str(tmp_path), "ROOT").replace("/w/same", "/same")
    assert mlir("l.mlir") == mlir("r.mlir")
