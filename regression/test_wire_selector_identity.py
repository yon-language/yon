"""On the wire the hash finds an operation, and a comparison of its description proves it.

A call between processes names its operation by a 23-bit selector (the FNV-1a of the name) and the
root of its signature (a hash of the roots of its types). Two names with the same selector and the
same signature would be one operation for the server: no equality rests on a hash alone
(radici-tipo-1). When a session opens, the caller sends once the description of every operation it
calls in that Space (name, selector, the words of the signature) and the server compares it byte
for byte; then the selectors hold for the session. A client compiled against a server that
exported `op_qzx` is refused, with the reason of the registry, by a server rebuilt with `op_danb`
in its place, instead of getting the answer of `op_danb`.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")


def _fnv(name):
    h = 2166136261
    for c in name.encode():
        h = ((h ^ c) * 16777619) & 0xffffffff
    return h & 0x7fffff


def test_the_two_names_share_their_selector():
    assert _fnv("op_qzx") == _fnv("op_danb") == 5282024


def _server(tmp, name, delta):
    (tmp / "ledger.yon").write_text(
        f"place Entry {{\n  fun {name}(x: Number): Number {{ return x + {delta} }}\n"
        "  fun main: Number { return 0 }\n}\n")
    r = subprocess.run([str(YONC), "ledger.yon", "-o", "Ledger_srv"], cwd=tmp,
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.mark.slow
def test_a_call_is_not_answered_by_another_operation_with_the_same_selector(tmp_path):
    _server(tmp_path, "op_qzx", 2)
    (tmp_path / "client.yon").write_text(
        "import ledger::op_qzx from Ledger\n\nplace Entry {\n  fun main: Number { return op_qzx(100) }\n}\n")
    r = subprocess.run([str(YONC), "client.yon", "-o", "client"], cwd=tmp_path,
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    assert subprocess.run(["./client"], cwd=tmp_path, timeout=60).returncode == 102
    _server(tmp_path, "op_danb", 50)
    run = subprocess.run(["./client"], cwd=tmp_path, capture_output=True, text=True, timeout=60)
    assert run.returncode == 3, (run.returncode, run.stderr)
    assert ("cross-Space call refused: Space 'Ledger' describes the operation op_qzx otherwise than "
            "its caller (the descriptions of the session differ byte for byte)") in run.stderr, run.stderr


@pytest.mark.slow
def test_a_call_to_the_operation_it_describes_is_answered_after_the_server_is_rebuilt(tmp_path):
    """The twin: the server rebuilt with the same operation (another body) answers the session."""
    _server(tmp_path, "op_qzx", 2)
    (tmp_path / "client.yon").write_text(
        "import ledger::op_qzx from Ledger\n\nplace Entry {\n  fun main: Number { return op_qzx(100) }\n}\n")
    r = subprocess.run([str(YONC), "client.yon", "-o", "client"], cwd=tmp_path,
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    _server(tmp_path, "op_qzx", 7)
    assert subprocess.run(["./client"], cwd=tmp_path, timeout=60).returncode == 107
