"""Int64 is not a ring: an operation of Int64 is an arrow into Int64 + Overflow.

The sum and the product of Int64 refuse a result outside [-2^63, 2^63) (`on error Overflow`), so
(x + 1) - 1 is not x where x + 1 overflows: the ring normalizer of the type indices, which decides
equalities of Z/2^64 (Word64, whose operations wrap), does not decide them on Int64. Between Int64
values only definitional equality holds, and nothing reassociates. A law of the prelude that a
counterexample refutes leaves the prelude: Int64.Negate is neither involutive (negate(negate(min))
overflows) nor additive (negate(max + 1) overflows).
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "ring"\n\n[runtime]\nbackend = "memory"\n'
_OVF = "error: arithmetic: an Int64 operation leaves [-2^63, 2^63)"


def _project(tmp_path, entry):
    (tmp_path / "yon.toml").write_text(_TOML)
    (tmp_path / "Entry.yon").write_text(entry)
    return tmp_path


def _emit(tmp_path, entry):
    r = subprocess.run([str(EMIT), str(_project(tmp_path, entry))], capture_output=True,
                       text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def _run(tmp_path, entry):
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(_project(tmp_path, entry)), "-o", str(exe)],
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)


def test_an_identity_of_the_ring_that_overflows_is_refused_on_int64(tmp_path):
    """(x + 1) - 1 = x holds in Z/2^64 and fails in Int64 at x = max_value: refused."""
    rc, out = _emit(tmp_path, "place Entry {\n  fun p(x: Int64): (x + 1) - 1 = x { return clear }\n"
                              "  fun main: Number { return 7 }\n}\n")
    assert rc != 0 and "[E2001]" in out and "type mismatch: expected Id_Int64" in out, out[-600:]


def test_a_definitional_equality_on_int64_is_accepted(tmp_path):
    rc, out = _emit(tmp_path, "place Entry {\n  fun p(x: Int64): x + 1 = x + 1 { return clear }\n"
                              "  fun main: Number { return 7 }\n}\n")
    assert rc == 0, out[-600:]


def test_the_identity_is_false_at_the_maximum(tmp_path):
    """The counterexample, run: (max + 1) - 1 is no Int64, the Overflow refusal."""
    r = _run(tmp_path, "place Entry {\n  fun main: Number {\n    m := Int64.max_value\n"
                       "    return if (m + 1) - 1 == m then 1 else 2\n  }\n}\n")
    assert r.returncode == 3 and _OVF in r.stderr, (r.returncode, r.stderr)


@pytest.mark.parametrize("law, body", [
    ("involutive", "    m := Int64.min_value\n    return if neg(neg(m)) == m then 1 else 2\n"),
    ("additive", "    a := Int64.max_value\n    return if neg(a + 1) == neg(a) + neg(1) then 1 else 2\n"),
])
def test_a_law_of_negate_is_refuted_on_int64(tmp_path, law, body):
    """negate(n) = 0 - n: at the minimum, and past the maximum, the law gives the Overflow."""
    r = _run(tmp_path, "place Entry {\n  fun neg(n: Int64): Int64 { return 0 - n }\n"
                       "  fun main: Number {\n" + body + "  }\n}\n")
    assert r.returncode == 3 and _OVF in r.stderr, (law, r.returncode, r.stderr)


def test_the_prelude_states_no_refuted_law_of_negate():
    src = (ROOT / "prelude" / "num64" / "Int64.yon").read_text()
    block = src[src.index("morph Negate from Int64 to Int64"):]
    block = block[:block.index("}\n") + 2]
    assert "law involutive" not in block and "law additive" not in block, block


def test_the_reciprocal_of_number_is_not_involutive(tmp_path):
    """1 / (1 / 49) is not 49 in IEEE doubles: the prelude declares no law of Reciprocal."""
    r = _run(tmp_path, "place Entry {\n  fun rec(n: Number): Number { return 1 / n }\n"
                       "  fun main: Number {\n    return if rec(rec(49)) == 49 then 1 else 2\n  }\n}\n")
    assert r.returncode == 2, (r.returncode, r.stderr)
    src = (ROOT / "prelude" / "num64" / "Number.yon").read_text()
    block = src[src.index("morph Reciprocal from Number to Number"):]
    block = block[:block.index("}\n") + 2]
    assert "law" not in block, block


_SUM = ("place Sum carried by i64 is algebra {\n"
        '  operation add(a: Sum, b: Sum): Sum as "+"\n'
        '  operation zero: Sum as "0"\n'
        "  law associative ∀a : Sum ∀b : Sum ∀c : Sum, (a + b) + c = a + (b + c)\n"
        "  law commutative ∀a : Sum ∀b : Sum, a + b = b + a\n"
        "  law neutral ∀a : Sum, a + zero = a\n}\n")


def _emit_sum(tmp_path, statement):
    (tmp_path / "yon.toml").write_text('[package]\nname = "ring"\n\n[world.W]\nobjects = ["Sum"]\n\n'
                                       '[runtime]\nbackend = "memory"\n')
    (tmp_path / "Sum.yon").write_text(_SUM)
    (tmp_path / "Entry.yon").write_text("place Entry {\n  fun p(x: Sum, y: Sum): " + statement +
                                        " { return clear }\n  fun main: Number { return 7 }\n}\n")
    r = subprocess.run([str(EMIT), str(tmp_path)], capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout + r.stderr


def test_the_ring_of_the_indices_decides_on_a_place_that_wraps(tmp_path):
    """On a place carried by i64, whose sum wraps (Z/2^64), the ring normalizer decides x + y = y + x."""
    rc, out = _emit_sum(tmp_path, "x + y = y + x")
    assert rc == 0, out[-600:]


def test_the_ring_of_the_indices_refutes_a_false_law(tmp_path):
    """The false direction of the same normalizer: x + y = x is refused."""
    rc, out = _emit_sum(tmp_path, "x + y = x")
    assert rc != 0 and "[E2001]" in out and "type mismatch: expected Id_Sum" in out, out[-600:]
