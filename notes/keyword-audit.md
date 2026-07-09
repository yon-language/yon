# Yon keyword audit — anchored, analysis-only

**Method.** Every row is anchored to the live code, not memory. The keyword list
is extracted from `frontend/lexer.mll`:

```
grep -nE '^\s*"[a-z_]+",\s*[A-Z_]+;' frontend/lexer.mll     # 116 word-keywords
```

For each keyword: **grammar-use** = occurrences of its TOKEN in a real production
of `frontend/parser.mly` (total token lines minus the `%token` declaration);
**example-use** = whole-word count across every `*.yon` under `examples/` and
`regression/`. Nothing in `frontend/lexer.mll` or `frontend/parser.mly` was
modified — this is analysis. Date: 2026-07-09.

**Guiding principle applied.** The yardstick is a *usable and explainable*
surface, not power. A keyword that isn't explainable in one line, or that
duplicates a concept already covered, is surface noise — flagged below, not
removed (surface decisions stay with the author).

---

## Executive summary

| metric | value |
|---|---|
| total surface keywords | **116** |
| true orphans (token never in a production) | **0** |
| unexercised (in grammar, 0 `.yon` example) | **0** |
| `TIENI` (keep) | 97 |
| stub-only (only the syntax-triangle example, ≤2 uses) | 11 |
| consolidation candidates (redundant concept) | 6 |
| retired surface forms still tokenised | 2 |

**Two structural facts, both anchored:**

1. **No dead tokens.** Every one of the 116 tokens appears in at least one
   `parser.mly` production. The grammar carries no orphan tokens.
2. **No unexercised keywords.** Every keyword appears in at least one `.yon`
   source. This is *not* luck — it is enforced by the **syntax-triangle gate**
   (`regression/test_syntax_triangle.py` + `CANONICAL-FORMS.md` +
   `SYNTAX-TRIANGLE.md`): adding a keyword without a corpus example and a book
   entry fails CI. So Tables A and C below are **empty by construction** — a
   genuine strength worth stating plainly.

The real surface-noise signal is therefore not "orphans" but **redundancy** and
**stub-only usage**: keywords that exist and parse and have exactly one
hand-made example, but no organic use anywhere in the corpus.

---

## Table A — ORPHANS (token never used in a production → removal candidates)

**Empty.** No token in `frontend/lexer.mll` is absent from `frontend/parser.mly`
productions. (Verified: for every token, `grep -wE "$TOK" parser.mly | grep -vE '^\s*%'`
returns ≥1 line.)

## Table B — REDUNDANT (same concept, multiple keywords → consolidation PROPOSALS)

Consolidation is a **proposal**; the author decides. Counts are example-uses.

| cluster | keywords (example-uses) | proposal |
|---|---|---|
| **morphism family** | `morph`(18) · `morphism`(15) · `functor`(15) · `view`(13) · `geomorph`(6) · `morphisms`(4) · `functorial`(2) | Six-plus words for "structure-preserving map between places". `morph`/`morphism`/`functor` are each well-used and arguably distinct (1-cell vs named decl vs functor); but `morphisms`(4), `geomorph`(6), `functorial`(2) are thin — candidates to fold into `morphism`/`functor`. |
| **law / verification** | `law`(11) · `verify`(4) · `lawful`(2) · `invertible`(2) | `lawful` and `invertible` (2 each) duplicate what `law`/`verify` already express — fold in. |
| **co/limits** | `pullback`(4, retired) · `pushout`(2, retired) · `pull`(8) · `push`(22) | `pullback`/`pushout` surface forms are **retired** (`surface_ast.ml`: "EPullback/EPushout retired surface form, no longer produced") yet still tokenised — see Table D. |
| **nat / transform** | `nat`(2) | `nat` (natural-transformation keyword) is stub-only; overlaps the `morph`/`functor` machinery. |
| **naming collision (NOT true redundancy)** | `comp`(6, cubical) · `compose`(3, morphism) · `hcomp`(3, cubical) | Semantically distinct (cubical composition vs morphism composition vs homogeneous composition) but the similar names read as noise to a newcomer. Keep, but document the distinction. |

