"""An integer divided by zero is a declared refusal, not undefined behaviour.

`/` and `%` on an integer carrier lower to divsi/remsi, which LLVM leaves
undefined for a divisor of zero and for -2^63 / -1. A divisor of zero is the
refusal DivisionByZero (exit 3, its sentence on stderr); -2^63 / -1, whose
quotient leaves the range, is the refusal Int64Overflow; -2^63 % -1 is 0.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_ZERO = "error: arithmetic: an integer divided by zero, or its remainder by zero, is no integer"
_OVF = "error: arithmetic: an Int64 operation leaves [-2^63, 2^63)"


def _run(tmp_path: Path, body: str, extra: str = ""):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text('[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n')
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main: Number {\n" + body + "}\n"
        "fun int64(n: Int64): Int64 { return n }\n" + extra + "}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)], capture_output=True,
                       text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)


_OPS = {"quotient": "/", "remainder": "%"}


@pytest.mark.parametrize("what", sorted(_OPS))
def test_an_int64_by_zero_is_refused(tmp_path, what):
    op = _OPS[what]
    r = _run(tmp_path, f"  q := int64(7) {op} int64(0)\n  return if q == int64(1) then 1 else 2\n")
    assert r.returncode == 3, (r.returncode, r.stderr)
    assert _ZERO in r.stderr, r.stderr


@pytest.mark.parametrize("what", sorted(_OPS))
def test_an_int32_by_zero_is_refused(tmp_path, what):
    op = _OPS[what]
    extra = ("fun seven: Int32 { return 7 }\n"
             "fun nought: Int32 { return 0 }\n")
    r = _run(tmp_path, f"  q := seven {op} nought\n  return if q == seven then 1 else 2\n", extra)
    assert r.returncode == 3, (r.returncode, r.stderr)
    assert _ZERO in r.stderr, r.stderr


def test_the_quotient_outside_the_range_is_refused(tmp_path):
    r = _run(tmp_path, "  q := Int64.min_value / int64(-1)\n  return if q == int64(1) then 1 else 2\n")
    assert r.returncode == 3, (r.returncode, r.stderr)
    assert _OVF in r.stderr, r.stderr


def test_the_remainder_by_minus_one_is_zero(tmp_path):
    r = _run(tmp_path, "  return if Int64.min_value % int64(-1) == int64(0) then 42 else 1\n")
    assert r.returncode == 42, r.stderr


def test_a_divisor_that_is_not_zero_divides(tmp_path):
    r = _run(tmp_path, ("  return if int64(-7) / int64(2) == int64(-3) and int64(-7) % int64(2) == int64(-1)\n"
                        "            and int64(85) / int64(2) == int64(42) then 42 else 1\n"))
    assert r.returncode == 42, r.stderr
