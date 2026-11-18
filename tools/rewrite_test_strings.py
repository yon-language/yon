#!/usr/bin/env python3
"""Rewrite the Yon programs that stay in the strings of the Python tests, in place.

What tools/extract_programs.py cannot move (a program that depends on a parameter of the test, a
fragment that is assembled with one) stays in its string. This tool reads each string literal of a
test that holds Yon text: a literal that is a whole program by itself is handed to the rewriter of
the migrations (`yonrw <rule>`) and put back in its place, written with the same quotes; a literal it
cannot rewrite (a fragment, a piece of an f-string) is listed, with its file and line, for the step
of the migration to rewrite by hand. A file in which no rule applies stays byte for byte as it was.

  python3 tools/rewrite_test_strings.py <rule> [--write] [files...]   # default: every regression/test_*.py
"""
import ast
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           cwd=Path(__file__).resolve().parent, check=True).stdout.strip())
YONRW = ROOT / "frontend" / "_build" / "default" / "yonrw.exe"
YON = re.compile(r"\bfun [a-z_]\w*\s*[(:{<]|\bplace [A-Z]\w*\s*[{<]|\bplace [A-Z]\w* (is|carried)|\btopos\b")


def rewrite_text(rule: str, text: str):
    """(new text or None if not a program, refusal reason or None)."""
    with tempfile.NamedTemporaryFile("w", suffix=".yon", delete=False) as fh:
        fh.write(text)
        path = fh.name
    r = subprocess.run([str(YONRW), rule, path], capture_output=True, text=True)
    Path(path).unlink()
    if r.returncode == 0:
        return r.stdout, None
    if "does not parse" in r.stderr:
        return None, None
    return None, r.stderr.strip()


def literal(text: str, original: str) -> str:
    """A Python literal for `text`, in the quotes of `original` (a plain string literal)."""
    prefix = re.match(r"[rRbBuU]*", original).group(0)
    body = original[len(prefix):]
    q = '"""' if body.startswith('"""') else "'''" if body.startswith("'''") else body[0]
    if "r" in prefix.lower():
        if q in text or text.endswith("\\"):
            prefix, q = "", q  # a raw literal cannot hold it: write it escaped
        else:
            return prefix + q + text + q
    if len(q) == 3:
        esc = text.replace("\\", "\\\\").replace(q, "\\" + q[0] * 3)
    else:
        esc = text.replace("\\", "\\\\").replace(q, "\\" + q).replace("\n", "\\n").replace("\t", "\\t")
    return prefix + q + esc + q


def process(rule: str, path: Path, write: bool):
    src = path.read_bytes()
    tree = ast.parse(src)
    starts = [0]
    for ln in src.split(b"\n")[:-1]:
        starts.append(starts[-1] + len(ln) + 1)
    parents = {c: n for n in ast.walk(tree) for c in ast.iter_child_nodes(n)}
    edits, listed = [], []
    for n in ast.walk(tree):
        if not (isinstance(n, ast.Constant) and isinstance(n.value, str) and YON.search(n.value)):
            continue
        s = starts[n.lineno - 1] + n.col_offset
        e = starts[n.end_lineno - 1] + n.end_col_offset
        original = src[s:e].decode()
        inside_fstring = isinstance(parents.get(n), ast.JoinedStr)
        if inside_fstring or not re.match(r"[rRbBuU]*['\"]", original):
            listed.append((n.lineno, "a piece of an f-string or of an implicit concatenation"))
            continue
        new, why = rewrite_text(rule, n.value)
        if why:
            listed.append((n.lineno, "the rewrite was refused: " + why.splitlines()[0]))
        elif new is None:
            listed.append((n.lineno, "a fragment, not a whole program"))
        elif new != n.value:
            edits.append((s, e, literal(new, original)))
    if edits and write:
        out, at = [], 0
        for s, e, t in sorted(edits):
            out += [src[at:s], t.encode()]
            at = e
        out.append(src[at:])
        path.write_bytes(b"".join(out))
    return edits, listed


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__, file=sys.stderr)
        return 64
    rule, files = args[0], [Path(a) for a in args[1:]] or sorted((ROOT / "regression").glob("test_*.py"))
    write = "--write" in sys.argv[1:]
    nedits = nlisted = 0
    for f in files:
        edits, listed = process(rule, f, write)
        nedits += len(edits)
        nlisted += len(listed)
        for line, why in listed:
            shown = f.relative_to(ROOT) if f.resolve().is_relative_to(ROOT) else f
            print(f"{shown}:{line}: {why}")
    print(f"{nedits} literals rewritten{'' if write else ' (dry run)'}, {nlisted} listed", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