## Table C — UNEXERCISED (in grammar, 0 examples → "needs an example")

**Empty**, by the syntax-triangle gate (every keyword has at least one corpus
example). The nearest analogue is *stub-only* usage below.

## Table D — STUB-ONLY & RETIRED (declared, parses, but ≤2 corpus uses)

These parse and typecheck but have only their mandated triangle example — no
organic use. The clearest "reconsider" set under the usable-and-explainable
principle.

| keyword | example-uses | note |
|---|---|---|
| `converts` | 1 | merge-move field law; overlaps `maps`/`aggregates` |
| `requires` | 1 | overlaps `uses`/effect declarations |
| `partial` | 1 | function modifier; genuinely rare, not redundant |
| `adjunction` | 2 | categorical decl, no organic use |
| `terminal` | 2 | terminal-object decl, no organic use |
| `topology` | 2 | Grothendieck-topology decl, no organic use |
| `unifies` | 2 | merge-move; single example |
| `aggregates` | 2 | merge-move field law |
| `bi` | 2 | bidirectional reduction modifier |
| `multishot` | 2 | continuation modifier |
| `internal` | 2 | visibility modifier |
| `functorial` | 2 | → consolidate (Table B) |
| `lawful` / `invertible` | 2 / 2 | → consolidate (Table B) |
| `nat` | 2 | → consolidate (Table B) |
| `pullback` / `pushout` | 4 / 2 | **retired** surface forms, still tokenised |

---

## Full per-keyword table (116 rows)

Columns: keyword · category · token · grammar-rule-uses · example-uses · verdict.

