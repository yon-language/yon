"""The syntax triangle: lexer <-> corpus <-> book, closed as one invariant.

`test_keyword_docs.py` guards a single edge (lexer -> book, keyword level). This
suite closes the keyword triangle and keeps it closed in CI. Three legs plus a
regenerable matrix:

  Leg 1  lexer -> book       every lexer keyword has a `#### `kw`` section in
                             website/docs/book/22-keywords.md.
  Leg 2  lexer -> corpus     every lexer keyword is exercised by a compiling
                             example (examples/, keyword_coverage/, yon_tests/,
                             cross_space/) or is in KEYWORD_ALLOWLIST (reserved /
                             kernel tokens).
  Leg 4  book -> corpus       every CodeWindow `file="proj/"` block is byte-identical
                             to the real examples/proj files (net of omitted files);
                             every other `.yon` fenced block compiles to a recorded
                             exit or is marked illustrative.

The production side (one canonical form and its rejected deviations per grammar
production) is the fourth leg, and it lives in its own gate,
`regression/test_canonical_forms.py`, backed by executable fixtures under
`regression/canonical_forms/` and projected to `regression/CANONICAL-FORMS.md`.
Adding a keyword to the lexer without its example and its book section fails HERE;
adding a production to the grammar without a fixture fails THERE.

Artifact: regression/SYNTAX-TRIANGLE.md, the keyword matrix, regenerable with
`python regression/test_syntax_triangle.py` and CI-checkable with `--check`.
"""
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LEXER = ROOT / "frontend" / "lexer.mll"
KEYWORDS_MD = ROOT / "website" / "docs" / "book" / "22-keywords.md"
MATRIX = ROOT / "regression" / "SYNTAX-TRIANGLE.md"
BOOK = ROOT / "website" / "docs" / "book"
EXAMPLES = ROOT / "examples"
YONC = ROOT / "toolchain" / "yonc"

CORPUS_ROOTS = [
    EXAMPLES,
    ROOT / "regression" / "keyword_coverage",
    ROOT / "regression" / "yon_tests",
    ROOT / "regression" / "cross_space",
]

# Reserved / kernel-internal tokens a corpus `.yon` is not required to exercise.
# Everything else must appear in a compiling example. The generics form `<A, B>`
# is deliberately NOT here: it lives in the corpus (`identity<T>`), enforced by
# test_leg2_generics_in_corpus_not_allowlist.
KEYWORD_ALLOWLIST = {
    "El",      # kernel decode type; no surface syntax, exercised by the test_el oracle
    "PathP",   # cubical dependent path; kernel form, test_path_core
    "I0",      # cubical interval endpoint 0; kernel form
    "I1",      # cubical interval endpoint 1; kernel form
    "Type_",   # lexing prefix, not a standalone token; the numbered form Type_0 is exercised
}


# --------------------------------------------------------------------------- #
# Extractors (structural, no compilation)
# --------------------------------------------------------------------------- #
def lexer_keyword_tokens() -> dict[str, str]:
    """word -> TOKEN, the lexer keyword table (same regex as test_keyword_docs)."""
    out = {}
    for word, tok in re.findall(r'"([a-z_]+)",\s*([A-Z_]+)', LEXER.read_text()):
        out[word] = tok
    return out


def documented_keywords() -> set[str]:
    return set(re.findall(r"^#### `([A-Za-z_][A-Za-z0-9_]*)`", KEYWORDS_MD.read_text(), re.M))


def _strip_comments(s: str) -> str:
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    return s


def corpus_files() -> list[Path]:
    files: list[Path] = []
    for root in CORPUS_ROOTS:
        if root.exists():
            files += list(root.glob("**/*.yon"))
    return files


def corpus_token_counts() -> dict[str, int]:
    counts: dict[str, int] = {}
    for p in corpus_files():
        for t in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", _strip_comments(p.read_text())):
            counts[t] = counts.get(t, 0) + 1
    return counts


# --------------------------------------------------------------------------- #
# Book blocks
# --------------------------------------------------------------------------- #
def _clean_block(s: str) -> str:
    s = s.strip()
    if s.startswith("{`") and s.endswith("`}"):
        s = s[2:-2]
    s = re.sub(r"^\s*```[a-z]*\n", "", s)
    s = re.sub(r"\n```\s*$", "", s)
    return s.strip("\n")


