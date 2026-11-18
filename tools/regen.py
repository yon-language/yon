#!/usr/bin/env python3
"""Regenerate every derived file of the repository, or check that none is stale.

A file is a source (written by hand, in one place) or a derived file (generated, never edited by
hand), never half of each; regression/FLOW.md is the map. This command runs the generators in the order of the flow,
the sources first:

  python3 tools/regen.py            # rewrite every derived file
  python3 tools/regen.py --check    # exit 1, naming each stale file and the command that rewrites it

The gate runs `--check` in tier 0.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           cwd=Path(__file__).resolve().parent, check=True).stdout.strip())

# (what it derives, the command that rewrites it, the same command with --check), in the order of
# the flow: GRAMMAR.tokens comes before the highlighters that read it
STEPS = [
    ("regression/GRAMMAR.ebnf and regression/GRAMMAR.tokens (frontend/parser.mly, frontend/lexer.mll)",
     ["python3", "regression/test_grammar_guard.py"]),
    ("the lists of Prism, of the VS Code grammar and the keyword index (regression/GRAMMAR.tokens)",
     ["python3", "tools/gen_highlighters.py"]),
    ("regression/refusals/CATALOGUE.md and the drafts, and the catalogue against the refusal proofs "
     "(regression/refusals/catalogue.py)",
     ["python3", "regression/refusals/catalogue.py"]),
]


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for what, cmd in STEPS:
        r = subprocess.run(cmd + (["--check"] if check else []), cwd=ROOT, capture_output=True, text=True)
        if r.returncode != 0:
            stale.append((what, " ".join(cmd), (r.stdout + r.stderr).strip()))
        elif not check:
            print((r.stdout + r.stderr).strip())
    if stale:
        for what, cmd, out in stale:
            print(f"stale: {what}\n  {out}\n  rewrite with: {cmd}   (or all of them: python3 tools/regen.py)",
                  file=sys.stderr)
        return 1
    print("every derived file is current" if check else "regenerated every derived file")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
