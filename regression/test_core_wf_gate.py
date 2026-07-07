"""Core well-formedness / term-checking gate (core_wf.ml + core_check.ml).

This drives ONLY the frontend emitter (yoner_emit_mlir.exe) with YON_CORE_WF=1,
so it needs no MLIR toolchain: the kernel re-check (type certification + body
term-checking) runs during desugar, BEFORE any lowering. It pins two properties
the gate must have:

  (1) SOUNDNESS on the corpus — no valid example is false-rejected. The gate must
      SKIP every construct outside the pure dependent fragment (Place/Emit/stream/
      cubical, runtime primitives, 0-ary-call artifacts) rather than reject it.

  (2) It still REJECTS a genuinely ill-typed, pure-dependent function body
      (a `Type_error` from Core_check), so the gate is not vacuous.

A gate rejection is reported on stderr as "kernel re-check rejected ..." with a
nonzero exit; that is the signal we assert on.
"""
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
FE = ROOT / "frontend"
EXD = ROOT / "examples"
EMIT = FE / "_build" / "default" / "yoner_emit_mlir.exe"

EXAMPLES = sorted(p.name[:-4] for p in EXD.glob("*.yon")) if EXD.exists() else []


def _emit(src_path, extra_env=None):
    env = dict(os.environ, YON_CORE_WF="1")
    if extra_env:
        env.update(extra_env)
    return subprocess.run([str(EMIT), str(src_path)],
                          capture_output=True, timeout=120, env=env)


@pytest.fixture(scope="session", autouse=True)
def _toolchain():
    if not EMIT.exists():
        pytest.skip(f"frontend emitter not built: {EMIT} (run dune build)")


def _rejected(res):
    return b"kernel re-check rejected" in res.stderr or b"does not check" in res.stderr


@pytest.mark.parametrize("name", EXAMPLES)
def test_gate_does_not_false_reject(name):
    """Every corpus example passes the kernel re-check (type + body gate)."""
    res = _emit(EXD / f"{name}.yon")
    assert not _rejected(res), (
        f"{name}: core-wf falsely rejected a valid program:\n"
        + res.stderr.decode(errors="replace"))


def test_gate_reports_body_check_counts():
    """The YON_CORE_WF=1 log reports body-check counts, and at least one corpus
    example has a pure dependent body that is actually kernel-checked (not all
    skipped) — otherwise the term-checking pass would be vacuous."""
    total_checked = 0
    for name in EXAMPLES:
        res = _emit(EXD / f"{name}.yon")
        for line in res.stderr.decode(errors="replace").splitlines():
            if "function bodies kernel-checked" in line:
                total_checked += int(line.split("]")[1].strip().split()[0])
    assert total_checked > 0, "no function body was kernel-checked across the corpus"


# A self-contained program that is ill-typed in the pure dependent fragment: it
# claims a code-polymorphic identity at El(A) -> El(B) (returns an El(A) where
# El(B) is demanded). In a CORRECT pipeline the surface type-checker already
# rejects this (a surface-valid program whose Core lowering is ill-typed would be
# a desugaring bug the kernel gate exists to catch — but such a bug should not
# exist to craft from surface syntax). So here we only assert the WHOLE frontend
# refuses it — defense in depth: surface OR kernel, never a clean emit. The
# kernel gate's own rejection path is pinned directly at the unit level by
# test_core_check.ml case (c) [certify_term ... = `Type_error].
ILL_TYPED_SRC = """\
fun bad(A: Type, B: Type, x: El(A)): El(B) { return x }

fun main(): number { return 0 }
"""


def test_frontend_refuses_ill_typed_pure_body(tmp_path):
    src = tmp_path / "ill_typed.yon"
    src.write_text(ILL_TYPED_SRC)
    res = _emit(src)
    stderr = res.stderr.decode(errors="replace")
    # A well-typed emit (rc == 0 with MLIR on stdout) would mean an ill-typed
    # dependent program slipped all the way through — a soundness bug.
    assert res.returncode != 0 or not res.stdout, (
        "an ill-typed dependent program emitted successfully:\n" + stderr)
