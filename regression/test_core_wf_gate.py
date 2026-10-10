"""Core well-formedness / term-checking gate (core_wf.ml + core_check.ml).

This drives ONLY the frontend emitter (yoner_emit_mlir.exe) with YON_CORE_WF=1,
so it needs no MLIR toolchain: the kernel re-check (type certification + body
term-checking) runs during desugar, BEFORE any lowering. It pins two properties
the gate must have:

  (1) SOUNDNESS on the corpus — no valid example is false-rejected. The gate must
      SKIP every construct outside the pure dependent fragment (Place/Emit/stream/
      cubical, runtime primitives, 0-ary-call artifacts) rather than reject it.
      Every RAN example must also print the `[core-wf]` log: the gate RAN, and
      some example checks more bodies than the prelude alone (one corpus pass).

  (2) It still REJECTS a genuinely ill-typed, pure-dependent function body
      (a `Type_error` from Core_check), so the gate is not vacuous.

A gate rejection is reported on stderr as "kernel re-check rejected ..." with a
nonzero exit; that is the signal we assert on.
"""
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

import compiling_corpus as cc

ROOT = Path(__file__).resolve().parent.parent
FE = ROOT / "frontend"
EXD = ROOT / "examples"
EMIT = FE / "_build" / "default" / "yoner_emit_mlir.exe"
YONC = ROOT / "toolchain" / "yonc"

# Corpus names: single-file examples/<name>.yon and dir-projects examples/<name>/
# (the place-project migration). Both are emitted; a place needs the project
# context a directory carries, so a dir is emitted through yonc.
EXAMPLES = sorted(set(
    [p.name[:-4] for p in EXD.glob("*.yon")]
    + [d.name for d in EXD.iterdir() if d.is_dir() and (d / "yon.toml").exists()]
)) if EXD.exists() else []


def _example_src(name):
    d = EXD / name
    return d if d.is_dir() else EXD / f"{name}.yon"


def _emit(src_path, extra_env=None):
    # The frontend accepts a single .yon file OR a project directory (it mounts
    # the project context a `place` needs), and prints the YON_CORE_WF log to
    # stderr in both cases. Pass the path straight through.
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


def _bodies_checked(stderr: str) -> int | None:
    m = re.search(r"\[core-wf\] (\d+) function bodies kernel-checked", stderr)
    return int(m.group(1)) if m else None


_MIN_PROJECT_TOML = '[package]\nname = "minp"\n[runtime]\nbackend = "memory"\n'
_MIN_PROJECT_ENTRY = "place Entry {\n  fun main(): Number { return 0 }\n}\n"


def test_gate_runs_on_corpus_without_false_reject(tmp_path):
    """One pass over the corpus pins both properties of the gate:

      - SOUNDNESS: no example is rejected by the kernel re-check, and every
        example the baseline marks RAN emits (exit 0) WITH the `[core-wf]` log
        on stderr -- proof the gate actually ran on it, so "not rejected" is not
        the silence of a gate that never fired.
      - NOT VACUOUS: some example has more bodies kernel-checked than a project
        whose only function is `main` -- the prelude's bodies alone, measured
        live, not hard-coded -- so the corpus's own pure dependent bodies reach
        the term checker rather than all being skipped.
    """
    base = cc.baseline()
    minp = tmp_path / "minp"
    minp.mkdir()
    (minp / "yon.toml").write_text(_MIN_PROJECT_TOML)
    (minp / "Entry.yon").write_text(_MIN_PROJECT_ENTRY)
    floor_res = _emit(minp)
    assert floor_res.returncode == 0, floor_res.stderr.decode(errors="replace")
    floor = _bodies_checked(floor_res.stderr.decode(errors="replace"))
    assert floor is not None, "no [core-wf] body count for the minimal project"

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = dict(zip(EXAMPLES, pool.map(lambda n: _emit(_example_src(n)), EXAMPLES)))

    false_rejected, silent, counts = [], [], {}
    for name, res in results.items():
        err = res.stderr.decode(errors="replace")
        if _rejected(res):
            false_rejected.append(f"{name}:\n{err[-600:]}")
        if base.get(name) not in (None, "EMITFAIL"):
            n = _bodies_checked(err)
            if res.returncode != 0 or n is None or "dependent types certified" not in err:
                silent.append(f"{name} (exit {res.returncode}): {err[-300:]}")
            else:
                counts[name] = n
    assert not false_rejected, "core-wf falsely rejected valid programs:\n" + "\n".join(false_rejected)
    assert not silent, ("RAN examples where the gate did not run (no [core-wf] log) "
                        "or the emit failed:\n" + "\n".join(silent))
    assert counts, "no RAN example in the corpus"
    best = max(counts, key=counts.get)
    assert counts[best] > floor, (
        f"no example has a body kernel-checked beyond the prelude's {floor} "
        f"(max {counts[best]} in {best}): the body checker is vacuous on the corpus")


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

fun main(): Number { return 0 }
"""


# The well-typed twin: the same signature returning El(A) at El(A). It must emit,
# so the rejection below is about the El(A)/El(B) mismatch and nothing else
# (not `Type`, not the El of a parameter, not a parse error).
WELL_TYPED_TWIN = ILL_TYPED_SRC.replace("): El(B) {", "): El(A) {")


def test_frontend_refuses_ill_typed_pure_body(tmp_path):
    good = tmp_path / "well_typed.yon"
    good.write_text(WELL_TYPED_TWIN)
    ok = _emit(good)
    assert ok.returncode == 0 and ok.stdout, (
        "the well-typed twin must emit:\n" + ok.stderr.decode(errors="replace"))
    src = tmp_path / "ill_typed.yon"
    src.write_text(ILL_TYPED_SRC)
    res = _emit(src)
    stderr = res.stderr.decode(errors="replace")
    # A well-typed emit (rc == 0 with MLIR on stdout) would mean an ill-typed
    # dependent program slipped all the way through — a soundness bug.
    assert res.returncode != 0, (
        "an ill-typed dependent program emitted successfully:\n" + stderr)
    assert "Fatal error: exception" not in stderr, stderr
    # Today the SURFACE checker refuses it (E2001, the return mismatch); a kernel
    # refusal would carry "kernel re-check rejected". Either is a refusal of the
    # El(A)-for-El(B) return, and nothing else is accepted.
    surface = "[E2001]" in stderr and "expected El(B), got El(A)" in stderr
    assert surface or _rejected(res), f"rejected for the wrong reason:\n{stderr[-600:]}"
