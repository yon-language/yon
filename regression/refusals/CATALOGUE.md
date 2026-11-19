# The catalogue of refusals

Every form Yon refuses, with its code, its message and its proof. GENERATED from
`regression/refusals/catalogue.py` (`python3 regression/refusals/catalogue.py`); do not edit.

Each entry: the code and the band that reads it (grammar: the lexer or the parser; checker: the
type; project: the layout of the files; manifest: `yon.toml`), the message, why, how the right
form is written, the page of the book, and its refusal proofs: folders of
`regression/canonical_forms/`, or a draft in `regression/refusals/drafts/` while the compiler does
not refuse the form yet. The state: a code that no step produces yet is in `NO_PRODUCER` of
`regression/test_error_codes.py`.

## A. Forms that are gone (grammar, E1003)

### NO-001 `and` · E1003 · grammar

- book: book 22-keywords, «Word-form operators» (the page still teaches `and`/`or`: to rewrite)
- draft: `regression/refusals/drafts/expression/dev_word_and`

```
error[E1003]: `and` is not an operator of Yon
  --> Entry.yon:5:12
   |
 5 |     c := a and b
   |            ^^^
   = why: Boolean and, or and not are written `&&`, `||`, `!`, one way each
   = write: c := a && b
```

### NO-002 `or` · E1003 · grammar

- book: book 22-keywords, «Word-form operators» (the page still teaches `and`/`or`: to rewrite)
- draft: `regression/refusals/drafts/expression/dev_word_or`

```
error[E1003]: `or` is not an operator of Yon
  --> Entry.yon:5:12
   |
 5 |     c := a or b
   |            ^^
   = why: Boolean and, or and not are written `&&`, `||`, `!`, one way each
   = write: c := a || b
```

### NO-003 `not` · E1003 · grammar

- book: book 22-keywords, «Word-form operators» (the page still teaches `and`/`or`: to rewrite)
- draft: `regression/refusals/drafts/expression/dev_word_not`

```
error[E1003]: `not` is not an operator of Yon
  --> Entry.yon:4:10
   |
 4 |     c := not a
   |          ^^^
   = why: Boolean not is written `!`; the word `not` stays only in `e is not p`
   = write: c := !a
```

### NO-004 `pipe` · E1003 · grammar

- book: book 05-functions-and-effects, «Lambdas and pipes.» (it still teaches `|>`: to rewrite)
- proof: `regression/canonical_forms/expression/dev_old_pipe` (gives E2001 until its step aligns it)

```
error[E1003]: `|>` is not an operator of Yon
  --> Entry.yon:3:32
   |
 3 |   fun main: Number { return 21 |> twice }
   |                                ^^
   = why: a fun is applied by writing its arguments, f(x); `↦` carries a value along a bridge
   = write: y := same(21)
```

### NO-005 `mapsto-ascii` · E1003 · grammar

- book: book 21-tooling, «yon-lsp, the language server»
- draft: `regression/refusals/drafts/hott/dev_ascii_mapsto`

```
error[E1003]: `|->` is not a token of Yon
  --> Entry.yon:4:13
   |
 4 |     y := tt |-> bridge
   |             ^^^
   = why: a symbol is written one way in the text, as its glyph; the ASCII spelling is a shortcut of the editor
   = write: y := tt ↦ bridge
```

### NO-006 `inj-ascii` · E1003 · grammar

- book: book 21-tooling, «yon-lsp, the language server»
- draft: `regression/refusals/drafts/coproduct/dev_ascii_injection`

```
error[E1003]: `>->` is not a token of Yon
  --> Entry.yon:2:43
   |
 2 |   fun one: List<Number> { return (1, Nil) >-> Cons }
   |                                           ^^^
   = why: a symbol is written one way in the text, as its glyph; the ASCII spelling is a shortcut of the editor
   = write: return (1, Nil) ↪ Cons
```

### NO-007 `neq-glyph` · E1003 · grammar

- book: book 22-keywords, «Word-form operators» (the page still teaches `and`/`or`: to rewrite)
- draft: `regression/refusals/drafts/expression/dev_neq_glyph`

```
error[E1003]: `≠` is not a comparison: in an expression the comparison is `!=`
  --> Entry.yon:3:12
   |
 3 |     c := 1 ≠ 2
   |            ^
   = why: comparisons are written in ASCII, `==` `!=` `<=` `>=`; `≠` belongs to a statement, where it is the negation of a path, `¬(a = b)`
   = write: c := 1 != 2
```

### NO-008 `heyt-and` · E1003 · grammar

- book: book 08-heyting-core, «Ω as a place to do topology»
- draft: `regression/refusals/drafts/expression/dev_heyt_and`

```
error[E1003]: `&&?` is not a token of Yon
  --> Entry.yon:3:18
   |
 3 |     p := present &&? absent
   |                  ^^^
   = why: a connective of Heyting logic is written one way, as its glyph; the ASCII spelling is a shortcut of the editor
   = write: p := present ∧ absent
```

### NO-009 `heyt-or` · E1003 · grammar

- book: book 08-heyting-core, «Ω as a place to do topology»
- draft: `regression/refusals/drafts/expression/dev_heyt_or`

```
error[E1003]: `||?` is not a token of Yon
  --> Entry.yon:3:18
   |
 3 |     p := present ||? absent
   |                  ^^^
   = why: a connective of Heyting logic is written one way, as its glyph; the ASCII spelling is a shortcut of the editor
   = write: p := present ∨ absent
```

### NO-010 `heyt-imp` · E1003 · grammar

- book: book 08-heyting-core, «Ω as a place to do topology»
- draft: `regression/refusals/drafts/expression/dev_heyt_imp`

```
error[E1003]: `=>?` is not a token of Yon
  --> Entry.yon:3:18
   |
 3 |     p := present =>? absent
   |                  ^^^
   = why: a connective of Heyting logic is written one way, as its glyph; the ASCII spelling is a shortcut of the editor
   = write: p := present → absent
```

### NO-011 `heyt-not` · E1003 · grammar

- book: book 08-heyting-core, «Ω as a place to do topology»
- draft: `regression/refusals/drafts/expression/dev_heyt_not`

```
error[E1003]: `!?` is not a token of Yon
  --> Entry.yon:3:10
   |
 3 |     p := !? absent
   |          ^^
   = why: a connective of Heyting logic is written one way, as its glyph; the ASCII spelling is a shortcut of the editor
   = write: p := ¬absent
```

### NO-012 `pi-word` · E1003 · grammar

- book: book 22-keywords, «HoTT: pairs, paths, universes»
- proof: `regression/canonical_forms/hott/dev_old_pi`
- draft: `regression/refusals/drafts/hott/dev_pi_word`

```
error[E1003]: `Pi` is not a word of Yon
  --> Entry.yon:2:17
   |
 2 |   fun prende(f: Pi x : Number, x = x): Number { return 0 }
   |                 ^^
   = why: a quantifier over types is written one way, as its glyph
   = write: Πx : Number, x = x
```

### NO-013 `sigma-word` · E1003 · grammar

- book: book 22-keywords, «HoTT: pairs, paths, universes»
- proof: `regression/canonical_forms/hott/dev_old_sigma`
- draft: `regression/refusals/drafts/hott/dev_sigma_word`

```
error[E1003]: `Sigma` is not a word of Yon
  --> Entry.yon:2:17
   |
 2 |   fun prende(f: Sigma x : Number, x = x): Number { return 0 }
   |                 ^^^^^
   = why: a quantifier over types is written one way, as its glyph
   = write: Σx : Number, x = x
```

### NO-014 `clear-arg` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_clear_arg`

```
error[E1003]: `clear` takes no argument
  --> Bool.yon:3:76
   |
 3 |   proof fun eta(a: Bool): bit2b(Bit.b2bit(a)) = a { return match a { tt => clear tt, ff => stay ff } }
   |                                                                            ^^^^^^^^
   = why: `stay a` is the path that stays at a; `clear` alone is a proof by computation
   = write: tt => stay tt
```

### NO-015 `refl` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_refl`

```
error[E1003]: `refl` is not a word of Yon
  --> Bool.yon:3:76
   |
 3 |   proof fun eta(a: Bool): bit2b(Bit.b2bit(a)) = a { return match a { tt => refl(tt), ff => stay ff } }
   |                                                                            ^^^^
   = why: the path that stays at a is `stay a`; a proof by computation is `clear`
   = write: tt => stay tt
```

### NO-016 `repeat` · E1003 · grammar

- book: book 04-control-flow, «Loops.» (the page still teaches `repeat at most`: to rewrite)
- draft: `regression/refusals/drafts/repeat/dev_repeat`

```
error[E1003]: `repeat at most` is not a loop of Yon
  --> Entry.yon:4:5
   |
 4 |     repeat at most 3 times { acc <- acc + 1 }
   |     ^^^^^^^^^^^^^^
   = why: a loop that runs N times is written one way, `iter N do { … }`
   = write: iter 3 do { acc <- acc + 1 }
```

### NO-017 `topos-where` · E1003 · grammar

- book: book 16-projects-and-packages, «A project is a directory»
- draft: `regression/refusals/drafts/topos/dev_topos_where`

```
error[E1003]: `where` does not follow `topos`
  --> w/Topos.yon:1:7
   |
 1 | topos where {
   |       ^^^^^
   = why: a topos is the block of its Space, written `topos { }`
   = write: topos {
```

### NO-018 `topos-named` · E1003 · grammar

- book: book 16-projects-and-packages, «A project is a directory»
- draft: `regression/refusals/drafts/topos/dev_named`

```
error[E1003]: a topos has no name of its own
  --> w/Topos.yon:1:7
   |
 1 | topos CoinTopos where {
   |       ^^^^^^^^^
   = why: the name of a topos is the name of its folder
   = write: topos {
```

### NO-019 `error-kw` · E1003 · grammar

- book: book 19-when-things-go-wrong, «Errors are places»
- draft: `regression/refusals/drafts/error/dev_error_kw`

```
error[E1003]: `error` does not declare a place
  --> QueryError.yon:1:1
   |
 1 | error QueryError { this < Error  sqlstate Number }
   | ^^^^^
   = why: an error is a place under Error, and `this < Error` says so
   = write: place QueryError { this < Error  sqlstate Number }
```

### NO-020 `place-on-error` · E1003 · grammar

- book: book 05-functions-and-effects, «Failure is a coproduct: `on error`»
- draft: `regression/refusals/drafts/error/dev_place_on_error`

```
error[E1003]: `on error` belongs on a fun, not on a place
  --> QueryInsert.yon:1:19
   |
 1 | place QueryInsert on error QueryError { sql Number }
   |                   ^^^^^^^^
   = why: a fun that can fail returns T + E; a place does not fail
   = write: place QueryInsert { sql Number }
```

### NO-021 `is-omega` · E1003 · grammar

- book: book 08-heyting-core, «Ω as a place to do topology»
- draft: `regression/refusals/drafts/pattern/dev_is_omega`

```
error[E1003]: `unknown` is not a pattern of `is`
  --> Entry.yon:5:15
   |
 5 |     when u is unknown { r <- 1 }
   |               ^^^^^^^
   = why: a value of Ω becomes a Boolean only through `decide`
   = write: r <- match decide(u) { Present => 0, Absent => 0, Unknown => 1 }
```

### NO-022 `generic-path-param` · E1003 · grammar

- book: book 10-generics, «Generic arrows»
- proof to write: no use in the corpus to copy; the form with its bound names is read off frontend/parser.mly

```
error[E1003]: inside `< >` a path is written in parentheses
   = why: inside `< >` only simple types are written, so a path goes in parentheses
   = write: place X<p : (a = b)>
```

### NO-023 `inline-sum` · E1003 · grammar

- book: book 06-worlds-and-places, «Coproducts: the injection is an arrow of the sum»
- draft: `regression/refusals/drafts/coproduct/dev_inline_sum`

```
error[E1003]: a sum has a name: `A | B` is not a type
  --> Entry.yon:2:18
   |
 2 |   fun ignored(s: A | B(Number)): Number { return 0 }
   |                  ^^^^^^^^^^^^^
   = why: every sum is a place with a name and its arms, where its match is written once
   = write: place S { this > A :U B Number }
```

### NO-024 `on-error-sum` · E1003 · grammar

