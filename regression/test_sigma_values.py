"""A value of a Sigma type goes through generics, lists and nesting.

A pair is a value like any other: a generic reads its type parameters from inside the Sigma of a
parameter, a list holds pairs, a pair holds a pair. A type parameter that no argument determines is
refused with its code and its reason.

Layer/kind: frontend + native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _compile(tmp_path, src):
    f = tmp_path / "p.yon"
    f.write_text(src)
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(f), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r, exe


def _entry(body, main):
    return "place Entry {\n" + body + "  fun main: Number { " + main + " }\n}\n"


def _runs(tmp_path, body, main):
    r, exe = _compile(tmp_path, _entry(body, main))
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).returncode


def _refused(tmp_path, body, main, *words):
    r, _ = _compile(tmp_path, _entry(body, main))
    out = r.stdout + r.stderr
    assert r.returncode != 0, out
    assert "Fatal error" not in out, out
    assert "exception" not in out.lower(), out
    for w in words:
        assert w in out, out
    return out


FIRST = "  fun first<K, V>(p: Σx : K, V): K { return fst(p) }\n"
SECOND = "  fun second<K, V>(p: Σx : K, V): V { return snd(p) }\n"
KEYS = "  fun keys<K, V>(xs: List<Σx : K, V>): Number { return List.length(xs) }\n"
MID = "  fun mid(p: Σx : Number, Σy : Number, Number): Number { return fst(snd(p)) }\n"


def test_a_generic_reads_its_parameters_from_a_sigma(tmp_path):
    assert _runs(tmp_path, FIRST, "return first(pair(42, 7))") == 42


def test_a_generic_returns_the_second_component(tmp_path):
    assert _runs(tmp_path, SECOND, "return second(pair(42, 7))") == 7


def test_a_list_holds_pairs(tmp_path):
    assert _runs(tmp_path, KEYS, "return keys(List.cons(pair(1, 2), List.empty))") == 1


def test_a_pair_holds_a_pair(tmp_path):
    assert _runs(tmp_path, MID, "return mid(pair(1, pair(42, 3)))") == 42


# what enters a list comes out: the pair in the slot is read back, component by component

def test_the_pair_read_back_from_a_list(tmp_path):
    assert _runs(tmp_path, "",
                 "mut t := 0\n"
                 "  for every p in List.cons(pair(40, 2), List.empty) { t <- t + fst(p) + snd(p) }\n"
                 "  return t") == 42


def test_a_nested_pair_read_back_from_a_list(tmp_path):
    assert _runs(tmp_path, "",
                 "mut t := 0\n"
                 "  for every p in List.cons(pair(1, pair(42, 3)), List.empty) { t <- fst(snd(p)) }\n"
                 "  return t") == 42


def test_a_pair_from_a_list_passes_to_a_function(tmp_path):
    assert _runs(tmp_path, MID,
                 "mut t := 0\n"
                 "  for every p in List.cons(pair(1, pair(42, 3)), List.empty) { t <- mid(p) }\n"
                 "  return t") == 42


def test_a_pair_from_a_list_passes_to_a_generic(tmp_path):
    assert _runs(tmp_path, FIRST,
                 "mut t := 0\n"
                 "  for every p in List.cons(pair(42, 7), List.empty) { t <- first(p) }\n"
                 "  return t") == 42


def test_the_list_keeps_its_order_and_its_pairs(tmp_path):
    assert _runs(tmp_path, "",
                 "mut t := 0\n"
                 "  xs := List.cons(pair(1, 2), List.cons(pair(10, 20), List.empty))\n"
                 "  for every p in xs { t <- t * 100 + fst(p) }\n"
                 "  return t - 68") == 42


def test_a_pair_lives_in_a_cell(tmp_path):
    assert _runs(tmp_path, "",
                 "mut c := pair(1, 2)\n"
                 "  c <- pair(40, 2)\n"
                 "  return fst(c) + snd(c)") == 42


def test_a_pair_is_captured_by_a_closure(tmp_path):
    assert _runs(tmp_path,
                 "  fun apply(f: Number -> Number, x: Number): Number { return f(x) }\n",
                 "p := pair(40, 2)\n"
                 "  return apply(fun(y: Number) => fst(p) + y, snd(p))") == 42


def test_a_generic_keeps_the_boolean_of_a_pair(tmp_path):
    assert _runs(tmp_path,
                 FIRST + "  fun pick(b: Boolean): Number { return if b then 42 else 0 }\n",
                 "return pick(first(pair(true, 7)))") == 42


def test_a_boolean_in_a_pair_comes_back_from_a_list(tmp_path):
    assert _runs(tmp_path,
                 "  fun pick(b: Boolean): Number { return if b then 42 else 0 }\n",
                 "mut t := 0\n"
                 "  for every p in List.cons(pair(true, 7), List.empty) { t <- pick(fst(p)) }\n"
                 "  return t") == 42


def test_an_int64_in_a_pair_keeps_its_bits_through_a_list(tmp_path):
    # 2^53 + 1 has no f64: the 64 bits come back only if nothing converted them
    assert _runs(tmp_path,
                 "  fun big(n: Int64): Int64 { return n * 9007199254740992 + 1 }\n"
                 "  fun odd(n: Int64): Number { return if n % 2 == 1 then 42 else 0 }\n",
                 "mut t := 0\n"
                 "  for every p in List.cons(pair(big(1), 7), List.empty) { t <- odd(fst(p)) }\n"
                 "  return t") == 42


def test_a_generic_gives_back_a_pair_from_a_pair(tmp_path):
    assert _runs(tmp_path, FIRST,
                 "return snd(first(pair(pair(1, 42), 7)))") == 42


def test_a_function_returns_what_a_generic_gave_back_from_a_nested_pair(tmp_path):
    assert _runs(tmp_path,
                 FIRST + "  fun inner: Boolean { return fst(first(pair(pair(true, 1), 7))) }\n",
                 "return if inner then 42 else 0") == 42


def test_a_function_returns_the_pair_a_generic_gave_back(tmp_path):
    assert _runs(tmp_path,
                 "  fun same<T>(x: T): T { return x }\n"
                 "  fun made: Σx : Number, Number { return same(pair(42, 7)) }\n",
                 "return fst(made)") == 42


def test_a_generic_gives_back_an_int64_from_a_pair(tmp_path):
    assert _runs(tmp_path,
                 FIRST + "  fun big(n: Int64): Int64 { return n * 9007199254740992 + 1 }\n"
                 "  fun odd(n: Int64): Number { return if n % 2 == 1 then 42 else 0 }\n",
                 "return odd(first(pair(big(1), 7)))") == 42


def test_the_head_of_a_list_of_pairs(tmp_path):
    assert _runs(tmp_path, "",
                 "return match List.head(List.cons(pair(42, 7), List.empty)) {\n"
                 "    Absent => 0,\n    Found as p => fst(p)\n  }") == 42


def test_a_fold_reads_the_pairs(tmp_path):
    assert _runs(tmp_path, "",
                 "xs := List.cons(pair(40, 1), List.cons(pair(1, 0), List.empty))\n"
                 "  return List.fold_left(xs, 1, fun(acc: Number, p: Σx : Number, Number) => acc + fst(p))") == 42


def test_two_equal_pairs_in_a_slot_are_one_value(tmp_path):
    # identity by content, as every value of the FNV heap: the lists of equal pairs are one list
    assert _runs(tmp_path, "",
                 "a := List.cons(pair(1, 2), List.empty)\n"
                 "  b := List.cons(pair(1, 2), List.empty)\n"
                 "  c := List.cons(pair(1, 3), List.empty)\n"
                 "  return (if a == b then 40 else 0) + (if a == c then 0 else 2)") == 42


def test_two_arguments_of_one_type_parameter_are_both_pairs(tmp_path):
    # the first comes from a slot and fixes the slot, the second enters it as a pair, whole
    assert _runs(tmp_path,
                 "  fun second_of<T>(a: T, b: T): T { return b }\n",
                 "mut t := 0\n"
                 "  for every p in List.cons(pair(1, 2), List.empty) {\n"
                 "    t <- snd(second_of(p, pair(7, 42)))\n  }\n"
                 "  return t") == 42


def test_a_sigma_over_a_conjunction_of_paths_runs(tmp_path):
    assert _runs(tmp_path,
                 "  fun value(a: Number, s: { x : Number where (x = a) ∧ (x = a) }): Number { return fst(s) }\n",
                 "return value(42, pair(42, pair(refl(42), refl(42))))") == 42


SUB = "{ a : Number where Πx : Number, Πy : Number, x = y }"
PROOF = "Πx : Number, Πy : Number, x = y"
SUB_BODY = (f"  fun plus(n: Number): Number {{ return n + 0 }}\n"
            f"  fun forget(s: {SUB}): Number {{ return plus(s) }}\n"
            f"  fun read(s: {SUB}): Number {{ return fst(s) }}\n"
            f"  fun made(p: {PROOF}): {SUB} {{ return pair(42, p) }}\n"
            f"  fun from_pair(p: {PROOF}): Number {{ return plus(made(p)) }}\n"
            f"  fun read_pair(p: {PROOF}): Number {{ return read(made(p)) }}\n")


def _function_text(mlir, name):
    start = mlir.index(f"func.func @{name}(")
    end = mlir.find("func.func @", start + 1)
    return mlir[start:end if end > 0 else len(mlir)]


def test_a_comprehension_is_its_carrier_without_a_slot(tmp_path):
    # the proof has no bits: no handle of a pair in place of the number. No proof of this false
    # statement exists to run, so the code itself says it
    f = tmp_path / "p.yon"
    f.write_text(_entry(SUB_BODY, "return 42"))
    out = tmp_path / "p.mlir"
    r = subprocess.run([str(YONC), "--emit=mlir", str(f), "-o", str(out)],
                       capture_output=True, text=True, timeout=300, cwd=tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    mlir = out.read_text()
    for name in ("read", "from_pair", "read_pair", "forget"):
        body = _function_text(mlir, name)
        assert "__arm_new_2" not in body and "yon_rt_arm_field" not in body, body
    assert "llvm.extractvalue" in _function_text(mlir, "from_pair")


def test_the_proof_of_a_comprehension_has_no_value(tmp_path):
    _refused(tmp_path,
             f"  fun proof(s: {SUB}): {PROOF} {{ return snd(s) }}\n",
             "return 42",
             "E2001", "proof of a comprehension")


# the boundary between Spaces: a handle does not cross, the wire has no frame for a Sigma yet

def _across_spaces(tmp_path, ty, read, value):
    proj = tmp_path / "proj"
    (proj / "w").mkdir(parents=True)
    (proj / "yon.toml").write_text('[package]\nname = "p"\n\n[runtime]\nbackend = "memory"\n\n'
                                   '[world.W]\nobjects = ["Q"]\nspaces  = ["w"]\n')
    (proj / "w" / "Topos.yon").write_text("topos WTopos where {\n}\n")
    (proj / "w" / "Q.yon").write_text(
        f"place Q {{\n  side Number\n  fun digest(x: {ty}): Number {{ return {read} }}\n}}\n")
    (proj / "Entry.yon").write_text(
        f"place Entry {{\n  fun main: Number {{ return Q.digest({value}) }}\n}}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    return r, exe


@pytest.mark.parametrize("ty,read,value", [
    ("Σx : Number, Number", "fst(x)", "pair(42, 7)"),
    ("List<Σx : Number, Number>", "List.length(x)", "List.cons(pair(42, 7), List.empty)"),
])
def test_a_pair_at_the_boundary_is_refused_with_its_reason(tmp_path, ty, read, value):
    r, _ = _across_spaces(tmp_path, ty, read, value)
    out = r.stdout + r.stderr
    assert r.returncode != 0, out
    assert "E2001" in out and "Fatal error" not in out and "stage0.topos.mlir" not in out, out
    assert "argument 1 of" in out, out


# a type no argument determines

def test_a_parameter_nothing_fixes_is_refused(tmp_path):
    out = _refused(tmp_path,
                   "  fun ghost<K, V>(p: Σx : K, Number): List<V> { return List.empty }\n",
                   "x := ghost(pair(1, 2))\n  return 0",
                   "E2001", "ambiguous call of ghost", "type parameter V")
    assert "unknown" not in out, out


def test_a_component_nothing_fixes_is_refused(tmp_path):
    _refused(tmp_path,
             "  fun half<K, V>(p: Σx : K, Number): Σy : V, Number { return half(p) }\n",
             "x := half(pair(1, 2))\n  return 0",
             "E2001", "ambiguous call of half", "V")


# a name of the prelude inside a Sigma is a type, not a parameter of the function

def test_a_sigma_over_a_prelude_place_is_no_generic(tmp_path):
    assert _runs(tmp_path,
                 "  fun size(p: Σx : List<Number>, Number): Number { return List.length(fst(p)) + snd(p) }\n",
                 "return size(pair(List.cons(1, List.empty), 41))") == 42


def test_the_name_of_a_binder_does_not_tell_two_products_apart(tmp_path):
    # a product of a place of the prelude and a number, built with no binder at all
    assert _runs(tmp_path,
                 "  fun size(p: Σx : List<Number>, Number): Number { return snd(p) }\n",
                 "return size(pair(List.cons(1, List.empty), 42))") == 42
    _refused(tmp_path,
             "  fun size(p: Σx : List<Number>, Number): Number { return snd(p) }\n",
             "return size(pair(1, 42))",
             "E2001", "size", "parameter p")


def test_a_sigma_over_a_lookup_is_no_generic(tmp_path):
    assert _runs(tmp_path,
                 "  fun grab(p: Σx : Lookup<Number>, Number): Number {\n"
                 "    return match fst(p) { Absent => snd(p), Found as v => v }\n  }\n",
                 "return grab(pair(List.head(List.cons(42, List.empty)), 7))") == 42


def test_a_sigma_over_text_is_no_generic(tmp_path):
    assert _runs(tmp_path,
                 "  fun grab(p: Σx : Text, Number): Number { return snd(p) }\n",
                 'return grab(pair("a", 42))') == 42


def test_text_in_a_pair_goes_through_a_list(tmp_path):
    assert _runs(tmp_path, "",
                 "mut t := 0\n"
                 '  for every p in List.cons(pair("a", 42), List.empty) { t <- snd(p) }\n'
                 "  return t") == 42


def test_a_generic_identity_returns_the_pair(tmp_path):
    assert _runs(tmp_path, "  fun same<T>(x: T): T { return x }\n",
                 "return fst(same(pair(42, 7)))") == 42
