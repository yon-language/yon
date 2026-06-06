# Yon keywords, a reasoned census

Every reserved word of the surface language, what it does, and whether a
compiling example in `examples/` exercises it. This file is kept in sync
with `frontend/lexer.mll` (the single source of truth for the keyword
table) and with the regression corpus.

Status legend:

- `example`: at least one program in `examples/` uses it and runs in the
  regression suite
- `wired`: implemented through the pipeline but not yet exercised by an
  example (micro-example pending)
- `parse-only`: recognized by the parser, no semantics yet (honestly
  flagged in the syntax reference)

Counts: 115 unique reserved words. Two-word contextual phrases and
duration suffixes are listed at the end; they are not reserved words.

## Top-level declarations

A Yon program is a list of these.

| Keyword | Status | What it does |
|---|---|---|
| `world` | example | Declares a category: a collection of objects and the structure-preserving maps between them |
| `place` | example | An object living in a world; fields, and operations when `with effects` |
| `space` | example | A runtime heap where instances of a place are allocated and addressed |
| `import` | example | Imports a module (`import "x/rates"`) or a qualified symbol |
| `internal` | example | Marks a function as not exported cross-Space |

## The four kinds of handle

Static structures of the topos: they compose but do not nest.

| Keyword | Status | What it does |
|---|---|---|
| `fun` | example | Ordinary function; also the inline lambda form |
| `move` | example | A map between two places (`move m from A to B`); the body is a list of mapping clauses |
| `view` | example | A representable functor on a place (`view V of P { show ... }`) |
| `reduction` | wired | Folds a structure to a value (`reduction(acc, x) => e of P`) |
| `operation` | example | A method exposed by a place; carries an effect |
| `cell` | example | A higher cell inside a place (CaTT style) |

## Categorical constructions

New objects from old ones, named after their universal property.

| Keyword | Status | What it does |
|---|---|---|
| `geomorph` | example | Geometric morphism between two worlds: the adjoint pair `pull`/`push` |
| `pull` | example | Inside a geomorph: the inverse image f*, the left adjoint |
| `push` | wired | Inside a geomorph: the direct image f lower star, the right adjoint |
| `pullback` | wired | Limit: glues two maps over a shared target |
| `pushout` | wired | Colimit: glues two maps under a shared source |
| `over` | example | Slice category: `place P over X`, objects equipped with a chosen map down to X |
| `topology` | wired | Equips a world with a notion of covering (Grothendieck / Lawvere-Tierney topology) |

## Functors and directions

| Keyword | Status | What it does |
|---|---|---|
| `functor` | example | A map between worlds preserving the categorical structure |
| `functorial` | wired | Marks an operation that behaves as a functor |
| `forward` | example | Reduction direction: forward |
| `backward` | wired | Reduction direction: backward |
| `bi` | wired | Bidirectional reduction (reserved word, see reference) |

## Certified algebra

| Keyword | Status | What it does |
|---|---|---|
| `algebra` | example | Names an algebra from the certified catalog (`uses algebra Additive`) |
| `uses` | example | Binds an operation to its algebra |
| `law` | example | Declares an algebraic law; the compiler verifies it against the catalog and rejects a false claim |
| `lawful` | wired | Reduction modifier: declared and verified law |
| `invertible` | wired | Reduction modifier: invertible |
| `solve` | example | Instantiates a law-verified place as a runnable handle |
| `fold` | example | Names a space's fold function (`with fold "sum_f64"`) |

## The explicit topos vocabulary

| Keyword | Status | What it does |
|---|---|---|
| `topos` | example | First-class declaration: a category rich enough to do logic inside |
| `objects` | wired | Lists the objects of the topos |
| `morphisms` | wired | Lists the maps of the topos |
| `terminal` | wired | The one-point object |
| `prop` | example | Subobject classifier: a map into Omega (`prop is_overdrawn(s): proposition = ...`) |
| `morph` | wired | Declares a single map (functor) between topoi; body uses `on object` / `on morphism` |
| `via` | example | In `on morphism op via op2`: which operation realizes the map |
| `each` | example | In `for each X by fnX` inside a nat transform: one component per object |

## Geometric-morphism clauses

| Keyword | Status | What it does |
|---|---|---|
| `adjunction` | wired | Declares the geomorph's adjoint pairing |
| `exact` | wired | In `exact pull` / `exact push`: the inverse image preserves finite limits |

## Error model

| Keyword | Status | What it does |
|---|---|---|
| `error` | example | `error E extends Base { }`: an error is a place that is a subobject of Base |
| `extends` | example | Subobject mono `P into B`; every E is a Base |

## Binding and mutation

| Keyword | Status | What it does |
|---|---|---|
| `be` | example | `be x holds e`: the only binding form, immutable (there is no `let`) |
| `holds` | example | The "=" of the binding |
| `becomes` | example | Cell mutation (`x becomes e`); rebinding does not exist |
| `partial` | example | Partial function: may not return |

## Connectives and type words

These read as English in declarations.

