"""Self-host frontend fixpoint: the compiler-in-Yon reproduces itself, bit-for-bit.

stage-0 = yonc (the OCaml reference). stage-1 = selfhost/selfhost_compiler.yon
built by yonc; it is a Yon0 -> MLIR compiler written in Yon0. Feed stage-1 its
OWN source and it emits MLIR (out1); lower out1 with yonc to get the stage-2
binary; feed stage-2 the same source and it emits MLIR (out2). The frontend
self-hosts iff out1 == out2 byte-for-byte -- the compiler compiled by yonc and
the compiler compiled by itself agree exactly. (The backend, MLIR -> native, is
reused via yonc by design; this pins the FRONTEND fixpoint over the Yon0 subset.)

Uses the tool's fixed /tmp paths, so it runs serially like the rest of the
self-host suite.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
COMPILER = ROOT / "selfhost" / "selfhost_compiler.yon"
IN_PATH = Path("/tmp/yon_selfhost_in.yon")
OUT_PATH = Path("/tmp/yon_selfhost_out.mlir")

pytestmark = pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")


def _emit_self(binary):
    """Run a self-host compiler on the compiler's own source; return the emitted MLIR."""
    IN_PATH.write_text(COMPILER.read_text())
    if OUT_PATH.exists():
        OUT_PATH.unlink()
    subprocess.run([str(binary)], capture_output=True, timeout=180)
    assert OUT_PATH.exists(), "no MLIR emitted for the compiler's own source"
    return OUT_PATH.read_text()


def test_frontend_fixpoint(tmp_path):
    # stage-1: build the compiler-in-Yon with yonc.
    s1 = tmp_path / "stage1"
    c = subprocess.run([str(YONC), str(COMPILER), "-o", str(s1)],
                       capture_output=True, text=True, timeout=300)
    assert c.returncode == 0 and s1.exists(), f"stage-1 build failed:\n{c.stderr[-800:]}"

    # stage-1 compiles the compiler source -> out1.
    out1 = _emit_self(s1)
    assert len(out1) > 100_000, "sanity: the compiler's MLIR should be substantial"

    # lower out1 to the stage-2 binary.
    m1 = tmp_path / "out1.mlir"
    m1.write_text(out1)
    s2 = tmp_path / "stage2"
    c = subprocess.run([str(YONC), str(m1), "-o", str(s2)],
                       capture_output=True, text=True, timeout=300)
    assert c.returncode == 0 and s2.exists(), f"stage-2 lowering failed:\n{c.stderr[-800:]}"

    # stage-2 compiles the compiler source -> out2. The fixpoint is out1 == out2.
    out2 = _emit_self(s2)
    assert out1 == out2, (
        "self-host frontend fixpoint BROKEN: the compiler compiled by yonc and "
        "the compiler compiled by itself emit different MLIR for the compiler source "
        f"(len out1={len(out1)}, out2={len(out2)})")
