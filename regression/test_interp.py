"""Interpreter-path regression: every example through eval_runner (the OCaml
Reduce/kernel interpreter), exit value pinned to interp_baseline.txt.

This is the judge for reduction-kernel changes (subst, beta, the de Bruijn form of
reduce) that the NATIVE exit-code regression (test_yon_pipeline) does not exercise:
the same programs run through a different execution engine, so a divergence between
the two baselines is a real signal. Folds the old run_interp.sh into the harness,
one node per baselined example. Layer/kind: ocaml / functional.

Baseline changes (an example's interpreter exit moving) must land with an explaining
commit, like any golden.
"""
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXAMPLES = ROOT / "examples"
BASELINE = Path(__file__).resolve().parent / "interp_baseline.txt"
EVR = ROOT / "frontend" / "_build" / "default" / "eval_runner.exe"

_LINE = re.compile(r"INTERP (\S+) exit=(.+)")


def _baseline():
    d = {}
    if BASELINE.exists():
        for line in BASELINE.read_text().splitlines():
            m = _LINE.match(line.strip())
            if m:
                d[m.group(1)] = m.group(2)
    return d


_BASE = _baseline()


def _interp_exit(path):
    """Mirror run_interp.sh: last `EXIT n` line -> n, no line -> ERR, timeout -> TIMEOUT."""
    try:
        r = subprocess.run([str(EVR), str(path)], capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    exits = [l for l in r.stdout.splitlines() if l.startswith("EXIT ")]
    return exits[-1][len("EXIT "):].strip() if exits else "ERR"


def _resolve(name):
    """An example is either a directory PROJECT (examples/<name>/, post the
    filesystem-worlds migration) or a single file (examples/<name>.yon).
    eval_runner accepts both; prefer the directory."""
    d = EXAMPLES / name
    if d.is_dir():
        return d
    f = EXAMPLES / f"{name}.yon"
    return f if f.exists() else None


@pytest.mark.skipif(not EVR.exists(), reason="eval_runner.exe not built")
@pytest.mark.parametrize("name,expected", sorted(_BASE.items()))
def test_interp_exit_matches_baseline(name, expected):
    src = _resolve(name)
    if src is None:
        pytest.skip(f"example {name} not present (neither dir nor .yon)")
    got = _interp_exit(src)
    assert got == expected, (
        f"interpreter exit for {name}: got {got}, baseline {expected}. "
        "A reduction-kernel change, or the baseline needs an explained update.")