- book: book 05-functions-and-effects, «Failure is a coproduct: `on error`»
- draft: `regression/refusals/drafts/error/dev_on_error_sum`

```
error[E1003]: `on error` names one place
  --> Entry.yon:2:41
   |
 2 |   fun k(x: Number) on error DomainError | Overflow: Number { return x }
   |                                         ^^^^^^^^^^
   = why: two errors together are a place with a name, whose arms are the errors
   = write: place KFailed { this < Error  this > DomainError :U Overflow }, then `on error KFailed`
```

### NO-025 `at` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_at`

```
error[E1003]: `@` is not an operator of Yon
  --> Entry.yon:4:12
   |
 4 |     x := p @ I0
   |            ^^^^
   = why: the ends of a path are its fields `start` and `end`; a point inside it is `p at i`
   = write: x := p.start
```

### NO-026 `plusplus` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_path_plusplus`

```
error[E1003]: `++` is not an operator of Yon
  --> Entry.yon:5:12
   |
 5 |     j := p ++ q
   |            ^^
   = why: two paths are joined with `concat(p, q)`
   = write: j := concat(p, q)
```

### NO-027 `carry` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- proof: `regression/canonical_forms/hott/dev_old_carry`

```
error[E1003]: `carry … along …` is not a form of Yon
  --> Entry.yon:6:15
   |
 6 |     return if carry 41 along bridge == 42 then 42 else 1
   |               ^^^^^
   = why: a value is carried by applying the equivalence to it
   = write: x ↦ bridge
```

### NO-028 `id-same` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- proof: `regression/canonical_forms/hott/dev_old_id`, `regression/canonical_forms/hott/dev_old_same`

```
error[E1003]: `Id(A, x, y)` is not a type of Yon
   = why: the type of a path from x to y is written x = y; its type is read from the ends
   = write: x = y
```

### NO-029 `pathp` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_pathp`

```
error[E1003]: `PathP` is not a word of Yon
  --> Entry.yon:1:50
   |
 1 | // coverage: a parameter of dependent path type `PathP(i, A, x, y)` (TyPathP).
   |                                                  ^^^^^
   = why: a path over another path is written from a along p to b
   = write: from a along p to b
```

### NO-031 `pair` · E1003 · grammar

- book: book 22-keywords, «HoTT: pairs, paths, universes»
- draft: `regression/refusals/drafts/hott/dev_pair`

```
error[E1003]: `pair` is not a word of Yon
  --> Entry.yon:3:10
   |
 3 |     p := pair(1, 2)
   |          ^^^^
   = why: a pair is written (a, b)
   = write: p := (1, 2)
```

### NO-032 `fst` · E1003 · grammar

- book: book 22-keywords, «HoTT: pairs, paths, universes»
- draft: `regression/refusals/drafts/hott/dev_fst`

```
error[E1003]: `fst(p)` is not a fun of Yon
  --> Entry.yon:4:10
   |
 4 |     x := fst(p)
   |          ^^^^^^
   = why: the parts of a pair are read as its fields
   = write: x := p.fst
```

### NO-034 `functor-head` · E1003 · grammar

- book: book 07-arrows, «One level up: between worlds»
- draft: `regression/refusals/drafts/functor/dev_functor_head`

```
error[E1003]: a functor takes its argument in `on object`
  --> w/Topos.yon:3:17
   |
 3 | functor Identity(x: Number) from W to V { return x }
   |                 ^^^^^^^^^^^
   = why: a functor is given by what it does on objects and on every generator
   = write: functor Identity from W to V { on object(x: Number): Number { return x } }
```

### NO-035 `morph` · E1003 · grammar

- book: book 07-arrows, «One level up: between worlds»
- draft: `regression/refusals/drafts/move/dev_morph`

```
error[E1003]: `morph` is not a word of Yon
  --> AccountEU.yon:2:3
   |
 2 |   morph LiftEU from Account to AccountEU {
   |   ^^^^^
   = why: between toposes an arrow is a functor; inside one it is a fun of the place it returns
   = write: a fun from Account to AccountEU, in place AccountEU (between toposes, a functor in Topos.yon)
```

### NO-036 `promote` · E1003 · grammar

- book: book 17-how-spaces-talk, «Spawn and discovery»
- draft: `regression/refusals/drafts/spawn/dev_promote`

```
error[E1003]: `promote` is not a word of Yon
  --> Entry.yon:4:38
   |
 4 |     results := spawn in 2 parallel { promote rep(spawn_index) }
   |                                      ^^^^^^^
   = why: a spawn puts a value in its channel with `emit`
   = write: results := spawn in 2 parallel { emit rep(spawn_index) }
```

### NO-037 `fold-method` · E1003 · grammar

- book: book 12-standard-library, «Collections and streams»
- draft: `regression/refusals/drafts/for_every/dev_fold_method`

```
error[E1003]: `.fold(…)` is not a method of Yon
  --> Entry.yon:4:12
   |
 4 |     t := xs.fold(0, fun(a: Number, v: Number) => a)
   |            ^^^^^
   = why: the fold is written one way, `fold a { … }`; `List.fold_left` is a fun written with it
   = write: t := List.fold_left(xs, 0, fun(a: Number, v: Number) => a)
```

### NO-038 `exact-push` · E1003 · grammar

- book: book 07-arrows, «`geomorph`: an adjoint pair between two sites»
- draft: `regression/refusals/drafts/geomorph/dev_exact_push`

```
error[E1003]: `exact` is not a clause of a geomorph
  --> Account.yon:3:5
   |
 3 |     exact push
   |     ^^^^^
   = why: that push and pull are exact is proven, not written
   = write: (the line goes; push and pull stay)
```

### NO-039 `maps-to` · E1003 · grammar

- book: book 22-keywords, «Moves and mapping clauses»
- draft: `regression/refusals/drafts/move/dev_maps_to`

```
error[E1003]: `maps to` is not a clause of a move
  --> Entry.yon:4:7
   |
 4 |     x maps to x by ident
   |       ^^^^^^^
   = why: a clause of a move is written one way, `field to field by f`
   = write: x to x by ident
```

### NO-040 `toplevel-fun` · E1003 · grammar

- book: book 06-worlds-and-places, «A place is its structure»
- draft: `regression/refusals/drafts/function/dev_toplevel_fun`

```
error[E1003]: a fun lives inside a place
  --> Entry.yon:1:1
   |
 1 | fun one: Number { return 1 }
   | ^^^
   = why: a file is a place, and every fun lives in a place
   = write: place Entry { fun one: Number { return 1 } … }
```

### NO-041 `prop-eq` · E1003 · grammar

- book: book 22-keywords, «Bindings and mutation», `:=`
- draft: `regression/refusals/drafts/topos/dev_prop_eq`

```
error[E1003]: a prop is defined with `:=`
  --> bank/Topos.yon:2:31
   |
 2 |   prop is_overdrawn(s: State) = s.balance < 0
   |                               ^
   = why: `:=` defines; `=` is a path
   = write: prop is_overdrawn(s: State) := s.balance < 0
```

### NO-042 `import-file` · E1003 · grammar

- book: book 16-projects-and-packages, «Importing»
- draft: `regression/refusals/drafts/binding/dev_import_file`

```
error[E1003]: a file is not imported
  --> Entry.yon:1:8
   |
 1 | import "rates"
   |        ^^^^^^^
   = why: a place of the same Space is called with the dot; an import names a fun of another Space
   = write: Rates.n(x), with no import (rates.yon is the place Rates of this Space)
```

### NO-043 `import-as` · E1003 · grammar

- book: book 16-projects-and-packages, «Importing»
- draft: `regression/refusals/drafts/binding/dev_import_as`

```
error[E1003]: an import is not renamed
  --> Entry.yon:4:22
   |
 4 | import Bank::deposit as bank_deposit
   |                      ^^
   = why: the place before `::` already tells two funs apart
   = write: import Bank::deposit
```

### NO-044 `width-param` · E1003 · grammar

- book: book 06-worlds-and-places, «Sub-objects»
- proof to write: no use in the corpus to copy

```
error[E1003]: a place takes no number between `< >`
   = why: the width of a value is its layout, written with `carried by`
   = write: carried by i32
```

### NO-045 `heyting-one` · E1003 · grammar

- book: book 08-heyting-core, «Ω as a place to do topology»
- draft: `regression/refusals/drafts/expression/dev_heyting_one`

```
error[E1003]: `heyting(v)` takes its mask
  --> Entry.yon:3:10
   |
 3 |     h := heyting(5)
   |          ^^^^^^^^^^
   = why: a value of heyting<N> is built one way, from a value and a mask
   = write: heyting(v, m), with m the full mask
```

### NO-046 `imp-classic` · E1003 · grammar

- book: book 22-keywords, «Word-form operators» (the page still teaches `and`/`or`: to rewrite)
- draft: `regression/refusals/drafts/expression/dev_classic_implies`

```
error[E1003]: `=>` is not an implication of Booleans
  --> Entry.yon:6:12
   |
 6 |     when a => b { r <- 1 }
   |            ^^
   = why: a Boolean implication is `!a || b`; `=>` is the arrow of match arms and lambdas
   = write: when !a || b { r <- 1 }
```

### NO-047 `bare-forall` · E1003 · grammar

- book: book 06-worlds-and-places, «Certified laws: the algebra you declare is the algebra you get»
- proof: `regression/canonical_forms/algebra/dev_untyped_quantifier`

```
error[E1003]: a quantifier carries its type
   = why: every quantifier states the type it ranges over
   = write: ∀a : T
```

### NO-048 `when-here` · E1003 · grammar

- book: book 12-standard-library, «Collections and streams»
- draft: `regression/refusals/drafts/for_every/dev_when_here`

```
error[E1003]: `when here` is not a clause of `for every`
  --> Entry.yon:5:23
   |
 5 |     for every x in xs when here { r <- x }
   |                       ^^^^^^^^^
   = why: `here` filters nothing
   = write: for every x in xs { r <- x }
```

### NO-049 `scope-name` · E1003 · grammar

- book: book 11-spaces-and-packages, «Hermetic scopes»
- draft: `regression/refusals/drafts/scope/dev_scope_name`

```
error[E1003]: a scope has no name
  --> Entry.yon:4:11
   |
 4 |     scope Hermetic { sealed := base }
   |           ^^^^^^^^
   = why: the debug name of a region comes from where it is in the file
   = write: scope { sealed := base }
```

### NO-050 `mediatrix-old` · E1003 · grammar

- book: book 06-worlds-and-places, «A place is its structure»; PROPOSAL: no page of the book says it (the mediator ⟨ ⟩)
- draft: `regression/refusals/drafts/new/dev_old_mediatrix`

```
error[E1003]: `.->` is not a form of Yon
  --> Entry.yon:3:10
   |
 3 |     v := .-> Vote { value 7 }
   |          ^^^
   = why: the value of a place given by its fields is written P ⟨ … ⟩
   = write: v := Vote ⟨ value 7 ⟩
```

### NO-051 `forces` · E1003 · grammar

- book: book 08-heyting-core, «Forcing at a stage» (it describes `forces`: to rewrite)
- draft: `regression/refusals/drafts/forces/dev_forces`

```
error[E1003]: `forces` is not a statement of Yon
  --> Entry.yon:4:5
   |
 4 |     forces NodeA value is Number {
   |     ^^^^^^
   = why: the checker does not yet decide whether a stage forces the condition; a block that always runs forces nothing
   = write: this form has no successor; it may return with lotto S
```

### NO-052 `comp` · E1003 · grammar

- book: book 22-keywords, «Cubical composition and universe codes»
- draft: `regression/refusals/drafts/hott/dev_comp`

```
error[E1003]: `comp` is not a word of Yon
  --> Entry.yon:3:20
   |
 3 |     p := walk i => comp (refl(Number)) [ i = I0 => walk j => 9 ] 5
   |                    ^^^^
   = why: composing cubes is a form of the kernel, not of the program text
   = write: this form has no successor
```

### NO-053 `type-in` · E1003 · grammar

- book: PROPOSAL: no page of the book says it (the type `T in A, B`)
- proof: `regression/canonical_forms/type/dev_type_in`

```
error[E1003]: `T in A, B` is not a type
  --> Entry.yon:2:23
   |
 2 |   fun price(x: Number in EUR, USD): Number {
   |                       ^^^^^^
   = why: a currency is a place, not an annotation on a type
   = write: this form has no successor
```

