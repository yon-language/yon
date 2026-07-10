# Yon surface review — cleanup, correctness, metonymic re-imagining

Companion to `notes/keyword-audit.md` (the 116-keyword anchored table). This
adds three lenses the audit didn't: **(4)** which stubs/redundants to cut,
**(3)** whether constructs are *used correctly* (not just present), **(2)** the
metonymic re-map, domain by domain. All anchored to the live tree; analysis
only, no lexer/grammar changed. Order follows the review plan: 4 → 3 → 2.

---

> **CORRECTION (verified against the grammar + semantics, 2026-07-10).** The
> "consolidate the morphism family / `nat` / `pullback`-`pushout`" proposals below
> were based on name-similarity and low usage counts — NOT verified semantics. On
> inspection they are WRONG: `morph` (1-cell), `morphism` (decl), `morphisms {}`
> (block container), `geomorph` (a geometric morphism, its own concept with
> dedicated examples), `functor` (decl), `functorial` (a *modifier*), `view`
> (representable) are **seven distinct categorical roles**, not synonyms. `nat` is
> unambiguous (a natural transformation, `nat kind N from S to T`). `pullback`/
> `pushout` tokens are LIVE (`place P = pullback(f,g)`, the `pullback(f,g,a,b)`
> value) — only the dead `EPullback`/`EPushout` AST nodes are vestiges. **Net: the
> surface is well-designed; nothing here should be consolidated.** The proposals
> below are kept for the record, struck through in intent.

## Part 4 — Stub-only & redundant → consolidate or cut

Two clean-up piles. Counts are corpus example-uses (from the audit).

### 4a. Redundant families (consolidation *proposals* — author decides)

**Morphism family — the single biggest surface noise.** Seven near-synonyms for
"structure-preserving map between places":

| keyword | uses | role today | proposal |
|---|---|---|---|
| `morph` | 18 | 1-cell / morphism lambda | **keep** — the core word |
| `morphism` | 15 | named morphism declaration | **keep** — the declaration form |
| `functor` | 15 | functor declaration | **keep** — genuinely distinct (functor ≠ morphism) |
| `view` | 13 | representable `Hom(-,P)` | **keep** — distinct concept, well-used |
| `geomorph` | 6 | geometric morphism | **fold into `morphism geometric`** or a modifier — 6 uses, a special case of morphism |
| `morphisms` | 4 | plural in a `morphisms { }` block | **fold into `morphism`** — plural-vs-singular is not a concept |
| `functorial` | 2 | functoriality marker | **fold into `functor`** (a `functor` is functorial by definition) |

