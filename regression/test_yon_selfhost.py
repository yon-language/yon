"""Self-hosted behaviour suite: the tests are written IN Yon.

Three kinds of test-in-Yon, mapped to three levels of "is this realized":

  prove/    type-level proofs. A function `fun p(): Id(T, lhs, rhs) { return
            refl(...) }` type-checks IFF lhs and rhs are definitionally equal.
            The proposition is the type, refl is the proof, the type-checker is
            the oracle. Expected: EMIT succeeds (exit 0) == property holds.

  negative/ false proofs / illegal captures. Expected: REJECTED at compile time
            (emit exit 3) -- the language refuses to prove something false.

  runtime/  operational checks: `fun main(): Number { return actual - expected }`
            returns 0 iff the property holds at run time. Expected: the native
            binary exits 0. This is where forms that only compute (not
            definitionally equal) are proved -- e.g. J on refl.

A fourth check looks at the emitted MLIR shape directly (erasure).

pytest is only the harness; the assertions about Yon are written in Yon.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FE = ROOT / "frontend"
FT = ROOT / "runtime"
EMIT = FE / "_build" / "default" / "yoner_emit_mlir.exe"
TOPOS = ROOT / "mlir" / "build" / "topos-opt"
TESTS = ROOT / "regression" / "yon_tests"


def _tool(name, env):
    return os.environ.get(env) or shutil.which(name) or shutil.which(f"{name}-18") or name


LLC = _tool("llc", "YONC_LLC")
MLIRTRANS = _tool("mlir-translate", "YONC_MLIR_TRANSLATE")
CC = os.environ.get("YONC_CC", "gcc")

_RT = [
    "yon_rt.o", "yon_mmap.o", "leech_orbits.o", "yon_arena.o", "yon_curtis_canon.o",
    "xleech2_coord.o", "xleech2_heap.o", "xleech2_mphf.o",
    "vendor/mmgroup/mat24_tables.o", "vendor/mmgroup/mat24_functions.o",
    "vendor/mmgroup/gen_leech.o", "vendor/mmgroup/gen_leech3.o",
    "vendor/mmgroup/gen_leech_type.o", "vendor/mmgroup/gen_leech_reduce.o",
    "vendor/mmgroup/gen_xi_functions.o", "vendor/mmgroup/mm_group_n.o",
    "vendor/mmgroup/mm_index.o",
]
RTSET = [str(FT / n) for n in _RT]

PROVE = sorted(str(p) for p in (TESTS / "prove").glob("*.yon"))
NEGATIVE = sorted(str(p) for p in (TESTS / "negative").glob("*.yon"))
RUNTIME = sorted(str(p) for p in (TESTS / "runtime").glob("*.yon"))


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, timeout=120)


@pytest.fixture(scope="session", autouse=True)
def _built():
    miss = [p for p in (EMIT, TOPOS) if not Path(p).exists()] + [n for n in RTSET if not Path(n).exists()]
    if miss:
        pytest.skip(f"toolchain not built: {miss[0]}")


@pytest.mark.parametrize("src", PROVE, ids=[Path(p).stem for p in PROVE])
def test_proof_in_yon(src):
    """A Yon proof of a definitional equality must type-check (emit exit 0)."""
    r = subprocess.run([str(EMIT), src], capture_output=True, timeout=60)
    assert r.returncode == 0, (
        f"proof did not type-check -- property does not hold:\n"
        f"{r.stderr.decode(errors='replace')[-600:]}"
    )


@pytest.mark.parametrize("src", NEGATIVE, ids=[Path(p).stem for p in NEGATIVE])
def test_negative_in_yon(src):
    """A false proof / illegal capture must be rejected at compile time (exit 3)."""
    r = subprocess.run([str(EMIT), src], capture_output=True, timeout=60)
    assert r.returncode == 3, (
        f"expected compile-time rejection (exit 3), got exit {r.returncode} -- "
        f"the language proved something it should not have"
    )


@pytest.mark.parametrize("src", RUNTIME, ids=[Path(p).stem for p in RUNTIME])
def test_runtime_in_yon(src, tmp_path):
    """An operational check: native binary must exit 0 (actual - expected == 0)."""
    b = tmp_path / Path(src).stem
    mlir, s1, s2, ll, obj, exe = (str(b) + e for e in (".mlir", ".s1", ".s2", ".ll", ".o", ".bin"))
    e = subprocess.run([str(EMIT), src], capture_output=True, timeout=60)
    assert e.returncode == 0, e.stderr.decode(errors="replace")[-600:]
    Path(mlir).write_bytes(e.stdout)
    a = _run([str(TOPOS), "--algebra-verifier", "--lower-topos-extensions",
              "--lower-topos-to-standard", mlir])
    Path(s1).write_bytes(a.stdout)
    bb = _run([str(TOPOS), "--lower-topos-to-llvm", s1])
    Path(s2).write_bytes(bb.stdout)
    t = _run([MLIRTRANS, s2, "--mlir-to-llvmir"])
    Path(ll).write_bytes(t.stdout)
    assert _run([LLC, "-filetype=obj", ll, "-o", obj]).returncode == 0
    assert _run([CC, "-no-pie", obj, *RTSET, "-lpthread", "-lm", "-o", exe]).returncode == 0
    rc = subprocess.run([exe], capture_output=True, timeout=30).returncode
    assert rc == 0, f"runtime property failed: binary exited {rc} (expected 0)"


def test_mlir_erasure(tmp_path):
    """Level 3: a universe-typed parameter is erased -- the emitted MLIR has no
    !llvm.ptr token and universe_taker lowers to () -> f64 (the kw_paths fix).
    kw_paths is a dir-project (place migration), so emit through yonc, which mounts
    the project context; the raw frontend cannot infer a world for a bare place."""
    out = tmp_path / "kw_paths.mlir"
    subprocess.run([str(ROOT / "toolchain" / "yonc"), "--emit=mlir",
                    str(ROOT / "examples" / "kw_paths"), "-o", str(out)],
                   capture_output=True, timeout=60)
    mlir = out.read_text(errors="replace") if out.exists() else ""
    assert "!llvm.ptr" not in mlir, "type-level token leaked into the emitted code"
    assert "@universe_taker() -> f64" in mlir, "type-argument was not erased before emit"
