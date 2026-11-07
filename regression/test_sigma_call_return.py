"""The type of a call speaks of its arguments, also when it is a Sigma.

At a call the arguments stand in place of the parameters in the whole type of the result: a path,
a product of paths, a Sigma at any depth. `snd` of a value of a Sigma has the fibre at the first
component, so the binder never stays free in the type of a value: a free binder or a free parameter
would be read as a variable of the caller, and any two variables of the caller would be equal.
The binder of a Sigma does not capture an argument of the same name.

Layer/kind: frontend / end-to-end, acceptances and refusals with their code and the words of the
reason, and with their line wherever the refusal is on the line of a proof.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

MK = "  fun mk(d: Number): Σx : Number, (x = d) ∧ (x = d) { return pair(d, pair(refl(d), refl(d))) }\n"
WIT = "  fun wit(d: Number): Σr : Number, r = d { return pair(d, refl(d)) }\n"
PAIR = "(Number, Number)"


def _entry(body):
    return "place Entry {\n" + body + "  fun main: Number { return 42 }\n}\n"


def _compile(tmp_path, src):
    f = tmp_path / "p.yon"
    f.write_text(src)
    exe = tmp_path / "exe"
    return subprocess.run([str(YONC), str(f), "-o", str(exe)],
                          capture_output=True, text=True, timeout=300), exe


def _accepted(tmp_path, body):
    r, exe = _compile(tmp_path, _entry(body))
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).returncode == 42


def _line_of(src, text):
    return next(i for i, line in enumerate(src.splitlines(), 1) if text in line)


def _refused(tmp_path, body, where, *words, reason="type mismatch"):
    # refused with its code, on the line of the proof, for its reason
    src = _entry(body)
    r, _ = _compile(tmp_path, src)
    out = r.stdout + r.stderr
    assert r.returncode != 0, out
    assert "Fatal error" not in out and "exception" not in out.lower(), out
    assert "E2001" in out, out
    assert f"[line {_line_of(src, where)}," in out, out
    for w in (reason, *words):
        assert w in out, out


# the proof read from the result of a call is a proof on the arguments

def test_the_proof_read_from_a_call_is_on_the_argument(tmp_path):
    _accepted(tmp_path, MK + "  fun use(e: Number): e = e { return fst(snd(mk(e))) }\n")


def test_the_proof_used_on_another_argument_is_refused(tmp_path):
    _refused(tmp_path, MK + "  fun use(e: Number, f: Number): e = f { return fst(snd(mk(e))) }\n",
             "fun use", "expected Id_Number(e, f)")


def test_a_proof_on_the_names_of_the_parameters_proves_nothing_about_the_caller(tmp_path):
    # the hole: with the names of the callee left free, x and d were variables of this function,
    # and any two numbers were equal
    _refused(tmp_path, MK + "  fun bad(x: Number, d: Number): x = d { return fst(snd(mk(0))) }\n",
             "fun bad", "Id_Number(x, d)")


def test_the_second_proof_speaks_of_the_first_component_of_the_call(tmp_path):
    _accepted(tmp_path, MK + "  fun use(e: Number): fst(mk(e)) = e { return snd(snd(mk(e))) }\n")
    _refused(tmp_path, MK + "  fun use(e: Number, f: Number): fst(mk(f)) = e { return snd(snd(mk(e))) }\n",
             "fun use")


def test_the_arguments_stand_all_at_once(tmp_path):
    # an argument may name another parameter: a and b are swapped, not collapsed
    two = "  fun two(a: Number, b: Number, q: a = b): Σx : Number, (a = b) ∧ (a = b) { return pair(a, pair(q, q)) }\n"
    _accepted(tmp_path, two + "  fun use(a: Number, b: Number, q: b = a): b = a { return fst(snd(two(b, a, q))) }\n")
    _refused(tmp_path, two + "  fun use(a: Number, b: Number, q: b = a): a = b { return fst(snd(two(b, a, q))) }\n",
             "fun use", "Id_Number(a, b)", "Id_Number(b, a)")


def test_a_nested_sigma_speaks_of_the_arguments_at_every_depth(tmp_path):
    three = ("  fun three(d: Number): Σa : Number, Σb : Number, (a = d) ∧ (b = d) "
             "{ return pair(d, pair(d, pair(refl(d), refl(d)))) }\n")
    _accepted(tmp_path, three + "  fun use(e: Number): e = e { return fst(snd(snd(three(e)))) }\n"
                                "  fun other(e: Number): fst(snd(three(e))) = e { return snd(snd(snd(three(e)))) }\n")
    _refused(tmp_path, three + "  fun bad(a: Number, d: Number): a = d { return fst(snd(snd(three(0)))) }\n",
             "fun bad", "Id_Number(a, d)")
    _refused(tmp_path, three + "  fun bad(b: Number, d: Number): b = d { return snd(snd(snd(three(0)))) }\n",
             "fun bad", "Id_Number(b, d)")


def test_a_call_flows_into_a_sigma_on_the_arguments(tmp_path):
    _accepted(tmp_path, WIT + "  fun same(e: Number): Σw : Number, w = e { return wit(e) }\n")
    _refused(tmp_path, WIT + "  fun other(e: Number, f: Number): Σw : Number, w = f { return wit(e) }\n",
             "fun other")


# the value of a body that ends without a return: the same statement, the same verdict

DECLARES = "declares return type"


def test_a_binding_in_tail_position_flows_on_the_arguments(tmp_path):
    _accepted(tmp_path, WIT + "  fun keeps(e: Number): Σw : Number, w = e { r := wit(e) }\n")
    _refused(tmp_path, WIT + "  fun bad(e: Number, f: Number): Σw : Number, w = f { r := wit(e) }\n",
             "fun bad", reason=DECLARES)


def test_a_call_in_tail_position_flows_on_the_arguments(tmp_path):
    _accepted(tmp_path, WIT + "  fun keeps(e: Number): Σw : Number, w = e { wit(e) }\n")
    _refused(tmp_path, WIT + "  fun bad(e: Number, f: Number): Σw : Number, w = f { wit(e) }\n",
             "fun bad", reason=DECLARES)


def test_the_expected_binder_does_not_capture_in_tail_position(tmp_path):
    _refused(tmp_path, W2 + "  fun bad(x: Number, q: x = 1): Σx : Number, (x = 0) ∧ (x = 1) { w2(x, q) }\n",
             "fun bad", reason=DECLARES)


def test_a_parameter_of_sigma_type_is_on_the_arguments(tmp_path):
    takes = "  fun takes(d: Number, s: Σx : Number, x = d): Number { return fst(s) }\n"
    _accepted(tmp_path, WIT + takes + "  fun use(e: Number): Number { return takes(e, wit(e)) }\n")
    _refused(tmp_path, WIT + takes + "  fun use(e: Number, f: Number): Number { return takes(e, wit(f)) }\n",
             "fun use", "parameter s", reason="takes")


def test_a_pair_written_at_the_call_is_checked_against_the_sigma(tmp_path):
    # the fibre at the first component of the pair
    wants = "  fun wants(d: Number, s: Σx : Number, (x = d) ∧ (x = d)): Number { return fst(s) }\n"
    _accepted(tmp_path, wants + "  fun use(e: Number): Number { return wants(e, pair(e, pair(refl(e), refl(e)))) }\n")
    _refused(tmp_path, wants + "  fun use(e: Number, f: Number): Number "
                               "{ return wants(e, pair(f, pair(refl(f), refl(f)))) }\n",
             "fun use", "parameter s", reason="wants")


def test_a_sigma_argument_with_another_fibre_is_refused(tmp_path):
    # two products with the same components have the same fibre only if their paths are the same
    plain = "  fun plain(s: Σx : Number, x = 1): Number { return fst(s) }\n"
    _accepted(tmp_path, plain + "  fun use(s: Σr : Number, r = 1): Number { return plain(s) }\n")
    _refused(tmp_path, plain + "  fun use(s: Σr : Number, r = 2): Number { return plain(s) }\n",
             "fun use", "parameter s", reason="plain")


# the binder does not capture

def test_an_argument_named_as_the_binder_stays_the_argument(tmp_path):
    # with the capture the call would have the type Σr : Number, r = r
    _accepted(tmp_path, WIT + "  fun keeps(r: Number): Σw : Number, w = r { return wit(r) }\n")
    _refused(tmp_path, WIT + "  fun loses(r: Number): Σw : Number, w = w { return wit(r) }\n",
             "fun loses")


def test_the_proof_read_with_an_argument_named_as_the_binder(tmp_path):
    _accepted(tmp_path, MK + "  fun use(x: Number): x = x { return fst(snd(mk(x))) }\n")
    _refused(tmp_path, MK + "  fun bad(x: Number, y: Number): y = x { return fst(snd(mk(x))) }\n",
             "fun bad", "Id_Number(y, x)")


def test_an_argument_inside_an_expression_named_as_the_binder(tmp_path):
    # the name of the binder is inside the argument, not the whole of it
    _accepted(tmp_path, WIT + "  fun keeps(r: Number): Σw : Number, w = r + 1 { return wit(r + 1) }\n")
    _refused(tmp_path, WIT + "  fun loses(r: Number): Σw : Number, w = w + 1 { return wit(r + 1) }\n",
             "fun loses")


def test_an_argument_named_as_an_inner_binder_stays_the_argument(tmp_path):
    inner = ("  fun inner(d: Number): Σa : Number, Σb : Number, b = d "
             "{ return pair(d, pair(d, refl(d))) }\n")
    _accepted(tmp_path, inner + "  fun keeps(b: Number): Σw : Number, Σz : Number, z = b { return inner(b) }\n")
    _refused(tmp_path, inner + "  fun loses(b: Number): Σw : Number, Σz : Number, z = z { return inner(b) }\n",
             "fun loses")


W2 = "  fun w2(d: Number, q: d = 1): Σr : Number, (r = 0) ∧ (d = 1) { return pair(0, pair(refl(0), q)) }\n"


def test_the_expected_binder_does_not_capture_the_argument_of_a_call(tmp_path):
    # with the capture bad would say that one number is equal to 0 and to 1
    _refused(tmp_path, W2 + "  fun bad(x: Number, q: x = 1): Σx : Number, (x = 0) ∧ (x = 1) { return w2(x, q) }\n",
             "fun bad")


def test_the_call_flows_into_an_expected_binder_with_another_name(tmp_path):
    _accepted(tmp_path, W2 + "  fun keeps(x: Number, q: x = 1): Σw : Number, (w = 0) ∧ (x = 1) { return w2(x, q) }\n")


def test_the_expected_binder_does_not_capture_a_variable_in_a_pair_in_a_variable(tmp_path):
    # the type of p has no binder of its own: the x of its fibre is the parameter
    _refused(tmp_path, "  fun bad(x: Number, q: x = 1): Σx : Number, x = 1 {\n"
                       "    p := pair(0, q)\n"
                       "    return p\n  }\n",
             "return p")


def test_the_pair_built_with_a_first_component_named_as_a_binder(tmp_path):
    # the same substitution, when a pair is checked against a Sigma: the first component is a term
    # of the outside, the inner binder does not capture it
    sigma = "Σa : Number, Σb : Number, (a = b) ∧ (b = b)"
    _refused(tmp_path, f"  fun loses(b: Number, c: Number, q: c = c): {sigma} "
                       "{ return pair(b, pair(c, pair(q, q))) }\n",
             "fun loses")
    _accepted(tmp_path, f"  fun keeps(b: Number): {sigma} "
                        "{ return pair(b, pair(b, pair(refl(b), refl(b)))) }\n")


def test_a_parameter_named_as_the_binder_is_hidden_by_it(tmp_path):
    # the binder hides the parameter of its name: the fibre speaks of the binder
    hid = "  fun hid(x: Number): Σx : Number, x = x { return pair(x, refl(x)) }\n"
    _accepted(tmp_path, hid + "  fun use(e: Number): Number { return fst(hid(e)) }\n"
                              "  fun read(e: Number): fst(hid(e)) = fst(hid(e)) { return snd(hid(e)) }\n")


# a fibre that reads the binder or a parameter through fst and snd

def test_the_binder_under_a_projection_in_the_fibre(tmp_path):
    fib = (f"  fun fib(d: Number): Σp : {PAIR}, fst(p) = d "
           "{ return pair(pair(d, 0), refl(d)) }\n")
    _accepted(tmp_path, fib + "  fun use(e: Number): e = e { return snd(fib(e)) }\n")
    _refused(tmp_path, fib + f"  fun bad(p: {PAIR}, d: Number): fst(p) = d {{ return snd(fib(0)) }}\n",
             "fun bad")


def test_a_parameter_under_a_projection_in_the_result(tmp_path):
    # the argument is the pair (7, 0), not a pair of the caller that bears the name of the parameter
    k = f"  fun k(s: {PAIR}, q: s = pair(7, 0)): fst(s) = 7 {{ return k(s, q) }}\n"
    _accepted(tmp_path, k + "  fun use: 7 = 7 { return k(pair(7, 0), refl(pair(7, 0))) }\n")
    _refused(tmp_path, k + f"  fun bad(s: {PAIR}): fst(s) = 7 {{ return k(pair(7, 0), refl(pair(7, 0))) }}\n",
             "fun bad")


def test_two_products_with_other_binders_under_a_projection(tmp_path):
    # the name of the binder does not tell two products apart, under fst either
    _accepted(tmp_path,
              f"  fun left(d: Number, s: Σp : {PAIR}, fst(p) = d): Σq : {PAIR}, fst(q) = d {{ return s }}\n")
    _refused(tmp_path,
             f"  fun bad(d: Number, s: Σp : {PAIR}, fst(p) = d): Σq : {PAIR}, snd(q) = d {{ return s }}\n",
             "fun bad")


# a parameter that is a function, called in the type of the result

INC = "  fun inc(n: Number): Number { return n + 1 }\n"
CALLS = "  fun k(g: Number -> Number, q: g = inc): g(0) = 1 { return k(g, q) }\n"


def test_a_called_parameter_is_the_argument(tmp_path):
    _accepted(tmp_path, INC + CALLS + "  fun use: inc(0) = 1 { return k(inc, refl(inc)) }\n")
    _refused(tmp_path, INC + CALLS + "  fun bad(g: Number -> Number): g(0) = 1 { return k(inc, refl(inc)) }\n",
             "fun bad")


def test_a_parameter_named_as_a_fun_is_the_parameter(tmp_path):
    # what the substitution relies on: a name called is the parameter first, then the fun
    r, exe = _compile(tmp_path, "place Entry {\n" + INC +
                      "  fun k(inc: Number -> Number): Number { return inc(0) }\n"
                      "  fun main: Number { return k(fun(x: Number) => x + 42) }\n}\n")
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).returncode == 42


# a cell: its type does not change, so a proof read from it stays true

def test_a_cell_keeps_the_statement_of_its_first_value(tmp_path):
    _refused(tmp_path, WIT + "  fun bad: Number {\n"
                             "    mut c := wit(1)\n"
                             "    c <- wit(2)\n"
                             "    return fst(c)\n  }\n",
             "c <- wit(2)")


# a value in a variable: the proof speaks of that value

def test_the_proof_read_from_a_variable_speaks_of_the_variable(tmp_path):
    _accepted(tmp_path, f"  fun read(d: Number, s: Σx : Number, x = d): fst(s) = d {{ return snd(s) }}\n")
    _refused(tmp_path, f"  fun bad(x: Number, d: Number, s: Σx : Number, x = d): x = d {{ return snd(s) }}\n",
             "fun bad", "Id_Number(x, d)")


def test_the_proof_of_a_comprehension_speaks_of_its_element(tmp_path):
    _accepted(tmp_path, "  fun proof(a: Number, s: { x : Number where x = a }): fst(s) = a { return snd(s) }\n")
    _refused(tmp_path,
             "  fun bad(x: Number, a: Number, s: { x : Number where x = a }): x = a { return snd(s) }\n",
             "fun bad", "Id_Number(x, a)")


def _on_the_kernel(tmp_path, body):
    meta = ROOT / "meta"
    if not meta.exists():
        pytest.skip("meta/ missing")
    proj = tmp_path / "meta"
    shutil.copytree(meta, proj)
    proofs = proj / "kernel" / "Proofs.yon"
    source = proofs.read_text()
    assert "place Proofs {\n" in source
    proofs.write_text(source.replace("place Proofs {\n", "place Proofs {\n" + body, 1))
    return subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                          capture_output=True, text=True, timeout=300)


# what peak_of asks of it: the proofs of a recursive call, whose result does not compute. The
# project of the kernel is a project of proofs: a proof reaches no native code

SAME = ("  fun same(n: Nat): Σm : Nat, m = n {\n"
        "    return match n {\n"
        "      zero => pair(zero, refl(zero)),\n"
        "      succ as k => pair(fst(same(k)) ↪ succ, (fun(x: Nat) => x ↪ succ, snd(same(k))) ↦ ap)\n"
        "    }\n  }\n")


def _kernel_refusal(r, body, where):
    # the body opens the place: its lines count from the line of the place
    opening = _line_of((ROOT / "meta" / "kernel" / "Proofs.yon").read_text(), "place Proofs {")
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "type mismatch" in out, out
    assert f"[line {opening + _line_of(body, where)}," in out, out


def test_a_branch_reads_the_proof_of_its_recursive_call(tmp_path):
    r = _on_the_kernel(tmp_path, SAME)
    assert r.returncode == 0, r.stdout + r.stderr


def test_the_proof_of_the_recursive_call_says_only_its_argument(tmp_path):
    # the proof of same(k) is on k: it does not close the branch of succ(k)
    wrong = SAME.replace("pair(fst(same(k)) ↪ succ, (fun(x: Nat) => x ↪ succ, snd(same(k))) ↦ ap)",
                         "pair(fst(same(k)) ↪ succ, snd(same(k)))")
    assert wrong != SAME
    _kernel_refusal(_on_the_kernel(tmp_path, wrong), wrong, "succ as k")


def test_a_recursive_proof_used_on_another_number_is_refused(tmp_path):
    body = SAME + "  fun bad(n: Nat, k: Nat): fst(same(k)) = n { return snd(same(k)) }\n"
    _kernel_refusal(_on_the_kernel(tmp_path, body), body, "fun bad")


# the binder of a branch inside an endpoint does not capture an argument either

PICK = ("  fun pick(d: Nat, n: Nat): (match n { zero => d, succ as k => d }) = d {\n"
        "    return match n { zero => refl(d), succ as k => refl(d) }\n  }\n")


def test_an_argument_named_as_the_binder_of_a_branch_stays_the_argument(tmp_path):
    # with the capture the endpoint would compute to the payload, zero, and not to k
    r = _on_the_kernel(tmp_path, PICK + "  fun use(k: Nat): k = k { return pick(k, zero ↪ succ) }\n")
    assert r.returncode == 0, r.stdout + r.stderr


def test_the_argument_in_a_branch_is_not_the_payload(tmp_path):
    body = PICK + "  fun bad(k: Nat): zero = k { return pick(k, zero ↪ succ) }\n"
    _kernel_refusal(_on_the_kernel(tmp_path, body), body, "fun bad")


STATED = "Σp : Peak, (p ↦ Peak.left = d1) ∧ (p ↦ Peak.right = d2)"
READ = (f"  fun left_of(d1: Step, d2: Step, s: {STATED}): fst(s) ↦ Peak.left = d1 {{\n"
        "    return fst(snd(s))\n  }\n"
        f"  fun right_of(d1: Step, d2: Step, s: {STATED}): fst(s) ↦ Peak.right = d2 {{\n"
        "    return snd(snd(s))\n  }\n")
AT_ARGS = "s: Σr : Peak, (r ↦ Peak.left = e) ∧ (r ↦ Peak.right = f)"


def test_the_statement_of_peak_of_is_read_on_the_arguments_in_the_kernel(tmp_path):
    r = _on_the_kernel(tmp_path, READ +
                       f"  fun read(e: Step, f: Step, {AT_ARGS}): fst(s) ↦ Peak.left = e {{\n"
                       "    return left_of(e, f, s)\n  }\n"
                       f"  fun read_right(e: Step, f: Step, {AT_ARGS}): fst(s) ↦ Peak.right = f {{\n"
                       "    return right_of(e, f, s)\n  }\n")
    assert r.returncode == 0, r.stdout + r.stderr


def test_the_statement_of_peak_of_on_the_other_step_is_refused_in_the_kernel(tmp_path):
    r = _on_the_kernel(tmp_path, READ +
                       f"  fun wrong(e: Step, f: Step, {AT_ARGS}): fst(s) ↦ Peak.left = f {{\n"
                       "    return left_of(e, f, s)\n  }\n")
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "type mismatch" in out, out


def test_the_statement_of_peak_of_with_its_steps_swapped_is_refused_in_the_kernel(tmp_path):
    r = _on_the_kernel(tmp_path, READ +
                       f"  fun swapped(e: Step, f: Step, {AT_ARGS}): fst(s) ↦ Peak.left = e {{\n"
                       "    return left_of(f, e, s)\n  }\n")
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "E2001" in out and "left_of" in out and "parameter s" in out, out
