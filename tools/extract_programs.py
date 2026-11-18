#!/usr/bin/env python3
"""Move the Yon programs of the Python tests out of their strings, into files.

A test that writes a Yon program in a string hides it from every tool that reads Yon: the
formatter, the rewriter of the migrations, the MLIR comparison of the gate. This tool finds, in
each test of regression/, the string expressions whose value depends on no parameter (literals,
implicit concatenations, f-strings and `+`, `%`, `.format`, `.replace`, `.join`, `.strip` of such
values and of module constants) and whose value is a whole program the parser reads. Each moves to
regression/programs/<test module>/<function>_<n>.yon, and the expression becomes
`program("<test module>/<function>_<n>.yon")`, which reads the same text: the assertions of the
test do not change. An expression that depends on a parameter, a fragment that is not a program by
itself, and a docstring stay where they are (the tool for the generated programs reads those).

  python3 tools/extract_programs.py --dry-run     # what would move, file by file
  python3 tools/extract_programs.py               # move them
"""
import ast
import collections
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           cwd=Path(__file__).resolve().parent, check=True).stdout.strip())
REGRESSION = ROOT / "regression"
PROGRAMS = REGRESSION / "programs"
YONFMT = ROOT / "frontend" / "_build" / "default" / "yonfmt.exe"
YON = re.compile(r"\bfun [a-z_]\w*\s*[(:{<]|\bplace [A-Z]\w*\s*[{<]|\bplace [A-Z]\w* (is|carried)|\btopos\b")
STR_METHODS = ("format", "replace", "join", "strip", "lstrip", "rstrip")
HELPER = "from yon_programs import program"


def stringy(n):
    return ((isinstance(n, ast.Constant) and isinstance(n.value, str)) or isinstance(n, ast.JoinedStr)
            or (isinstance(n, ast.BinOp) and isinstance(n.op, (ast.Add, ast.Mod)))
            or (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in STR_METHODS))


def docstrings(tree):
    out = set()
    for n in ast.walk(tree):
        if isinstance(n, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.body:
            first = n.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                out.add(id(first.value))
    return out


def parses(text: str) -> bool:
    with tempfile.NamedTemporaryFile("w", suffix=".yon", delete=False) as fh:
        fh.write(text)
        path = fh.name
    r = subprocess.run([str(YONFMT), "--raw", path], capture_output=True, text=True)
    Path(path).unlink()
    return r.returncode != 2     # 2: the text does not parse; 3: it parses, the formatter stops


def candidates(path: Path):
    """(start, end, value, function) for each static whole program of a test, by byte offsets."""
    src = path.read_bytes()
    tree = ast.parse(src)
    parents = {c: n for n in ast.walk(tree) for c in ast.iter_child_nodes(n)}
    module = {}
    for st in tree.body:
        if isinstance(st, ast.Assign) and len(st.targets) == 1 and isinstance(st.targets[0], ast.Name):
            module[st.targets[0].id] = st.value
    memo, values = {}, {}

    def static(expr, depth=0):
        if depth > 20:
            return False
        for n in ast.walk(expr):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id != "str":
                v = module.get(n.id)
                if v is None:
                    return False
                if n.id not in memo:
                    memo[n.id] = None
                    memo[n.id] = static(v, depth + 1)
                if not memo[n.id]:
                    return False
            if isinstance(n, ast.Call):
                f = n.func
                if not (isinstance(f, ast.Attribute) and f.attr in STR_METHODS):
                    return False
            if isinstance(n, (ast.Lambda, ast.ListComp, ast.GeneratorExp, ast.Subscript, ast.Starred)):
                return False
        return True

    def value(expr):
        env = {}
        for name in sorted({n.id for n in ast.walk(expr) if isinstance(n, ast.Name)} - {"str"}):
            if name not in values:
                values[name] = value(module[name])
            env[name] = values[name]
        return eval(compile(ast.Expression(expr), str(path), "eval"), {"__builtins__": {"str": str}}, env)

    docs = docstrings(tree)
    lines = src.split(b"\n")
    starts = [0]
    for ln in lines[:-1]:
        starts.append(starts[-1] + len(ln) + 1)
    out, seen = [], set()
    for n in ast.walk(tree):
        if not (isinstance(n, ast.Constant) and isinstance(n.value, str) and YON.search(n.value)):
            continue
        if id(n) in docs:
            continue
        top = n
        while parents.get(top) is not None and stringy(parents[top]):
            top = parents[top]
        if isinstance(parents.get(top), ast.JoinedStr):
            top = parents[top]
        if id(top) in seen or id(top) in docs:
            continue
        seen.add(id(top))
        if not static(top):
            continue
        try:
            text = value(top)
        except Exception:
            continue
        if not isinstance(text, str) or not parses(text):
            continue
        anc, fn = top, "module"
        while anc in parents:
            anc = parents[anc]
            if isinstance(anc, (ast.FunctionDef, ast.AsyncFunctionDef)):
                fn = anc.name
                break
        s = starts[top.lineno - 1] + top.col_offset
        e = starts[top.end_lineno - 1] + top.end_col_offset
        out.append((s, e, text, fn))
    # outermost and disjoint
    out.sort()
    kept = []
    for c in out:
        if kept and c[0] < kept[-1][1]:
            continue
        kept.append(c)
    return kept


def main() -> int:
    dry = "--dry-run" in sys.argv[1:]
    total = collections.Counter()
    for path in sorted(REGRESSION.glob("test_*.py")):
        cands = candidates(path)
        if not cands:
            continue
        stem = path.stem
        total[stem] = len(cands)
        if dry:
            continue
        src = path.read_bytes()
        counter = collections.Counter()
        pieces, at = [], 0
        for s, e, text, fn in cands:
            counter[fn] += 1
            rel = f"{stem}/{fn}_{counter[fn]}.yon"
            dest = PROGRAMS / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(text)
            pieces.append(src[at:s])
            pieces.append(f'program("{rel}")'.encode())
            at = e
        pieces.append(src[at:])
        new = b"".join(pieces).decode()
        if HELPER not in new:
            # after the last import at the top of the module
            lines = new.split("\n")
            last = max((i for i, ln in enumerate(lines[:80]) if re.match(r"(import |from \S+ import )", ln)), default=0)
            lines.insert(last + 1, HELPER)
            new = "\n".join(lines)
        path.write_text(new)
    print(f"{sum(total.values())} programs in {len(total)} test files" + (" (dry run)" if dry else ""))
    for stem, n in total.most_common():
        print(f"  {stem}: {n}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
