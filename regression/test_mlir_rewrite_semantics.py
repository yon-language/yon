"""The Topos MLIR rewrite passes preserve the meaning of the program.

test_mlir_passes.py checks each rewrite pass textually, on a hand-written
fixture: the op it targets is gone, the folded value is there. That says the
pass DID something; it does not say the program still computes the same
thing. This module is the semantic check: for a handful of corpus programs
we lower the frontend's Topos MLIR twice, once WITHOUT the rewrite pass and
once WITH it, carry both to a native binary, run them, and require the same
exit code, equal to the one regression/baseline_exitcodes.txt records for the
program (so "both wrong in the same way" cannot pass either).

The pipeline is toolchain/yonc's, stage by stage:
    yoner_emit_mlir -> topos-opt --algebra-verifier [REWRITE...]
                       --lower-topos-extensions --lower-topos-to-standard
    -> topos-opt --lower-topos-to-llvm -> mlir-translate -> llc -> cc + runtime
The "without" leg drops --structural-value-numbering too, the one rewrite pass
yonc ships in stage 1, so that pass is measured like the others.

Which passes: only those whose effect survives into the lowered program on
real corpus input (SVN, heyting-short-circuit, coherence-elimination).
place-fusion and world-specialization rewrite the Topos module of some
examples, but their effect is erased by the lowering (the standard MLIR is
byte-identical), and move-composition and topos-cps-conversion change no
corpus example: for those four there is no program whose binary could
differ, so they run only in the combined "all" leg. Each (program, pass) node
also asserts that the pass changed the standard MLIR, so a node can never
pass by comparing a program with itself.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = [pytest.mark.mlir, pytest.mark.integration]

ROOT = Path(__file__).resolve().parent.parent
EXD = ROOT / "examples"
EMIT = ROOT / "frontend" / "_build" / "default" / "yoner_emit_mlir.exe"
TOPOS = os.environ.get("YONC_TOPOS_OPT") or str(ROOT / "mlir" / "build" / "topos-opt")
BASELINE = Path(__file__).resolve().parent / "baseline_exitcodes.txt"


def _tool(name, env):
    return os.environ.get(env) or shutil.which(name) or shutil.which(f"{name}-18") or name


MLIRTRANS = _tool("mlir-translate", "YONC_MLIR_TRANSLATE")
LLC = _tool("llc", "YONC_LLC")
CC = os.environ.get("YONC_CC", "gcc")
_RT_NAMES = [
    "yon_rt.o", "yon_mmap.o", "leech_orbits.o", "yon_arena.o", "yon_curtis_canon.o",
    "xleech2_coord.o", "xleech2_heap.o", "xleech2_mphf.o",
    "vendor/mmgroup/mat24_tables.o", "vendor/mmgroup/mat24_functions.o",
    "vendor/mmgroup/gen_leech.o", "vendor/mmgroup/gen_leech3.o",
    "vendor/mmgroup/gen_leech_type.o", "vendor/mmgroup/gen_leech_reduce.o",
    "vendor/mmgroup/gen_xi_functions.o", "vendor/mmgroup/mm_group_n.o",
    "vendor/mmgroup/mm_index.o",
]
RTSET = [str(ROOT / "runtime" / n) for n in _RT_NAMES]

# Programs with a Heyting / pattern / closure / arena mix, none touching a
# machine-global name, each well under a second to run.
PROGRAMS = ["kw_heyting", "heyting_excluded_middle", "kw_patterns",
            "handle_lambdas", "kw_is_literal", "arena_basic"]
PASSES = {
    "svn": ["--structural-value-numbering"],
    "heyting-short-circuit": ["--heyting-short-circuit"],
    "coherence-elimination": ["--coherence-elimination"],
    "all": ["--structural-value-numbering", "--heyting-short-circuit",
            "--coherence-elimination", "--move-composition", "--place-fusion",
            "--world-specialization"],
}
# heyting_excluded_middle has no structurally duplicate value: SVN leaves its
# standard MLIR byte-identical, so that pair would compare a program with itself.
CASES = [(p, k) for p in PROGRAMS for k in PASSES
         if (p, k) != ("heyting_excluded_middle", "svn")]


@pytest.fixture(scope="session", autouse=True)
def _toolchain():
    missing = [str(p) for p in (EMIT, Path(TOPOS)) if not Path(p).exists()]
    missing += [n for n in RTSET if not Path(n).exists()]
    if missing:
        pytest.skip(f"toolchain not built: {missing[0]} (run dune build / make / cmake)")
    for t in (MLIRTRANS, LLC):
        if not (shutil.which(t) or Path(t).exists()):
            pytest.skip(f"tool not found on PATH: {t}")


def _expected_exit(name):
    m = re.search(rf"^RAN {re.escape(name)} exit=(\d+)$", BASELINE.read_text(), re.MULTILINE)
    assert m, f"{name}: no `RAN {name} exit=N` line in {BASELINE.name}"
    return int(m.group(1))


def _run(cmd, what):
    r = subprocess.run(cmd, capture_output=True, timeout=120)
    if r.returncode != 0:
        pytest.fail(f"{what} failed (exit {r.returncode}):\n"
                    f"{r.stderr.decode(errors='replace')[-2000:]}")
    return r.stdout


def _standard(name, rewrites, tmp):
    """Emit `name` and lower it to standard MLIR with `rewrites` inserted
    before the lowering passes; return the standard MLIR text."""
    src = next((c for c in (EXD / f"{name}.yon", EXD / name) if c.exists()), None)
    if src is None:
        pytest.fail(f"{name}: example source not found ({EXD / name}[.yon])")
    topos = tmp / f"{name}.topos.mlir"
    if not topos.exists():
        out = _run([str(EMIT), str(src)], f"{name}: EMIT")
        assert out, f"{name}: EMIT produced no MLIR"
        topos.write_bytes(out)
    std = _run([TOPOS, "--algebra-verifier", *rewrites, "--lower-topos-extensions",
                "--lower-topos-to-standard", str(topos)],
               f"{name}: topos-opt stage 1 with {rewrites}")
    assert std, f"{name}: stage 1 with {rewrites} printed nothing"
    return std.decode()


def _exit_code(std_mlir, tag, tmp):
    """Carry standard MLIR to a native binary, run it, return its exit code."""
    s1, s2, ll, obj, exe = (tmp / f"{tag}.{e}" for e in ("s1", "s2", "ll", "o", "bin"))
    s1.write_text(std_mlir)
    s2.write_bytes(_run([TOPOS, "--lower-topos-to-llvm", str(s1)], f"{tag}: to-llvm"))
    ll.write_bytes(_run([MLIRTRANS, str(s2), "--mlir-to-llvmir"], f"{tag}: mlir-translate"))
    _run([LLC, "-filetype=obj", str(ll), "-o", str(obj)], f"{tag}: llc")
    nopie = [] if os.uname().sysname == "Darwin" else ["-no-pie"]
    _run([CC, *nopie, str(obj), *RTSET, "-lpthread", "-lm", "-o", str(exe)], f"{tag}: link")
    r = subprocess.run([str(exe)], capture_output=True, timeout=60, cwd=tmp)
    return r.returncode


@pytest.mark.parametrize("name,rewrite", CASES)
def test_rewrite_preserves_exit_code(name, rewrite, tmp_path):
    expected = _expected_exit(name)
    without = _standard(name, [], tmp_path)
    with_pass = _standard(name, PASSES[rewrite], tmp_path)
    assert with_pass != without, (
        f"{name}: {PASSES[rewrite]} left the standard MLIR unchanged; this node would "
        f"compare the program with itself (pick another program for the pass)")
    rc_without = _exit_code(without, f"{name}.without", tmp_path)
    rc_with = _exit_code(with_pass, f"{name}.with", tmp_path)
    assert rc_without == expected, (
        f"{name}: without the rewrite the binary exits {rc_without}, the baseline "
        f"records {expected}")
    assert rc_with == rc_without, (
        f"{name}: {rewrite} changed the program's meaning: exit {rc_with} with "
        f"the pass, {rc_without} without it")