### NO-054 `call-in` · E1003 · grammar

- book: book 11-spaces-and-packages, «Cross-package imports»
- proof to write: no use in the corpus to copy

```
error[E1003]: `f(args) in S` is not a call of Yon
   = why: `f(args) in S` applied a morph or a move to the heaps of S inside this process; it was never a call to another Space
   = write: this form has no successor; a call to another Space goes through a wire
```

### NO-055 `merge` · E1003 · grammar

- book: book 22-keywords, «Moves and mapping clauses»
- draft: `regression/refusals/drafts/merge/dev_merge`

```
error[E1003]: `unifies` is not a form of a move
  --> Entry.yon:3:14
   |
 3 |   move Merge unifies A, B {
   |              ^^^^^^^
   = why: merging moves is not checked: `Move.merge` gives unknown
   = write: this form has no successor
```

### NO-056 `view` · E1003 · grammar

- book: book 07-arrows, «`view`: observe a place, never change it» (to rewrite: the view leaves)
- draft: `regression/refusals/drafts/view/dev_view`

```
error[E1003]: `view` is not a declaration of Yon
  --> Account.yon:3:3
   |
 3 |   view Snapshot of Account {
   |   ^^^^
   = why: a view does nothing more than a fun of its place
   = write: a fun in place Account that returns the fields it shows
```

### NO-057 `law-bare` · E1003 · grammar

- book: book 06-worlds-and-places, «Certified laws: the algebra you declare is the algebra you get»
- draft: `regression/refusals/drafts/algebra/dev_law_bare`

```
error[E1003]: a law needs its statement
  --> Pair.yon:4:3
   |
 4 |   law commutative
   |   ^^^^^^^^^^^^^^^
   = why: a law has a statement with typed quantifiers, and the checker judges it
   = write: law commutative ∀a : Additive ∀b : Additive, a + b = b + a
```

### NO-058 `reduction-fold` · E1003 · grammar

- book: book 07-arrows, «`reduction`: what the operations mean»
- draft: `regression/refusals/drafts/reduction/dev_reduction_fold`

```
error[E1003]: a reduction takes no `fold "…"`
  --> Entry.yon:2:44
   |
 2 |   reduction Sum<T> of Tally with multishot fold "sum_f64" {
   |                                            ^^^^^^^^^^^^^^
   = why: how a reduction is carried out is not a name written in the source
   = write: reduction Sum<T> of Tally with multishot {
```

### NO-059 `requires` · E1003 · grammar

- book: book 20-capabilities, «Status»
- proof to write: to be written from the move of examples/capability_flow_demo/Entry.yon, with its places

```
error[E1003]: `requires` is not a clause of a move
   = why: a capability that is not enforced is not written
   = write: this form has no successor
```

### NO-060 `handle-lambda` · E1003 · grammar

- book: book 22-keywords, «The four kinds of handle»
- draft: `regression/refusals/drafts/expression/dev_handle_lambda`

```
error[E1003]: `move(…) => …` is not a value of Yon
  --> Entry.yon:3:11
   |
 3 |     m1 := move(s: P) => P ⟨ v 1 ⟩ from P to P
   |           ^^^^^^^^^^
   = why: a move, a functor and a view are declared with a name, not written as lambdas
   = write: this form has no successor; declare the move with a name (the inline reduction stays)
```

### NO-061 `el-match` · E1003 · grammar

- book: book 22-keywords, «Cubical composition and universe codes»
- draft: `regression/refusals/drafts/hott/dev_el_match`

```
error[E1003]: `el_match` is a form of the kernel
  --> Entry.yon:1:24
   |
 1 | // coverage: EElMatch `el_match(target, ret, body)` (El eliminator). Grammar:
   |                        ^^^^^^^^
   = why: the codes of the universe stay inside the kernel
   = write: this form has no successor
```

### NO-062 `is-carrier` · E1003 · grammar

- book: book 06-worlds-and-places, «Sub-objects»
- proof: `regression/canonical_forms/fusion/dev_old_is`

```
error[E1003]: `is i64` after a place name is not how a layout is written
   = why: the layout of a place is written `carried by`
   = write: place P carried by i64
```

### NO-063 `in-sequence` · E1003 · grammar

- book: book 12-standard-library, «Collections and streams»
- draft: `regression/refusals/drafts/in_sequence/dev_in_sequence`

```
error[E1003]: `in sequence over` is not a loop of Yon
  --> Entry.yon:5:5
   |
 5 |     in sequence over x in xs { acc <- x }
   |     ^^^^^^^^^^^^^^^^
   = why: one form does something on every element: `for every`
   = write: for every x in xs { acc <- x }
```

### NO-064 `field-write` · E1003 · grammar

- book: book 14-values-cells-lifetime, «Lifetime»
- proof: `regression/canonical_forms/assignment/dev_field_mutation` (gives E2001 until its step aligns it)

```
error[E1003]: a field is not changed in place
  --> Entry.yon:4:5
   |
 4 |     p.x <- 42
   |     ^^^^^^
   = why: only a variable changes; a new value is written P ⟨ … ⟩
   = write: w := Vote ⟨ value 8 ⟩
```

### NO-065 `toplevel-bind` · E1003 · grammar

- book: book 03-values-and-bindings, «Bindings are immutable.»
- draft: `regression/refusals/drafts/binding/dev_toplevel_bind`

```
error[E1003]: a binding lives inside a fun
  --> Entry.yon:1:1
   |
 1 | base := 40
   | ^^^^
   = why: a value shared by the funs of a place is a fun without arguments of that place
   = write: fun base: Number { return 40 } (inside the place)
```

### NO-066 `over` · E1003 · grammar

- book: book 06-worlds-and-places, «A place is its structure»
- proof: `regression/canonical_forms/place/dev_old_over`

```
error[E1003]: `over` is not a clause of a place
   = why: a family over X is a place with a field or a fun to X
   = write: a field or a fun to X
```

### NO-067 `sub-where` · E1003 · grammar

- book: book 06-worlds-and-places, «Sub-objects»
- draft: `regression/refusals/drafts/subcontains/dev_sub_where`

```
error[E1003]: a named sub-object states its invariant in a `constraint fun`
  --> Piccolo.yon:1:30
   |
 1 | place Piccolo { this < Int64 where 0 <= this && this < 10 }
   |                              ^^^^^
   = why: with a name, `constraint fun`; without a name, `where`
   = write: place Piccolo { this < Int64  constraint fun valido(c: Piccolo): Boolean { return 0 <= c && c < 10 } }
```

### NO-068 `arm-path` · E1003 · grammar

- book: book 06-worlds-and-places, «Coproducts: the injection is an arrow of the sum»
- proof to write: to be written with the form the rule recognises

```
error[E1003]: an arm does not carry a path
   = why: a path in a place with arms is declared with `cell`
   = write: cell loop from base to base
```

### NO-091 `ind-path` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_ind_path`

```
error[E1003]: `ind_path` is not a fun of Yon
  --> Entry.yon:3:10
   |
 3 |     r := ind_path(d, p)
   |          ^^^^^^^^
   = why: the induction on paths is written `induct(d, p)`
   = write: r := induct(d, p)
```

### NO-144 `standalone-op` · E1003 · grammar

- book: book 06-worlds-and-places, «A place is its structure»
- draft: `regression/refusals/drafts/algebra/dev_standalone_op`

```
error[E1003]: an operation lives inside a place
  --> Entry.yon:1:1
   |
 1 | operation twice(a: Number): Number uses algebra Additive
   | ^^^^^^^^^
   = why: a file is a place, and an operation belongs to the place it acts on
   = write: place P { operation twice(a: Number): Number uses algebra Additive }
```

### NO-145 `functor-law` · E1003 · grammar

- book: book 07-arrows, «One level up: between worlds»
- proof to write: with the new head of the functor: the law has no form to copy from yet

```
error[E1003]: a functor declares no law
   = why: that a functor keeps identities and composition is checked by the compiler
   = write: functor Identity from W to V { on object(x: Number): Number { return x } }
```

### NO-147 `el-type` · E1003 · grammar

- book: book 22-keywords, «Cubical composition and universe codes»
- draft: `regression/refusals/drafts/hott/dev_el_type`

```
error[E1003]: `El` is a form of the kernel
  --> Entry.yon:5:16
   |
 5 |   fun useEl(e: El(Carrier)): Number { return 0 }
   |                ^^
   = why: the codes of the universe stay inside the kernel
   = write: this form has no successor
```

### NO-148 `handle-type` · E1003 · grammar

- book: book 22-keywords, «The four kinds of handle»
- draft: `regression/refusals/drafts/type/dev_handle_type`

```
error[E1003]: `move from W to V` is not a type
  --> Entry.yon:2:14
   |
 2 |   fun usa(m: move from W to V): Number { return 0 }
   |              ^^^^^^^^^^^^^^^^
   = why: a move is declared with a name, and named where it is used
   = write: this form has no successor; name the move where it is declared
```

### NO-149 `plam` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- proof: `regression/canonical_forms/variant/dev_old_plam`

```
error[E1003]: `plam` is not a word of Yon
  --> Entry.yon:3:48
   |
 3 |     return match S1.base { base => 42, loop => plam i => 42 }
   |                                                ^^^^
   = why: a path is built with walk i => e
   = write: loop => walk i => 42
```

### NO-150 `old-arm-pattern` · E1003 · grammar

- book: book 06-worlds-and-places, «Coproducts: the injection is an arrow of the sum»
- proof: `regression/canonical_forms/coproduct/dev_old_pattern`, `regression/canonical_forms/coproduct/dev_old_arm`

```
error[E1003]: `Cons(h, t)` is not a pattern of Yon
  --> Entry.yon:3:59
   |
 3 |   fun head(l: List2): Number { return match l { Nil => 0, Cons(h, t) => h } }
   |                                                           ^^^^^^^^^^
   = why: an arm with a payload is matched as `Cons as (h, t)`
   = write: Cons as (h, t) => h
```

### NO-151 `where-type` · E1003 · grammar

- book: book 09-hott-types, «Comprehension types»
- draft: `regression/refusals/drafts/comprehension/dev_where_type`

```
error[E1003]: after `where` comes a Boolean test: `n = 5` is a type
  --> Entry.yon:2:34
   |
 2 |   fun five(x: { n : Number where n = 5 }): Number { return 0 }
   |                                  ^^^^^
   = why: `{ n : T where … }` keeps the values of T for which the test is true
   = write: { n : Number where n == 5 }
```

### NO-153 `prop-quantifier-parens` · E1003 · grammar

- book: book 06-worlds-and-places, «Certified laws: the algebra you declare is the algebra you get»
- draft: `regression/refusals/drafts/topos/dev_prop_quantifier_parens`

```
error[E1003]: the body of a quantifier follows a comma
  --> w/Topos.yon:2:42
   |
 2 |   prop some_other(x: Coin) := ∃ y : Coin (x != y)
   |                                          ^^^^^^^^
   = why: a binder is written one way everywhere: `∀ y : T, body`, as in a law
   = write: prop some_other(x: Coin) := ∃ y : Coin, x != y
```

### NO-154 `import-from` · E1003 · grammar

- book: book 11-spaces-and-packages, «Cross-package imports»; PROPOSAL: no page of the book says it (concrete and abstract Spaces)
- draft: `regression/refusals/drafts/binding/dev_import_from`

```
error[E1003]: an import does not reach another Space
  --> Entry.yon:1:26
   |
 1 | import Bank::deposit_net from Bank
   |                          ^^^^^^^^^
   = why: between two concrete Spaces only a wire passes; an import copies the code of an abstract Space
   = write: w := wire to space Bank, then escape w.deposit_net(5)
```

### NO-158 `hit-surface` · E1003 · grammar

- book: book 06-worlds-and-places, «Coproducts: the injection is an arrow of the sum»
- proof: `regression/canonical_forms/variant/dev_old_hit`, `regression/canonical_forms/variant/dev_old_hit_payload`

```
error[E1003]: hit is a form of the kernel: a Noneary arm is its name: Heads
  --> Entry.yon:4:10
   |
 4 |     z := hit(Heads)
   |          ^^^^^^^^^^
   = why: a point of a sum is written by its arm: the arm alone, or `x ↪ A` with a payload
   = write: z := Heads
```

### NO-159 `hit-elim-surface` · E1003 · grammar