Net: 7 → 4 words, with `geomorph`/`morphisms`/`functorial` (≤6 uses each) becoming
modifiers or dropping. Both a correctness win (fewer overlapping concepts) and a
legibility win (a newcomer can't tell 7 apart in one line).

**Law / verification family:**

| keyword | uses | proposal |
|---|---|---|
| `law` | 11 | **keep** |
| `verify` | 4 | **keep** |
| `lawful` | 2 | **fold into `law`** — "lawful" is what having a `law` means |
| `invertible` | 2 | **fold into `verify invertible`** or a `law` — a property to check, not its own keyword |

**Co/limits:** `pull`(8)/`push`(22) **keep** (well-used, metonymic); `pullback`(4)/
`pushout`(2) are **retired surface forms still tokenised** — see Part 3, drop the tokens.

### 4b. Stub-only (≤2 corpus uses — one hand-made example, no organic use)

| keyword | uses | verdict |
|---|---|---|
| `adjunction` | 2 | advanced categorical decl — **keep as advanced, or drop** if never used organically |
| `terminal` | 2 | terminal-object decl — same |
| `topology` | 2 | Grothendieck-topology decl — same |
| `nat` | 2 | **ambiguous**: natural-transformation vs natural-number. **Disambiguate** (rename one) |
| `unifies` | 2 | merge-move (`Merge unifies A, B`) — keep (it names a real op) |
| `aggregates` | 2 | merge-move field law — keep (paired with `maps`/`converts`) |
| `converts` | 1 | merge-move field law — **fold into `maps … by`**? overlaps |
| `requires` | 1 | **fold into `uses`** — effect/capability dependency, overlaps |
| `bi` | 2 | bidirectional reduction modifier — keep (a real modifier) |
| `multishot` | 2 | continuation modifier — keep (a real modifier) |
| `internal` | 2 | visibility modifier — keep (a real modifier) |
| `partial` | 1 | function modifier — keep (genuinely rare, not redundant) |

The modifiers (`bi`/`multishot`/`internal`/`partial`) are low-use but *not*
redundant — they name real switches. The candidates to actually cut are the
unexercised categorical decls (`adjunction`/`terminal`/`topology`) if they carry
no organic weight, and the `nat` ambiguity to fix.

---

## Part 3 — Are constructs used *correctly*? (not just present)

The audit showed **0 orphan tokens** and **0 unexercised keywords** (syntax-triangle
gate). The correctness gaps are elsewhere: **dead AST forms** and **semantic
overlap**.

### 3a. Dead surface forms (AST node kept for exhaustive matches, never produced)

Anchored to `surface_ast.ml` comments + a parser grep (constructor never emitted
by a production):

| node | status | action |
|---|---|---|
| `ENewIn` / `SNewIn` | retired — `new P in Space` removed in v1.1 (a place's space is its filesystem dir) | dead; drop when convenient |
| `EPullback` / `EPushout` | "retired surface form, no longer produced" | dead; **also drop the `pullback`/`pushout` tokens** (Part 4a) |
| `SAssignBecomes` | the `becomes` token is retired; node is internal-only (`x = e` is the surface) | internal-only, fine |
| `EAll` | `all P where cond` removed in v1.1; 2 lingering parser refs | verify + drop the dead production |

These aren't bugs — they're vestiges kept for `match` exhaustiveness. But they're
surface *noise* in the AST and a reader trips on them. Low-risk cleanup.

### 3b. Semantic coherence

- **Morphism family** (Part 4a): 7 keywords, overlapping semantics — the clearest
  "used, but the *set* is incoherent" finding.
- **`nat`**: one token, two meanings (natural transformation / natural number).
  A real correctness smell — disambiguate.
- **`comp` / `compose` / `hcomp`**: three similarly-named composition keywords that
  are *semantically distinct* (cubical / morphism / homogeneous). Correct, but the
  naming collision misleads. Document the distinction (done for `comp`/`hcomp` in
  the keyword book; `compose` could cross-reference).
- Everything else in the audit: used in a real production, exercised by a corpus
  example (the triangle enforces it). No mis-used survivors found.

---

## Part 2 — The metonymic map, domain by domain

The finding that matters: **Yon is already metonymic in four coherent fields.**
The cubical layer was the one Lisp-island; the journey vocabulary closed it. The
rest already speaks — re-imagining it wholesale would *hurt* (familiarity is a
feature in three zones). So this is a map of *what already works*, *what to
sharpen*, and *what to leave*.

### Fields that already cohere (leave the metaphor, at most sharpen)

| field | metaphor | keywords | verdict |
|---|---|---|---|
| **cubical / paths** | **journey** | `stay` `back` `carry…along` `span` `++` `<=>` `match` `through` | ✅ done this session |
| **ontology** | **geography** | `place` `space` `topos` `world` `cell` `new` | ✅ coherent — an *object* is a *place* in the topos |
| **effects / space** | **industry & wiring** | `wire to` `produce` `emit` `spawn` `drop` `visits` `promote` | ✅ coherent — cabling, a production line, emitting, dropping |
| **morphisms** | **movement / mapping** | `move from…to…by` `pull` `push` `over` `view` | ⚠️ coherent *core*, noisy *edges* (Part 4a) |

The prize connection, already true: `move x from A to B by law` (place transport)
and `carry x along bridge` (cubical transport) **share the journey verb** — the
two levels rhyme. Keep and lean into it.

### Zones to leave familiar (do *not* metonymize — familiarity is the feature)

- **Binder `be x holds e` / `x = e`** — keep. It's already metonymic (the variable
  *holds* the value) and it gives Yon character. `be … holds` reads as declarative
  English. Reassignment `x = e` is universal. Leave both.
- **Generics `fun f<T>(x: T): T`** — keep. Angle-bracket generics read instantly to
  anyone from Rust/TS/Swift. Metonymizing them would trade legibility for nothing.
- **Control `if/then/else`, `iter`, `while`, `for`, `every`, `repeat`** — keep.
  Control flow wants to be *invisible*. A new construct (`match` on a HIT) earns an
  evocative name; an `if` does not.

### Targeted opportunities (worth doing — Part 4 + a sharpen)

1. **Morphism-family consolidation** (Part 4a): 7 → 4, edges become modifiers.
   The one change that improves correctness *and* charm.
2. **`nat` disambiguation** (Part 3b): split the two meanings.
3. **Retired-form/token cleanup** (Part 3a): drop dead nodes + `pullback`/`pushout`
   tokens.

### Optional evocative touches (nice-to-have, low priority)

- Bare HIT constructors: `base` instead of `hit(base)` inside `match` — makes
  `match x { base => .. }` read perfectly (the part naming the whole). Small
  parser change, high polish. (Flagged at end of the metonymic-renaming work.)
- `new P { … }` → an indefinite-article form `a P { … }` reads like natural
  language ("a Circle with …") — but `new` is universally understood; marginal.

---

## Bottom line for the conversation

The honest conclusion isn't "re-imagine everything" — it's that **Yon is already
a metonymic language in four coherent fields, and three zones rightly stay
familiar.** The real work is *targeted*: consolidate the morphism family (7→4),
fix the `nat` ambiguity, and clear the retired vestiges. That sharpens both
correctness and charm without breaking the parts that already work — and without
drifting toward novelty-for-its-own-sake.

Recommended order when we implement (all touch lexer/grammar → after we talk):
**morphism consolidation** first (biggest win), then **`nat` split**, then the
**retired-form cleanup** (lowest risk, do anytime).
