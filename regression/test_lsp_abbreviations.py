"""The symbols of Yon typed with abbreviations, as in Lean, and the formatter's Unicode.

yon_lsp completes `\\mapsto` to ↦ and the other symbols; yonfmt writes the ASCII forms in
Unicode.

Layer/kind: tooling / end-to-end over the protocol.
"""
import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LSP = ROOT / "frontend" / "_build" / "default" / "yon_lsp.exe"
FMT = ROOT / "frontend" / "_build" / "default" / "yonfmt.exe"

pytestmark = pytest.mark.skipif(not LSP.exists(), reason="yon_lsp not built")


def _frame(msg):
    body = json.dumps(msg).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def _completion(text, line, character):
    uri = "file:///tmp/abbr.yon"
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": uri, "text": text}}},
        {"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
         "params": {"textDocument": {"uri": uri},
                    "position": {"line": line, "character": character}}},
        {"jsonrpc": "2.0", "id": 3, "method": "shutdown"},
        {"jsonrpc": "2.0", "method": "exit"},
    ]
    r = subprocess.run([str(LSP)], input=b"".join(_frame(m) for m in msgs),
                       capture_output=True, timeout=30)
    out = r.stdout.decode()
    replies = []
    while "Content-Length:" in out:
        head, out = out.split("\r\n\r\n", 1)
        n = int(head.split("Content-Length:")[1].strip())
        raw = out.encode()[:n]
        out = out.encode()[n:].decode()
        replies.append(json.loads(raw))
    return next(m["result"] for m in replies if m.get("id") == 2)


@pytest.mark.parametrize("name,sym", [("mapsto", "↦"), ("inj", "↪"), ("forall", "∀"),
                                      ("exists", "∃"), ("and", "∧"), ("or", "∨"),
                                      ("to", "→"), ("not", "¬"), ("iff", "↔")])
def test_an_abbreviation_completes_to_its_symbol(name, sym):
    text = f"x \\{name}"
    items = _completion(text, 0, len(text))
    item = next(i for i in items if i["label"] == "\\" + name)
    edit = item["textEdit"]
    assert edit["newText"] == sym
    assert edit["range"]["start"]["character"] == 2 and edit["range"]["end"]["character"] == len(text)


def test_a_prefix_offers_what_it_starts(tmp_path):
    items = _completion("x \\m", 0, 4)
    assert [i["label"] for i in items] == ["\\mapsto"]


def test_the_range_counts_the_symbols_before_it():
    # ∀ is one unit of the protocol and three bytes
    text = "∀a \\inj"
    items = _completion(text, 0, len(text))
    assert items[0]["textEdit"]["range"]["start"]["character"] == 3


def test_no_backslash_gives_the_names_of_the_program():
    items = _completion("place Entry {}\n", 0, 5)
    assert all(not i["label"].startswith("\\") for i in items)


def test_the_formatter_writes_the_ascii_forms_in_unicode(tmp_path):
    src = tmp_path / "f.yon"
    src.write_text(
        "place Plus is algebra {\n"
        "  operation plus(a: Plus, b: Plus): Plus as \"+\"\n"
        "  law c ∀a : Plus, a = a &&? (a = a =>? a = a) ||? !?(a = a)\n"
        "}\n"
        "place Box { this > Full Number :U Empty }\n"
        "place Entry {\n"
        "  fun i(x: Number): Number { return x }\n"
        "  fun mk: Box { return 1 >-> Full }\n"
        "  fun main: Number { return 1 |-> i }\n"
        "}\n")
    r = subprocess.run([str(FMT), str(src)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    out = r.stdout
    assert "1 ↦ i" in out and "1 ↪ Full" in out
    assert "|->" not in out and ">->" not in out
    assert "∧" in out and "→" in out and "∨" in out and "¬" in out
    for ascii_form in ("&&?", "||?", "=>?", "!?"):
        assert ascii_form not in out
