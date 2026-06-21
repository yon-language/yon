"""Keyword / surface-syntax coverage suite for Yon.

Goal: every keyword the lexer recognizes must be EXERCISED by something that
the test machinery checks -- either a .yon example that compiles (the corpus
in examples/ or the micro-examples in keyword_coverage/), or, for the
kernel-internal forms that have no surface syntax, an OCaml core oracle.

Two kinds of node:
  - test_keyword_covered[kw]   : the keyword appears in a compiling example,
                                 or is a known kernel-internal form whose
                                 oracle passes.
  - test_coverage_example_emits: each keyword_coverage/*.yon emits MLIR.

This is the systematic per-keyword coverage; test_yon_pipeline.py is the
behavioural regression (exit codes) on the example corpus.
"""

import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LEXER = ROOT / "frontend" / "lexer.mll"
EXAMPLES = ROOT / "examples"
COVERAGE = ROOT / "regression" / "keyword_coverage"
BUILD = ROOT / "frontend" / "_build" / "default"
EMIT = BUILD / "yoner_emit_mlir.exe"

# Kernel-internal forms: no surface syntax, exercised by core oracles.
KERNEL_INTERNAL = {
    "El": "test_el",
    "PathP": "test_path_core",
    "el_match": "test_el",
    "quote": "test_quote",
    "I0": "test_path_core",   # cubical interval endpoint 0
    "I1": "test_path_core",   # cubical interval endpoint 1
}

# Lexing prefixes that are not standalone tokens: the real surface form is the
# numbered universe (Type_0, Type_1, ...). Covered iff a numbered form is used.
LEXING_PREFIXES = {"Type_"}


def _keywords():
    """Keyword set = string literals the lexer maps to tokens."""
    txt = LEXER.read_text()
    return sorted(set(re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"', txt)))


def _exercised_tokens():
    srcs = (
        list(EXAMPLES.glob("**/*.yon"))                       # incl. project dirs
        + list(COVERAGE.glob("**/*.yon"))                     # incl. coverage project dirs
        + list((COVERAGE / "yon_modules").glob("*.yon"))
        + list((ROOT / "regression" / "yon_tests").glob("**/*.yon"))   # migrated projects
        + list((ROOT / "regression" / "cross_space").glob("**/*.yon"))  # wire/space keywords
    )
    text = " ".join(p.read_text() for p in srcs)
    return set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text))


KEYWORDS = _keywords()
EXERCISED = _exercised_tokens()
COVERAGE_FILES = sorted(str(p) for p in COVERAGE.glob("*.yon"))


@pytest.fixture(scope="session", autouse=True)
def _built():
    if not EMIT.exists():
        pytest.skip("frontend not built (run: cd frontend && dune build)")


@pytest.mark.parametrize("kw", KEYWORDS)
def test_keyword_covered(kw):
    if kw in EXERCISED:
        return
    if kw in LEXING_PREFIXES:
        # not a standalone token; the numbered surface form must be exercised
        assert any(t.startswith(kw) and t != kw for t in EXERCISED), (
            f"no numbered form of '{kw}' (e.g. {kw}0) exercised"
        )
        return
    assert kw in KERNEL_INTERNAL, (
        f"keyword '{kw}' is exercised by no example and is not a known "
        f"kernel-internal form -- add a micro-example to keyword_coverage/"
    )
    oracle = BUILD / f"{KERNEL_INTERNAL[kw]}.exe"
    assert oracle.exists(), f"oracle {oracle.name} not built for kernel form '{kw}'"
    r = subprocess.run([str(oracle)], capture_output=True, timeout=60)
    assert r.returncode == 0, r.stdout.decode(errors="replace")[-1000:]


@pytest.mark.parametrize("f", COVERAGE_FILES, ids=[Path(f).stem for f in COVERAGE_FILES])
def test_coverage_example_emits(f):
    r = subprocess.run([str(EMIT), f], capture_output=True, timeout=60)
    assert r.returncode == 0, r.stderr.decode(errors="replace")[-800:]
