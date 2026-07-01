"""Keyword documentation gate.

Every surface keyword in the lexer must be documented, and the alphabetical index in
syntax-reference.md must be in sync with the keyword reference. This catches the drift the
manual audit found: live keywords (spawn, the cubical constructs, ...) that had no entry, and
an index that had gone out of order. Adding a keyword to the lexer without a `#### `kw``
section in 21-keywords.md, or hand-editing the index, fails here.

  - test_every_lexer_keyword_documented: lexer keyword table ⊆ `#### `kw`` entries.
  - test_keyword_index_in_sync: website/scripts/gen-keyword-index.py --check passes.
"""
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LEXER = ROOT / "frontend" / "lexer.mll"
KEYWORDS_MD = ROOT / "website" / "docs" / "book" / "21-keywords.md"
GEN = ROOT / "website" / "scripts" / "gen-keyword-index.py"


def lexer_keywords() -> set[str]:
    """The surface words in the lexer keyword table (`"kw", TOKEN`)."""
    text = LEXER.read_text()
    return set(re.findall(r'"([a-z_]+)",\s*[A-Z_]+', text))


def documented_keywords() -> set[str]:
    text = KEYWORDS_MD.read_text()
    return set(re.findall(r"^#### `([A-Za-z_][A-Za-z0-9_]*)`", text, re.MULTILINE))


@pytest.mark.skipif(not LEXER.exists() or not KEYWORDS_MD.exists(),
                    reason="lexer or keyword reference missing")
def test_every_lexer_keyword_documented():
    missing = sorted(lexer_keywords() - documented_keywords())
    assert not missing, (
        "lexer keywords with no `#### `kw`` section in website/docs/book/21-keywords.md: "
        f"{missing}. Document each (a sentence + a compiling example), then run "
        "website/scripts/gen-keyword-index.py."
    )


@pytest.mark.skipif(not GEN.exists(), reason="keyword-index generator missing")
def test_keyword_index_in_sync():
    r = subprocess.run([sys.executable, str(GEN), "--check"],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, (
        f"{r.stdout}{r.stderr}".strip()
        or "keyword index out of sync; run website/scripts/gen-keyword-index.py"
    )
