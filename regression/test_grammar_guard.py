"""The guard of the syntax: the grammar and the tokens of Yon are registered files.

Two files stand for the surface syntax as the parser reads it:

  regression/GRAMMAR.ebnf    the EBNF of frontend/parser.mly, as `obelisk ebnf` prints it;
  regression/GRAMMAR.tokens  the census of the whole lexer, read off frontend/lexer.mll by
                             regression/lexer_census.py: every case of every rule, the keyword
                             table and the wrapper `token`, each with its pattern, the tokens it
                             can give, the conditions it reads, the states it writes and what it
                             refuses; the cases that read or write a state, or give more than one
                             token, again in # Context, with their code.

A change to the grammar or to the lexer that is not also a change to these two files fails here:
nothing enters or leaves the syntax without its diff being written down and seen. The files are
regenerated, never edited by hand:

  python regression/test_grammar_guard.py            # rewrite the two files
  python regression/test_grammar_guard.py --check    # exit 1 if either is stale
"""
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lexer_census  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
PARSER = ROOT / "frontend" / "parser.mly"
LEXER = ROOT / "frontend" / "lexer.mll"
EBNF = ROOT / "regression" / "GRAMMAR.ebnf"
TOKENS = ROOT / "regression" / "GRAMMAR.tokens"


# The EBNF is the output of one version of Obelisk: another version may print the same grammar
# differently, and the guard would report a change of the tool as a change of the syntax.
OBELISK_VERSION = "0.8.1"


class ObeliskMissing(RuntimeError):
    """Obelisk is not installed, or is not the version the registered EBNF was printed with."""


def obelisk_version():
    """The version Obelisk prints at the head of its help (it has no --version), or None."""
    try:
        out = subprocess.run(["obelisk", "-help"], capture_output=True, text=True)
    except FileNotFoundError:
        return None
    m = re.search(r"Obelisk version (\S+)", out.stdout + out.stderr)
    return m.group(1) if m else None


def require_obelisk():
    v = obelisk_version()
    if v is None:
        raise ObeliskMissing(
            "obelisk is not installed (or not on PATH): the guard of the syntax needs Obelisk "
            + OBELISK_VERSION + " to print the EBNF of frontend/parser.mly (opam install obelisk."
            + OBELISK_VERSION + ")")
    if v != OBELISK_VERSION:
        raise ObeliskMissing(
            "obelisk " + v + " is installed, but regression/GRAMMAR.ebnf is printed by Obelisk "
            + OBELISK_VERSION + ": with another version a difference would be the tool's, not the "
            "grammar's (opam install obelisk." + OBELISK_VERSION + ")")


def ebnf_text() -> str:
    """The EBNF of the parser, from Obelisk (a dependency of the gate, like Menhir)."""
    require_obelisk()
    out = subprocess.run(["obelisk", "ebnf", str(PARSER)], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("obelisk ebnf failed: " + out.stderr.strip())
    return out.stdout


def declared_tokens(mly: str) -> list:
    """The `%token` names, in order of declaration."""
    names = []
    for line in mly.splitlines():
        m = re.match(r"%token(\s*<[^>]*>)?\s+(.*)", line)
        if not m:
            continue
        body = re.sub(r"/\*.*?\*/", "", m.group(2))
        for name in body.split():
            if re.fullmatch(r"[A-Z][A-Z0-9_]*", name) and name not in names:
                names.append(name)
    return names


def tokens_text() -> str:
    """regression/GRAMMAR.tokens: the census of the whole lexer (regression/lexer_census.py)."""
    return lexer_census.census()[0]


def test_the_ebnf_is_registered():
    assert EBNF.read_text() == ebnf_text(), (
        "regression/GRAMMAR.ebnf is stale: frontend/parser.mly changed. Regenerate it with "
        "`python regression/test_grammar_guard.py` and commit the diff with the grammar.")


def test_the_tokens_are_registered():
    assert TOKENS.read_text() == tokens_text(), (
        "regression/GRAMMAR.tokens is stale: the tokens of frontend/parser.mly or their spellings in "
        "frontend/lexer.mll changed. Regenerate it with `python regression/test_grammar_guard.py` "
        "and commit the diff with the grammar.")


def test_every_token_of_the_parser_is_given_by_the_lexer():
    """Each %token of parser.mly is given by some case of the lexer, by the keyword table, or by
    the wrapper `token`: a token no rule gives is a word of the grammar nobody can write."""
    _, sets = lexer_census.census()
    missing = sorted(set(sets["declared"]) - sets["produced"])
    assert missing == [], "tokens of parser.mly that no rule of the lexer gives: " + ", ".join(missing)


def test_every_token_the_lexer_gives_is_declared():
    _, sets = lexer_census.census()
    unknown = sorted(sets["produced"] - set(sets["declared"]))
    assert unknown == [], "tokens the lexer gives that parser.mly does not declare: " + ", ".join(unknown)


def test_every_keyword_of_the_table_has_its_token():
    # a keyword whose token the parser does not declare stops the census
    mll = LEXER.read_text().replace('"place", PLACE;', '"place", PLACE;\n      "zebra", ZEBRA;', 1)
    try:
        lexer_census.census(mll_text=mll)
    except lexer_census.ExtractorStop as e:
        assert "ZEBRA" in str(e), e
    else:
        raise AssertionError("a keyword with an undeclared token did not stop the census")


def test_a_form_the_census_cannot_read_stops_it():
    """An action that uses a name the vocabulary does not know stops the census, with the rule
    and the name: the census never skips what it cannot read."""
    mll = LEXER.read_text().replace("{ LEQ }", "{ mystery_state := 1; LEQ }", 1)
    assert mll != LEXER.read_text()
    try:
        lexer_census.census(mll_text=mll)
    except lexer_census.ExtractorStop as e:
        assert "mystery_state" in str(e) and '"<="' in str(e), e
    else:
        raise AssertionError("an action the census cannot read did not stop it")


def test_a_changed_condition_changes_the_census():
    """The code of a case of context is in the census: a condition that changes changes the file."""
    mll = LEXER.read_text().replace("| Inside _ | Line _ -> EQEQ", "| Inside _ -> EQEQ", 1)
    assert mll != LEXER.read_text()
    assert lexer_census.census(mll_text=mll)[0] != lexer_census.census()[0]


def test_obelisk_is_the_version_of_the_registered_ebnf():
    require_obelisk()


if __name__ == "__main__":
    try:
        require_obelisk()
    except ObeliskMissing as e:
        print("syntax guard stopped: " + str(e))
        sys.exit(2)
    if "--check" in sys.argv:
        stale = [p.name for p, t in ((EBNF, ebnf_text()), (TOKENS, tokens_text()))
                 if not p.exists() or p.read_text() != t]
        if stale:
            print(", ".join(stale) + " stale: run `python regression/test_grammar_guard.py` and commit the diff.")
            sys.exit(1)
        print("GRAMMAR.ebnf and GRAMMAR.tokens are current.")
        sys.exit(0)
    EBNF.write_text(ebnf_text())
    TOKENS.write_text(tokens_text())
    print("wrote regression/GRAMMAR.ebnf and regression/GRAMMAR.tokens")