- book: book 06-worlds-and-places, «Coproducts: the injection is an arrow of the sum»
- proof: `regression/canonical_forms/variant/dev_old_hit_elim`

```
error[E1003]: hit_elim is a form of the kernel: the eliminator is written match x { arm => .. }
  --> Entry.yon:4:35
   |
 4 |   fun f(c: Coin): Number { return hit_elim(mot, [Heads => 1, Tails => 0], c) }
   |                                   ^^^^^^^^
   = why: the eliminator of a sum is `match`, with a branch for each arm
   = write: return match c { Heads => 1, Tails => 0 }
```

### NO-160 `bare-meet-type` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- proof: `regression/canonical_forms/hott/dev_bare_meet`

```
error[E1003]: in a type ∧ does not stand bare among the endpoints of a path
  --> Entry.yon:2:23
   |
 2 |   fun f(a: Number, q: a = a ∧ a = a): Number { return 0 }
   |                       ^^^^^^^^^^^^^
   = why: a conjunction of paths is written with each path in its parentheses; an endpoint that is a meet keeps its own
   = write: q: (a = a) ∧ (a = a)
```

### NO-161 `path-chain` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_path_chain`

```
error[E1003]: a path has two ends: a = b = c has no reading in a type
  --> Entry.yon:2:23
   |
 2 |   fun f(a: Number, q: a = a = a): Number { return 0 }
   |                       ^^^^^^^^^
   = why: the type of a path names its two endpoints; two paths in a row are a conjunction or a composition
   = write: q: (a = b) ∧ (b = c)
```

### NO-162 `product-triple` · E1003 · grammar

- book: book 22-keywords, «HoTT: pairs, paths, universes»
- proof: `regression/canonical_forms/hott/dev_product_three`

```
error[E1003]: a product has two components: (A, B, C) has no reading in a type
  --> Entry.yon:2:12
   |
 2 |   fun f(p: (Number, Number, Number)): Number { return 0 }
   |            ^^^^^^^^^^^^^^^^^^^^^^^^
   = why: a product is binary; more components nest
   = write: p: (Number, (Number, Number))
```

### NO-164 `let` · E1001 · grammar

- book: PROPOSAL: no page of the book says it (binding)
- proof: `regression/canonical_forms/binding/dev_let`

```
error[E1001]: let
  --> Entry.yon:3:5
   |
 3 |     let x = 42
   |     ^^^^^^^^^^
   = why: let is not a Yon keyword; the only binding form is x := e
   = write: x := 42
```

### NO-168 `old-projection` · E1001 · grammar

- book: PROPOSAL: no page of the book says it (coproduct)
- proof: `regression/canonical_forms/coproduct/dev_old_projection`

```
error[E1001]: Full as x
  --> Entry.yon:3:46
   |
 3 |   fun get(b: Box): Number { return match b { Full { _1 as p } => p, Empty => 0 } }
   |                                              ^^^^^^^^^^^^^^^^
   = why: the braces are for the fields of a place: a payload is read with as
   = write: Full as p => p
```

### NO-172 `arrow-into-call` · E1001 · grammar

- book: PROPOSAL: no page of the book says it (expression)
- proof: `regression/canonical_forms/expression/dev_arrow_into_call`

```
error[E1001]: write (a, y) ↦ add
  --> Entry.yon:3:34
   |
 3 |   fun main: Number { return 40 ↦ add(2) }
   |                                  ^^^^^^
   = why: the right of an arrow is a name; the arguments are the tuple on its left
   = write: (40, 2) ↦ add
```

### NO-180 `ternary` · E1002 · grammar

- book: PROPOSAL: no page of the book says it (if_expr)
- proof: `regression/canonical_forms/if_expr/dev_ternary`

```
error[E1002]: unexpected character
  --> Entry.yon:4:19
   |
 4 |     return c == 1 ? 42 : 0
   |                   ^
   = why: the C ternary c ? a : b does not exist; if c then a else b is the form
   = write: if c == 1 then 42 else 0
```

### NO-188 `multibyte-char` · E1002 · grammar

- book: book 22-keywords, «Word-form operators»
- proof: `regression/canonical_forms/expression/dev_multibyte_char`

```
error[E1002]: unexpected character `∘` (U+2218)
  --> Entry.yon:3:12
   |
 3 |     c := 1 ∘ 2
   |            ^
   = why: a character that no rule of the lexer reads is not a symbol of Yon; it is named whole, with its code point
```

### NO-189 `if-in-operator` · E1003 · grammar

- book: book 04-control-flow (PROPOSAL: the page does not say yet that an `if` inside an operator takes parentheses)
- proof: `regression/canonical_forms/expression/dev_if_in_operator`

```
error[E1003]: an `if` inside an operator is written in parentheses: (if c then a else b)
  --> Entry.yon:4:14
   |
 4 |     x := 1 + if c then 2 else 3
   |              ^^^^
   = why: the else branch of an `if` extends to the right as far as it can, so the `if` stands at the top of an expression; inside an operator its parentheses say where it ends
   = write: x := 1 + (if c then 2 else 3)
```

### NO-190 `lambda-in-operator` · E1003 · grammar

- book: book 05-functions-and-effects, «Lambdas and pipes.»
- proof: `regression/canonical_forms/expression/dev_lambda_in_operator`

```
error[E1003]: a lambda inside an operator is written in parentheses: (fun(x) => e)
  --> Entry.yon:3:14
   |
 3 |     n := 2 * fun(x: Number) => x
   |              ^^^^^
   = why: the body of a lambda extends to the right as far as it can, so the lambda stands at the top of an expression; inside an operator its parentheses say where it ends
   = write: g := h ↦ (fun(x: Number) => x + 1)
```

### NO-191 `walk-in-operator` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- proof: `regression/canonical_forms/expression/dev_walk_in_operator`

```
error[E1003]: a `walk` inside an operator is written in parentheses: (walk i => e)
  --> Entry.yon:3:14
   |
 3 |     p := 1 + walk i => 5
   |              ^^^^
   = why: the body of a `walk` extends to the right as far as it can, so the `walk` stands at the top of an expression; inside an operator its parentheses say where it ends
   = write: p := 1 + (walk i => 5)
```

### NO-192 `at-before-operator` · E1003 · grammar

- book: book 09-hott-types, «Paths as journeys»
- proof: `regression/canonical_forms/expression/dev_at_before_operator`

```
error[E1003]: a path applied with @ is written in parentheses before an operator that binds tighter: (p @ i) + 1
  --> Entry.yon:4:14
   |
 4 |     return p @ I0 + 1
   |              ^^^^^^
   = why: `@` is a postfix below the arithmetic, so `a + p @ i` is `(a + p) @ i`; an operator that binds tighter after it would read it as its left operand, and the parentheses say so
   = write: return (p @ I0) + 1
```

## B. The head: modifiers and clauses a declaration does not take (grammar, E1004)

### NO-069 `constraint-given` · E1004 · grammar

- book: PROPOSAL: no page of the book says it (`constraint fun`); book 05-functions-and-effects, «Modifiers.»
- draft: `regression/refusals/drafts/function/dev_constraint_given`
- state: the code is registered and no step produces it yet

```
error[E1004]: a `constraint fun` has a body: `is given` is refused
  --> Intervallo.yon:4:51
   |
 4 |   constraint fun ordinato(i: Intervallo): Boolean is given
   |                                                   ^^^^^^^^
   = why: an invariant is checked; an axiom is what is not checked
   = write: constraint fun ordinato(i: Intervallo): Boolean { return i.lo <= i.hi }
```

### NO-070 `proof-given` · E1004 · grammar

- book: book 18-the-project, «Proofs in a project»
- draft: `regression/refusals/drafts/function/dev_proof_given`
- state: the code is registered and no step produces it yet

```
error[E1004]: a `proof fun` has a body: `is given` is refused
  --> Bool.yon:3:51
   |
 3 |   proof fun eta(a: Bool): bit2b(Bit.b2bit(a)) = a is given
   |                                                   ^^^^^^^^
   = why: a proof states no axiom
   = write: proof fun eta(a: Bool): bit2b(b2bit(a)) = a { return match a { tt => stay tt, ff => stay ff } }
```

### NO-071 `internal-constraint` · E1004 · grammar

- book: PROPOSAL: no page of the book says it (`constraint fun`)
- draft: `regression/refusals/drafts/function/dev_internal_constraint`
- state: the code is registered and no step produces it yet

```
error[E1004]: a `constraint fun` is not internal
  --> Intervallo.yon:4:3
   |
 4 |   internal constraint fun ordinato(i: Intervallo): Boolean { return i.lo <= i.hi }
   |   ^^^^^^^^
   = why: a constraint is part of what its place promises: who writes P ⟨ … ⟩ must see it
   = write: constraint fun ordinato(i: Intervallo): Boolean { return i.lo <= i.hi }
```

### NO-072 `proof-constraint` · E1004 · grammar

- book: PROPOSAL: no page of the book says it (`constraint fun`)
- draft: `regression/refusals/drafts/function/dev_proof_constraint`
- state: the code is registered and no step produces it yet

```
error[E1004]: a fun is a proof or a constraint, not both
  --> Intervallo.yon:4:3
   |
 4 |   proof constraint fun ordinato(i: Intervallo): Boolean { return i.lo <= i.hi }
   |   ^^^^^^^^^^^^^^^^
   = why: the modifier of a fun is one of `proof` and `constraint`
   = write: constraint fun ordinato(i: Intervallo): Boolean { return i.lo <= i.hi }
```

### NO-073 `law-given` · E1004 · grammar

- book: book 06-worlds-and-places, «Certified laws: the algebra you declare is the algebra you get»
- draft: `regression/refusals/drafts/algebra/dev_law_given`
- state: the code is registered and no step produces it yet

```
error[E1004]: a law has no `is given`
  --> Pair.yon:4:54
   |
 4 |   law commutative ∀a : Pair ∀b : Pair, a + b = b + a is given
   |                                                      ^^^^^^^^
   = why: an axiom is what is not checked; a law of an algebra is judged
   = write: (the line goes; the axiom of the heap is written in the type of its handle)
```

### NO-074 `carried-given` · E1004 · grammar

- book: book 06-worlds-and-places, «Sub-objects»
- draft: `regression/refusals/drafts/fusion/dev_carried_given`
- state: the code is registered and no step produces it yet

```
error[E1004]: `carried by` takes no `is given`
  --> Byte.yon:1:27
   |
 1 | place Byte carried by i64 is given { this < Int64 }
   |                           ^^^^^^^^
   = why: `is given` is only the body of a fun
   = write: place Plus32 carried by i32 { … }
```

### NO-146 `nat-given` · E1004 · grammar

- book: book 07-arrows, «One level up: between worlds»
- draft: `regression/refusals/drafts/nat_transform/dev_nat_given`
- state: the code is registered and no step produces it yet

```
error[E1004]: a nat transform has no `is given`
  --> w/Topos.yon:5:31
   |
 5 | nat transform Eta from F to G is given {
   |                               ^^^^^^^^
   = why: a nat transform is given by its component at each object
   = write: nat transform Eta from F to G {
```

## C. Second writings only the type sees (checker, E2019 Writing_refused)

### NO-030 `ua-equiv` · E2019 · checker

- book: book 09-hott-types, «Paths as journeys»
- proof: `regression/canonical_forms/hott/dev_old_ua` (gives E1001 until its step aligns it), `regression/canonical_forms/hott/dev_old_equiv` (gives E1001 until its step aligns it)
- state: the code is registered and no step produces it yet

```
error[E2019]: `ua(e)` is not a fun of Yon
   = why: an equivalence gives the path between its types, `path of e`
   = write: path of e
```

### NO-033 `lower-type` · E2019 · checker

- book: book 06-worlds-and-places, «A place is its structure»
- draft: `regression/refusals/drafts/type/dev_lower_type`
- state: the code is registered and no step produces it yet

```
error[E2019]: `number` is not a type of Yon
  --> Entry.yon:2:14
   |
 2 |   fun one(x: number): Number { return x }
   |              ^^^^^^
   = why: a type is a place, and a place is written with a capital
   = write: x: Number
```

### NO-075 `list-cons` · E2019 · checker

- book: book 06-worlds-and-places, «Coproducts: the injection is an arrow of the sum»
- draft: `regression/refusals/drafts/coproduct/dev_ctor_fun`
- state: the code is registered and no step produces it yet

