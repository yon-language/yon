"""The tests that wait for a migration Antonio decided: each one is an xfail strict with its reason,
written once here, and becomes green with the commit of the migration. An xfail passes on any
failure, and the acceptance baseline records only that an example does not emit: the code and the
words of the refusal are here too, and regression/test_succ_pred_on_int64.py checks that each
source still fails for them."""
import pytest

# succ <=> pred on Int64: false where succ(max) leaves Int64 (Overflow); true on Z, where the six
# tests move (lot N, the place Z). The acceptance run holds the same three examples as EMITFAIL in
# regression/baseline_exitcodes.txt (cx_carry, cx_univalence_named, cx_univalence_succ). The refusal:
# Int64 is no ring, so the coherence pred(succ(a)) = a that `<=>` synthesizes does not convert.
SUCC_PRED_CODE = "E2001"
SUCC_PRED_WORDS = "type mismatch: expected Id_Int64(_code, a), got Id_Int64(a, a)"
SUCC_PRED_SOURCES = ["examples/cx_carry", "examples/cx_univalence_named", "examples/cx_univalence_succ",
                     "regression/canonical_forms/hott/equivalence.yon",
                     "regression/yon_tests/prove/transport_ua_succ.yon",
                     "regression/programs/test_audit_probes/"
                     "test_transport_along_an_inline_univalence_path_applies_the_equivalence_1.yon"]
# the place Iso of test_dependent_fields, with succ and pred on Int64: its left_law pred(succ(x)) = x
SUCC_PRED_FIELD_SOURCE = "regression/programs/test_dependent_fields/module_3.yon"
SUCC_PRED_FIELD_WORDS = "type mismatch: expected Id_Int64(pred(succ(x)), x), got Id_Int64(pred(succ(x)), pred(succ(x)))"
SUCC_PRED_BLOCK = "09-hott-types:43ac"   # a block of the book, read by test_syntax_triangle
SUCC_PRED_ON_INT64 = pytest.mark.xfail(
    strict=True,
    reason="the equivalence succ/pred is false on Int64 (succ(max) overflows), true on Z: "
           "it migrates to Z in lot N")

# A ring law on Int64 that holds in Z on the domain of Int64 (x * (x + 1) = x * x + x): the normalizer
# of the type indices no longer decides Int64 as Z/2^64, and it will decide it in Z (lot N).
RING_LAW_ON_INT64_CODE = "E2001"
RING_LAW_ON_INT64_WORDS = "type mismatch: expected Id_Int64"
RING_LAW_ON_INT64 = pytest.mark.xfail(
    strict=True,
    reason="a ring law on Int64 holds in Z on the domain of Int64; the normalizer of the type "
           "indices decides it in Z in lot N")
