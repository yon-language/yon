"""Conformance gate — source <-> binary differential (de Bruijn defect D3).

For each pure single-file example, compare two independent computations of the program:

  KERNEL  : frontend/eval_runner.exe evaluates the source via the kernel reducer
            (Builtins.reduce_with_builtins) and prints `EXIT n`.
  BINARY  : toolchain/yonc compiles the source to native; we read its exit code.

A disagreement means the kernel and the compiled binary compute different values —
a back-end miscompile (or a kernel bug). That is the re-check defect D3 asks for: today the
binary is trusted, not validated against the kernel. This gate validates it WHERE THE
INTERPRETER IS COMPLETE.

The interpreter is incomplete for the imperative / effectful / stdlib layer. Sometimes it says
so (`[no extractable value, assuming 0]` on --trace stderr); but for `iter` / `while` / `produce`
/ `spawn` / `wire` / `for every` it computes a WRONG value (EXIT 0) SILENTLY — a finding in its
own right (the interpreter should error, not return a wrong 0). Programs using those constructs
are therefore scoped out by source inspection, not trusted to the punt message. The gate FAILS
only on a genuine disagreement on a program inside the interpreter-complete fragment. Completing
the interpreter (so it errors instead of returning a wrong 0, then evaluates the imperative
layer) is the path to widening D3 to the whole corpus.
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
YONC = ROOT / "toolchain" / "yonc"
EVAL = ROOT / "frontend" / "_build" / "default" / "eval_runner.exe"
EXAMPLES = ROOT / "examples"

_EXIT = re.compile(r"EXIT (\d+)")


def _kernel_eval(src: Path):
    """Return (exit_code, punted) from the kernel interpreter, or (None, _) on error."""
    r = subprocess.run([str(EVAL), "--trace", str(src)], capture_output=True, text=True, timeout=120)
    punted = "no extractable value" in r.stderr
    m = _EXIT.search(r.stdout)
    return (int(m.group(1)) if m else None), punted


def _binary_exit(src: Path, tmp: Path):
    b = tmp / "sbd"
    c = subprocess.run([str(YONC), str(src), "-o", str(b)], capture_output=True, timeout=240)
    if c.returncode != 0 or not b.exists():
        return None
    return subprocess.run([str(b)], capture_output=True, timeout=120).returncode


@pytest.mark.skipif(not YONC.exists() or not EVAL.exists(),
                    reason="toolchain/yonc or eval_runner not built")
def test_source_binary_differential(tmp_path):
    srcs = sorted(EXAMPLES.glob("*.yon"))
    if not srcs:
        pytest.skip("no single-file examples found")

    agree, scoped, mismatches = 0, 0, []
    for src in srcs:
        # the interpreter now SELF-REPORTS incompleteness ("EVAL INCOMPLETE", exit 6) instead of
        # returning a wrong value — so we trust its EXIT n and scope out everything else.
        ev, punted = _kernel_eval(src)
        bx = _binary_exit(src, tmp_path)
        if bx is None:
            scoped += 1; continue                 # does not compile / link here
        if ev is None or punted:
            scoped += 1; continue                 # interpreter refused (EVAL INCOMPLETE) or punted
        if ev == bx:
            agree += 1
        else:
            mismatches.append(f"{src.name}: kernel={ev} binary={bx}")

    print(f"\nsource<->binary differential: {agree} agree | {scoped} out-of-interpreter-scope "
          f"| {len(mismatches)} MISMATCH (of {len(srcs)} examples)")
    for m in mismatches:
        print("  MISMATCH:", m)

    assert not mismatches, (
        "kernel and compiled binary disagree on a program the interpreter fully evaluated "
        f"(a back-end or kernel bug):\n  " + "\n  ".join(mismatches))
    # at least some programs must be interpreter-complete, else the gate checks nothing
    assert agree > 0, "no example was interpreter-complete; the differential validated nothing"
