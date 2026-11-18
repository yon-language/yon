#!/usr/bin/env python3
"""The lists of the highlighters, generated from regression/GRAMMAR.tokens.

Three derived lists, each between two visible markers in a file that is otherwise written by hand
(a derived list is generated, never edited; the text outside its markers is a source):

  website/src/theme/prism-include-languages.js   the keywords, the booleans and the operators of Prism (site and book)
  lsp/editors/vscode/syntaxes/yon.tmLanguage.json the declarations, keywords, lexer types and operators
                                                 of the VS Code grammar (the marker is the key "comment")
  website/docs/syntax-reference.md                the keyword index of the site

A word enters a highlighter only if the lexer gives it and some production of the parser reads it
(GRAMMAR.tokens: no `refused=`), so a form that is gone stops being colored by itself. The keyword
index lists every word of the lexer, with its description in website/docs/book/22-keywords.md.

The category of each word and spelling is written once, in tools/keyword_categories.txt. The
generator stops, saying why, if a live word or spelling has no category, if a category names a word
or spelling the lexer does not give, if a word of the lexer has no description in 22-keywords.md, or
if a description names a word the lexer does not have.

  python3 tools/gen_highlighters.py           # rewrite the three lists
  python3 tools/gen_highlighters.py --check   # exit 1 and name what is stale
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                           cwd=Path(__file__).resolve().parent, check=True).stdout.strip())
TOKENS = ROOT / "regression" / "GRAMMAR.tokens"
CATEGORIES = ROOT / "tools" / "keyword_categories.txt"
PRISM = ROOT / "website" / "src" / "theme" / "prism-include-languages.js"
VSCODE = ROOT / "lsp" / "editors" / "vscode" / "syntaxes" / "yon.tmLanguage.json"
SYNREF = ROOT / "website" / "docs" / "syntax-reference.md"
KEYWORDS_MD = ROOT / "website" / "docs" / "book" / "22-keywords.md"
COMMAND = "python3 tools/gen_highlighters.py"
MARK = "generated from regression/GRAMMAR.tokens, do not edit (" + COMMAND + ")"

WORD_CATEGORIES = ["declaration", "storage", "control", "binding", "word", "constant", "boolean",
                   "hott", "type"]
SPELLING_CATEGORIES = ["operator", "operator-heyting", "punctuation", "type", "word"]
# the scope of VS Code each category takes
SCOPE = {"control": "keyword.control.yon", "declaration": "storage.type.yon",
         "storage": "storage.type.yon", "binding": "keyword.other.binding.yon",
         "word": "keyword.operator.word.yon", "constant": "constant.language.yon",
         "boolean": "constant.language.yon", "hott": "keyword.other.hott.yon",
         "type": "support.type.primitive.yon", "operator": "keyword.operator.yon",
         "operator-heyting": "keyword.operator.intuitionistic.yon"}


class Stop(RuntimeError):
    pass


# ------------------------------------------------------------------------------------------------
# The sources
# ------------------------------------------------------------------------------------------------
def lexer():
    """(keywords, live keywords, live spellings) of GRAMMAR.tokens."""
    lines = TOKENS.read_text().splitlines()
    keywords, live = [], []
    for ln in lines:
        if ln.startswith("KEYWORD\t"):
            f = ln.split("\t")
            keywords.append(f[1])
            if not any(x.startswith("refused=") for x in f[3:]):
                live.append(f[1])
    refused_tokens = {ln.split("\t")[1] for ln in lines
                      if ln.startswith("TOKEN\t") and "\trefused=" in ln}
    spellings = []
    for ln in lines:
        if not ln.startswith("CASE\traw_token\t"):
            continue
        f = ln.split("\t")
        gives = [x[6:].split(" | ") for x in f[3:] if x.startswith("gives=")]
        if not gives or set(gives[0]) <= refused_tokens:
            continue
        pat = f[2]
        if not re.fullmatch(r'\s*(("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')\s*\|?\s*)+', pat):
            continue        # a pattern, not a spelling (identifiers, numbers, `on error`)
        for a, b in re.findall(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'', pat):
            s = (a or b).replace("\\\\", "\\")
            if s != '"' and s not in spellings:
                spellings.append(s)
    return keywords, live, spellings


def categories(live, spellings):
    words, spells = {}, {}
    for n, ln in enumerate(CATEGORIES.read_text().splitlines(), 1):
        if not ln.strip() or ln.startswith("#"):
            continue
        f = ln.split("\t")
        if len(f) != 3 or f[0] not in ("word", "spelling"):
            raise Stop(f"{CATEGORIES.name}:{n}: a line that is not `word|spelling <tab> x <tab> category`")
        kind, x, c = f
        if kind == "word":
            if c not in WORD_CATEGORIES:
                raise Stop(f"{CATEGORIES.name}:{n}: `{c}` is not a category of words ({', '.join(WORD_CATEGORIES)})")
            words[x] = c
        else:
            if c not in SPELLING_CATEGORIES:
                raise Stop(f"{CATEGORIES.name}:{n}: `{c}` is not a category of spellings")
            spells[x] = c
    for what, have, want in (("word", words, live), ("spelling", spells, spellings)):
        missing = [x for x in want if x not in have]
        if missing:
            raise Stop(f"live {what}s of the lexer with no category in {CATEGORIES.name}: " + ", ".join(missing))
        unknown = [x for x in have if x not in want]
        if unknown:
            raise Stop(f"{CATEGORIES.name} names {what}s the lexer does not give, or that no live form reads: "
                       + ", ".join(unknown))
    return words, spells


def descriptions(keywords):
    """The identifier-like `#### `kw`` sections of 22-keywords.md, checked against the lexer."""
    documented = set(re.findall(r"^#### `([A-Za-z_][A-Za-z0-9_]*)`", KEYWORDS_MD.read_text(), re.M))
    missing = sorted(set(keywords) - documented, key=str.lower)
    if missing:
        raise Stop("words of the lexer with no description (`#### `word``) in 22-keywords.md: " + ", ".join(missing))
    extra = sorted(documented - set(keywords), key=str.lower)
    if extra:
        raise Stop("22-keywords.md describes words the lexer does not have: " + ", ".join(extra))


# ------------------------------------------------------------------------------------------------
# The derived lists
# ------------------------------------------------------------------------------------------------
def prism(text, words, spells):
    low = [w for w in sorted(words, key=str.lower) if w[0].islower()]
    kw = [w for w in low if words[w] != "boolean"]
    bools = [w for w in low if words[w] == "boolean"]
    block = ("    // BEGIN " + MARK + "\n"
             "    keyword: new RegExp(\n"
             "      '\\\\b(?:' +\n"
             "        '" + "|".join(kw) + "' +\n"
             "        ')\\\\b',\n"
             "    ),\n"
             "    boolean: /\\b(?:" + "|".join(bools) + ")\\b/,\n"
             "    // END generated from regression/GRAMMAR.tokens\n")
    text = splice(text, PRISM, r"    // BEGIN generated from regression/GRAMMAR\.tokens, do not[^\n]*\n.*?    // END generated from regression/GRAMMAR\.tokens\n",
                  block)
    # the operators: every live spelling of an operator, the longest first (a JS regex literal)
    ops = sorted((s for s in spells if spells[s] in ("operator", "operator-heyting")), key=lambda s: (-len(s), s))
    lit = "|".join("".join("\\" + c if c in ".^$|?*+()[]{}\\/" else c for c in x) for x in ops)
    block = ("    // BEGIN " + MARK + ": operators\n"
             "    operator: /" + lit + "/,\n"
             "    // END generated from regression/GRAMMAR.tokens: operators\n")
    return splice(text, PRISM, r"    // BEGIN generated from regression/GRAMMAR\.tokens[^\n]*: operators\n.*?    // END generated from regression/GRAMMAR\.tokens: operators\n",
                  block)


def splice(text, path, pattern, block):
    new, n = re.subn(pattern, lambda _m: block, text, count=1, flags=re.S)
    if n != 1:
        raise Stop(f"{path.relative_to(ROOT)}: the markers of the generated list are not there")
    return new


def alt(xs):
    """An alternation of spellings, with only the metacharacters of the regex escaped."""
    return "|".join("".join("\\" + c if c in ".^$|?*+()[]{}\\" else c for c in x) for x in xs)


def json_block(key, value, indent):
    """`"key": value` as the file writes it, two spaces a level, at `indent`."""
    body = json.dumps(value, indent=2, ensure_ascii=False).replace("\n", "\n" + " " * indent)
    return f'"{key}": {body}'


def vscode(text, words, spells):
    by = lambda c: [w for w in sorted(words, key=str.lower) if words[w] == c]
    comment = MARK
    declarations = {
        "comment": "A declaration keyword followed by the name it binds; " + comment,
        "match": "\\b(" + "|".join(by("declaration")) + ")\\s+([A-Za-z_][A-Za-z0-9_]*)",
        "captures": {"1": {"name": "storage.type.yon"}, "2": {"name": "entity.name.type.yon"}},
    }
    pats = []
    for cats in (["control"], ["declaration", "storage"], ["binding"], ["word"],
                 ["constant", "boolean"], ["hott"]):
        ws = sorted((w for w in words if words[w] in cats), key=str.lower)
        pats.append({"comment": comment, "name": SCOPE[cats[0]], "match": "\\b(" + "|".join(ws) + ")\\b"})
    glyph_words = [s for s in spells if spells[s] == "word"]
    if glyph_words:
        pats.append({"comment": comment, "name": SCOPE["word"], "match": alt(glyph_words)})
    keywords = {"patterns": pats}
    lexer_types = {"comment": comment, "name": SCOPE["type"],
                   "match": "\\b(" + "|".join(by("type")) + ")\\b"}
    glyph_types = [s for s in spells if spells[s] == "type"]
    ops = []
    for c in ("operator-heyting", "operator"):
        xs = sorted((s for s in spells if spells[s] == c), key=lambda s: (-len(s), s))
        ops.append({"comment": comment, "name": SCOPE[c], "match": alt(xs)})
    if glyph_types:
        ops.append({"comment": comment, "name": SCOPE["type"], "match": alt(glyph_types)})
    operators = {"patterns": ops}

    def replace_entry(text, key, value, indent):
        start = text.find(f'\n{" " * indent}"{key}": ')
        if start < 0:
            raise Stop(f"{VSCODE.relative_to(ROOT)}: no entry `{key}`")
        i = text.index(":", start) + 1
        while text[i] == " ":
            i += 1
        depth, j, in_str = 0, i, False
        while True:
            ch = text[j]
            if in_str:
                if ch == "\\":
                    j += 2; continue
                if ch == '"':
                    in_str = False
            elif ch == '"':
                in_str = True
            elif ch in "{[":
                depth += 1
            elif ch in "}]":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        return text[:start + 1] + " " * indent + json_block(key, value, indent) + text[j + 1:]

    text = replace_entry(text, "declarations", declarations, 4)
    text = replace_entry(text, "keywords", keywords, 4)
    text = replace_entry(text, "operators", operators, 4)
    # the first pattern of `types` is the types the lexer gives; the second, by hand, is the
    # names of places that no lexer gives (kept for lotto W)
    data = json.loads(text)
    types = data["repository"]["types"]["patterns"]
    hand = [p for p in types if "comment" not in p or MARK not in p.get("comment", "")]
    new_types = {"patterns": [lexer_types] + hand}
    return replace_entry(text, "types", new_types, 4)


def index(text, keywords):
    entries = [f"[`{k}`](/book/keywords#{k.lower()}) ·" for k in sorted(keywords, key=str.lower)]
    entries[-1] = entries[-1][:-2]
    block = ("<!-- BEGIN " + MARK + ": the keyword index -->\n\n" + "\n".join(entries)
             + "\n\n<!-- END generated from regression/GRAMMAR.tokens -->")
    return splice(text, SYNREF, r"<!-- BEGIN generated from regression/GRAMMAR\.tokens[^\n]*-->.*?<!-- END generated from regression/GRAMMAR\.tokens -->",
                  block)


def generate():
    keywords, live, spellings = lexer()
    words, spells = categories(live, spellings)
    descriptions(keywords)
    return {PRISM: prism(PRISM.read_text(), words, spells),
            VSCODE: vscode(VSCODE.read_text(), words, spells),
            SYNREF: index(SYNREF.read_text(), keywords)}


def main() -> int:
    try:
        out = generate()
    except Stop as e:
        print("gen_highlighters stopped: " + str(e), file=sys.stderr)
        return 2
    stale = [p for p, t in out.items() if p.read_text() != t]
    if "--check" in sys.argv[1:]:
        if stale:
            print("stale, generated from regression/GRAMMAR.tokens: "
                  + ", ".join(str(p.relative_to(ROOT)) for p in stale) + f". Run: {COMMAND}", file=sys.stderr)
            return 1
        print("the lists of the highlighters are current")
        return 0
    for p in stale:
        p.write_text(out[p])
    print("wrote " + (", ".join(str(p.relative_to(ROOT)) for p in stale) if stale else "nothing: all current"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
