"""Self-host M6 differential oracle -- the Yon0-in-Yon compiler agrees with yonc.

For a corpus of Yon0 programs, compile each one BOTH with the OCaml reference
compiler (`yonc`) and with selfhost/selfhost_compiler.yon (the compiler written in
Yon, which reads a source file and emits an MLIR module), run both native binaries,
and require the SAME exit code. Agreement with the reference is the convergence
metric toward the M-bootstrap: where the two compilers agree, the Yon-in-Yon
frontend behaves as the reference does.

This oracle already earned its keep: it caught a real bug -- `a - b - c` was parsed
right-associative (a-(b-c)) instead of left (a-b)-c, so `10 - 3 - 2` gave 9 where
the reference gave 5. The parser was fixed to left-associative and the two now
converge (see the chain_sub / mixed_prec cases below).

Note: selfhost_compiler.yon reads/writes fixed /tmp paths (Yon's argv access has
friction), so these cases share global files and must run serially (as the rest of
the self-host suite already does).
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
COMPILER = ROOT / "selfhost" / "selfhost_compiler.yon"
IN_PATH = Path("/tmp/yon_selfhost_in.yon")     # the tool's hardcoded input
OUT_MLIR = Path("/tmp/yon_selfhost_out.mlir")  # the tool's hardcoded output

# (name, Yon0 source, expected exit). The core assertion is reference == self-hosted;
# `expected` is a sanity anchor that also rejects a shared-wrong-answer.
PROGRAMS = [
    ("arith",      "fun main(): number { return 2 + 3 * 4 }", 14),
    ("single_sub", "fun main(): number { return 10 - 3 }", 7),
    ("chain_sub",  "fun main(): number { return 10 - 3 - 2 }", 5),
    ("mixed_prec", "fun main(): number { return 100 - 2 * 3 - 4 }", 90),
    ("let42",      "fun main(): number { be x holds 20  be y holds 22  return x + y }", 42),
    ("if_false",   "fun main(): number { be x holds 20  be y holds 22  "
                   "return if x == y then 99 else x + y }", 42),
    ("call",       "fun dbl(x): number { return x + x }\n"
                   "fun main(): number { return dbl(21) }", 42),
    ("fact5",      "fun fact(n): number { return if n == 0 then 1 else n * fact(n - 1) }\n"
                   "fun main(): number { return fact(5) }", 120),
    ("sum10",      "fun sum(n): number { return if n == 0 then 0 else n + sum(n - 1) }\n"
                   "fun main(): number { return sum(10) }", 55),
]


def _run(binary):
    return subprocess.run([str(binary)], capture_output=True, timeout=60).returncode


def _reference(tmp_path, src):
    """Compile and run src with the OCaml reference compiler."""
    s = tmp_path / "ref_src.yon"
    s.write_text(src)
    b = tmp_path / "ref_bin"
    c = subprocess.run([str(YONC), str(s), "-o", str(b)],
                       capture_output=True, text=True, timeout=180)
    assert c.returncode == 0 and b.exists(), \
        f"reference did not compile the program:\n{c.stderr[-800:]}"
    return _run(b)


def _self_hosted(tmp_path, compiler_bin, src):
    """Compile and run src with the Yon0-in-Yon compiler (prebuilt as compiler_bin)."""
    IN_PATH.write_text(src)
    if OUT_MLIR.exists():
        OUT_MLIR.unlink()
    subprocess.run([str(compiler_bin)], capture_output=True, timeout=60)
    assert OUT_MLIR.exists(), "the Yon0-in-Yon compiler did not write an MLIR module"
    b = tmp_path / "self_bin"
    c = subprocess.run([str(YONC), str(OUT_MLIR), "-o", str(b)],
                       capture_output=True, text=True, timeout=180)
    assert c.returncode == 0 and b.exists(), \
        f"MLIR emitted by the Yon0-in-Yon compiler did not compile:\n{c.stderr[-800:]}"
    return _run(b)


@pytest.fixture(scope="module")
def compiler_bin(tmp_path_factory):
    """Build the Yon0-in-Yon compiler once for the whole module."""
    d = tmp_path_factory.mktemp("selfhostc")
    b = d / "selfhost_compiler"
    c = subprocess.run([str(YONC), str(COMPILER), "-o", str(b)],
                       capture_output=True, text=True, timeout=240)
    assert c.returncode == 0 and b.exists(), \
        f"selfhost_compiler.yon did not build:\n{c.stderr[-800:]}"
    return b


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc not present")
@pytest.mark.parametrize("name,src,expected", PROGRAMS, ids=[p[0] for p in PROGRAMS])
def test_differential(tmp_path, compiler_bin, name, src, expected):
    a = _reference(tmp_path, src)
    b = _self_hosted(tmp_path, compiler_bin, src)
    assert a == b, \
        f"[{name}] reference exited {a}, self-hosted exited {b} -- the compilers DIVERGE"
    assert a == expected, \
        f"[{name}] both compilers exited {a}, expected {expected}"
