"""The website speaks the LIVE language.

The syntax triangle gates the book's ```yon blocks and CodeWindows: those are
compiled for real. Nothing gated the rest of the site — the React homepage,
the thirty components, the prose outside a fenced block — and that is exactly
where a retired form survives unnoticed. The homepage shipped
`fun main(): number` (lowercase, an E1001 since the primitives became prelude
places) for as long as it took a human to read it.

Two legs, both cheap:

  leg A  no RETIRED keyword appears as Yon code anywhere under website/src or
         website/docs. "As Yon code" means inside backticks, a fenced block, a
         CodeWindow, or a JSX <code>/{styles.kw} span — not in English prose,
         where "objects" and "verify" are ordinary words.

  leg B  no lowercase primitive type (`: number`, `: text`, `: boolean`,
         `: unit`) appears in a type position. They are the kernel codes; the
         surface writes Number, Text, Boolean, Unit.

Both read the live lexer for the keyword set, so a word that comes BACK stops
being flagged without touching this file.
"""
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LEXER = ROOT / "frontend" / "lexer.mll"
SITE = ROOT / "website"

# Words the language once had and no longer has. Each is checked against the
# live lexer below: if it comes back, the test stops flagging it by itself.
RETIRED = [
    "terminal", "pullback", "pushout", "topology", "adjunction", "functorial",
    "lawful", "invertible", "subcontains", "verify", "becomes", "partial",
    "span", "plainly", "stay",
]

# Files that may legitimately name a retired word as Yon code: the pages whose
# subject IS the retirement. Each entry says why.
ALLOW = {
    "docs/book/22-keywords.md",       # documents what was retired, and why
    "docs/syntax-reference.md",       # same, in table form
    "docs/book/08-heyting-core.md",   # explains why `topology` was withdrawn
    "docs/book/91-future-work.md",    # the ledger of what may return
}


def live_keywords() -> set[str]:
    return set(re.findall(r'^\s*"([a-z_][a-z0-9_]*)",\s*[A-Z]', LEXER.read_text(), re.M))


def site_files():
    out = []
    for pat in ("src/**/*.js", "src/**/*.jsx", "docs/**/*.md", "docs/**/*.mdx"):
        out += sorted(SITE.glob(pat))
    return [p for p in out if "node_modules" not in str(p)]


def code_zones(text: str, is_js: bool) -> str:
    """The parts of a file that claim to BE Yon code."""
    zones = re.findall(r"`[^`\n]+`", text)                       # inline code
    zones += re.findall(r"```[a-z]*\n.*?```", text, re.S)        # fenced
    zones += re.findall(r"<CodeWindow.*?</CodeWindow>", text, re.S)
    if is_js:
        zones += re.findall(r"<code>.*?</code>", text, re.S)     # JSX inline code
        zones += re.findall(r"\{`.*?`\}", text, re.S)            # template literals
        # syntax-highlighted spans: {styles.kw}>word<
        zones += re.findall(r"styles\.\w+\}>[^<]*<", text)
    return "\n".join(zones)


@pytest.mark.parametrize("path", site_files(), ids=lambda p: str(p.relative_to(SITE)))
def test_no_retired_keyword_as_code(path):
    rel = str(path.relative_to(SITE))
    if rel in ALLOW:
        pytest.skip("documents the retirement itself")
    live = live_keywords()
    dead = [w for w in RETIRED if w not in live]
    text = path.read_text(errors="replace")
    blob = code_zones(text, path.suffix == ".js")
    # A mention that SAYS the word was retired is legitimate prose, even in
    # backticks: the sentence is about the retirement. Judged per paragraph,
    # so "the `verify` word was retired" passes and a live example does not.
    def is_explained(word: str) -> bool:
        for para in re.split(r"\n\s*\n", text):
            if re.search(r"`" + word + r"`", para) and re.search(
                    r"\bretire|\bwithdraw|\bno longer\b|\bwas removed\b", para):
                continue
            if re.search(r"\b" + word + r"\b", code_zones(para, path.suffix == ".js")):
                return False
        return True
    found = sorted({w for w in dead
                    if re.search(r"\b" + w + r"\b", blob) and not is_explained(w)})
    assert not found, (
        f"{rel} shows retired construct(s) as Yon code: {found}. "
        "The language no longer has them; rewrite the example or move the "
        "mention into prose that says they were retired."
    )


@pytest.mark.parametrize("path", site_files(), ids=lambda p: str(p.relative_to(SITE)))
def test_no_lowercase_primitive_in_type_position(path):
    rel = str(path.relative_to(SITE))
    if rel in ALLOW:
        pytest.skip("documents the kernel codes themselves")
    text = path.read_text(errors="replace")
    blob = code_zones(text, path.suffix == ".js")
    # `: number` / `-> text` / `of boolean` in a type position
    bad = set(re.findall(r"(?::\s*|->\s*|\bof\s+)(number|text|boolean|unit)\b", blob))
    # JSX splits `():{' '}` from `<span>number</span>`, so the colon is never
    # adjacent — but a span carrying the TYPE class says the same thing more
    # directly: whatever is in it IS a type. (This is how the homepage bug hid.)
    bad |= set(re.findall(r"styles\.ty\}>\s*(number|text|boolean|unit)\s*<", text))
    bad = sorted(bad)
    assert not bad, (
        f"{rel} writes the kernel code(s) {bad} in a type position. Since the "
        "primitives became prelude places, the surface writes Number, Text, "
        "Boolean, Unit — lowercase is E1001."
    )
