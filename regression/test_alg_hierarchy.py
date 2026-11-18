"""The signatures Magma, Semigroup, Monoid and Group, and a fun parameter that uses one.

`this <` between algebras: the heir reads the signature above it, its operations
and its laws, so the models of the heir are a subobject. A law of a signature that
follows from the laws before it is proved there, once, and no model is asked for
it. `fun f<T uses Monoid>` takes a model at each call, and a place with two
structures names the algebra: `f<Additive>(xs)`.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest
from yon_programs import program

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_CONCAT_ALL = (
    program("test_alg_hierarchy/module_1.yon")
)


def _build(tmp_path: Path, main_body: str, places: dict = None, top: str = _CONCAT_ALL):
    proj = tmp_path / "proj"
    proj.mkdir()
    objs = ", ".join(f'"{p}"' for p in (places or {}))
    (proj / "yon.toml").write_text(
        '[package]\nname = "hier"\n\n'
        + (f"[world.W]\nobjects = [{objs}]\n\n" if places else "")
        + '[runtime]\nbackend = "memory"\n')
    for name, src in (places or {}).items():
        (proj / f"{name}.yon").write_text(src)
    (proj / "Entry.yon").write_text(
        top + "place Entry {\nfun main: Number {\n" + main_body + "\n}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


def _exit_of(tmp_path, main_body, places=None, top=_CONCAT_ALL):
    rc, out, exe = _build(tmp_path, main_body, places, top)
    assert rc == 0, out
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).returncode


# ─── the parameter takes a model ───────────────────────────────────────────


def test_concat_all_on_additive(tmp_path):
    body = "  r := concat_all<Additive>(three(1, 2, 39))\n  return if r == 42 then 42 else 1"
    assert _exit_of(tmp_path, body) == 42


def test_concat_all_on_multiplicative(tmp_path):
    body = "  r := concat_all<Multiplicative>(three(2, 3, 7))\n  return if r == 42 then 42 else 1"
    assert _exit_of(tmp_path, body) == 42


def test_concat_all_on_text_needs_no_name(tmp_path):
    body = ('  r := concat_all(List.cons("a", List.cons("b", List.cons("c", List.empty))))\n'
            '  return if Text.equal(r, "abc") then 42 else 1')
    assert _exit_of(tmp_path, body) == 42


def test_the_empty_list_is_the_unit_of_the_named_algebra(tmp_path):
    top = program("test_alg_hierarchy/test_the_empty_list_is_the_unit_of_the_named_algebra_1.yon")
    body = "  return if sum_of_none == 0 and product_of_none == 1 then 42 else 1"
    assert _exit_of(tmp_path, body, top=top) == 42


_COUNT = (program("test_alg_hierarchy/module_2.yon"))


def test_a_place_with_one_structure_is_its_model(tmp_path):
    top = program("test_alg_hierarchy/test_a_place_with_one_structure_is_its_model_1.yon")
    body = "  return some_of(List.cons(None, List.cons(Some, List.empty)))"
    assert _exit_of(tmp_path, body, {"Count": _COUNT}, top) == 42


def test_a_word_uses_the_operator_of_the_algebra_it_names(tmp_path):
    top = program("test_alg_hierarchy/test_a_word_uses_the_operator_of_the_algebra_it_names_1.yon")
    body = ("  w := Word64.from_int64(6)\n  v := Word64.from_int64(7)\n"
            "  return if concat_all<Multiplicative>(words(w, v)) == Word64.from_int64(42)\n"
            "         and concat_all<Additive>(words(w, v)) == Word64.from_int64(13)\n"
            "         then 42 else 1")
    assert _exit_of(tmp_path, body, top=top) == 42


# ─── what the parameter refuses ────────────────────────────────────────────


def test_a_value_with_no_structure_is_refused(tmp_path):
    rc, out, _ = _build(tmp_path, "  return concat_all(List.cons(1, List.empty))")
    assert rc != 0 and "E2001" in out, out
    assert "Number does not use Monoid" in out, out


def test_a_place_that_uses_no_monoid_is_refused(tmp_path):
    src = program("test_alg_hierarchy/test_a_place_that_uses_no_monoid_is_refused_1.yon")
    top = program("test_alg_hierarchy/test_a_place_that_uses_no_monoid_is_refused_2.yon")
    rc, out, _ = _build(tmp_path, "  return 42", {"Box": src}, top)
    assert rc != 0 and "E2001" in out, out
    assert "Box does not use Monoid" in out, out


def test_two_structures_without_a_name_are_ambiguous(tmp_path):
    rc, out, _ = _build(tmp_path, "  r := concat_all(three(1, 2, 39))\n  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "is ambiguous" in out and "Int64 has 2 structures" in out, out
    assert "Additive" in out and "Multiplicative" in out, out


def test_an_algebra_outside_the_signature_is_refused(tmp_path):
    src = program("test_alg_hierarchy/test_an_algebra_outside_the_signature_is_refused_1.yon")
    rc, out, _ = _build(tmp_path, "  r := concat_all<Flip>(three(1, 2, 39))\n  return 42", {"Flip": src})
    assert rc != 0 and "E2001" in out, out
    assert "names Flip, which is no Monoid" in out, out


def test_an_algebra_the_values_are_no_model_of_is_refused(tmp_path):
    rc, out, _ = _build(tmp_path, "  r := concat_all<BooleanOr>(three(1, 2, 39))\n  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "Int64 is no model of it" in out, out


def test_a_bound_that_names_no_algebra_is_refused(tmp_path):
    top = (program("test_alg_hierarchy/test_a_bound_that_names_no_algebra_is_refused_1.yon"))
    rc, out, _ = _build(tmp_path, "  return first(List.cons(1, List.empty))", top=top)
    assert rc != 0 and "E2001" in out, out
    assert "Monoidd, which is no algebra" in out, out


def test_a_member_outside_the_signature_is_refused(tmp_path):
    top = program("test_alg_hierarchy/test_a_member_outside_the_signature_is_refused_1.yon")
    rc, out, _ = _build(tmp_path, "  return 42", top=top)
    assert rc != 0 and "E2001" in out, out


def test_the_body_is_checked_parametric_in_the_parameter(tmp_path):
    top = program("test_alg_hierarchy/test_the_body_is_checked_parametric_in_the_parameter_1.yon")
    rc, out, _ = _build(tmp_path, "  return 42", top=top)
    assert rc != 0 and "E2001" in out, out


def test_a_comparison_is_not_read_as_type_arguments(tmp_path):
    body = ("  a := 1\n  b := 2\n  c := 3\n"
            "  return if a < b and b > (a) then 42 else 1")
    assert _exit_of(tmp_path, body, top="") == 42


# ─── the two instances are told apart ──────────────────────────────────────


def test_an_operation_is_named_by_its_algebra(tmp_path):
    top = (program("test_alg_hierarchy/test_an_operation_is_named_by_its_algebra_1.yon"))
    body = "  return if sum(40, 2) == 42 and product(6, 7) == 42 then 42 else 1"
    assert _exit_of(tmp_path, body, top=top) == 42


def test_an_operation_on_a_value_that_is_no_model_is_refused(tmp_path):
    rc, out, _ = _build(tmp_path, "  r := Additive.op(1, 2)\n  return 42", top="")
    assert rc != 0 and "E2001" in out and "Number is no model of it" in out, out


def test_int64_keeps_its_exact_operators(tmp_path):
    src = (ROOT / "prelude" / "num64" / "Int64.yon").read_text()
    assert "uses algebra Additive, Multiplicative" in src
    top = program("test_alg_hierarchy/test_int64_keeps_its_exact_operators_1.yon")
    rc, out, exe = _build(tmp_path, "  r := big + 1\n  return if r == 0 then 1 else 2", top=top)
    assert rc == 0, out
    # the sum on Int64 is the exact one: an overflow stops the program, it does not wrap
    assert subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).returncode not in (1, 2)


# ─── the signature read whole ──────────────────────────────────────────────


def test_an_heir_takes_the_operations_of_the_signature(tmp_path):
    src = program("test_alg_hierarchy/test_an_heir_takes_the_operations_of_the_signature_1.yon")
    rc, out, _ = _build(tmp_path, "  return 42", {"Count": src}, top="")
    assert rc != 0 and "does not give its operation unit" in out, out


def test_an_heir_takes_the_laws_of_the_signature(tmp_path):
    wrong = _COUNT.replace("Some => Some }", "Some => None }")
    rc, out, _ = _build(tmp_path, "  return 42", {"Count": wrong}, top="")
    assert rc != 0 and "E2101" in out, out
    assert "law associative of algebra Monoid" in out or "law neutral of algebra Monoid" in out, out


def test_this_under_a_name_that_is_no_algebra_is_refused(tmp_path):
    src = program("test_alg_hierarchy/test_this_under_a_name_that_is_no_algebra_is_refused_1.yon")
    rc, out, _ = _build(tmp_path, "  return 42", {"Nope": src}, top="")
    assert rc != 0 and "E2001" in out and "`this < Number`, which is no algebra" in out, out


def test_a_declared_again_operation_must_have_the_signatures_type(tmp_path):
    src = (program("test_alg_hierarchy/test_a_declared_again_operation_must_have_the_signatures_type_1.yon"))
    rc, out, _ = _build(tmp_path, "  return 42", {"Odd": src}, top="")
    assert rc != 0 and "E2001" in out and "does not have the type it has in Magma" in out, out


def test_a_fun_named_concat_is_read_from_its_own_body(tmp_path):
    """On a carrier of texts only the carrier's own concatenation is the machine's:
    a fun of the house with that name and a body is that body, and here it is no
    monoid, since op(unit, a) is the unit."""
    src = (program("test_alg_hierarchy/test_a_fun_named_concat_is_read_from_its_own_body_1.yon"))
    rc, out, _ = _build(tmp_path, "  return 42", {"Left": src}, top="")
    assert rc != 0 and "E2101" in out, out
    assert "law neutral of algebra Monoid on place Left" in out, out


def test_a_concat_with_no_body_exists_only_in_the_prelude(tmp_path):
    """The reading of a concat with no body as the concatenation of the texts is
    closed to the program: only the prelude declares a primitive."""
    src = (program("test_alg_hierarchy/test_a_concat_with_no_body_exists_only_in_the_prelude_1.yon"))
    rc, out, _ = _build(tmp_path, "  return 42", {"Left": src}, top="")
    assert rc != 0 and "E2007" in out, out
    assert "the primitives of the runtime are declared in the prelude only" in out, out


# ─── a lemma on the signature ──────────────────────────────────────────────

# inv(unit) is not the unit, so this model fails the lemma; the axioms are what
# it is refuted on, and no one asks it for the lemma, which the axioms imply.
_NOT_A_GROUP = (program("test_alg_hierarchy/module_3.yon"))


def test_the_lemma_is_not_asked_of_a_model(tmp_path):
    rc, out, _ = _build(tmp_path, "  return 42", {"Two": _NOT_A_GROUP}, top="")
    assert rc != 0 and "E2101" in out, out
    assert "law inverse of algebra Group" in out, out
    assert "inverse_of_unit" not in out, out


def test_the_lemma_comes_down_to_additive_proved(tmp_path):
    """A carrier the certification cannot decide: each axiom of Additive is not
    certified, by name, and the lemma the signature proved is not among them."""
    src = (program("test_alg_hierarchy/test_the_lemma_comes_down_to_additive_proved_1.yon"))
    rc, out, _ = _build(tmp_path, "  return 42", {"Sum": src}, top="")
    assert rc != 0, out
    assert "law inverse of algebra Additive" in out, out
    assert "inverse_of_unit" not in out, out


def test_without_its_axioms_the_lemma_is_an_axiom(tmp_path):
    """The proof is a real one: take away what it rests on and the same statement
    is asked of the model, and refuted."""
    weak = (program("test_alg_hierarchy/test_without_its_axioms_the_lemma_is_an_axiom_1.yon"))
    model = _NOT_A_GROUP.replace("uses algebra Group", "uses algebra Weak")
    rc, out, _ = _build(tmp_path, "  return 42", {"Weak": weak, "Two": model}, top="")
    assert rc != 0 and "E2101" in out and "inverse_of_unit" in out, out


# ─── the free semigroup ────────────────────────────────────────────────────

_WORDS = (
    program("test_alg_hierarchy/module_4.yon")
)


def test_normal_form_on_additive(tmp_path):
    body = ("  r := List.normal_form<Additive>(three_words(1, 2, 39))\n"
            "  return if r == 42 then 42 else 1")
    assert _exit_of(tmp_path, body, top=_WORDS) == 42


def test_normal_form_on_multiplicative(tmp_path):
    body = ("  r := List.normal_form<Multiplicative>(three_words(2, 3, 7))\n"
            "  return if r == 42 then 42 else 1")
    assert _exit_of(tmp_path, body, top=_WORDS) == 42


def test_normal_form_on_a_word_of_one_letter_is_the_letter(tmp_path):
    body = ("  r := List.normal_form<Additive>(one(42))\n"
            "  return if r == 42 then 42 else 1")
    top = program("test_alg_hierarchy/test_normal_form_on_a_word_of_one_letter_is_the_letter_1.yon")
    assert _exit_of(tmp_path, body, top=top) == 42


def test_normal_form_keeps_the_order_of_a_word_of_text(tmp_path):
    body = ('  w := pair("a", List.cons("b", List.cons("c", List.empty)))\n'
            '  return if Text.equal(List.normal_form(w), "abc") then 42 else 1')
    assert _exit_of(tmp_path, body, top="") == 42


def test_normal_form_with_two_structures_and_no_name_is_ambiguous(tmp_path):
    rc, out, _ = _build(tmp_path, "  r := List.normal_form(three_words(1, 2, 3))\n  return 42", top=_WORDS)
    assert rc != 0 and "E2001" in out and "is ambiguous" in out, out


def test_a_word_reads_only_on_an_associative_operation(tmp_path):
    """The free semigroup holds only if the operation is associative: subtraction
    modulo 2, on the side that matters, is no model of Semigroup."""
    minus = (program("test_alg_hierarchy/test_a_word_reads_only_on_an_associative_operation_1.yon"))
    rc, out, _ = _build(tmp_path, "  return 42", {"Odd": minus}, top="")
    assert rc != 0 and "E2101" in out, out
    assert "law associative of algebra Semigroup on place Odd is refuted" in out, out


def test_an_empty_list_is_refused_by_normal_form(tmp_path):
    rc, out, _ = _build(tmp_path, "  r := List.normal_form<Additive>(List.empty)\n  return 42", top="")
    assert rc != 0 and "E2001" in out and "no argument fixes the values" in out, out


# ─── the algebras of the user ──────────────────────────────────────────────


def _in_space(tmp_path: Path, files: dict, main_body: str, top: str = ""):
    """A project whose places live in the Space `w`: the world comes from the toml."""
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    objs = ", ".join(f'"{p}"' for p in files)
    (proj / "yon.toml").write_text(
        '[package]\nname = "user_alg"\n\n'
        f'[world.W]\nobjects = [{objs}]\nspaces  = ["w"]\n\n'
        '[runtime]\nbackend = "memory"\n')
    for name, src in files.items():
        (proj / "w" / f"{name}.yon").write_text(src)
    (proj / "w" / "Topos.yon").write_text(program("test_alg_hierarchy/_in_space_1.yon"))
    (proj / "Entry.yon").write_text(
        top + "place Entry {}\nfun main: Number {\n" + main_body + "\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


_TALLY = (program("test_alg_hierarchy/module_5.yon"))
_SEEN = (program("test_alg_hierarchy/module_6.yon"))
_ONLY_TALLY = (program("test_alg_hierarchy/module_7.yon"))
_SEEN_LIST = "List.cons(Never, List.cons(Once, List.empty))"


def test_a_user_algebra_is_a_bound_like_a_signature_of_the_prelude(tmp_path):
    rc, out, exe = _in_space(tmp_path, {"Tally": _TALLY, "Seen": _SEEN},
                             f"  return seen_of({_SEEN_LIST})", _CONCAT_ALL + _ONLY_TALLY)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


def test_a_model_of_a_user_algebra_is_a_model_of_the_signature_above(tmp_path):
    rc, out, exe = _in_space(tmp_path, {"Tally": _TALLY, "Seen": _SEEN},
                             f"  return concat_of({_SEEN_LIST})", _CONCAT_ALL + _ONLY_TALLY)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


def test_a_user_algebra_inherits_the_laws_and_adds_its_own(tmp_path):
    not_neutral = program("test_alg_hierarchy/test_a_user_algebra_inherits_the_laws_and_adds_its_own_1.yon")
    rc, out, _ = _in_space(tmp_path, {"Tally": _TALLY, "Seen": not_neutral}, "  return 42")
    assert rc != 0 and "E2101" in out and "law neutral of algebra Tally on place Seen" in out, out
    (tmp_path / "own").mkdir()
    not_idempotent = (program("test_alg_hierarchy/test_a_user_algebra_inherits_the_laws_and_adds_its_own_2.yon"))
    rc, out, _ = _in_space(tmp_path / "own", {"Tally": _TALLY, "Flip": not_idempotent}, "  return 42")
    assert rc != 0 and "E2101" in out and "law idempotent of algebra Tally on place Flip" in out, out


def test_a_model_of_the_signature_above_is_no_model_of_the_user_algebra(tmp_path):
    plain = _SEEN.replace("uses algebra Tally", "uses algebra Monoid")
    rc, out, _ = _in_space(tmp_path, {"Tally": _TALLY, "Seen": plain},
                           f"  return seen_of({_SEEN_LIST})", _CONCAT_ALL + _ONLY_TALLY)
    assert rc != 0 and "E2001" in out and "Seen does not use Tally" in out, out


_POINTED = (program("test_alg_hierarchy/module_8.yon"))
_SIDE = (program("test_alg_hierarchy/module_9.yon"))
_NEXT = (program("test_alg_hierarchy/module_10.yon"))


def test_a_signature_of_the_user_from_nothing_is_a_bound(tmp_path):
    rc, out, exe = _in_space(tmp_path, {"Pointed": _POINTED, "Side": _SIDE},
                             "  return answer(next_of(Left))", _NEXT)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


def test_a_false_law_of_a_user_signature_is_refuted(tmp_path):
    wrong = _SIDE.replace("Left => Right, Right => Left", "Left => Right, Right => Right")
    rc, out, _ = _in_space(tmp_path, {"Pointed": _POINTED, "Side": wrong}, "  return 42")
    assert rc != 0 and "E2101" in out and "law returns of algebra Pointed on place Side" in out, out


def test_the_refusal_strikes_the_undeclared_algebra_not_the_one_in_a_space(tmp_path):
    undeclared = _SIDE.replace("uses algebra Pointed", "uses algebra Nope")
    rc, out, _ = _in_space(tmp_path, {"Side": undeclared}, "  return 42")
    assert rc != 0 and "E2001" in out and "which is no algebra" in out, out
    (tmp_path / "declared").mkdir()
    rc, out, exe = _in_space(tmp_path / "declared", {"Pointed": _POINTED, "Side": _SIDE}, "  return 42")
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


# ─── the laws answer Generated ─────────────────────────────────────────────

_ONE = (program("test_alg_hierarchy/module_11.yon"))


def test_is_associative_answers_from_the_law_with_no_closure(tmp_path):
    # the closure of 1 under + does not end: only the law can answer
    body = ("  m := Generated.generated_by_instance<Additive>(of_one(1))\n"
            "  return match Generated.is_associative(m) { Boolean as b => answer(b), DomainError as d => refused(d) }")
    assert _exit_of(tmp_path, body, top=_ONE) == 42


def test_is_commutative_answers_from_the_law_with_no_closure(tmp_path):
    body = ("  m := Generated.generated_by_instance<Additive>(of_one(1))\n"
            "  return match Generated.is_commutative(m) { Boolean as b => answer(b), DomainError as d => refused(d) }")
    assert _exit_of(tmp_path, body, top=_ONE) == 42


def test_a_law_the_instance_does_not_state_is_decided_on_the_closure(tmp_path):
    # Text is a Monoid with no law of commutativity: the question goes to the closure,
    # which on texts does not end, and the answer is the refusal past its limit
    top = (program("test_alg_hierarchy/test_a_law_the_instance_does_not_state_is_decided_on_the_closure_1.yon"))
    body = ('  m := Generated.generated_by_instance(HashSet.add(HashSet.add(HashSet.empty, "a"), "b"))\n'
            "  return match Generated.is_commutative(m) { Boolean as b => answer(b), DomainError as d => refused(d) }")
    assert _exit_of(tmp_path, body, top=top) == 2


def test_the_same_operation_with_no_instance_goes_to_the_closure(tmp_path):
    top = program("test_alg_hierarchy/test_the_same_operation_with_no_instance_goes_to_the_closure_1.yon")
    body = ("  m := Generated.generated_by(plus, of_one(1))\n"
            "  return match Generated.is_associative(m) { Boolean as b => answer(b), DomainError as d => refused(d) }")
    assert _exit_of(tmp_path, body, top=top) == 2


# ─── the free magma ────────────────────────────────────────────────────────


def test_the_free_magma_keeps_the_parentheses_and_the_order(tmp_path):
    body = ("  a := MerkleTree.leaf(1)\n  b := MerkleTree.leaf(2)\n  c := MerkleTree.leaf(3)\n"
            "  left := MerkleTree.node2(0, MerkleTree.node2(0, a, b), c)\n"
            "  right := MerkleTree.node2(0, a, MerkleTree.node2(0, b, c))\n"
            "  ab := MerkleTree.node2_commutative(0, a, b)\n"
            "  ba := MerkleTree.node2_commutative(0, b, a)\n"
            "  return if not MerkleTree.equal(left, right)\n"
            "         and not MerkleTree.equal(MerkleTree.node2(0, a, b), MerkleTree.node2(0, b, a))\n"
            "         and MerkleTree.equal(ab, ba) then 42 else 1")
    assert _exit_of(tmp_path, body, top="") == 42


# ─── the heir is a subobject ───────────────────────────────────────────────


def test_an_heir_that_states_again_a_law_of_the_signature_is_refused(tmp_path):
    # stated again, the law would replace the one of Group, and a model of the
    # weaker law would pass for a group
    loose = (program("test_alg_hierarchy/test_an_heir_that_states_again_a_law_of_the_signature_is_refused_1.yon"))
    rc, out, _ = _in_space(tmp_path, {"Loose": loose}, "  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "law inverse of Loose is a law of Group, which Loose inherits" in out, out
    assert "give the new law its own name" in out, out


def test_a_chain_of_signatures_that_comes_back_is_refused(tmp_path):
    a = program("test_alg_hierarchy/test_a_chain_of_signatures_that_comes_back_is_refused_1.yon")
    b = program("test_alg_hierarchy/test_a_chain_of_signatures_that_comes_back_is_refused_2.yon")
    rc, out, _ = _in_space(tmp_path, {"A": a, "B": b}, "  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "algebra A is `this <` itself through A < B < A" in out, out


def test_a_law_named_commutative_that_states_another_thing_answers_no(tmp_path):
    # the law named commutative here says op(a, a) = a: the word asks for
    # op(a, b) = op(b, a), which does not follow, and the closure decides
    idem = (program("test_alg_hierarchy/test_a_law_named_commutative_that_states_another_thing_answers_no_1.yon"))
    left = (program("test_alg_hierarchy/test_a_law_named_commutative_that_states_another_thing_answers_no_2.yon"))
    top = (program("test_alg_hierarchy/test_a_law_named_commutative_that_states_another_thing_answers_no_3.yon"))
    body = ("  m := Generated.generated_by_instance(HashSet.add(HashSet.add(HashSet.empty, Ay), Be))\n"
            "  return match Generated.is_commutative(m) { Boolean as b => answer(b), DomainError as d => refused(d) }")
    rc, out, exe = _in_space(tmp_path, {"Idem": idem, "Lp": left}, body, top)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


# ─── an internal instance is its carrier inside its house ──────────────────

_HIDDEN = (program("test_alg_hierarchy/module_12.yon"))
_WORD = (program("test_alg_hierarchy/module_13.yon"))
_MEET = (program("test_alg_hierarchy/module_14.yon"))
_OUTSIDE = "is internal: outside its house its values do not convert through its carrier, and come from its funs, and from its operations for an algebra"


def test_inside_its_house_an_internal_instance_is_its_carrier(tmp_path):
    # a fun in the body of an instance is a fun of its house, on the carrier:
    # a Sum from an Int64, an Int64 from a Sum, a literal, the carrier's sum
    rc, out, exe = _in_space(tmp_path, {"Sum": _HIDDEN},
                             "  return if Sum.value(Sum.make(40) + Sum.make(2)) == 42"
                             " and Sum.raised(Sum.forty) == 42 then 42 else 1")
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


def test_outside_its_house_an_internal_instance_is_opaque(tmp_path):
    # the same funs in another place of the same Space: no literal is a Sum,
    # and a Sum is no i64
    rc, out, _ = _in_space(tmp_path, {"Sum": _HIDDEN, "Meet": _MEET}, "  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "type mismatch: expected Sum, got Int64 (Sum " + _OUTSIDE in out, out
    assert "type mismatch: expected Int64, got Sum (Sum " + _OUTSIDE in out, out
    assert "type mismatch: expected Sum, got Number (Sum " + _OUTSIDE in out, out


def test_outside_its_house_no_model_takes_the_operations_of_an_internal_instance(tmp_path):
    # a model is a house of its own, even in the Space of the instance
    rc, out, _ = _in_space(tmp_path, {"Sum": _HIDDEN, "Word": _WORD}, "  return 42")
    assert rc != 0 and "E2001" in out, out
    assert "place Word uses algebra Sum but does not give its operation op" in out, out
    assert "(Sum is internal: outside its house its carrier is opaque, and no model takes the operations from it)" in out, out


_PASS = (program("test_alg_hierarchy/module_15.yon"))
_ADDS = (program("test_alg_hierarchy/module_16.yon"))
_HEAD = ("  doubled := Pass.twice_each(List.cons(Sum.make(21), List.empty))\n"
         "  head_value := match doubled { Nil => Sum.value(Sum.unit), Cons as (h, t) => Sum.value(h) }\n"
         "  return if Adds.go(40) == 42 and Adds.by_op(42) == 42 and head_value == 42 then 42 else 1")


def test_outside_its_house_the_values_of_an_internal_instance_come_from_its_funs_and_operations(tmp_path):
    # Pass and Adds, out of the house of Sum, reach its values only through
    # the funs of its house and its operations: +, Sum.op, Sum.unit; in the
    # Space of Sum and in another Space alike
    rc, out, exe = _in_space(tmp_path, {"Sum": _HIDDEN, "Pass": _PASS, "Adds": _ADDS}, _HEAD)
    assert rc == 0, out
    assert subprocess.run([str(exe)], timeout=30).returncode == 42
    proj = tmp_path / "two" / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "v").mkdir(parents=True)
    (proj / "yon.toml").write_text(
        '[package]\nname = "user_alg"\n\n'
        '[world.W]\nobjects = ["Sum", "Pass", "Adds"]\nspaces  = ["w", "v"]\n\n'
        '[runtime]\nbackend = "memory"\n')
    (proj / "w" / "Sum.yon").write_text(_HIDDEN)
    (proj / "v" / "Pass.yon").write_text(_PASS)
    (proj / "v" / "Adds.yon").write_text(_ADDS)
    for d in ("w", "v"):
        (proj / d / "Topos.yon").write_text(program("test_alg_hierarchy/test_outside_its_house_the_values_of_an_internal_instance_come_from_its_funs_and_operations_1.yon"))
    (proj / "Entry.yon").write_text(program("test_alg_hierarchy/test_outside_its_house_the_values_of_an_internal_instance_come_from_its_funs_and_operations_2.yon"))
    exe = tmp_path / "two" / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run([str(exe)], timeout=30).returncode == 42


def test_a_nesting_of_operations_of_an_algebra_is_checked_once_per_level(tmp_path):
    # each call is checked once: twenty levels of Additive.op take the time of
    # twenty calls, not of 2^20
    import time
    e = "one"
    for _ in range(20):
        e = f"Additive.op({e}, one)"
    top = "fun one: Int64 { return 1 }\nfun go: Int64 { return " + e + " }\n"
    start = time.monotonic()
    rc, out, exe = _build(tmp_path, "  return if go == 21 then 42 else 1", top=top)
    took = time.monotonic() - start
    assert rc == 0, out
    assert subprocess.run([str(exe)], capture_output=True, timeout=30).returncode == 42
    assert took < 10, f"twenty nested operations took {took:.1f} s to compile"


# ─── a place `this <` an algebra is an algebra ─────────────────────────────

_SUM64 = ("place Sum carried by i64 {\n"
          "  this < Monoid\n"
          '  operation op(a: Sum, b: Sum): Sum as "+"\n'
          '  operation unit: Sum as "0"\n'
          "LAW}\n")


def test_a_place_below_an_algebra_is_an_algebra(tmp_path):
    # no `is algebra`: by `this < Monoid` Sum is an instance on i64, a model of
    # itself, with the funs of its house and the laws of Monoid certified on
    # the carrier
    make = program("test_alg_hierarchy/test_a_place_below_an_algebra_is_an_algebra_1.yon")
    body = "  return if Sum.op(Sum.make(40), Sum.make(2)) + Sum.unit == Sum.make(42) then 42 else 1"
    assert _exit_of(tmp_path, body, {"Sum": "internal " + _SUM64.replace("LAW", make)}) == 42
    (tmp_path / "f").mkdir()
    false = "  law absorbs ∀a : Sum, a + unit = unit\n"
    rc, out, _ = _build(tmp_path / "f", "  return 42", {"Sum": _SUM64.replace("LAW", false)})
    assert rc != 0 and "E2101" in out, out
    assert "law absorbs of algebra Sum on the carrier i64 is refuted" in out, out


def test_a_place_below_an_algebra_takes_is_given_on_its_carrier(tmp_path):
    # i32 is no carrier the solver models: the laws are axioms with `is given`,
    # not certified without it
    plus32 = _SUM64.replace("Sum", "Plus32").replace("i64", "i32").replace("LAW", "")
    given = plus32.replace("carried by i32 {", "carried by i32 is given {")
    rc, out, _ = _build(tmp_path, "  return 42", {"Plus32": given})
    assert rc == 0, out
    (tmp_path / "n").mkdir()
    rc, out, _ = _build(tmp_path / "n", "  return 42", {"Plus32": plus32})
    assert rc != 0 and "E2102" in out, out


def test_is_algebra_where_it_follows_from_this_is_refused(tmp_path):
    cases = {
        "Odd": (program("test_alg_hierarchy/test_is_algebra_where_it_follows_from_this_is_refused_1.yon"),
                "place Odd is already an algebra by `this < Monoid`: `is algebra` is written only at a root,"
                " a signature below no algebra; write `place Odd { this < Monoid ... }`"),
        "Sum": (_SUM64.replace("LAW", "").replace("carried by i64 {", "carried by i64 is algebra {"),
                "place Sum is already an algebra by `this < Monoid`: `is algebra` is written only at a root,"
                " a signature below no algebra; write `place Sum carried by i64 { this < Monoid ... }`"),
        "Plus32": (_SUM64.replace("Sum", "Plus32").replace("LAW", "")
                   .replace("carried by i64 {", "carried by i32 is given is algebra {"),
                   "place Plus32 is already an algebra by `this < Monoid`: `is algebra` is written only at a root,"
                   " a signature below no algebra; write `place Plus32 carried by i32 is given { this < Monoid ... }`"),
    }
    for name, (src, words) in cases.items():
        (tmp_path / name).mkdir()
        rc, out, _ = _build(tmp_path / name, "  return 42", {name: src})
        assert rc != 0 and "E2001" in out, out
        assert words in out, out
