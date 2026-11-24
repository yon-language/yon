#!/usr/bin/env python3
"""The mutants of the control predicates: each predicate answers "yes" always, and the gate says
whether it notices.

For every mutant of tools/mutants/mutants.py the body of one control predicate (a rule of the
checker that refuses, a certifier, a check of a law, a verifier of an MLIR pass) is replaced by the
answer that accepts everything; the tree is built and gate 1 runs on it. A mutant the gate leaves
green is a predicate whose "no" no test of gate 1 sees.

The work happens on a throwaway export of a commit (git archive, not a worktree): the export is
built once, each mutant is applied to one file, built, gated and reverted. The export is removed at
the end of the round unless --keep is given. Nothing here is part of a gate.

  python3 tools/mutants/run_mutants.py [--ref HEAD] [--only ID,ID] [--keep] [--wide]

  --wide   for a mutant gate 1 leaves green, run also the wide set of tests of the checker
           (WIDE below), to tell "no test of gate 1 sees it" from "no test of the suite sees it"

The log of each mutant is in notes/logs/mutants/<round>/<id>.log, the table of the round in
notes/logs/mutants/<round>/summary.tsv.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           cwd=HERE, check=True).stdout.strip())
sys.path.insert(0, str(HERE))
import mutants as M  # noqa: E402

WIDE = ["regression/test_projects.py", "regression/test_canonical_forms.py",
        "regression/test_soundness_probes.py", "regression/test_audit_probes.py",
        "regression/test_hits_in_the_prelude.py", "regression/test_core_wf.py",
        "regression/test_drop_check.py", "regression/test_algebras.py"]


def sh(cmd, cwd, log, timeout=None, env=None):
    t0 = time.time()
    with open(log, "a") as f:
        f.write(f"$ {cmd}\n")
        f.flush()
        try:
            r = subprocess.run(cmd, shell=True, cwd=cwd, stdout=f, stderr=subprocess.STDOUT,
                               timeout=timeout, env=env)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            f.write(f"TIMEOUT after {timeout}s\n")
            rc = 124
        f.write(f"[rc {rc}, {time.time() - t0:.0f}s]\n")
    return rc


def export(ref, tree, log, worktree=False):
    if tree.exists():
        shutil.rmtree(tree)
    tree.mkdir(parents=True)
    if worktree:
        # the working tree as it is: the tracked files and the new ones git does not ignore
        sh(f"git -C {ROOT} ls-files -co --exclude-standard -z | (cd {ROOT} && tar --null -T - -cf -) "
           f"| tar -x -C {tree}", ROOT, log)
    else:
        sh(f"git -C {ROOT} archive {ref} | tar -x -C {tree}", ROOT, log)
    os.symlink(ROOT / ".venv", tree / ".venv")
    # notes/ is outside git: the gate keeps its temporary files there
    for d in ("notes/tmp", "notes/logs", "notes/gate-failures"):
        (tree / d).mkdir(parents=True, exist_ok=True)
    # The mlir build is configured against this tree's own sources.
    llvm = "/opt/homebrew/opt/llvm@18/lib/cmake"
    steps = [
        "make -C runtime",
        f"cmake -G Ninja -S mlir -B mlir/build -DMLIR_DIR={llvm}/mlir -DLLVM_DIR={llvm}/llvm",
        "ninja -C mlir/build",
        "dune build --root frontend",
        # gate 1 picks its tests from `git status`: a local repository of the export, never pushed
        "git init -q && git add -A && git -c commit.gpgsign=false -c user.name=mutants "
        "-c user.email=mutants@localhost commit -q -m base",
    ]
    for s in steps:
        if sh(s, tree, log) != 0:
            raise SystemExit(f"the export does not build at: {s} (see {log})")


def gate1(tree, log, env):
    return sh("bash regression/gate.sh 1", tree, log, timeout=3600, env=env)


def picked(log):
    txt = Path(log).read_text()
    m = re.findall(r"tier 1: targeted:(.*)", txt)
    return m[-1].strip() if m else "-"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--only", default="")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--wide", action="store_true")
    ap.add_argument("--round", default=time.strftime("%Y%m%dT%H%M%S"))
    ap.add_argument("--worktree", action="store_true",
                    help="export the working tree (tracked and new files) instead of a commit")
    a = ap.parse_args()
    sha = "worktree" if a.worktree else subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--short", a.ref],
        capture_output=True, text=True, check=True).stdout.strip()
    logs = ROOT / "notes" / "logs" / "mutants" / f"{a.round}-{sha}"
    logs.mkdir(parents=True, exist_ok=True)
    tree = ROOT / "notes" / "tmp" / "mutants" / "tree"
    export(a.ref, tree, logs / "export.log", a.worktree)
    env = dict(os.environ, YON_GATE_FAILURES=str(tree / "notes" / "gate-failures"))
    only = set(x for x in a.only.split(",") if x)
    rows = []
    summary = logs / "summary.tsv"
    summary.write_text("id\tfile\tpredicate\tverdict\tgate1_tests\twide\tseconds\n")
    for m in M.MUTANTS:
        if only and m.id not in only:
            continue
        log = logs / f"{m.id}.log"
        log.write_text(f"mutant {m.id}: {m.file} {m.predicate}\n{m.why}\n")
        t0 = time.time()
        path = tree / m.file
        orig = path.read_text()
        try:
            new = M.apply(m, orig)
        except M.NotApplied as e:
            verdict, tests, wide = "not-applied: " + str(e), "-", "-"
        else:
            path.write_text(new)
            with open(log, "a") as f:
                f.write("--- the mutation ---\n" + M.show(orig, new) + "\n")
            rc = gate1(tree, log, env)
            tests = picked(log)
            txt = log.read_text()
            built = not re.search(r"GATE RED \(build", txt)
            if not built:
                verdict = "not-built"
            elif rc == 0:
                verdict = "SURVIVED"
            else:
                verdict = "killed"
            wide = "-"
            if a.wide and verdict == "SURVIVED":
                w = sh(".venv/bin/pytest " + " ".join(WIDE) + " -q -x -n auto -p no:cacheprovider "
                       "--basetemp notes/tmp/yon-pytest-wide --skip-ledger regression/SKIPS.txt", tree, log, timeout=3600, env=env)
                wide = "killed" if w != 0 else "SURVIVED"
            path.write_text(orig)
        rows.append((m.id, m.file, m.predicate, verdict, tests, wide, f"{time.time() - t0:.0f}"))
        with open(summary, "a") as f:
            f.write("\t".join(rows[-1]) + "\n")
        print("\t".join(rows[-1]), flush=True)
    # the tree back to the base, rebuilt, so a kept export is the commit itself
    sh("git checkout -q -- . && dune build --root frontend", tree, logs / "export.log")
    if not a.keep:
        shutil.rmtree(tree)
        print(f"export removed: {tree}")
    print(f"summary: {summary}")


if __name__ == "__main__":
    main()
