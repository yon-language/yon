"""Word64, the ring Z/2^64 on 64 bits, and its bits.

A sum and a product of words wrap; and, or, xor, not and the two shifts are
the second structure on the same bits. From an integer to a word is total
(the residue modulo 2^64); from a word to an integer is partial in both
readings, signed and unsigned (on error DomainError when the value does not
fit). The words a heap reads and writes are Word64.

Layer/kind: native / end-to-end.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")

_TOML = '[package]\nname = "probe"\n\n[runtime]\nbackend = "memory"\n'


def _value(tmp_path: Path, main_body: str) -> int:
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main: Number {\n" + main_body + "}\n}\n")
    exe = tmp_path / "exe"
    r = subprocess.run([str(YONC), str(proj), "-o", str(exe)],
                       capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stdout + r.stderr
    return subprocess.run([str(exe)], timeout=30).returncode


def _signed_is(word: str, int64: str) -> str:
    return (f"  return match Word64.to_signed({word}) {{\n"
            f"    Int64 as n => (if n == {int64} then 42 else 1),\n"
            "    DomainError as d => 2 }\n")


def test_the_sum_wraps_past_the_largest_integer(tmp_path):
    w = "Word64.add(Word64.from_int64(Int64.max_value), Word64.one)"
    assert _value(tmp_path, _signed_is(w, "Int64.min_value")) == 42


def test_the_product_wraps(tmp_path):
    w = "Word64.mul(Word64.from_int64(4294967296), Word64.from_int64(4294967296))"
    assert _value(tmp_path, _signed_is(w, "0")) == 42


def test_the_difference_wraps_below_zero(tmp_path):
    w = "Word64.sub(Word64.zero, Word64.one)"
    assert _value(tmp_path, _signed_is(w, "0 - 1")) == 42


def test_and_or_xor_not(tmp_path):
    body = ("  a := Word64.from_int64(12)\n  b := Word64.from_int64(10)\n"
            "  ok := Word64.bit_and(a, b) == Word64.from_int64(8)\n"
            "    and Word64.bit_or(a, b) == Word64.from_int64(14)\n"
            "    and Word64.bit_xor(a, b) == Word64.from_int64(6)\n"
            "    and Word64.bit_not(Word64.zero) == Word64.from_int64(0 - 1)\n"
            "  return if ok then 42 else 1\n")
    assert _value(tmp_path, body) == 42


def test_shift_left_drops_the_top_bits(tmp_path):
    body = ("  return match Word64.shift_left(Word64.from_int64(3), 62) {\n"
            "    Word64 as w => (if w == Word64.from_int64(Int64.min_value + Int64.two_to_62)"
            " then 42 else 1),\n"
            "    DomainError as d => 2 }\n")
    assert _value(tmp_path, body) == 42


def test_shift_right_is_logical(tmp_path):
    # all ones moved 60 places down leave 15: zeros enter at the top
    body = ("  return match Word64.shift_right(Word64.from_int64(0 - 1), 60) {\n"
            "    Word64 as w => (if w == Word64.from_int64(15) then 42 else 1),\n"
            "    DomainError as d => 2 }\n")
    assert _value(tmp_path, body) == 42


def test_a_shift_of_64_places_is_a_domain_error(tmp_path):
    body = ("  return match Word64.shift_left(Word64.one, 64) {\n"
            "    Word64 as w => 1,\n    DomainError as d => 42 }\n")
    assert _value(tmp_path, body) == 42


def test_a_word_of_2_63_or_more_has_no_unsigned_int64(tmp_path):
    body = ("  return match Word64.to_unsigned(Word64.bit_not(Word64.zero)) {\n"
            "    Int64 as n => 1,\n    DomainError as d => 42 }\n")
    assert _value(tmp_path, body) == 42


def test_a_word_below_2_63_reads_back_unsigned(tmp_path):
    body = ("  return match Word64.to_unsigned(Word64.from_int64(41)) {\n"
            "    Int64 as n => (if n + 1 == 42 then 42 else 1),\n"
            "    DomainError as d => 2 }\n")
    assert _value(tmp_path, body) == 42


def test_a_word_takes_no_integer_arithmetic(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "yon.toml").write_text(_TOML)
    (proj / "Entry.yon").write_text(
        "place Entry {\nfun main: Number {\n"
        "  return if Word64.one + 1 == Word64.zero then 1 else 2\n}\n}\n")
    r = subprocess.run([str(YONC), str(proj), "-o", str(tmp_path / "exe")],
                       capture_output=True, text=True, timeout=180)
    out = r.stdout + r.stderr
    assert r.returncode != 0 and "[E2001]" in out, out
    assert "operator requires matching numeric/duration/money operands; got Word64 and number" in out, out