| Keyword | Status | What it does |
|---|---|---|
| `of` | example | `list of T`, `view of P`, `reduction ... of P` |
| `in` | example | `place P in W`, `space S in W`, `for every x in e` |
| `to` | example | `move m from A to B`, `maps to`, `resolves to` |
| `from` | example | Source of move/morph/geomorph/import |
| `by` | example | `A maps to B by f`: the function realizing the clause |
| `is` | example | Pattern condition: `e is pattern` (a variable, a literal, `present`/`absent`/`unknown`) |
| `not` | wired | Pattern negation: `e is not pattern` |
| `list` | wired | The list type: `list of T` |
| `map` | example | The map type: `map of K to V` |
| `stream` | example | The stream type: `stream of T`, plus modifiers |
| `with` | example | `with effects`, `with multishot`, `with fold`, `compose h1 with h2` |
| `compose` | example | Handle composition, `(compose f with g)(x) = g(f(x))`; kind discipline enforced |
| `effects` | example | `place P with effects { }`: the place exposes operations |
| `requires` | example | `move m ... requires CAP1, CAP2`: required capabilities |
| `init` | example | `init X as Space`: initializes a Space |
| `unifies` | wired | Merge move: `move m unifies A, B { }` merges two places field by field |
| `share` | wired | In the merge move: shared fields, no conflict |
| `resolves` | example | `conflict on f resolves to fn`: the conflict-resolution function |
| `heyting` | wired | `heyting<N>` / `heyting(v, mask)`: an integer in Heyting (intuitionistic) arithmetic, trits with an Unknown mask |

## Stream back-pressure

| Keyword | Status | What it does |
|---|---|---|
| `buffer` | wired | `buffer N`: bounds the stream queue |
| `drop` | wired | `drop oldest` / `drop newest`: drop policy (the policy word is contextual) |

## Control flow

| Keyword | Status | What it does |
|---|---|---|
| `when` | example | Conditional chain `when c { } otherwise { }`; branches are for effects, an inner `return` does not exit the function |
| `otherwise` | example | The else branch of `when` and of `repeat` |
| `if` `then` `else` | example | Expression-level conditional (selects values); lowers to `scf.if` |
| `iter` | example | `iter N do { }`: bounded loop, always terminates |
| `while` | example | `while cond do { }`: general loop, may not terminate |
| `do` | example | Introduces the body of `iter`/`while` |
| `for` `every` | example | `for every x in e { }`: iteration over a List (1.0 executes sequentially) |
| `here` | wired | `when here`: Space filter on the iteration (declared intent, not yet a runtime distinction) |
| `sequence` | example | `in sequence over x in e { }`: explicit sequential iteration |
| `repeat` `at` `most` `times` | example | `repeat at most N times { } [otherwise { }]`: the body runs N times, then the otherwise |
| `forever` | example | Infinite loop (`while present`); typically paired with effects |
| `scope` | example | Formally hermetic block: an MLIR `IsolatedFromAbove` region, nothing leaks |
| `forces` | example | `forces stage cond { }`: Kripke-Joyal forcing block at a stage |
| `produce` | example | Producer block of a stream |
| `emit` | example | Emits a value into the active stream or handler |
| `return` | example | Return from the function |
| `new` | example | Instance construction: `new Q { ... }` |

## Word-form operators

| Keyword | Status | What it does |
|---|---|---|
| `and` `or` | example | Conjunction/disjunction, also in pattern conditions |
| `all` | example | `all P where cond`: quantification over the sections of a place |
| `where` | example | The constraint of `all` and of the comprehension `{ x : A where P }` (the subobject carved out by the fibre) |

## Views and mapping clauses

| Keyword | Status | What it does |
|---|---|---|
| `show` | wired | Inside a view: `show name` / `show name = e`, the exposed fields |
| `as` | example | Alias: `import q as a`, `init X as Space` |
| `maps` | wired | Move clause: `A maps to B by f` |
| `converts` | example | Move clause: field conversion |
| `aggregates` | wired | Move clause: aggregation of several fields |
| `multishot` | wired | `with multishot`: the continuation may be resumed more than once |

## Three-valued logic and effects

| Keyword | Status | What it does |
|---|---|---|
| `present` `unknown` | example | The certain/uncertain values of the Heyting tri-value |
| `absent` | wired | The third value; all three usable as patterns in `when`/`forces` |
| `visits` | example | Effect signature: `fun h(x) visits Output`; the caller must cover the effect, up to `main` |
| `true` `false` | example | The boolean literals (in Omega) |

## HoTT / dependent types

| Keyword | Status | What it does |
|---|---|---|
| `Type` | wired | The universe of types (`Type_N` for levels, recognized at the lex-rule level) |
| `Pi` | example | Dependent product type (dependent functions) |
| `Sigma` | wired | Dependent sum type (dependent pairs) |
| `Id` | example | Identity type: paths between two terms |
| `refl` | wired | The reflexivity path |
| `pair` | example | Constructor of the Sigma pair |
| `fst` `snd` | wired | Projections of the pair |
| `ind_path` | parse-only | The J eliminator at surface level: parsing only, honestly flagged in the reference |

## Two-word contextual phrases

Not reserved words: each word stays free as a user identifier. The
parser reads plain identifiers and validates them in context.

`on object`, `on morphism ... via ...`, `on error E`, `subset of`,
`conflict on F resolves to fn`, `nat transform t from F to G`,
`exact pull` / `exact push`, the `on <op>` clauses inside reduction
bodies, and the policy words `oldest` / `newest` after `drop`.

## Special literals (not keywords)

Duration suffixes `ms`, `s`, `min`, `h`, `d`, `y` (`2s + 500ms`; a
duration is a `number` of milliseconds) and `Type_N` for universe
levels.

## Known cleanups

`over` is registered twice in the lexer table (same word, same token,
harmless). Candidate for removal.
