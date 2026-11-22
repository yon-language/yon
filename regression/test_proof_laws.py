"""Two laws of the proofs, as ordinary tests.

1. Every normalizer that certifies a law also refutes a law known false. A normalizer that answers
   "proven" to everything passes every test that only states true laws; one false law, refused by its
   code and its words, is the other half. The normalizers and the test of their false law are listed
   in FALSE_LAWS; the ones whose false law is not written yet are in FALSE_LAWS_PENDING, with the
   reason (it only shrinks).
2. A test of the run time whose operands are constants may be answered by the compiler, folding them:
   the run time is then never asked. Its twin reads the same operands at run time (an Int64 counted up
   from `SystemOs.arg_count`, which is 1 when the program is run without arguments and which the
   compiler cannot know), and must give
   the same answer. RUNTIME_TWINS lists the tests that have their twin here.
"""
import ast
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

# normalizer -> (the test that a law false on it is refused (file::test), its code, its words)
FALSE_LAWS = {
    "the evaluation on a finite carrier (algebra_check)":
        ("regression/test_proof_laws.py::test_a_false_law_on_a_finite_carrier_is_refuted",
         "E2101", "refuted"),
    "z3 over 64-bit words (algebra_check)":
        ("regression/test_algebras.py::test_a_law_false_on_the_carrier_is_refuted", "E2101", "refuted"),
    "z3 over IEEE doubles (algebra_check)":
        ("regression/test_algebras.py::test_the_ieee_sum_is_not_associative", "E2101", "refuted"),
    "the three truth values of Omega (algebra_check, Heyting G3)":
        ("regression/test_heyting_algebra.py::test_the_excluded_middle_is_refuted_on_omega",
         "E2101", "refuted"),
    "the ring of the type indices (dispatcher.ml, is_ring_carrier)":
        ("regression/test_int64_is_no_ring.py::test_the_ring_of_the_indices_refutes_a_false_law",
         "E2001", "type mismatch"),
}
FALSE_LAWS_PENDING = {
    "the ring of the naturality squares (naturality_symcheck.ml, ring_equal)":
        "no surface program reaches it with a false square yet",
    "the coherences of CaTT (catt_r_yon.ml, normalize_coherence)": "group S0, the CaTT certificate",
}


def _src(ref):
    path, _, name = ref.partition("::")
    src = (ROOT / path).read_text()
    for n in ast.walk(ast.parse(src)):
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return ast.get_source_segment(src, n)
    return None


@pytest.mark.parametrize("normalizer", sorted(FALSE_LAWS))
def test_each_normalizer_refutes_a_false_law(normalizer):
    ref, code, words = FALSE_LAWS[normalizer]
    src = _src(ref)
    assert src is not None, f"{normalizer}: no test {ref}"
    assert code in src and words in src, (
        f"{normalizer}: the test does not check the refusal by its code {code} and its words")


def _build(tmp_path, places, main_body, objects=()):
    proj = tmp_path / "proj"
    proj.mkdir()
    objs = ", ".join(f'"{o}"' for o in objects)
    (proj / "yon.toml").write_text(
        '[package]\nname = "laws"\n\n' + (f"[world.W]\nobjects = [{objs}]\n\n" if objects else "")
        + '[runtime]\nbackend = "memory"\n')
    for name, src in places.items():
        (proj / f"{name}.yon").write_text(src)
    (proj / "Entry.yon").write_text("place Entry {\nfun main: Number {\n" + main_body + "\n}\n"
                                    "fun int64(n: Int64): Int64 { return n }\n"
                                    "fun late(n: Number): Int64 { return if n > 1 then int64(1) + late(n - 1) else int64(0) }\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True, text=True,
                       timeout=300)
    return r.returncode, r.stdout + r.stderr, exe


_COUNT = ("place Count uses algebra Monoid {\n  this > None :U Some\n"
          "  fun op(a: Count, b: Count): Count { return OP }\n"
          "  fun unit: Count { return None }\n}\n")


def test_a_true_law_on_a_finite_carrier_is_proven(tmp_path):
    src = _COUNT.replace("OP", "match a { None => b, Some => Some }")
    rc, out, _ = _build(tmp_path, {"Count": src}, "  return 42", objects=["Count"])
    assert rc == 0, out


def test_a_false_law_on_a_finite_carrier_is_refuted(tmp_path):
    """op(a, b) = a: unit · Some = None, not Some; the neutral law is false on two arms."""
    rc, out, _ = _build(tmp_path, {"Count": _COUNT.replace("OP", "a")}, "  return 42",
                        objects=["Count"])
    assert rc != 0 and "E2101" in out, out
    assert "of algebra Monoid on place Count is refuted" in out, out


# --- the twins of the run time ---------------------------------------------
_ZERO = "error: arithmetic: an integer divided by zero, or its remainder by zero, is no integer"
_OVF = "error: arithmetic: an Int64 operation leaves [-2^63, 2^63)"
_LATE = "late(SystemOs.arg_count)"

RUNTIME_TWINS = {
    # test_integer_division.py: the same quotients with the operands read at run time
    "regression/test_integer_division.py::test_an_int64_by_zero_is_refused": "test_the_late_divisor_zero_is_refused",
    "regression/test_integer_division.py::test_the_quotient_outside_the_range_is_refused":
        "test_the_late_quotient_outside_the_range_is_refused",
}


def _late(tmp_path, body):
    rc, out, exe = _build(tmp_path, {}, body)
    assert rc == 0, out
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)


@pytest.mark.parametrize("op", ["/", "%"])
def test_the_late_divisor_zero_is_refused(tmp_path, op):
    r = _late(tmp_path, f"  q := int64(7) {op} {_LATE}\n  return if q == int64(1) then 1 else 2")
    assert r.returncode == 3, (r.returncode, r.stderr)
    assert _ZERO in r.stderr, r.stderr


def test_the_late_quotient_outside_the_range_is_refused(tmp_path):
    r = _late(tmp_path, f"  q := Int64.min_value / (int64(-1) + {_LATE})\n"
                        "  return if q == int64(1) then 1 else 2")
    assert r.returncode == 3, (r.returncode, r.stderr)
    assert _OVF in r.stderr, r.stderr


def test_the_late_quotient_is_the_quotient(tmp_path):
    r = _late(tmp_path, f"  q := int64(85) / (int64(2) + {_LATE})\n"
                        "  return if q == int64(42) then 42 else 1")
    assert r.returncode == 42, (r.returncode, r.stderr)


def test_each_runtime_twin_exists():
    here = (ROOT / "regression" / "test_proof_laws.py").read_text()
    for ref, twin in RUNTIME_TWINS.items():
        assert _src(ref) is not None, f"no test {ref}"
        assert f"def {twin}(" in here, f"no twin {twin} of {ref}"
