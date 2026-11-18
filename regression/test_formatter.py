"""The formatter is safe and idempotent, and the LSP exposes it.

Two guarantees:
- Idempotence gate over the corpus: every file the formatter accepts formats to a
  fixed point (formatting its own output reproduces it). A formatter wired into
  "format on save" must be stable; an unstable one would fight the user's editor.
  Files with an uncovered construct are left unchanged (fail-safe) and skipped.
- The language server advertises documentFormattingProvider and returns a
  whole-document TextEdit for a formattable buffer -- the same Formatter the CLI
  runs, so `yonfmt` and the editor cannot disagree.
"""
import json
import subprocess
from pathlib import Path

import re

import pytest

ROOT = Path(__file__).resolve().parent.parent
FMT = ROOT / "frontend" / "_build" / "default" / "yonfmt.exe"
LSP = ROOT / "frontend" / "_build" / "default" / "yon_lsp.exe"

CANONICAL = ROOT / "regression" / "canonical_forms"

# Two accepted fixtures use a form the formatter does not write, and that leaves the language: the
# operation at top level and the binding at top level. They leave the corpus with their forms.
UNCOVERED = {
    CANONICAL / "algebra" / "standalone_op.yon": "an operation at top level (a form that leaves)",
    CANONICAL / "binding" / "canonical.yon": "a binding at top level (a form that leaves)",
}


def _refused_by_the_parser(f: Path) -> bool:
    """A file of a refusal proof the parser refuses on purpose (its .expect: reject_clean, E1xxx):
    a text that does not parse cannot be formatted."""
    if CANONICAL not in f.parents:
        return False
    construct, name = f.relative_to(CANONICAL).parts[:2]
    exp = CANONICAL / construct / (Path(name).stem + ".expect")
    if not exp.exists():
        return False
    t = exp.read_text()
    return "status: reject_clean" in t and re.search(r"^code: E1\d{3}", t, re.M) is not None


CORPUS = sorted(
    f for f in (list((ROOT / "examples").rglob("*.yon"))
                + list((ROOT / "regression" / "yon_tests").rglob("*.yon"))
                + list((ROOT / "prelude").rglob("*.yon"))
                + list((ROOT / "selfhost").rglob("*.yon"))
                + list((ROOT / "meta").rglob("*.yon"))
                + list(CANONICAL.rglob("*.yon")))
    if f not in UNCOVERED and not _refused_by_the_parser(f)
)


def _fmt(path: Path):
    """Run yonfmt on a file. Returns (returncode, stdout)."""
    r = subprocess.run([str(FMT), str(path)], capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout


@pytest.mark.skipif(not FMT.exists(), reason="yonfmt not built")
def test_formatter_is_idempotent_on_corpus(tmp_path):
    formatted = 0
    for f in CORPUS:
        rc, out1 = _fmt(f)
        if rc != 0:
            continue  # uncovered construct -> fail-safe, left unchanged; skip
        formatted += 1
        once = tmp_path / "once.yon"
        once.write_text(out1)
        rc2, out2 = _fmt(once)
        assert rc2 == 0, f"formatter output not re-formattable: {f}"
        assert out2 == out1, f"formatter is not idempotent on {f}"
    # 100% coverage floor: every corpus file formats. A new construct that the
    # formatter does not cover drops this below total and flags that it needs
    # support (or, for a genuinely unparseable fixture, an explicit exclusion here).
    assert formatted == len(CORPUS), (
        f"formatter covers {formatted}/{len(CORPUS)} corpus files, expected all; "
        "extend frontend/formatter.ml for the new construct")


@pytest.mark.skipif(not FMT.exists(), reason="yonfmt not built")
def test_formatter_leaves_uncovered_files_unchanged(tmp_path):
    """Fail-safe: on an uncovered construct, --write must NOT touch the file."""
    src = "reduction R targets Foo { fold bar }\n"  # an uncovered top-level form
    f = tmp_path / "x.yon"
    f.write_text(src)
    r = subprocess.run([str(FMT), "--write", str(f)], capture_output=True, text=True, timeout=60)
    assert f.read_text() == src, f"fail-safe violated: file was modified\n{r.stdout}{r.stderr}"


def _frame(obj) -> bytes:
    b = json.dumps(obj).encode()
    return f"Content-Length: {len(b)}\r\n\r\n".encode() + b


@pytest.mark.skipif(not LSP.exists(), reason="yon_lsp not built")
def test_lsp_advertises_and_serves_formatting():
    uri = "file:///tmp/yonfmt_demo/demo.yon"
    text = "fun   f(x: Number):Number{return x+1}\n"
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "text": text}}},
        {"jsonrpc": "2.0", "id": 2, "method": "textDocument/formatting",
         "params": {"textDocument": {"uri": uri},
                    "options": {"tabSize": 2, "insertSpaces": True}}},
        {"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    inp = b"".join(_frame(m) for m in msgs)
    out = subprocess.run([str(LSP)], input=inp, capture_output=True, timeout=30).stdout.decode(errors="replace")
    assert "documentFormattingProvider" in out, out
    assert '"newText"' in out, out
    # the squashed input must come back canonically spaced
    assert "return x + 1" in out, out
