"""End-to-end pytest suite for Yon.

Drives the full native pipeline on every example
    .yon -> emit MLIR -> topos-opt (Topos dialect lowering) -> mlir-translate
         -> llc -> link against the C runtime -> native binary -> run
and asserts the exit code matches regression/baseline_exitcodes.txt.

Also runs the OCaml kernel oracles (test_*.exe, 0 failures) and the runtime
MPHF bijection self-check. Mirrors regression/run_regression.sh, one pytest
node per example so failures are isolated and named.

Tool discovery honours the same env vars as yonc (YONC_TOPOS_OPT, YONC_LLC,
YONC_MLIR_TRANSLATE, YONC_MLIR_OPT, YONC_CC); falls back to the -18 suffix.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FE = ROOT / "frontend"
FT = ROOT / "runtime"
EXD = ROOT / "examples"
EMIT = FE / "_build" / "default" / "yoner_emit_mlir.exe"
BASELINE = ROOT / "regression" / "baseline_exitcodes.txt"


def _tool(name, env):
    cand = os.environ.get(env) or shutil.which(name) or shutil.which(f"{name}-18")
    if not cand:
        p = Path(f"/usr/lib/llvm-18/bin/{name}")
        cand = str(p) if p.exists() else name
    return cand


TOPOS = os.environ.get("YONC_TOPOS_OPT") or str(ROOT / "mlir" / "build" / "topos-opt")
LLC = _tool("llc", "YONC_LLC")
MLIRTRANS = _tool("mlir-translate", "YONC_MLIR_TRANSLATE")
MLIROPT = _tool("mlir-opt", "YONC_MLIR_OPT")
CC = os.environ.get("YONC_CC", "gcc")

LOWER = ("--convert-scf-to-cf --convert-cf-to-llvm --convert-func-to-llvm "
         "--convert-arith-to-llvm --reconcile-unrealized-casts").split()

_RT_NAMES = [
    "yon_rt.o", "yon_mmap.o", "leech_orbits.o", "yon_arena.o", "yon_curtis_canon.o",
    "xleech2_coord.o", "xleech2_handler_stack.o", "xleech2_heap.o", "xleech2_mphf.o",
    "vendor/mmgroup/mat24_tables.o", "vendor/mmgroup/mat24_functions.o",
    "vendor/mmgroup/gen_leech.o", "vendor/mmgroup/gen_leech3.o",
    "vendor/mmgroup/gen_leech_type.o", "vendor/mmgroup/gen_leech_reduce.o",
    "vendor/mmgroup/gen_xi_functions.o", "vendor/mmgroup/mm_group_n.o",
    "vendor/mmgroup/mm_index.o",
]
RTSET = [str(FT / n) for n in _RT_NAMES]


def _run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, timeout=120, **kw)


def _parse_baseline():
    """name -> expected outcome ('EMITFAIL' or integer exit code)."""
    out = {}
    for line in BASELINE.read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "EMITFAIL":
            out[parts[1]] = "EMITFAIL"
        elif parts[0] == "RAN":
            out[parts[1]] = int(parts[2].split("=")[1])
    return out


BASE = _parse_baseline()
EXAMPLES = sorted(BASE.keys())


@pytest.fixture(scope="session", autouse=True)
def _toolchain():
    missing = [str(p) for p in (EMIT, Path(TOPOS)) if not Path(p).exists()]
    missing += [n for n in RTSET if not Path(n).exists()]
    if missing:
        pytest.skip(f"toolchain not built: {missing[0]} (run dune build / make / cmake)")


def _build_and_run(name, tmp):
    """Replicate run_regression.sh for one example. Returns 'EMITFAIL',
    'BUILDFAIL', or the integer exit code of the native binary."""
    src = EXD / f"{name}.yon"
    mlir, s1, s2, ll, obj, exe = (tmp / f"{name}.{e}"
                                  for e in ("mlir", "s1", "s2", "ll", "o", "bin"))
    r = _run([str(EMIT), str(src)])
    if r.returncode != 0 or not r.stdout:
        return "EMITFAIL"
    mlir.write_bytes(r.stdout)

    lowered = False
    a = _run([TOPOS, "--algebra-verifier", "--lower-topos-extensions",
              "--lower-topos-to-standard", str(mlir)])
    if a.returncode == 0 and a.stdout:
        s1.write_bytes(a.stdout)
        b = _run([TOPOS, "--lower-topos-to-llvm", str(s1)])
        if b.returncode == 0 and b.stdout:
            s2.write_bytes(b.stdout)
            lowered = True
    if not lowered:
        f = _run([MLIROPT, str(mlir), *LOWER])
        if f.returncode != 0 or not f.stdout:
            return "BUILDFAIL"
        s2.write_bytes(f.stdout)

    t = _run([MLIRTRANS, str(s2), "--mlir-to-llvmir"])
    if t.returncode != 0 or not t.stdout:
        return "BUILDFAIL"
    ll.write_bytes(t.stdout)
    if _run([LLC, "-filetype=obj", str(ll), "-o", str(obj)]).returncode != 0:
        return "BUILDFAIL"
    if _run([CC, "-no-pie", str(obj), *RTSET, "-lpthread", "-lm",
             "-o", str(exe)]).returncode != 0:
        return "BUILDFAIL"
    try:
        rc = subprocess.run([str(exe)], capture_output=True, timeout=30).returncode
        # shell convention used by the baseline: a signal N is reported as 128+N
        # (Python returns -N for a signal); mod 256 like a process exit code.
        return (rc if rc >= 0 else 128 - rc) % 256
    except subprocess.TimeoutExpired:
        return "TIMEOUT"


@pytest.mark.parametrize("name", EXAMPLES)
def test_example(name, tmp_path):
    expected = BASE[name]
    got = _build_and_run(name, tmp_path)
    assert got == expected, f"{name}: expected {expected}, got {got}"


# --- OCaml kernel oracles (alpha-equivalence, paths, HIT, isEquiv, eta-Sigma) ---

ORACLES = sorted(str(p) for p in (FE / "_build" / "default").glob("test_*.exe"))


@pytest.mark.parametrize("oracle", ORACLES, ids=[Path(o).stem for o in ORACLES])
def test_ocaml_oracle(oracle):
    r = _run([oracle])
    assert r.returncode == 0, r.stdout.decode(errors="replace")[-2000:]


# --- runtime MPHF bijection self-check (196560 minimal vectors) ---

def test_runtime_mphf(tmp_path):
    exe = tmp_path / "test_mphf"
    objs = [str(FT / n) for n in _RT_NAMES if n not in ("yon_rt.o",)]
    c = _run([CC, "-std=c11", "-O2", f"-I{FT}", f"-I{FT}/vendor/mmgroup",
              str(FT / "test_mphf.c"), *objs, "-lm", "-lpthread", "-o", str(exe)])
    assert c.returncode == 0, c.stderr.decode(errors="replace")[-2000:]
    r = subprocess.run([str(exe)], capture_output=True, timeout=180)
    assert r.returncode == 0 and b"BIJECTION VERIFIED" in r.stdout
