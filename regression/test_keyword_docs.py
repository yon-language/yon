"""Keyword index gate.

The alphabetical index in syntax-reference.md must be in sync with the keyword
reference (22-keywords.md). This catches the drift the manual audit found: an index
that had gone out of order. Hand-editing the index fails here.

  - test_keyword_index_in_sync: website/scripts/gen-keyword-index.py --check passes.

That every lexer keyword HAS a `#### `kw`` section is leg 1 of the syntax triangle,
test_syntax_triangle::test_leg1_every_keyword_documented (it was also checked here,
with the same two regexes and the same subset oracle; one copy is enough).
"""
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
GEN = ROOT / "website" / "scripts" / "gen-keyword-index.py"


@pytest.mark.skipif(not GEN.exists(), reason="keyword-index generator missing")
def test_keyword_index_in_sync():
    r = subprocess.run([sys.executable, str(GEN), "--check"],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, (
        f"{r.stdout}{r.stderr}".strip()
        or "keyword index out of sync; run website/scripts/gen-keyword-index.py"
    )