```
error[E2019]: `List.cons` is a second way to write `↪ Cons`
  --> Entry.yon:3:10
   |
 3 |     l := List.cons(1, Nil)
   |          ^^^^^^^^^
   = why: an arm of a sum is built with `↪`
   = write: l := (1, Nil) ↪ Cons
```

### NO-076 `list-empty` · E2019 · checker

- book: book 06-worlds-and-places, «Coproducts: the injection is an arrow of the sum»
- draft: `regression/refusals/drafts/coproduct/dev_list_empty`
- state: the code is registered and no step produces it yet

```
error[E2019]: `List.empty` is a second way to write `Nil`
  --> Entry.yon:3:14
   |
 3 |     mut r := List.empty
   |              ^^^^^^^^^^
   = why: an arm without payload is written by its name
   = write: mut r := Nil
```

### NO-077 `text-equal` · E2019 · checker

- book: book 13-content-addressed-heap, «Equality for free»
- draft: `regression/refusals/drafts/expression/dev_text_equal`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Text.equal` is a second way to write `==`
  --> Entry.yon:3:13
   |
 3 |     same := Text.equal("ciao", "mondo")
   |             ^^^^^^^^^^
   = why: two values are equal when they are the same value
   = write: same := "ciao" == "mondo"
```

### NO-078 `print` · E2019 · checker

- book: book 05-functions-and-effects, «Effects: `visits`»
- draft: `regression/refusals/drafts/function/dev_text_print`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Text.print` is not a fun of Yon
  --> Entry.yon:3:11
   |
 3 |     _p := Text.print("ciao")
   |           ^^^^^^^^^^
   = why: every print is `Output.print` under `visits Output`
   = write: _p := Output.print("ciao")
```

### NO-079 `apply-move` · E2019 · checker

- book: book 07-arrows, «`move`: the only way content crosses»
- draft: `regression/refusals/drafts/move/dev_apply_move`
- state: the code is registered and no step produces it yet

```
error[E2019]: `apply_move` is a second way to apply a move
  --> Entry.yon:8:10
   |
 8 |     n := apply_move(Squeeze, w)
   |          ^^^^^^^^^^
   = why: a move is applied like a fun, M(s)
   = write: n := Squeeze(w)
```

### NO-080 `int64-div` · E2019 · checker

- book: book 12-standard-library, «Numbers, time, randomness, hashing»
- draft: `regression/refusals/drafts/expression/dev_int64_div`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Int64.div` is a second way to write `/`
  --> Entry.yon:2:52
   |
 2 |   fun dividi(a: Int64, b: NonZero): Int64 { return Int64.div(a, b) }
   |                                                    ^^^^^^^^^
   = why: a divisor is a NonZero, so `/` never divides by zero
   = write: return a / b, with b: NonZero
```

### NO-081 `widen` · E2019 · checker

- book: book 06-worlds-and-places, «Sub-objects»
- draft: `regression/refusals/drafts/expression/dev_widen`
- state: the code is registered and no step produces it yet

```
error[E2019]: `widen_i32_i64` is not a fun of Yon
  --> Entry.yon:2:41
   |
 2 |   fun allarga(x: Int32): Int64 { return widen_i32_i64(x) }
   |                                         ^^^^^^^^^^^^^
   = why: an Int32 is already an Int64: the conversion is not written
   = write: return x
```

### NO-082 `bits` · E2019 · checker

- book: book 12-standard-library, «Maps, bits, sealed storage»
- draft: `regression/refusals/drafts/expression/dev_bits`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Bits` is not a place of Yon
  --> Entry.yon:3:10
   |
 3 |     b := Bits.shl(1, 5)
   |          ^^^^^^^^
   = why: the operations on bits are funs of Word64
   = write: Word64.shift_left(w, k)
```

### NO-083 `voyager-append` · E2019 · checker

- book: book 15-data-structures-on-the-lattice, «VoyagerList: storage that heals»
- draft: `regression/refusals/drafts/expression/dev_voyager_append`
- state: the code is registered and no step produces it yet

```
error[E2019]: `VoyagerList.append` is not a fun of Yon
  --> Entry.yon:3:11
   |
 3 |     l2 := VoyagerList.append(l, 1)
   |           ^^^^^^^^^^^^^^^^^^
   = why: the fun that adds an element at the end is `push_back`
   = write: l2 := VoyagerList.push_back(l, 1)
```

### NO-084 `sequence` · E2019 · checker

- book: book 12-standard-library, «Collections and streams»
- draft: `regression/refusals/drafts/expression/dev_sequence`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Sequence` is not a place of Yon
  --> Entry.yon:4:10
   |
 4 |     m := Sequence.map(xs, fun(v: Number) => v)
   |          ^^^^^^^^^^^^
   = why: a sequence is a List
   = write: m := List.map(xs, fun(v: Number) => v)
```

### NO-085 `for-every-method` · E2019 · checker

- book: book 17-how-spaces-talk, «The channel»
- draft: `regression/refusals/drafts/for_every/dev_for_every_method`
- state: the code is registered and no step produces it yet

```
error[E2019]: `for_every` is not a method of Yon
  --> Entry.yon:3:7
   |
 3 |     s.for_every(fun(v: Number) => v)
   |       ^^^^^^^^^
   = why: a stream is read with the statement `for every`
   = write: for every v in s { … }
```

### NO-086 `to-stream` · E2019 · checker

- book: book 12-standard-library, «Collections and streams»
- draft: `regression/refusals/drafts/for_every/dev_to_stream`
- state: the code is registered and no step produces it yet

```
error[E2019]: `to_stream` is not a fun of Yon
  --> Entry.yon:3:19
   |
 3 |     xs := HashSet.to_stream(s)
   |                   ^^^^^^^^^
   = why: the elements of a collection are a List, `elements`
   = write: xs := HashSet.elements(s)
```

### NO-087 `stream-iterate` · E2019 · checker

- book: book 12-standard-library, «Collections and streams»
- draft: `regression/refusals/drafts/for_every/dev_stream_iterate`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Stream.iterate` is not a fun of Yon
  --> Entry.yon:3:10
   |
 3 |     s := Stream.iterate(fun(v: Number) => v, 0)
   |          ^^^^^^^^^^^^^^
   = why: a stream is given by its next step, the field `next`
   = write: place Stream<V> { next -> Unfold<V, Stream<V>> }, read s.next
```

### NO-088 `next-call` · E2019 · checker

- book: book 12-standard-library, «Collections and streams»
- draft: `regression/refusals/drafts/for_every/dev_next_call`
- state: the code is registered and no step produces it yet

```
error[E2019]: `s.next` takes no argument: it is read without (star)
  --> Entry.yon:3:16
   |
 3 |     u := s.next(star)
   |                ^^^^^^
   = why: a pure fun without arguments is read without parentheses
   = write: u := s.next
```

### NO-089 `inv-ap` · E2019 · checker

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_inv_ap`
- state: the code is registered and no step produces it yet

```
error[E2019]: the inverse of a path is written `back p`
  --> Entry.yon:4:10
   |
 4 |     r := inv(p)
   |          ^^^
   = why: a path has one way to write its inverse and one to write its image
   = write: r := back p
```

### NO-090 `transport` · E2019 · checker

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_transport`
- state: the code is registered and no step produces it yet

```
error[E2019]: `transport` is not a fun of Yon
  --> Entry.yon:3:10
   |
 3 |     y := transport(p, x)
   |          ^^^^^^^^^
   = why: a value is carried along an equivalence by applying it, x ↦ e
   = write: y := x ↦ e (toward a bridge)
```

### NO-092 `equiv-type` · E2019 · checker

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_equiv_type`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Equiv<A, B>` is not a type of Yon
  --> Entry.yon:2:17
   |
 2 |   fun prende(e: Equiv<Number, Number>): Number { return 0 }
   |                 ^^^^^^^^^^^^^^^^^^^^^
   = why: the type of the equivalences between A and B is written A ≃ B
   = write: e: Number ≃ Number
```

### NO-093 `merid` · E2019 · checker

- book: book 22-keywords, «HoTT: pairs, paths, universes»
- draft: `regression/refusals/drafts/hott/dev_merid`
- state: the code is registered and no step produces it yet

```
error[E2019]: `merid` is not a name of Yon
  --> Entry.yon:3:10
   |
 3 |     m := merid(a)
   |          ^^^^^
   = why: the path of a suspension is named `meridian`
   = write: m := meridian(a)
```

### NO-094 `to-bool-dec` · E2019 · checker

- book: book 08-heyting-core, «Ω as a place to do topology»
- draft: `regression/refusals/drafts/if_expr/dev_to_bool_dec`
- state: the code is registered and no step produces it yet

```
error[E2019]: `to_bool_dec` is not a fun of Yon
  --> Entry.yon:4:10
   |
 4 |     b := to_bool_dec(d)
   |          ^^^^^^^^^^^
   = why: a Decision is read with a match on its arms
   = write: b := match d { Present => true, Absent => false, Unknown => false }
```

### NO-095 `apply-as-transport` · E2019 · checker

- book: book 07-arrows, «`fun`: a plain computation»
- draft: `regression/refusals/drafts/expression/dev_apply_as_transport`
- state: the code is registered and no step produces it yet

```
error[E2019]: `↦` carries a value along a bridge: `add` is a fun
  --> Entry.yon:4:18
   |
 4 |     y := (40, 2) ↦ add
   |                  ^^^^^
   = why: a fun is applied by writing its arguments, add(a, b)
   = write: y := add(40, 2)
```

### NO-096 `pure-main-parens` · E2019 · checker

- book: book 07-arrows, «`fun`: a plain computation»; PROPOSAL: no page of the book says it (the funs without arguments)
- proof: `regression/canonical_forms/function/dev_pure_with_unit` (gives E2001 until its step aligns it)
- state: the code is registered and no step produces it yet

```
error[E2019]: a pure fun without arguments is declared without ()
  --> Entry.yon:2:13
   |
 2 |   fun answer(): Number { return 42 }
   |             ^^
   = why: `main` has no arguments and no effect: it is declared and read without parentheses
   = write: fun main: ExitCode { return 0 }
