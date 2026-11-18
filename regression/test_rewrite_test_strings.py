"""The Yon programs that stay in the strings of the Python tests are rewritten in place
(tools/rewrite_test_strings.py): a literal that is a whole program goes through the rewriter and
back into its quotes; what the tool cannot rewrite is listed; a file in which no rule applies stays
byte for byte as it was."""
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "rewrite_test_strings.py"
RW = ROOT / "frontend" / "_build" / "default" / "yonrw.exe"

pytestmark = pytest.mark.skipif(not RW.exists(), reason="yonrw not built")

SAMPLE = '''import os

PROG = """place Entry {
  fun main: Number {
    a := 7  -  2   // kept
    return a
  }
}
"""

def test_x(n):
    src = f"place Entry {{ fun main: Number {{ return {n} }} }}"
    piece = "fun helper(x: Number): Number { return x"
    return PROG, src, piece
'''


def _run(rule, f, *flags):
    return subprocess.run([sys.executable, str(TOOL), rule, *flags, str(f)],
                          capture_output=True, text=True, timeout=120)


def test_no_rule_that_applies_leaves_the_file_as_it_was(tmp_path):
    f = tmp_path / "test_sample.py"
    f.write_text(SAMPLE)
    r = _run("reprint-binop", f, "--write")
    assert r.returncode == 0, r.stderr
    assert f.read_text() == SAMPLE


def test_a_whole_program_is_rewritten_in_its_quotes_and_the_rest_is_listed(tmp_path):
    f = tmp_path / "test_sample.py"
    f.write_text(SAMPLE)
    r = _run("space-binop", f, "--write")
    assert r.returncode == 0, r.stderr
    assert f.read_text() == SAMPLE.replace("7  -  2", "7 - 2"), f.read_text()
    assert "a piece of an f-string" in r.stdout, r.stdout
    assert "a fragment, not a whole program" in r.stdout, r.stdout