CODEWINDOW = re.compile(r"<CodeWindow\s+(.*?)>(.*?)</CodeWindow>", re.S)
MARKER = re.compile(r"<!--\s*yon-gate:\s*(exit\s+-?\d+|illustrative|project\s+\S+)\s*-->")
PATH_MARKER = re.compile(r"^// ([\w./]+\.(?:yon|toml))\b")


def codewindows():
    """(chapter, file, run, out, content) for every CodeWindow in the book.

    Attributes are pulled from the opening tag individually so their order in the
    source never matters."""
    out = []
    for md in sorted(BOOK.glob("*.md")):
        for m in CODEWINDOW.finditer(md.read_text()):
            attrs = m.group(1)
            f = re.search(r'file="([^"]+)"', attrs)
            run = re.search(r'run="([^"]*)"', attrs)
            o = re.search(r"out=\{\[([^\]]*)\]\}", attrs)
            out.append((md.stem, f.group(1) if f else "",
                        run.group(1) if run else "", o.group(1) if o else "",
                        _clean_block(m.group(2))))
    return out


def fenced_yon_blocks():
    """Non-CodeWindow ```yon blocks with their preceding yon-gate marker (or None)."""
    out = []
    for md in sorted(BOOK.glob("*.md")):
        text = md.read_text()
        stripped = re.sub(r"<CodeWindow.*?</CodeWindow>", lambda mm: "\n" * mm.group(0).count("\n"), text, flags=re.S)
        for m in re.finditer(r"```yon\n(.*?)```", stripped, re.S):
            pre = stripped[:m.start()]
            mk = None
            tail = pre.rstrip().splitlines()[-3:] if pre.strip() else []
            for line in reversed(tail):
                g = MARKER.search(line)
                if g:
                    mk = g.group(1).strip()
                    break
            out.append((md.stem, mk, m.group(1).strip("\n")))
    return out


# --------------------------------------------------------------------------- #
# Compilation helpers
# --------------------------------------------------------------------------- #
import os
import shutil

NOISE = ("[YON-RT", "[structural", "yonc:", "ld:", "clang:")


def _run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120, **kw)


def compile_run_file(content: str, tmp: Path) -> tuple[bool, int]:
    src = tmp / "block.yon"
    src.write_text(content + "\n")
    r = _run([str(YONC), str(src), "-o", str(tmp / "b")])
    if r.returncode != 0:
        return False, -1
    return True, _run([str(tmp / "b")]).returncode


def _split_markers(content: str) -> dict[str, str]:
    """content with `// path` markers -> {path: body}; {} if none."""
    files, cur, buf = {}, None, []
    for line in content.splitlines():
        pm = PATH_MARKER.match(line)
        if pm:
            if cur:
                files[cur] = "\n".join(buf)
            cur, buf = pm.group(1), []
        elif cur is not None:
            buf.append(line)
    if cur:
        files[cur] = "\n".join(buf)
    return files