| keyword | category | token | rules | examples | verdict |
|---|---|---|---|---|---|
| `absent` | HoTT-cubical | ABSENT | 2 | 6 | TIENI |
| `adjunction` | morphism | ADJUNCTION_KW | 1 | 2 | STUB-ONLY (rivedere) |
| `aggregates` | morphism | AGGREGATES | 2 | 2 | STUB-ONLY (rivedere) |
| `algebra` | verification | ALGEBRA | 1 | 6 | TIENI |
| `and` | control | AND | 12 | 86 | TIENI |
| `as` | other | AS | 2 | 27 | TIENI |
| `at` | effects/space | AT | 1 | 43 | TIENI |
| `backward` | reduction | BACKWARD | 1 | 3 | TIENI |
| `be` | binder | LET | 3 | 2819 | TIENI |
| `bi` | reduction | BI | 1 | 2 | STUB-ONLY (rivedere) |
| `by` | other | BY | 8 | 43 | TIENI |
| `cell` | ontology/base | CELL | 1 | 23 | TIENI |
| `comp` | HoTT-cubical | COMP | 1 | 6 | TIENI |
| `compose` | morphism | COMPOSE | 1 | 3 | TIENI |
| `converts` | morphism | CONVERTS | 2 | 1 | STUB-ONLY (rivedere) |
| `do` | control | DO_KW | 2 | 130 | TIENI |
| `drop` | effects/space | DROP | 3 | 3 | TIENI |
| `each` | other | EACH | 1 | 17 | TIENI |
| `effects` | effects/space | EFFECTS | 1 | 6 | TIENI |
| `el_match` | HoTT-cubical | EL_MATCH | 1 | 3 | TIENI |
| `else` | control | ELSE_KW | 1 | 100 | TIENI |
| `emit` | effects/space | EMIT | 1 | 39 | TIENI |
| `error` | verification | ERROR_KW | 2 | 11 | TIENI |
| `every` | effects/space | EVERY | 2 | 20 | TIENI |
| `exact` | morphism | EXACT_KW | 2 | 16 | TIENI |
| `fold` | reduction | FOLD | 5 | 27 | TIENI |
| `for` | effects/space | FOR | 3 | 46 | TIENI |
| `forces` | effects/space | FORCES | 1 | 3 | TIENI |
| `forever` | effects/space | FOREVER | 1 | 4 | TIENI |
| `forward` | reduction | FORWARD | 1 | 3 | TIENI |
| `from` | other | FROM | 12 | 76 | TIENI |
| `fst` | HoTT-cubical | FST | 1 | 11 | TIENI |
| `fun` | binder | FUN | 7 | 570 | TIENI |
| `functor` | morphism | FUNCTOR | 2 | 15 | TIENI |
| `functorial` | morphism | FUNCTORIAL | 2 | 2 | CONSOLIDARE (morfismi) |
| `geomorph` | morphism | GEOM_MORPHISM | 1 | 6 | CONSOLIDARE (morfismi) |
| `hcomp` | HoTT-cubical | HCOMP | 1 | 3 | TIENI |
| `here` | effects/space | HERE | 1 | 12 | TIENI |
| `heyting` | HoTT-cubical | HEYT_INT_KW | 3 | 7 | TIENI |
| `hit` | HoTT-cubical | HIT_KW | 2 | 17 | TIENI |
| `hit_elim` | HoTT-cubical | HIT_ELIM | 1 | 14 | TIENI |
| `holds` | binder | HOLDS | 3 | 2802 | TIENI |
| `if` | control | IF_KW | 1 | 102 | TIENI |
| `import` | other | IMPORT | 4 | 18 | TIENI |
| `in` | other | IN | 7 | 92 | TIENI |
| `ind_path` | HoTT-cubical | IND_PATH | 1 | 4 | TIENI |
| `internal` | other | INTERNAL | 1 | 2 | STUB-ONLY (rivedere) |
| `invertible` | verification | INVERTIBLE | 1 | 2 | CONSOLIDARE (law/verify) |
| `is` | control | IS | 7 | 177 | TIENI |
| `iter` | control | ITER_KW | 1 | 120 | TIENI |
| `law` | verification | LAW | 2 | 11 | TIENI |
| `lawful` | verification | LAWFUL | 1 | 2 | CONSOLIDARE (law/verify) |
| `list` | ontology/base | LIST | 1 | 12 | TIENI |
| `map` | ontology/base | MAP | 5 | 16 | TIENI |
| `maps` | morphism | MAPS | 2 | 7 | TIENI |
| `morph` | morphism | MORPH_KW | 3 | 18 | TIENI |
| `morphism` | morphism | MORPHISM_KW | 6 | 15 | TIENI |
| `morphisms` | morphism | MORPHISMS_KW | 1 | 4 | CONSOLIDARE (morfismi) |
| `most` | effects/space | MOST | 1 | 4 | TIENI |
| `move` | morphism | MOVE | 4 | 16 | TIENI |
| `multishot` | effects/space | MULTI_SHOT | 1 | 2 | STUB-ONLY (rivedere) |
| `nat` | ontology/base | NAT | 1 | 2 | CONSOLIDARE (nat/transform) |
| `new` | ontology/base | NEW | 2 | 48 | TIENI |
| `not` | control | NOT | 6 | 58 | TIENI |
| `of` | other | OF | 10 | 140 | TIENI |
| `operation` | ontology/base | OPERATION | 2 | 8 | TIENI |
| `or` | control | OR | 8 | 20 | TIENI |
| `otherwise` | effects/space | OTHERWISE | 3 | 9 | TIENI |
| `over` | morphism | OVER | 3 | 30 | TIENI |
| `pair` | HoTT-cubical | PAIR | 1 | 14 | TIENI |
| `parallel` | effects/space | PARALLEL | 1 | 8 | TIENI |
| `partial` | other | PARTIAL | 1 | 1 | STUB-ONLY (rivedere) |
| `place` | ontology/base | PLACE | 4 | 287 | TIENI |
| `plam` | HoTT-cubical | PLAM | 3 | 15 | TIENI |
| `present` | HoTT-cubical | PRESENT | 2 | 7 | TIENI |
| `produce` | effects/space | PRODUCE | 2 | 25 | TIENI |
| `promote` | effects/space | PROMOTE | 1 | 3 | TIENI |
| `prop` | ontology/base | PROP_KW | 2 | 10 | TIENI |
| `pull` | morphism | PULL | 2 | 8 | TIENI |
| `pullback` | morphism | PULLBACK | 2 | 4 | RIVEDERE (retired) |
| `push` | morphism | PUSH | 5 | 22 | TIENI |
| `pushout` | morphism | PUSHOUT | 1 | 2 | RIVEDERE (retired) |
| `quote` | HoTT-cubical | QUOTE | 1 | 10 | TIENI |
| `reduction` | reduction | REDUCTION | 3 | 9 | TIENI |
| `refl` | HoTT-cubical | REFL | 1 | 27 | TIENI |
| `repeat` | effects/space | REPEAT | 1 | 5 | TIENI |
| `requires` | verification | REQUIRES | 1 | 1 | STUB-ONLY (rivedere) |
| `resolves` | morphism | RESOLVES | 1 | 4 | TIENI |
| `return` | control | RETURN | 2 | 586 | TIENI |
| `scope` | effects/space | SCOPE | 2 | 10 | TIENI |
| `sequence` | effects/space | SEQUENCE | 2 | 3 | TIENI |
| `share` | morphism | SHARE | 1 | 6 | TIENI |
| `show` | other | SHOW | 3 | 18 | TIENI |
| `snd` | HoTT-cubical | SND | 1 | 8 | TIENI |
| `space` | ontology/base | SPACE | 2 | 13 | TIENI |
| `spawn` | effects/space | SPAWN | 2 | 7 | TIENI |
| `stream` | ontology/base | STREAM | 3 | 24 | TIENI |
| `subcontains` | ontology/base | SUBCONTAINS | 1 | 6 | TIENI |
| `terminal` | ontology/base | TERMINAL_KW | 1 | 2 | STUB-ONLY (rivedere) |
| `then` | control | THEN_KW | 1 | 112 | TIENI |
| `times` | effects/space | TIMES | 1 | 8 | TIENI |
| `to` | other | TO | 20 | 137 | TIENI |
| `topology` | ontology/base | TOPOLOGY | 1 | 2 | STUB-ONLY (rivedere) |
| `topos` | ontology/base | TOPOS_KW | 1 | 91 | TIENI |
| `unifies` | morphism | UNIFIES | 1 | 2 | STUB-ONLY (rivedere) |
| `unknown` | HoTT-cubical | UNKNOWN | 2 | 18 | TIENI |
| `uses` | verification | USES | 1 | 4 | TIENI |
| `verify` | verification | VERIFY | 1 | 4 | TIENI |
| `via` | other | VIA_KW | 1 | 24 | TIENI |
| `view` | morphism | VIEW | 3 | 13 | TIENI |
| `visits` | effects/space | VISITS | 1 | 149 | TIENI |
| `when` | effects/space | WHEN | 6 | 18 | TIENI |
| `where` | other | WHERE | 3 | 90 | TIENI |
| `while` | control | WHILE_KW | 1 | 11 | TIENI |
| `wire` | effects/space | WIRE | 1 | 14 | TIENI |
| `with` | other | WITH | 3 | 50 | TIENI |

---

## Closing note

Of 116 keywords, **97 are `TIENI`** (well-used, distinct), **0 are orphans**,
**0 are unexercised** — the grammar is clean and the syntax-triangle gate keeps
every keyword pinned to a corpus example. The surface noise is concentrated in
**~17 keywords**: 11 stub-only (one hand-made example, no organic use), 4
consolidation candidates in the morphism/law families, and 2 retired co/limit
forms (`pullback`/`pushout`) still tokenised.

**Single biggest surface-noise finding:** the **morphism family** —
`morph`/`morphism`/`morphisms`/`geomorph`/`functor`/`functorial`/`view` — carries
seven near-synonymous keywords for "structure-preserving map". Three of them
(`morphisms`, `geomorph`, `functorial`) are thin (≤6 uses, `functorial` only its
stub). Under the *usable-and-explainable* principle, a newcomer cannot tell them
apart in one line — this cluster is the prime candidate for consolidation, and
the first place the surface would get simpler without losing expressiveness.

(Surface decisions stay with the author; `frontend/lexer.mll` and
`frontend/parser.mly` were not modified.)
