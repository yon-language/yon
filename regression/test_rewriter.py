"""The rewriter of the migrations changes only the nodes of one form and keeps every other byte
(frontend/rewriter.ml, `yonrw`).

Its oracle is the whole tree: the rewritten text must read as the program before with the rule
applied, and nothing else, or the file is left as it was. Here:

  1. on the whole corpus of the formatter, a rule that writes each binary operation again from its
     parts leaves every file byte for byte as it was;
  2. a rule that changes the text inside its nodes keeps the comments and the text around them;
  3. a rule that changes the program while saying it does not is refused, and the file is left as
     it was.
"""
import subprocess
from pathlib import Path

import pytest

from test_formatter import CORPUS

ROOT = Path(__file__).resolve().parent.parent
RW = ROOT / "frontend" / "_build" / "default" / "yonrw.exe"

pytestmark = pytest.mark.skipif(not RW.exists(), reason="yonrw not built (dune build in frontend/)")


def _rw(*args):
    return subprocess.run([str(RW), *map(str, args)], capture_output=True, text=True, timeout=60)


def test_the_rules_are_listed():
    r = _rw("--rules")
    assert r.returncode == 0 and "reprint-binop" in r.stdout, r.stdout + r.stderr


def test_writing_each_node_again_keeps_every_byte_of_the_corpus():
    changed, refused = [], []
    for f in CORPUS:
        r = _rw("reprint-binop", f)
        if r.returncode != 0:
            refused.append(f"{f.relative_to(ROOT)}: {r.stderr.strip()}")
        elif r.stdout != f.read_text():
            changed.append(str(f.relative_to(ROOT)))
    assert not refused, "\n".join(refused[:10])
    assert not changed, changed[:10]


SRC = 'place Entry {\n  // a comment before\n  fun main: Number {\n    a := 7  -  2   /* a comment after the operation */\n    b := a*3\n    return b      // the end\n  }\n}\n'


def test_a_rewrite_keeps_the_comments_and_the_text_around_its_nodes(tmp_path):
    f = tmp_path / "e.yon"
    f.write_text(SRC)
    r = _rw("space-binop", "--write", f)
    assert r.returncode == 0, r.stdout + r.stderr
    out = f.read_text()
    assert out == SRC.replace("7  -  2", "7 - 2").replace("a*3", "a * 3"), out


def test_a_rewrite_that_is_another_program_is_refused(tmp_path):
    f = tmp_path / "e.yon"
    f.write_text(SRC)
    r = _rw("test-swap-operands", "--write", f)
    assert r.returncode == 2 and "another program" in r.stderr, r.stdout + r.stderr
    assert f.read_text() == SRC