```

### NO-097 `effect-main-bare` · E2019 · checker

- book: book 05-functions-and-effects, «Effects: `visits`»
- draft: `regression/refusals/drafts/function/dev_main_effect_bare`
- state: the code is registered and no step produces it yet

```
error[E2019]: `main` visits Output: a fun with an effect is declared with ()
  --> Entry.yon:2:7
   |
 2 |   fun main: ExitCode visits Output {
   |       ^^^^
   = why: a fun with an effect takes Unit, so it is declared and called with ()
   = write: fun main(): ExitCode visits Output {
```

### NO-098 `masked-ctor` · E2019 · checker

- book: PROPOSAL: no page of the book says it (the mediator ⟨ ⟩)
- draft: `regression/refusals/drafts/new/dev_masked_ctor`
- state: the code is registered and no step produces it yet

```
error[E2019]: `mk` repeats Pt ⟨ … ⟩
  --> Pt.yon:2:7
   |
 2 |   fun mk(v: Number): Pt { return Pt ⟨ x v ⟩ }
   |       ^^
   = why: a fun whose body is only P ⟨ … ⟩ of its parameters is a second way to write it
   = write: the mediatrix P ⟨ … ⟩: p := Pt ⟨ x 7 ⟩
```

## D. Constraints, sub-objects and arithmetic (checker, E2016 / E2011 / E2012 / E2010 / E2001)

### NO-099 `constraint-literal` · E2016 · checker

- book: PROPOSAL: no page of the book says it (`constraint fun`); book 06-worlds-and-places, «Sub-objects»
- draft: `regression/refusals/drafts/subcontains/dev_constraint_literal`
- state: the code is registered and no step produces it yet

```
error[E2016]: Intervallo ⟨ lo 5 hi 1 ⟩ breaks `ordinato`
  --> Entry.yon:3:10
   |
 3 |     i := Intervallo ⟨ lo 5 hi 1 ⟩
   |          ^^^^^^^^^^^^^^^^^^^^^^^^
   = why: a literal enters a place only if every constraint fun of the place holds on it
   = write: i := Intervallo ⟨ lo 1 hi 5 ⟩
```

### NO-100 `constraint-unproven` · E2011 · checker

- book: book 05-functions-and-effects, «Failure is a coproduct: `on error`»
- draft: `regression/refusals/drafts/subcontains/dev_constraint_unproven`

```
error[E2011]: `crea` may build an Intervallo that breaks `ordinato`: it declares `on error ConstraintError`
  --> Intervallo.yon:5:55
   |
 5 |   fun crea(a: Number, b: Number): Intervallo { return Intervallo ⟨ lo a hi b ⟩ }
   |                                                       ^^^^^^^^^^^^^^^^^^^^^^^^
   = why: where the compiler cannot prove a constraint, the error is declared and handled
   = write: fun crea(a: Number, b: Number) on error ConstraintError: Intervallo {
```

### NO-101 `constraint-escape` · E2012 · checker

- book: book 19-when-things-go-wrong, «An error leaves by `escape`»
- draft: `regression/refusals/drafts/subcontains/dev_constraint_no_escape`

```
error[E2012]: `crea(a, b)` may be a ConstraintError: it is read with escape
  --> Entry.yon:3:10
   |
 3 |     i := Intervallo.crea(a, 4)
   |          ^^^^^^^^^^^^^^^^^^^^^
   = why: a value that may be an error is read with `escape` where only its success is wanted
   = write: i := escape Intervallo.crea(a, 4)
```

### NO-102 `constraint-bool` · E2001 · checker

- book: PROPOSAL: no page of the book says it (`constraint fun`)
- draft: `regression/refusals/drafts/subcontains/dev_constraint_type`

```
error[E2001]: a `constraint fun` returns a Boolean: `ordinato` returns Number
  --> Intervallo.yon:4:43
   |
 4 |   constraint fun ordinato(i: Intervallo): Number { return i.lo }
   |                                           ^^^^^^
   = why: an invariant is a yes-or-no question about the value
   = write: constraint fun ordinato(i: Intervallo): Boolean { return i.lo <= i.hi }
```

### NO-103 `constraint-effect` · E2010 · checker

- book: PROPOSAL: no page of the book says it (`constraint fun`)
- draft: `regression/refusals/drafts/subcontains/dev_constraint_effect`

```
error[E2010]: a `constraint fun` has no effect: `ordinato` visits Output
  --> Intervallo.yon:4:51
   |
 4 |   constraint fun ordinato(i: Intervallo): Boolean visits Output { return i.lo <= i.hi }
   |                                                   ^^^^^^^^^^^^^
   = why: a constraint is checked at every construction, so it terminates and has no effect
   = write: constraint fun ordinato(i: Intervallo): Boolean { return i.lo <= i.hi }
```

### NO-104 `exitcode-literal` · E2016 · checker

- book: PROPOSAL: no page of the book says it (ExitCode)
- draft: `regression/refusals/drafts/entrypoint/dev_exit_three`
- state: the code is registered and no step produces it yet

```
error[E2016]: 3 is not an ExitCode
  --> Entry.yon:3:12
   |
 3 |     return 3
   |            ^
   = why: 3 and 4 are the exits of the runtime: a program prints its result and exits 0
   = write: _p := Output.print("3") then return 0
```

### NO-105 `iter-negative` · E2016 · checker

- book: book 04-control-flow, «Loops.» (the page still teaches `repeat at most`: to rewrite)
- draft: `regression/refusals/drafts/iter/dev_iter_negative`
- state: the code is registered and no step produces it yet

```
error[E2016]: -1 is not a number of turns
  --> Entry.yon:4:10
   |
 4 |     iter -1 do { acc <- 1 }
   |          ^^
   = why: `iter` runs over { n : Int64 where 0 <= n }
   = write: iter 1 do { acc <- 1 }
```

### NO-106 `iter-number` · E2001 · checker

- book: book 04-control-flow, «Loops.» (the page still teaches `repeat at most`: to rewrite)
- draft: `regression/refusals/drafts/iter/dev_iter_number`

```
error[E2001]: `iter` counts an Int64: n is a Number
  --> Entry.yon:4:10
   |
 4 |     iter n do { acc <- 1 }
   |          ^
   = why: a Number becomes an Int64 with `Int64.from_number(n)` and `escape`
   = write: iter escape Int64.from_number(n) do { acc <- 1 }
```

### NO-107 `div-zero-literal` · E2016 · checker

- book: book 12-standard-library, «Numbers, time, randomness, hashing»
- draft: `regression/refusals/drafts/expression/dev_div_zero`
- state: the code is registered and no step produces it yet

```
error[E2016]: 0 is not a divisor
  --> Entry.yon:2:44
   |
 2 |   fun dividi(a: Int64): Int64 { return a / 0 }
   |                                            ^
   = why: a divisor is a NonZero, so `/` never divides by zero
   = write: (a divisor that is not zero)
```

### NO-108 `div-unproven` · E2001 · checker

- book: book 12-standard-library, «Numbers, time, randomness, hashing»
- draft: `regression/refusals/drafts/expression/dev_div_int64`

```
error[E2001]: the divisor b is an Int64, not a NonZero
  --> Entry.yon:2:54
   |
 2 |   fun dividi(a: Int64, b: Int64): Int64 { return a / b }
   |                                                      ^
   = why: a divisor is a NonZero, so `/` never divides by zero
   = write: fun dividi(a: Int64, b: NonZero): Int64 { return a / b }
```

### NO-109 `arith-number` · E2011 · checker

- book: book 05-functions-and-effects, «Failure is a coproduct: `on error`»
- draft: `regression/refusals/drafts/expression/dev_arith_undeclared`

```
error[E2011]: `a + b` may be a DomainError: `total` declares `on error DomainError`
  --> Entry.yon:2:52
   |
 2 |   fun total(a: Number, b: Number): Number { return a + b }
   |                                                    ^^^^^
   = why: where the compiler cannot prove an operation safe, its error is declared
   = write: fun total(a: Number, b: Number) on error DomainError: Number { return a + b }
```

### NO-110 `arith-int64` · E2011 · checker

- book: book 05-functions-and-effects, «Failure is a coproduct: `on error`»
- draft: `regression/refusals/drafts/expression/dev_overflow_undeclared`

```
error[E2011]: `a + b` may overflow: `total` declares `on error Overflow`
  --> Entry.yon:2:49
   |
 2 |   fun total(a: Int64, b: Int64): Int64 { return a + b }
   |                                                 ^^^^^
   = why: an Int64 is exact: past its range there is no Int64
   = write: fun total(a: Int64, b: Int64) on error Overflow: Int64 { return a + b }
```

## E. Shadowing (checker, E2015)

### NO-111 `rebind-same` · E2015 · checker

- book: book 03-values-and-bindings, «Bindings are immutable.»
- proof: `regression/canonical_forms/binding/dev_rebind` (gives E2001 until its step aligns it)
- state: the code is registered and no step produces it yet

```
error[E2015]: `x` is already bound: a value is defined once
  --> Entry.yon:9:5
   |
 9 |     x := 2
   |     ^
   = why: in the body of a fun a name means one value; to change it, `mut x := …` and `x <- …`
   = write: mut x := 1  then  x <- 2
```

### NO-112 `rebind-nested` · E2015 · checker

- book: book 22-keywords, «Bindings and mutation», `:=` (it still says that shadowing in an inner block is allowed: to rewrite)
- draft: `regression/refusals/drafts/binding/dev_rebind_nested`
- state: the code is registered and no step produces it yet

```
error[E2015]: `x` is already bound in this fun
  --> Entry.yon:5:14
   |
 5 |     when c { x := 2 }
   |              ^
   = why: in the body of a fun a name means one value, also in an inner block
   = write: mut x := 1  and  when c { x <- 2 }
```

### NO-113 `rebind-arm` · E2015 · checker

- book: book 03-values-and-bindings, «Bindings are immutable.»
- draft: `regression/refusals/drafts/pattern/dev_rebind_arm`
- state: the code is registered and no step produces it yet

```
error[E2015]: `h` is already bound: the arm binds it again
  --> Entry.yon:5:40
   |
 5 |     r := match xs { Nil => 0, Cons as (h, t) => h }
   |                                        ^
   = why: a name bound in an arm is a new name in the fun, and a name means one value
   = write: Cons as (k, t) => k
```

### NO-114 `rebind-lambda` · E2015 · checker

- book: book 05-functions-and-effects, «Lambdas and pipes.» (it still teaches `|>`: to rewrite)
- draft: `regression/refusals/drafts/binding/dev_rebind_lambda`
- state: the code is registered and no step produces it yet

```
error[E2015]: `x` is already bound: the lambda takes it as a parameter
  --> Entry.yon:4:14
   |
 4 |     f := fun(x: Number) => x
   |              ^
   = why: the parameter of a lambda is a new name in the fun, and a name means one value
   = write: f := fun(y: Number) => y
```

### NO-115 `rebind-house-fun` · E2015 · checker

- book: book 03-values-and-bindings, «Bindings are immutable.»
- draft: `regression/refusals/drafts/binding/dev_rebind_house_fun`
- state: the code is registered and no step produces it yet

```
error[E2015]: `one` is a fun of this place: a binding does not take its name
  --> Entry.yon:4:5
   |
 4 |     one := 1
   |     ^^^
   = why: a name in a place means one thing: its fun, or a local value
   = write: u := 1
```

## F. The project and the manifest (E4001 / E4002 / E4003 / E4004)

### NO-116 `fun-home` · E4003 · project

- book: book 06-worlds-and-places, «A place is its structure»; PROPOSAL: no page of the book says it (the home of a fun)
- draft: `regression/refusals/drafts/topos/dev_fun_home`
- state: the code is registered and no step produces it yet

```
error[E4003]: `b2bit` returns a Bit: it lives in place Bit
  --> Bool.yon:3:7
   |
 3 |   fun b2bit(b: Bool): Bit { return match b { tt => one, ff => zero } }
   |       ^^^^^
   = why: a fun from A to B of the project lives in place B
   = write: place Bit { … fun b2bit(b: Bool): Bit { … } }
```

### NO-117 `places-per-file` · E4001 · project

- book: book 16-projects-and-packages, «A project is a directory»
- draft: `regression/refusals/drafts/place/dev_two_places`

```
error[E4001]: a file holds one place: `Coin` belongs in Coin.yon
  --> Entry.yon:1:1
   |
 1 | place Coin { value Number }
   | ^^^^^^^^^^
   = why: a .yon file is a place, with the name of the file
   = write: Coin.yon: place Coin { value Number }
```

### NO-118 `functor-in-entry` · E4001 · project

- book: book 07-arrows, «One level up: between worlds»
- draft: `regression/refusals/drafts/functor/dev_functor_in_entry`

```
error[E4001]: a functor belongs in the Topos.yon of its package
  --> Entry.yon:2:3
   |
 2 |   functor Identity from W to V { on object(x: Number): Number { return x } }
   |   ^^^^^^^
   = why: functors and nat transforms go between worlds, and they live in Topos.yon
   = write: w/Topos.yon: topos { } and after it functor Identity from W to V { … }
```

### NO-119 `main-number` · E4002 · project

- book: book 02-hello-world (a page without sections); PROPOSAL: no page of the book says it (ExitCode)
- draft: `regression/refusals/drafts/entrypoint/dev_main_number`

```
error[E4002]: `main` returns Number; it must return an ExitCode
  --> Entry.yon:2:13
   |
 2 |   fun main: Number {
   |             ^^^^^^
   = why: the exit code says only how the program ended; its result is printed
   = write: fun main: ExitCode { return 0 }
```

### NO-120 `backend-memory` · E4004 · manifest

- book: book 17-how-spaces-talk, «Choosing a runtime backend»
- draft: `regression/refusals/drafts/entrypoint/dev_backend_memory`

```
error[E4004]: `memory` is not a backend
  --> yon.toml:5:11
   |
 5 | backend = "memory"
   |           ^^^^^^^^
   = why: the runtime has two backends, `separate` and `shm`
   = write: backend = "separate"
```

### NO-121 `objects` · E4004 · manifest

- book: book 16-projects-and-packages, «The manifest»
- draft: `regression/refusals/drafts/entrypoint/dev_objects`

```
error[E4004]: `objects` is not a key of a world
  --> yon.toml:5:1
   |
 5 | objects = ["Coin"]
   | ^^^^^^^
   = why: the places of a Space are its files
   = write: (the line goes)
```

### NO-122 `kind-proof` · E4004 · manifest

- book: book 18-the-project, «Proofs in a project»
- proof to write: the proof is in Python (regression/test_meta_yon.py); the folder copies its manifest

```
error[E4004]: `kind = "proof"` is not a key of a package
   = why: a proof is marked on its fun, `proof fun`
   = write: proof fun … (the line goes)
```

### NO-169 `b` · E4002 · project

- book: PROPOSAL: no page of the book says it (entrypoint)
- proof: `regression/canonical_forms/entrypoint/dev_b`

```
error[E4002]: ENTRYPOINT ERROR
  --> Entry.yon:1:1
   |
 1 | fun main: Number { return 0 }
   | ^^^^^^^^
   = why: form B
```

## G. Soundness and the other refusals of the checker

### NO-123 `positivity` · E2020 · checker

- book: book 06-worlds-and-places, «A place is its structure»; PROPOSAL: no page of the book says it (strict positivity)
- draft: `regression/refusals/drafts/place/dev_not_positive`
- state: the code is registered and no step produces it yet

```
error[E2020]: Bad appears left of an arrow in its own field
  --> Bad.yon:1:15
   |
 1 | place Bad { f Bad -> Number }
   |               ^^^
   = why: a recursive place appears only right of the arrows of its fields, or the checker can loop
   = write: (a field where Bad appears only right of every arrow)
```

### NO-124 `index-purity` · E2021 · checker

- book: book 14-values-cells-lifetime, «Lifetime»; PROPOSAL: no page of the book says it (the purity of an index)
- draft: `regression/refusals/drafts/hott/dev_cell_in_index`
- state: the code is registered and no step produces it yet

```
error[E2021]: the index of a type reads the variable `c`
  --> Entry.yon:4:10
   |
 4 |     p := stay c
   |          ^^^^^^
   = why: the index of a type is a value; a variable can change under it
   = write: v := c  then  p := stay v
```

### NO-125 `reduce-fuel` · E2022 · checker

- book: PROPOSAL: no page of the book says it (the bound of a reduction)
- proof to write: with the step that unfolds only the certified funs
- state: the code is registered and no step produces it yet

```
error[E2022]: the computation does not finish in 1000 steps
   = why: a verdict on a term that is not fully computed is no verdict
   = write: (unfold only funs proven to terminate)
```

### NO-126 `reserved-prefix` · E1002 · grammar

- book: PROPOSAL: no page of the book says it (the reserved prefix)
- draft: `regression/refusals/drafts/function/dev_reserved_prefix`

```
error[E1002]: a name of the program does not begin with `__`
  --> Entry.yon:2:7
   |
 2 |   fun __band(a: Number, b: Number): Number { return a }
   |       ^^^^^^
   = why: `__` begins the names the compiler makes
   = write: fun band_two(a: Number, b: Number): Number
```

### NO-127 `stream-twice` · E2014 · checker

- book: book 17-how-spaces-talk, «The channel»
- proof to write: with the refusal of the second read of a Stream: a program that reads a wire twice
- state: the code is registered and no step produces it yet

```
error[E2014]: the stream `s` is read a second time
   = why: a stream is read once: its values are not kept
   = write: (read it once, keep what is needed in a List)
```

### NO-128 `multishot-proof` · E2010 · checker

- book: book 18-the-project, «Proofs in a project»
- proof to write: the inline reduction inside a proof fun is read off frontend/parser.mly

```
error[E2010]: `multishot` is refused in a proof fun
   = why: resuming a reduction more than once makes the logic classical
   = write: (a reduction without multishot)
```

### NO-129 `discarded-call` · E2023 · checker

- book: book 05-functions-and-effects, «Effects: `visits`»
- draft: `regression/refusals/drafts/function/dev_discarded_call`
- state: the code is registered and no step produces it yet

```
error[E2023]: the value of `one(1)` is computed and thrown away
  --> Entry.yon:4:5
   |
 4 |     one(1)
   |     ^^^^^^
   = why: a statement is a call with an effect; a pure value is used, or not computed
   = write: (use the value, or remove the call)
```

### NO-130 `discarded-mediatrix` · E2023 · checker

- book: PROPOSAL: no page of the book says it (the mediator ⟨ ⟩)
- draft: `regression/refusals/drafts/new/dev_discarded_mediatrix`
- state: the code is registered and no step produces it yet

```
error[E2023]: the value Vote ⟨ value 7 ⟩ is written and thrown away
  --> Entry.yon:3:5
   |
 3 |     Vote ⟨ value 7 ⟩
   |     ^^^^^^^^^^^^^^^^
   = why: a value written P ⟨ … ⟩ goes in a variable
   = write: v := Vote ⟨ value 7 ⟩
```

### NO-131 `law-outside` · E2017 · checker

- book: book 06-worlds-and-places, «Certified laws: the algebra you declare is the algebra you get»
- draft: `regression/refusals/drafts/algebra/dev_law_outside`
- state: the code is registered and no step produces it yet

```
error[E2017]: a law lives only in an algebra: Entry is not an algebra
  --> Entry.yon:2:3
   |
 2 |   law riflessiva ∀x : Number, x = x
   |   ^^^
   = why: a law is a promise of an algebra, and the checker judges it
   = write: (the law goes in the algebra; a proven statement is a proof fun)
```

### NO-132 `law-cell` · E2017 · checker

- book: book 06-worlds-and-places, «Coproducts: the injection is an arrow of the sum»; PROPOSAL: no page of the book says it (the cells of a higher inductive place)
- draft: `regression/refusals/drafts/variant/dev_law_cell`
- state: the code is registered and no step produces it yet

```
error[E2017]: a law in a place with arms is not a cell: write `cell`
  --> Circle.yon:1:29
   |
 1 | place Circle { this > base  law loop base = base }
   |                             ^^^
   = why: a path in a place with arms is a cell
   = write: cell loop from base to base
```

### NO-133 `law-model` · E2017 · checker

- book: book 06-worlds-and-places, «Certified laws: the algebra you declare is the algebra you get»
- draft: `regression/refusals/drafts/algebra/dev_law_model`
- state: the code is registered and no step produces it yet

```
error[E2017]: a model declares no law: its algebra does
  --> Or.yon:3:3
   |
 3 |   law commutative ∀a : Number ∀b : Number, op(a, b) = op(b, a)
   |   ^^^
   = why: the laws are the algebra's; a model gives the operations
   = write: (the line goes)
```

### NO-134 `algebra-carried` · E2018 · checker

- book: book 06-worlds-and-places, «Certified laws: the algebra you declare is the algebra you get»
- draft: `regression/refusals/drafts/algebra/dev_algebra_carried`
- state: the code is registered and no step produces it yet

```
error[E2018]: an algebra has no layout
  --> Pair.yon:1:12
   |
 1 | place Pair carried by i64 {
   |            ^^^^^^^^^^^^^^
   = why: the layout belongs to a model, not to the algebra
   = write: place Pair {
```

### NO-135 `carried-number` · E2019 · checker

- book: book 06-worlds-and-places, «Sub-objects»
- draft: `regression/refusals/drafts/fusion/dev_carried_number`
- state: the code is registered and no step produces it yet

```
error[E2019]: `number` is not a layout
  --> Byte.yon:1:23
   |
 1 | place Byte carried by number { this < Int64 }
   |                       ^^^^^^
   = why: a layout is f64, i64, i32 or i1
   = write: carried by f64
```

### NO-136 `field-fun-clash` · E2005 · checker

- book: book 06-worlds-and-places, «A place is its structure»
- draft: `regression/refusals/drafts/place/dev_field_fun_clash`

```
error[E2005]: `value` is a field of Vote and a fun of Vote
  --> Vote.yon:2:7
   |
 2 |   fun value(v: Vote): Number { return 0 }
   |       ^^^^^^
   = why: a name in a place means one thing
   = write: (rename the fun)
```

### NO-137 `sub-same-field` · E2001 · checker

- book: book 06-worlds-and-places, «Sub-objects»
- draft: `regression/refusals/drafts/subcontains/dev_same_field`

```
error[E2001]: `message` is a field of Error: Mine already has it
  --> Mine.yon:1:28
   |
 1 | place Mine { this < Error  message Text }
   |                            ^^^^^^^
   = why: a sub-object has the fields of its parent and does not write them again
   = write: place Mine { this < Error }
```

### NO-138 `int64-additive` · E2001 · checker

- book: book 06-worlds-and-places, «Certified laws: the algebra you declare is the algebra you get»
- proof to write: with the numbers without primitives; the words are those of bound_parameter/dev_no_model

```
error[E2001]: Int64 does not use Additive
   = why: an Int64 sum can fail, and an operation of a model never fails
   = write: (Word64 is the model)
```

### NO-139 `cell-escapes` · E2001 · checker

- book: book 14-values-cells-lifetime, «Lifetime»
- draft: `regression/refusals/drafts/cell/dev_cell_escapes`

```
error[E2001]: the lambda reads the variable `acc`, which dies with its block
  --> Entry.yon:4:30
   |
 4 |     return fun(x: Number) => acc
   |                              ^^^
   = why: a variable lives as long as the block that declares it
   = write: (capture a value: v := acc, then read v)
```

### NO-140 `cross-space-escape` · E2012 · checker

- book: book 17-how-spaces-talk, «The channel»
- proof to write: with the errors of the Spaces: a manifest of two Spaces

```
error[E2012]: `deposit_net(5)` may be a WireError: it is read with escape
   = why: a fun of another Space returns (T + E) + WireError
   = write: y := escape deposit_net(5)
```

### NO-141 `name-case` · E4001 · project

- book: book 16-projects-and-packages, «A project is a directory»
- proof to write: a filesystem that does not tell upper from lower case cannot hold the two files: the proof runs on Linux only

```
error[E4001]: Vote.yon and voto.yon differ only by case
   = why: on macOS and Windows they are the same file
   = write: (one name)
```

### NO-157 `path-junction` · E2001 · checker

- book: book 09-hott-types, «Paths as journeys»
- draft: `regression/refusals/drafts/hott/dev_path_junction`

```
error[E2001]: the paths do not meet: the first ends at `tt`, the second starts at `ff`
  --> Entry.yon:7:18
   |
 7 |   r := concat(p, q)
   |                  ^^
   = why: two paths join only where the first ends and the second starts, in the same type
   = write: a second path that starts at `tt`, or a first path that ends at `ff`
```

### NO-163 `unbound` · E2001 · checker

- book: PROPOSAL: no page of the book says it (assignment)
- proof: `regression/canonical_forms/assignment/dev_unbound`

```
error[E2001]: unknown identifier
  --> Entry.yon:4:5
   |
 4 |     return y
   |     ^^^^^^^^
   = why: writing a name that was never bound; <- updates an existing cell, it does not declare
```

### NO-165 `ambiguous` · E2001 · checker

- book: PROPOSAL: no page of the book says it (bound_parameter)
- proof: `regression/canonical_forms/bound_parameter/dev_ambiguous`

```
error[E2001]: is ambiguous: Int64 has 2 structures
  --> Entry.yon:7:1
   |
 7 | fun of_one(a: Int64): Int64 { return concat_all(List.cons(a, List.empty)) }
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: is ambiguous: Int64 has 2 structures
```

### NO-166 `no-model` · E2001 · checker

- book: PROPOSAL: no page of the book says it (bound_parameter)
- proof: `regression/canonical_forms/bound_parameter/dev_no_model`

```
error[E2001]: Number does not use Monoid
  --> Entry.yon:8:3
   |
 8 |   fun main: Number { return concat_all(List.cons(1, List.empty)) }
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: number does not use Monoid
```

### NO-167 `old-injection` · E2001 · checker

- book: PROPOSAL: no page of the book says it (coproduct)
- proof: `regression/canonical_forms/coproduct/dev_old_injection`

```
error[E2001]: written x ↪ Full
  --> Entry.yon:3:24
   |
 3 |   fun mk: Box { return .-> Full { _1 1 } }
   |                        ^^^
   = why: an injection into a payload arm is x ↪ Arm: the mediatrice is for a place with fields
   = write: x ↪ Full
```

### NO-170 `apply-to-arm` · E2001 · checker

- book: PROPOSAL: no page of the book says it (expression)
- proof: `regression/canonical_forms/expression/dev_apply_to_arm`

```
error[E2001]: Full is an arm: an injection is written x ↪ Full
  --> Entry.yon:3:26
   |
 3 |   fun mk(): Box { return 1 ↦ Full }
   |                          ^
   = why: application goes to a fun; the diagnostic shows injection
   = write: x ↪ Full
```

### NO-171 `arity` · E2001 · checker

- book: PROPOSAL: no page of the book says it (expression)
- proof: `regression/canonical_forms/expression/dev_arity`

```
error[E2001]: expected 1 arguments, got 2
  --> Entry.yon:5:3
   |
 5 |   fun main: Number { return f(1, 2) }
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: wrong number of arguments at a call site
```

### NO-173 `inject-to-fun` · E2001 · checker

- book: PROPOSAL: no page of the book says it (expression)
- proof: `regression/canonical_forms/expression/dev_inject_to_fun`

```
error[E2001]: twice is a fun: it is applied with x ↦ twice
  --> Entry.yon:3:29
   |
 3 |   fun main: Number { return 21 ↪ twice }
   |                             ^^
   = why: injection goes to an arm; the diagnostic shows application
   = write: x ↦ twice
```

### NO-174 `unknown` · E2001 · checker

- book: PROPOSAL: no page of the book says it (expression)
- proof: `regression/canonical_forms/expression/dev_unknown`

```
error[E2001]: unknown identifier
  --> Entry.yon:4:3
   |
 4 |   fun main: Number { return nonexistent }
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: a reference to a name that is not bound
```

### NO-175 `dup-param` · E2001 · checker

- book: PROPOSAL: no page of the book says it (function)
- proof: `regression/canonical_forms/function/dev_dup_param`

```
error[E2001]: duplicate parameter
  --> Entry.yon:3:1
   |
 3 | place Entry {
   | ^^^^^^^^^^^^^
   = why: two parameters with the same name would silently shadow
```

### NO-176 `empty-body` · E2001 · checker

- book: PROPOSAL: no page of the book says it (function)
- proof: `regression/canonical_forms/function/dev_empty_body`

```
error[E2001]: empty body but a return type
  --> Entry.yon:4:1
   |
 4 | place Entry {
   | ^^^^^^^^^^^^^
   = why: a declared return type with no body has no value to return
```

### NO-177 `false-id` · E2001 · checker

- book: PROPOSAL: no page of the book says it (hott)
- proof: `regression/canonical_forms/hott/dev_false_id`

```
error[E2001]: type mismatch
  --> Entry.yon:3:35
   |
 3 |   proof fun bogus: 1 = 2 { return refl(1) }
   |                                   ^^^^
   = why: a false identity proof (1 = 2) rejected: the runtime never decides path equality
```

### NO-178 `path-nonpath` · E2001 · checker

- book: PROPOSAL: no page of the book says it (hott)
- proof: `regression/canonical_forms/hott/dev_path_nonpath`

```
error[E2001]: path application
  --> Entry.yon:2:29
   |
 2 |   fun main: Number { return 5 @ I0 }
   |                             ^
   = why: path application @ of a non-path value
```

### NO-179 `quote-carrier` · E2001 · checker

- book: PROPOSAL: no page of the book says it (hott)
- proof: `regression/canonical_forms/hott/dev_quote_carrier`

```
error[E2001]: quote
  --> Entry.yon:7:5
   |
 7 |     q := quote(Number, "text")
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: quote(c, a) where the inhabitant mistypes the carrier
```

### NO-181 `plain-fn` · E2001 · checker

- book: PROPOSAL: no page of the book says it (move)
- proof: `regression/canonical_forms/move/dev_plain_fn`

```
error[E2001]: expects morph
   --> Entry.yon:15:5
    |
 15 |     return run(plain)
    |     ^^^^^^^^^^^^^^^^^
    = why: a plain arrow passed where a morphism is required; handle-type stratification
```

### NO-182 `assign` · E2001 · checker

- book: PROPOSAL: no page of the book says it (produce)
- proof: `regression/canonical_forms/produce/dev_assign`

```
error[E2001]: is not supported inside
  --> Entry.yon:8:7
   |
 8 |       iter 3 do { emit i  i <- i + 1 }
   |       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: <- (a cell write) into a cell declared outside a produce body is refused: a produce is a value
```

### NO-183 `tail-mismatch` · E2001 · checker

- book: PROPOSAL: no page of the book says it (return)
- proof: `regression/canonical_forms/return/dev_tail_mismatch`

```
error[E2001]: declares return type Number
  --> Entry.yon:6:3
   |
 6 |   fun h: Number { y := "text" }
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: the implicit-return tail has the wrong type
```

### NO-184 `type-mismatch-return` · E2001 · checker

- book: PROPOSAL: no page of the book says it (return)
- proof: `regression/canonical_forms/return/dev_type_mismatch`

```
error[E2001]: expected Number, got Text
  --> Entry.yon:5:3
   |
 5 |   fun main: Number { return "text" }
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: returning text where number is declared
```

### NO-185 `missing-branch` · E2001 · checker

- book: PROPOSAL: no page of the book says it (variant)
- proof: `regression/canonical_forms/variant/dev_missing_branch`

```
error[E2001]: missing branch
  --> Entry.yon:3:37
   |
 3 |   fun pick(s: Sum): Number { return match s { B as x => x } }
   |                                     ^^^^^
   = why: a match missing a constructor branch
```

### NO-186 `payload-type-variant` · E2001 · checker

- book: PROPOSAL: no page of the book says it (variant)
- proof: `regression/canonical_forms/variant/dev_payload_type`

```
error[E2001]: expected Number, got Text
  --> Entry.yon:3:3
   |
 3 |   fun wrong: Sum { return "not a number" ↪ B }
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   = why: a variant payload of the wrong type: .-> B { _1 "not a number" } where B carries number
```

### NO-187 `wrong-arity` · E2001 · checker

- book: PROPOSAL: no page of the book says it (variant)
- proof: `regression/canonical_forms/variant/dev_wrong_arity`

```
error[E2001]: branch inj expects 1 binder(s), got 2
  --> Entry.yon:5:12
   |
 5 |     return match seven { inj as (x, y) => x, quot as (a, b, r) => clear 0 }
   |            ^^^^^
   = why: a match branch with the wrong payload arity
```

## H. Qualification between places and between Spaces (E2019 Writing_refused)

### NO-142 `bare-other-place` · E2019 · checker

- book: book 06-worlds-and-places, «A place is its structure»; PROPOSAL: no page of the book says it (the qualification between places)
- draft: `regression/refusals/drafts/function/dev_bare_other_place`
- state: the code is registered and no step produces it yet

```
error[E2019]: `bit2b` is a fun of place Bool: it is named `Bool.bit2b`
  --> Bit.yon:3:32
   |
 3 |   proof fun eps(b: Bit): b2bit(bit2b(b)) = b { return match b { one => stay one, zero => stay zero } }
   |                                ^^^^^
   = why: in its own place a fun is named bare; from another place of the Space it is named with the dot
   = write: Bool.bit2b(b)
```

### NO-143 `colon-same-space` · E2019 · project

- book: book 11-spaces-and-packages, «Cross-package imports»; PROPOSAL: no page of the book says it (the qualification between places)
- draft: `regression/refusals/drafts/function/dev_colon_same_space`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Bit` is in this Space: its fun is named `Bit.b2bit`
  --> Entry.yon:3:21
   |
 3 |     return match Bit::b2bit(tt) { one => 1, zero => 0 }
   |                     ^^
   = why: the dot is a call inside the Space; `::` crosses to another Space and brings WireError
   = write: Bit.b2bit(tt)
```

### NO-152 `colon-prefix` · E2019 · project

- book: book 11-spaces-and-packages, «Cross-package imports»; PROPOSAL: no page of the book says it (the qualification between places)
- draft: `regression/refusals/drafts/binding/dev_colon_prefix`
- state: the code is registered and no step produces it yet

```
error[E2019]: `d_op` lives in place DP of Space D, a concrete Space: it is called through a wire
  --> Entry.yon:1:8
   |
 1 | import svc::d_op
   |        ^^^
   = why: the name before `::` is the place where the fun lives, and only the code of an abstract Space is imported
   = write: w := wire to space D, then escape w.d_op(5)
```

### NO-155 `import-concrete` · E2019 · project

- book: book 11-spaces-and-packages, «Cross-package imports»; PROPOSAL: no page of the book says it (concrete and abstract Spaces)
- draft: `regression/refusals/drafts/binding/dev_import_concrete`
- state: the code is registered and no step produces it yet

```
error[E2019]: `Bank` is a concrete Space: it is reached through a wire, not imported
  --> Entry.yon:1:8
   |
 1 | import Bank::deposit_net
   |        ^^^^^^^^^^^^^^^^^
   = why: an import copies the code of a Space whose topos is `abstract topos`; between two concrete Spaces only a wire passes
   = write: w := wire to space Bank, then escape w.deposit_net(5)
```

### NO-156 `abstract-state` · E2024 · checker

- book: book 17-how-spaces-talk, «The channel»; PROPOSAL: no page of the book says it (concrete and abstract Spaces)
- draft: `regression/refusals/drafts/spawn/dev_abstract_wire`
- state: the code is registered and no step produces it yet

```
error[E2024]: an abstract Space holds no wire: `wire to space Bank` opens one
  --> Rates/Rates.yon:3:10
   |
 3 |     w := wire to space Bank
   |          ^^^^^^^^^^^^^^^^^^
   = why: the topos of an abstract Space is a theory; the wire and the state belong to the concrete Space that imports it
   = write: open the wire in a concrete Space; an abstract Space may declare the types of its messages
```

## The codes of the catalogue

Read from `frontend/error_codes.ml`.

| code | variant | title | entries |
|---|---|---|---|
| E1001 | `Parse_syntax` | syntax error | 3 |
| E1002 | `Lex_bad_token` | lexical error | 3 |
| E1003 | `Form_gone` | a form of the language that is gone: the message writes the new one | 85 |
| E1004 | `Head_refused` | a modifier or a clause that the declaration does not take (`is given` on a proof fun, a constraint fun, a law, a carrier; `internal constraint`; `proof constraint`) | 7 |
| E2001 | `Type_check` | type error | 27 |
| E2005 | `Arm_name_clash` | an arm and an arrow of the same home share a name | 1 |
| E2010 | `Proof_rule` | what a proof fun refuses: no termination certificate, is given, forever, while, a call of a fun the termination check does not certify, a call from code that runs | 2 |
| E2011 | `Error_undeclared` | an escape whose error has no way out: the signature does not declare it, or the code is a lambda, a producer or a spawn | 3 |
| E2012 | `Escape_missing` | a value that may be an error is read where its success is wanted without escape | 2 |
| E2014 | `Stream_read_twice` | the same Stream is read a second time: a Stream is read once | 1 |
| E2015 | `Name_rebound` | a name already bound in the fun is bound again (a block, an arm, a lambda, a fun of the house) | 5 |
| E2016 | `Constraint_refuted` | a literal does not satisfy the constraint of the place it enters (a constraint fun, ExitCode, NonZero, the turns of iter) | 4 |
| E2017 | `Law_outside_algebra` | a law lives outside an algebra (in a model, in a place with arms, in any other place) | 3 |
| E2018 | `Algebra_carried` | an algebra has a carrier: the layout belongs to a model | 1 |
| E2019 | `Writing_refused` | a writing the checker refuses by its type: the message writes the right one (a name that is gone, a second way to write a fun, a fun without arguments read with (), an effect without (), a name without its place, `::` inside one Space, a prefix of `::` that is not the place of the fun) | 30 |
| E2020 | `Place_not_positive` | a recursive place is not strictly positive | 1 |
| E2021 | `Index_impure` | the index of a type reads a cell | 1 |
| E2022 | `Reduction_unfinished` | a reduction of the kernel does not reach its normal form within the bound | 1 |
| E2023 | `Value_discarded` | a value computed or indicated and thrown away | 2 |
| E2024 | `Abstract_holds_state` | an abstract Space holds state (a wire end, an initialization that outlives a call): the state belongs to the concrete Space that imports it | 1 |
| E4001 | `Topos_layout` | topos layout violation | 3 |
| E4002 | `Entrypoint` | entrypoint violation | 2 |
| E4003 | `File_layout` | file layout violation | 1 |
| E4004 | `Manifest` | manifest error | 3 |
