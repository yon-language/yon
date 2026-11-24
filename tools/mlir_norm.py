#!/usr/bin/env python3
"""The MLIR of the corpus at a base and now, with the differences a group declares taken out of both.

`regression/gate.sh mlir <base>` dumps the MLIR of every program of the corpus at <base> and in the
working tree, and lists the programs whose text differs. When a group changes the MLIR of every
program for a reason it declares (an attribute on every fun, a new lowering), that list says nothing:
every program differs. This tool takes the declared differences out of both sides and compares
again; what is left differs for another reason, and each such program is a finding.

Each normalization is an option, and only the ones named are applied, to both sides:
  --linkage  the attribute `attributes {llvm.linkage = #llvm.linkage<internal>}` of a fun
  --frame    the variables: the calls of yon_rt_space_make/get/set/mark/reset and of
             __cell_make/get/set, the stub funs __cell_*, and the slots of a frame (llvm.alloca,
             llvm.load, llvm.store, llvm.ptrtoint, llvm.inttoptr, arith.bitcast, the count
             %cell_one_N of an alloca)
  --words    the words of the heap in line: the calls of yon_rt_region_read/write/cas and of the word
             primitives, the LLVM atomics (cmpxchg, atomicrmw, the extractvalue of their result)
  --names    the registration of the names of the operations between processes
             (yon_rt_register_op_name, yon_rt_register_import, the globals @yon_rpc_name_*)
Then, always: a constant that fed only a removed line goes too, and every SSA value is renamed by
its first appearance in its fun. A line a normalization removes is removed on both sides, so code of
the same shape that was there before goes on both sides alike; a block in line that has no
counterpart line on the other side (a check of bounds put in line) stays, and is a residue to read.

  regression/gate.sh mlir <base>          # the two dumps, in notes/tmp/mlir-<base> and notes/tmp/mlir-work
  python3 tools/mlir_norm.py --linkage --frame --words --names [BASE_DIR WORK_DIR]

Without the directories, the dumps of the last `gate.sh mlir` are read (the one base kept there).
"""
import argparse
import difflib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           cwd=Path(__file__).resolve().parent, check=True).stdout.strip())

RULES = {
    "linkage": dict(sub=re.compile(r" attributes \{llvm\.linkage = #llvm\.linkage<internal>\}")),
    "frame": dict(line=re.compile(r"@yon_rt_space_(make|get|set|mark|reset)\b|@__cell_(make|get|set)\b"
                                  r"|%cell_one_\d+ = llvm\.mlir\.constant|= llvm\.alloca|llvm\.load |llvm\.store "
                                  r"|= llvm\.ptrtoint|= llvm\.inttoptr|= arith\.bitcast"),
                  fun=re.compile(r"\s*func\.func @__cell_(make|get|set)\(")),
    "words": dict(line=re.compile(r"@yon_rt_region_(read|write|cas)\b"
                                  r"|@yon_rt_(read_word|write_word|compare_and_swap_word|word_of|value_of)\b"
                                  r"|llvm\.cmpxchg|llvm\.atomicrmw|= llvm\.extractvalue .*!llvm\.struct<\(i64, i1\)>")),
    "names": dict(line=re.compile(r"@yon_rt_register_op_name|@yon_rt_register_import|@yon_rpc_name_")),
}
SSA = re.compile(r"%[A-Za-z_][A-Za-z0-9_]*|%\d+")


def uses(l):
    rhs = l.split("=", 1)[1] if "=" in l and l.strip().startswith("%") else l
    return set(SSA.findall(rhs))


def constant_of(l):
    m = re.match(r"\s*(%\w+) = arith\.constant", l)
    return m.group(1) if m else None


def norm(text, rules):
    funs, cur = [], []
    for l in text.splitlines():
        if re.match(r"\s*func\.func ", l) and cur:
            funs.append(cur)
            cur = []
        cur.append(l)
    funs.append(cur)
    funs = [b for b in funs if not any(r.get("fun") and r["fun"].match(b[0]) for r in rules)]
    lines = []
    for body in funs:
        kept, dropped = [], []
        for l in body:
            for r in rules:
                if r.get("sub"):
                    l = r["sub"].sub("", l)
            gone = any(r.get("line") and r["line"].search(l) for r in rules)
            (dropped if gone else kept).append(l)
        fed = set().union(*(uses(l) for l in dropped)) if dropped else set()
        used = set().union(*(uses(l) for l in kept)) if kept else set()
        lines += [l for l in kept if not (constant_of(l) in fed and constant_of(l) not in used)]
    out, names = [], {}
    for l in lines:
        if re.match(r"\s*func\.func ", l):
            names = {}

        def ren(m):
            v = m.group(0)
            if v.startswith("%arg"):
                return v
            names.setdefault(v, f"%s{len(names)}")
            return names[v]
        out.append(SSA.sub(ren, l))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for k in RULES:
        ap.add_argument(f"--{k}", action="store_true")
    ap.add_argument("dirs", nargs="*")
    a = ap.parse_args()
    rules = [RULES[k] for k in RULES if getattr(a, k)]
    if a.dirs:
        base, work = map(Path, a.dirs[:2])
    else:
        tmp = ROOT / "notes" / "tmp"
        bases = sorted(p for p in tmp.glob("mlir-*") if p.name != "mlir-work")
        if len(bases) != 1:
            sys.exit("name the two directories: there is not one base dump in notes/tmp")
        base, work = bases[0], tmp / "mlir-work"
    same, rest = 0, []
    names = sorted({p.name for p in base.glob("*.mlir")} & {p.name for p in work.glob("*.mlir")})
    for f in names:
        x = norm((base / f).read_text(errors="replace"), rules)
        y = norm((work / f).read_text(errors="replace"), rules)
        if x == y:
            same += 1
            continue
        d = [l for l in difflib.unified_diff(x, y, lineterm="", n=0)
             if l[:1] in "+-" and l[:3] not in ("+++", "---")]
        rest.append((f, len(d), d[:6]))
    applied = ", ".join(k for k in RULES if getattr(a, k)) or "none"
    print(f"normalizations: {applied}; {same} identical, {len(rest)} differ")
    for f, n, d in sorted(rest, key=lambda r: r[1]):
        print(f"{n:6d}  {f}")
        for l in d:
            print(f"          {l[:150]}")


if __name__ == "__main__":
    main()