def run_codewindow(cw, tmp: Path):
    """Execute a CodeWindow's literal run= command and return filtered stdout lines."""
    _chapter, fname, run_cmd, _out, content = cw
    if fname.endswith("/"):                       # project: run against the real dir
        shutil.copytree(EXAMPLES / fname.rstrip("/"), tmp / fname.rstrip("/"))
    else:
        files = _split_markers(content)
        if files:                                 # multi-file single-`file=` (cross-package)
            for rel, body in files.items():
                (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
                (tmp / rel).write_text(body + "\n")
        else:
            (tmp / fname).write_text(content + "\n")
    env = {**os.environ, "PATH": f"{ROOT / 'toolchain'}:{os.environ['PATH']}"}
    r = _run(run_cmd, shell=True, cwd=tmp, env=env)
    obins = set(re.findall(r"-o\s+(\S+)", run_cmd))
    return [l for l in r.stdout.splitlines() if not l.startswith(NOISE) and l not in obins]


# =========================================================================== #
# Leg 1 — lexer -> book
# =========================================================================== #
@pytest.mark.skipif(not LEXER.exists() or not KEYWORDS_MD.exists(), reason="sources missing")
def test_leg1_every_keyword_documented():
    missing = sorted(set(lexer_keyword_tokens()) - documented_keywords())
    assert not missing, (
        f"lexer keywords with no `#### `kw`` section in 22-keywords.md: {missing}"
    )


# =========================================================================== #
# Leg 2 — lexer -> corpus (coverage)
# =========================================================================== #
@pytest.mark.skipif(not LEXER.exists(), reason="lexer missing")
def test_leg2_every_keyword_exercised():
    counts = corpus_token_counts()
    uncovered = []
    for kw in lexer_keyword_tokens():
        if counts.get(kw, 0) > 0:
            continue
        if kw in KEYWORD_ALLOWLIST or any(a.rstrip("_") == kw for a in KEYWORD_ALLOWLIST):
            continue
        uncovered.append(kw)
    assert not uncovered, (
        "lexer keywords exercised by NO compiling example and not in KEYWORD_ALLOWLIST: "
        f"{uncovered}. Add a gated example (preferred) or an allowlist entry with a reason."
    )


def test_leg2_generics_in_corpus_not_allowlist():
    """The generics form must live in the corpus, not the allowlist."""
    counts = corpus_token_counts()
    text = " ".join(_strip_comments(p.read_text()) for p in corpus_files())
    assert re.search(r"\w+<[A-Za-z_][\w ,]*>", text), (
        "no generics `<...>` occurrence in the corpus; the generic form must be "
        "exercised by a real example (e.g. identity<T>), not allowlisted away."
    )


# Leg 3 (production ledger: canonical form + rejected deviation per grammar
# production) now lives in its own gate, regression/test_canonical_forms.py, backed
# by the executable fixtures under regression/canonical_forms/. It owns the
# production-completeness check and the CANONICAL-FORMS.md projection.


# =========================================================================== #
# Leg 4 — book -> corpus (fidelity + block compilation)
# =========================================================================== #
def _project_codewindows():
    return [c for c in codewindows() if c[1].endswith("/")]


@pytest.mark.parametrize("cw", _project_codewindows(), ids=lambda c: f"{c[0]}:{c[1]}")
def test_leg4_codewindow_matches_real_project(cw):
    chapter, fname, _run_cmd, _out, content = cw
    proj = EXAMPLES / fname.rstrip("/")
    assert proj.is_dir(), f"CodeWindow {fname} has no backing examples/ project"
    # split shown content by // path markers, compare each to the real file
    cur, buf, shown = None, [], {}
    for line in content.splitlines():
        pm = PATH_MARKER.match(line)
        if pm:
            if cur:
                shown[cur] = "\n".join(buf)
            cur, buf = pm.group(1), []
        elif cur is not None:
            buf.append(line)
    if cur:
        shown[cur] = "\n".join(buf)
    assert shown, f"{chapter}:{fname} declares a project but shows no // path files"
    for rel, body in shown.items():
        real = proj / rel
        assert real.is_file(), f"{fname} shows {rel} which is not in examples/{fname}"
        real_body = real.read_text().rstrip("\n")
        assert body.rstrip("\n") == real_body, (
            f"{chapter}:{fname} block for {rel} DIVERGES from examples/{fname}{rel}\n"
            f"--- book ---\n{body}\n--- disk ---\n{real_body}"
        )


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")
@pytest.mark.parametrize("cw", codewindows(), ids=lambda c: f"{c[0]}:{c[1]}")
def test_leg4_codewindow_runs(cw, tmp_path):
    """Every CodeWindow, project or single-file, executed via its literal run= command."""
    chapter, fname, run_cmd, out, _content = cw
    outs = [x.strip().strip('"') for x in re.findall(r'"[^"]*"', out)] or [out.strip()]
    got = run_codewindow(cw, tmp_path)
    assert got == outs, f"{chapter}:{fname} produced {got}, recorded out={outs}"


@pytest.mark.parametrize("blk", fenced_yon_blocks(),
                         ids=lambda b: f"{b[0]}:{hash(b[2]) & 0xffff:04x}")
def test_leg4_prose_block_marked(blk):
    chapter, marker, content = blk
    if content.splitlines() and PATH_MARKER.match(content.splitlines()[0]):
        return  # a project-file fragment, covered by assembled-project fidelity
    assert marker is not None, (
        f"{chapter}: a ```yon block has no `<!-- yon-gate: ... -->` marker. Add "
        "`exit N` (a compiling standalone), `illustrative` (a fragment, counted), "
        "or `project NAME` (a project file). First line: "
        f"{content.splitlines()[0][:60] if content.splitlines() else '(empty)'!r}"
    )


@pytest.mark.skipif(not YONC.exists(), reason="toolchain/yonc missing")
@pytest.mark.parametrize(
    "blk", [b for b in fenced_yon_blocks() if b[1] and b[1].startswith("exit")],
    ids=lambda b: f"{b[0]}:{hash(b[2]) & 0xffff:04x}")
def test_leg4_exit_marked_block_runs(blk, tmp_path):
    chapter, marker, content = blk
    want = int(marker.split()[1])
    ok, code = compile_run_file(content, tmp_path)
    assert ok, f"{chapter}: an `exit {want}` block did not compile"
    assert code == want, f"{chapter}: block exit {code} != marked {want}"


# =========================================================================== #
# Matrix artifact
# =========================================================================== #
def build_matrix() -> str:
    toks = lexer_keyword_tokens()
    counts = corpus_token_counts()
    documented = documented_keywords()

    exempt = 0
    for _, mk, content in fenced_yon_blocks():
        if mk == "illustrative":
            exempt += 1

    lines = []
    lines.append("<!-- GENERATED by regression/test_syntax_triangle.py --check. Do not edit by hand. -->")
    lines.append("")
    lines.append("# Syntax triangle")
    lines.append("")
    lines.append("The lexer, the corpus, and the book, agreed. Every keyword the lexer knows")
    lines.append("is a keyword the corpus exercises and the book documents. The production side")
    lines.append("(one canonical form and its rejected deviations per grammar production) is a")
    lines.append("separate gate, `regression/test_canonical_forms.py`, projected to")
    lines.append("`regression/CANONICAL-FORMS.md`. Regenerate this file with")
    lines.append("`python regression/test_syntax_triangle.py`.")
    lines.append("")
    lines.append(f"- lexer keywords: **{len(toks)}**")
    lines.append(f"- corpus files: **{len(corpus_files())}**")
    lines.append(f"- CodeWindows: **{len(codewindows())}**  "
                 f"(project **{len(_project_codewindows())}**, single-file "
                 f"**{len(codewindows()) - len(_project_codewindows())}**)")
    lines.append(f"- prose `.yon` blocks marked illustrative (exempt, counted): **{exempt}**")
    lines.append(f"- allowlisted reserved/kernel tokens: **{len(KEYWORD_ALLOWLIST)}**")
    lines.append("")

    lines.append("## Keywords (lexer x corpus-count x book anchor)")
    lines.append("")
    lines.append("| keyword | token | corpus count | book #21 | status |")
    lines.append("|---|---|---|---|---|")
    for kw in sorted(toks):
        n = counts.get(kw, 0)
        anchor = "yes" if kw in documented else "**MISSING**"
        if n > 0:
            status = "exercised"
        elif kw in KEYWORD_ALLOWLIST:
            status = "allowlisted"
        else:
            status = "**UNCOVERED**"
        lines.append(f"| `{kw}` | `{toks[kw]}` | {n} | {anchor} | {status} |")
    lines.append("")
    return "\n".join(lines) + "\n"


def test_matrix_in_sync():
    assert MATRIX.exists(), "SYNTAX-TRIANGLE.md missing; run python regression/test_syntax_triangle.py"
    assert MATRIX.read_text() == build_matrix(), (
        "SYNTAX-TRIANGLE.md is stale; regenerate with "
        "`python regression/test_syntax_triangle.py`"
    )


if __name__ == "__main__":
    if "--check" in sys.argv:
        cur = MATRIX.read_text() if MATRIX.exists() else ""
        if cur != build_matrix():
            print("SYNTAX-TRIANGLE.md is stale; run without --check to regenerate.")
            sys.exit(1)
        print("SYNTAX-TRIANGLE.md up to date.")
    else:
        MATRIX.write_text(build_matrix())
        print(f"wrote {MATRIX.relative_to(ROOT)}")
