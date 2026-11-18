# The flow of the sources and the derived files

Every file of the syntax is one of two kinds:

- a **source**: written by hand, in one place;
- a **derived file**: generated from its sources, never edited by hand. The gate regenerates it and
  compares it byte for byte.

Nothing is half of each. A file that holds a derived list among hand-written text (a highlighter, a
page of the site) keeps the derived list between two markers that say
`generated from regression/GRAMMAR.tokens, do not edit`, and only the text outside them is a source.

One command rewrites every derived file, and the gate checks them all in tier 0:

```
python3 tools/regen.py            # rewrite every derived file
python3 tools/regen.py --check    # name each stale file and the command that rewrites it
```

## The sources

| source | what it says |
|---|---|
| `frontend/lexer.mll` | the tokens, their spellings, the states and the choices of context of the lexer |
| `frontend/parser.mly` | the grammar, the `%token` declarations, the refusals of the parser |
| `tools/keyword_categories.txt` | the category of each word and each spelling, for the highlighters |
| `website/docs/book/22-keywords.md` | the description of each word (its `#### `word`` section) |
| the text outside the markers of the highlighters | comments, strings, scopes, style |
| `frontend/error_codes.ml` | the diagnostic codes, their titles and severities |
| `regression/refusals/catalogue.py` | the catalogue of refusals: every form Yon refuses, with its code, message, why, how the right form is written, and its proofs |
| `regression/canonical_forms/` | the canonical form of each construct and its refusal proofs, each with its `.expect` |

## The derived files

| derived | from | generator | checked by |
|---|---|---|---|
| `regression/GRAMMAR.ebnf` | `frontend/parser.mly` | Obelisk 0.8.1, through `python3 regression/test_grammar_guard.py` | `test_grammar_guard.py` (registered, the version of Obelisk); gate 0 |
| `regression/GRAMMAR.tokens` | `frontend/lexer.mll`, and `frontend/parser.mly` for `%token` and for the tokens every production refuses | `regression/lexer_census.py`, through `python3 regression/test_grammar_guard.py` | `test_grammar_guard.py`: registered; every `%token` is given by a rule, every token given is declared; a form the census cannot read stops it; a changed condition changes the file; gate 0 |
| the keyword, boolean and operator lists of Prism, `website/src/theme/prism-include-languages.js` (site and book) | `regression/GRAMMAR.tokens`, `tools/keyword_categories.txt` | `python3 tools/gen_highlighters.py` | `test_website_surface.py`, `test_gen_highlighters.py`; gate 0 |
| the declarations, keywords, lexer types and operators of `lsp/editors/vscode/syntaxes/yon.tmLanguage.json` (the marker is the key `"comment"`) | the same | the same | the same |
| the keyword index of `website/docs/syntax-reference.md` | `regression/GRAMMAR.tokens` (the list), `22-keywords.md` (the descriptions) | the same | `test_keyword_docs.py`, `test_gen_highlighters.py`; gate 0 |
| `regression/refusals/CATALOGUE.md` and the drafts of the refusal proofs, `regression/refusals/drafts/` | `regression/refusals/catalogue.py`, with the codes and titles of `frontend/error_codes.ml` and the state of `NO_PRODUCER` (`regression/test_error_codes.py`) | `python3 regression/refusals/catalogue.py` | `test_refusal_catalogue.py`: both ways, every entry has a refusal proof in `regression/canonical_forms/` (or a draft, or the reason its proof cannot be written yet) and every refusal proof has its entry; every code is registered; gate 0 |
| the railroad diagrams of the grammar | `regression/GRAMMAR.ebnf` | the Railroad Diagram Generator (an external tool) | outside the gate |

A word enters a highlighter only if the lexer gives it and some production of the parser reads it
(no `refused=` in `GRAMMAR.tokens`): a form that is gone stops being colored by itself. The keyword
index lists every word of the lexer, refused ones included, since `22-keywords.md` documents what
was refused and why.

## Not derived yet

- The lexer of the self-host (`selfhost/selfhost_compiler.yon`, the `lex_*` functions) is to be
  compared with the same `regression/GRAMMAR.tokens` (step F1.6.1 of the syntax plan).
- The list of the primitive types of the VS Code grammar (`number`, `money`, `address`, …) is not
  from the lexer: it is written by hand, kept for the publication of the site.
- A draft of `regression/refusals/drafts/` becomes a refusal proof of `regression/canonical_forms/`
  when the compiler refuses its form: the entry then names the folder among its proofs, and the
  draft leaves.

## Local reports

`regression/CANONICAL-FORMS.md` (`python3 regression/test_canonical_forms.py`) and
`regression/SYNTAX-TRIANGLE.md` (`python3 regression/test_syntax_triangle.py`) are derived too, but
not kept in git: each test rewrites its report and checks it.
