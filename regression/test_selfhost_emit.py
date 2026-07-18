"""Self-host M1 gate — Yon emits MLIR that compiles and runs.

Stage 1 (test_selfhost.py) is a metacircular interpreter (eval: Term -> value).
This is the first step toward a real Yon-compiler-in-Yon: an emit pass
(gen: Term -> MLIR text) written in Yon. The oracle is end-to-end and format-
robust (not a byte-diff of the text): the Yon program emits an MLIR module, we
feed that Yon-emitted MLIR back through the same backend (topos-opt -> LLVM ->
native), run it, and require the exit code the source program denotes.

selfhost/emit_arith.yon compiles the Yon0 core `be x holds 20  be y holds 22
return x + y` (TLet/TLit/TAdd/TVar with an SSA environment) to a full MLIR module
and writes it via File.write_text; the compiled module must exit 42 = (20+22) mod
256. This pins that the emit catamorphism (constants, addf, fptosi, the SSA
counter, the de Bruijn env lookup) stays correct.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
SRC = ROOT / "selfhost" / "emit_arith.yon"


def _end_to_end(tmp_path, src_yon, out_mlir_path, expected_exit):
    """Compile a Yon emitter, run it (it writes an MLIR module), compile that
    Yon-emitted MLIR through the backend, run it, and require expected_exit."""
    emitter = tmp_path / "emitter"
    c1 = subprocess.run([str(YONC), str(src_yon), "-o", str(emitter)],
                        capture_output=True, text=True, timeout=180)
    assert c1.returncode == 0 and emitter.exists(), \
        f"{src_yon.name} did not compile:\n{c1.stderr[-800:]}"
    out_mlir = Path(out_mlir_path)
    if out_mlir.exists():
        out_mlir.unlink()
    subprocess.run([str(emitter)], capture_output=True, timeout=60)
    assert out_mlir.exists(), f"{src_yon.name} did not write an MLIR file"
    native = tmp_path / "native"
    c2 = subprocess.run([str(YONC), str(out_mlir), "-o", str(native)],
                        capture_output=True, text=True, timeout=180)
    assert c2.returncode == 0 and native.exists(), \
        f"MLIR emitted by {src_yon.name} did not compile:\n{c2.stderr[-800:]}"
    r = subprocess.run([str(native)], capture_output=True, timeout=60)
    assert r.returncode == expected_exit, \
        f"Yon-emitted program from {src_yon.name} exited {r.returncode}, expected {expected_exit}"


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
def test_m1_emit_arith(tmp_path):
    # M1: gen(Term -> MLIR) for a hand-built Term, `fun double(x){x+x}` / double(21).
    _end_to_end(tmp_path, ROOT / "selfhost" / "emit_arith.yon",
                "/tmp/yon_m1_out.mlir", 42)


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
def test_m2_compile_arith(tmp_path):
    # M2: text -> Term -> MLIR. Parses "2+3*4" (precedence: * over +) and the
    # emitted program computes 2 + (3*4) = 14, not (2+3)*4 = 20.
    _end_to_end(tmp_path, ROOT / "selfhost" / "compile_arith.yon",
                "/tmp/yon_m2_out.mlir", 14)


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
def test_m3_compile_fun(tmp_path):
    # M3: the Yon0 SURFACE. Lexes a real function with keywords, multi-digit
    # numbers and identifiers, parses `fun main(): number { be x holds 20
    # be y holds 22  return x + y }` into nested TLet with de Bruijn variables,
    # and the emitted program exits 42 = (20 + 22) mod 256.
    _end_to_end(tmp_path, ROOT / "selfhost" / "compile_fun.yon",
                "/tmp/yon_m3_out.mlir", 42)


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
def test_m4_compile_if(tmp_path):
    # M4: control flow. Adds `==` (arith.cmpf oeq -> i1) and if/then/else
    # (scf.if with scf.yield). `return if x == y then 99 else x + y` with
    # x=20, y=22: the condition is false, so the else branch runs and the
    # emitted program exits 42 = (20 + 22) mod 256 (not 99).
    _end_to_end(tmp_path, ROOT / "selfhost" / "compile_if.yon",
                "/tmp/yon_m4_out.mlir", 42)


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
def test_m5_compile_rec(tmp_path):
    # M5: functions, calls and RECURSION. Compiles two top-level functions,
    # `fun fact(n): number { return if n == 0 then 1 else n * fact(n - 1) }`
    # and `fun main(): number { return fact(5) }`, to real func.func/func.call
    # (a name is emitted as @fn_<hash>). The recursive self-call sits in the
    # else branch, so scf.if's laziness bottoms the recursion out at n == 0;
    # fact(5) = 120, so the emitted program exits 120.
    _end_to_end(tmp_path, ROOT / "selfhost" / "compile_rec.yon",
                "/tmp/yon_m5_out.mlir", 120)
