---
title: "Keywords, one by one"
---

import CodeWindow from '@site/src/components/CodeWindow';

# Keywords, one by one

Every reserved word of Yon, explained next to a compiling example.
Each snippet on this page is a file from `examples/` in the
repository: it builds and runs in the regression suite, with the exit
code shown.

This chapter answers *what does it mean?* For the normative table of
valid forms, with status per construct, see the
[Syntax Reference](/syntax-reference); for the maintainers' census,
`KEYWORDS.md` in the repository root.

## Top-level declarations

A Yon program is a list of these.

#### `world`

Declares a category: a collection of objects (places) and the structure-preserving maps between them. Every place lives in a world, and the world's `Code is X` clause names its coordinate enum.

#### `place`

An object living in a world: named fields, and operations when declared `with effects`. Instances are built with `new P { field value }`.

#### `space`

A runtime heap where instances of a place are allocated and addressed; equality inside a Space is the content-addressed single comparison of the xleech2 heap.

#### `import`

Brings a module or a qualified symbol into scope: `import "x/rates"`, `import q as a`. Multi-file by nature; see the chapter on projects and packages.

#### `internal`

Marks a function as not exported across Spaces: it never enters the cross-Space dispatch table.

## Bindings and mutation

#### `be`

The only binding form, and it is immutable: `be x holds e`. There is no `let` and no rebinding.

#### `holds`

The "equals" of the binding: it reads as English and it means *holds this value, permanently*.

#### `becomes`

Mutation, reserved to cells: `x becomes e`. Where `be` is a promise, `becomes` is an update; rebinding a `be` name does not exist.

#### `partial`

Marks a function that may not return on every input. The checker treats its calls accordingly.

## Control flow

#### `when`

The conditional chain: `when c { } when c2 { } otherwise { }`. Consecutive `when` blocks form one chain and the first true branch wins. Branches are for effects: a `return` inside a branch does not exit the function; select values with `if`/`then`/`else` instead.

#### `otherwise`

The else branch, of a `when` chain and of `repeat at most N times`.

#### `if`

Expression-level conditional: `if c then a else b` selects a value, and lowers to `scf.if`. Use it where the branch *is* the result.

#### `then`

Introduces the value of the true branch of `if`.

#### `else`

Introduces the value of the false branch of `if`.

#### `iter`

`iter N do { }`: the bounded loop. It always terminates, by construction.

#### `while`

`while cond do { }`: the general loop. It may not terminate, and that is its job.

#### `do`

Introduces the body of `iter` and `while`.

#### `for`

With `every`: `for every x in e { }`, iteration over a List. In 1.0 execution is sequential.

#### `every`

The companion of `for`; see above.

#### `here`

`for every x in e when here { }`: the Space filter in the for-every header. Declared intent in 1.0: execution is sequential and every element passes.

#### `sequence`

`in sequence over x in e { }`: iteration that is sequential by declaration, not by accident.

#### `repeat`

`repeat at most N times { } otherwise { }`: the body runs up to N times, then the otherwise.

#### `at`

Part of the `repeat at most N times` form.

#### `most`

Part of the `repeat at most N times` form.

#### `times`

Part of the `repeat at most N times` form.

#### `forever`

The infinite loop, typically wrapped around effects: a server, a producer, a heartbeat.

<CodeWindow file="v1_control_flow.yon"
            run="yonc v1_control_flow.yon -o v1_control_flow && ./v1_control_flow; echo $?"
            out={["42"]}>
{`fun main(): number {
  be acc holds 0
  be lst holds List.cons(5, List.cons(7, List.cons(9, List.empty(0))))

  for every x in lst { acc becomes acc + x }            // 21
  in sequence over y in lst { acc becomes acc + 1 }     // 24
  repeat at most 3 times { acc becomes acc + 2 }        // 30
  otherwise { acc becomes acc + 1 }                     // 31

  be d holds 2s + 500ms                                 // 2500 (ms)
  when d == 2500 { acc becomes acc + 10 }               // 41

  be i holds 0
  while i < 1 do {
    acc becomes acc + 1                                 // 42
    i becomes i + 1
  }
  return acc
}`}
</CodeWindow>

#### `scope`

The formally hermetic block: `scope { }` lowers to an MLIR `IsolatedFromAbove` region and the verifier enforces that nothing leaks in or out.

<CodeWindow file="hermetic_scope.yon"
            run="yonc hermetic_scope.yon -o hermetic_scope && ./hermetic_scope; echo $?"
            out={["42"]}>
{`fun main(): number {
  be base holds 40
  scope Hermetic {
    be sealed holds base + 2
  }
  return base + 2
}`}
</CodeWindow>

#### `forces`

The Kripke-Joyal forcing block: `forces stage cond { }` runs its body at a stage of the site, where the condition is forced. See the Heyting core chapter for the worked example.

<CodeWindow file="forcing_demo.yon"
            run="yonc forcing_demo.yon -o forcing_demo && ./forcing_demo; echo $?"
            out={["0"]}>
{`world Net { Code is X }
place NodeA in Net { value number }
fun guard(): number {
  forces NodeA value is number {
    return 1
  }
  return 0
}
fun main(): number { return 0 }`}
</CodeWindow>

#### `produce`

The producer block: `produce { ... }` builds a stream, the body emits into it, and the value of the block is the stream, consumed with `for every`. The close is structural: when the block ends, nobody can write any more, so the stream closes itself, and the consuming loop stops on its own. It works as an expression, so the canonical idiom is `be s holds produce { ... }`.

#### `emit`

Emits a value: into the stream being built inside a `produce` block, or into the active handler inside a reduction's `on` clause.

<CodeWindow file="kw_produce_emit.yon" run="yonc kw_produce_emit.yon -o produce_emit && ./produce_emit; echo $?" out={["42"]}>

```yon
fun main(): number {
  be s holds produce {
    emit 41
    emit 1
  }
  be total holds 0
  for every v in s {
    total becomes total + v
  }
  return total        // 41 + 1 = 42
}
```

</CodeWindow>

#### `return`

Returns from the function. Inside a `when` branch it does not exit the function; branches are for effects.

#### `new`

Instance construction: `new P { field value }`. With `new P in S { }` the instance is allocated in the Space S.

## Word-form operators

#### `and`

Conjunction, in expressions and in pattern conditions: `when a is present and b is present`.

#### `or`

Disjunction, same positions as `and`.

#### `all`

Quantification over the sections of a place: `all P where cond`.

#### `where`

The constraint of `all`, of the `topos ... where { }` block, and of the comprehension `{ x : A where P }`: the subobject carved out by the fibre P. With a mere-proposition fibre the comprehension is exactly the classified subobject of the formalization.

<CodeWindow file="comprehension_carrier.yon"
            run="yonc comprehension_carrier.yon -o comprehension_carrier && ./comprehension_carrier; echo $?"
            out={["0"]}>
{`world W { Code is X }
place Account in W { balance number }
fun takes_sub(s: { a : Account where Pi(x: Account). Pi(y: Account). Id(Account, x, y) }): number { return 0 }
fun main(): number { return 0 }`}
</CodeWindow>

## The four kinds of handle

Static structures of the topos: they compose, they do not nest.

#### `fun`

The ordinary function, and the inline lambda form `fun(x) => e` where an argument expects one.

#### `move`

A map between two places: `move m from A to B { }` with a body of mapping clauses, or the inline `move(s: P) => e from P to Q`. Applied with `apply_move`.

#### `view`

A representable functor on a place: the declaration `view V of P { show ... }` (lowered to a record place plus a constructor) or the inline `view(s: P) => e of P`.

#### `reduction`

Folds a structure to a value. Declared `reduction ... of P { on op { } be seed holds e }` against a place with effects, or inline `reduction(acc, x) => e of P`.

#### `operation`

A method signature exposed by a place `with effects`; it carries an effect and may bind to a certified algebra with `uses algebra`.

#### `cell`

A higher cell inside a place, CaTT style: the seed of the higher-dimensional structure.

<CodeWindow file="handle_lambdas.yon"
            run="yonc handle_lambdas.yon -o handle_lambdas && ./handle_lambdas; echo $?"
            out={["44"]}>
{`world W { Code is X }
place P in W { v number }
place Q in W { v number }
place R in W { v number }
fun main(): number {
  be m1 holds move(s: P) => new Q { v 1 } from P to Q
  be m2 holds move(s: Q) => new R { v 2 } from Q to R
  be mm holds compose m1 with m2
  be sp holds new P { v 0 }
  be sr holds mm(sp)
  be vw holds view(s: P) => 40 of P
  be forty holds vw(sp)
  return forty + 4
}`}
</CodeWindow>

## Views and `show`

#### `show`

Inside a view declaration: `show f` exposes the field, `show f = e` a derived value, `show f as "label"` keeps the field with presentation metadata.

#### `as`

The aliasing word: `import q as a`, `init X as Space`, `show f as "label"`.

<CodeWindow file="kw_view_show.yon"
            run="yonc kw_view_show.yon -o view_show && ./view_show; echo $?"
            out={["8"]}>
{`world W { Code is X }
place Account in W { balance number
  fee number }
view Snapshot of Account {
  show balance
  show net = balance - fee
  show fee as "monthly fee"
}
fun main(): number {
  be acc holds new Account { balance 50
    fee 8 }
  be snap holds Snapshot(acc)
  return snap.net + snap.fee - snap.balance + 8    // 42 + 8 - 50 + 8 = 8
}`}
</CodeWindow>

## Moves and mapping clauses

#### `unifies`

The merge move: `move m unifies A, B { }` merges two places field by field, applied with `Move.merge(m, s1, s2)`; the result lives in the first source place.

#### `share`

In the merge move: the fields shared without conflict.

#### `resolves`

`conflict on f resolves to fn`: the function that decides a conflicting field, applied to both values.

#### `maps`

`A maps to B by f`: the rename clause of a move (the `by` is mandatory).

#### `converts`

`A converts to B by f`: the transform clause.

#### `aggregates`

`src aggregates to dst by f`: the aggregation clause, one source in the grammar. The three kinds are operationally `f(source)`; the distinction is declared intent.

<CodeWindow file="kw_merge_move.yon"
            run="yonc kw_merge_move.yon -o merge_move && ./merge_move; echo $?"
            out={["22"]}>
{`world W { Code is X }
place A in W { v number
  w number }
place B in W { v number
  w number }
place Wide in W { x number
  y number }
place Narrow in W { x number
  total number }
fun pick(a: number, b: number): number { return a }
fun ident(x: number): number { return x }
fun double(x: number): number { return x * 2 }
move Merge unifies A, B {
  share v
  conflict on w resolves to pick
}
move Squeeze from Wide to Narrow {
  x maps to x by ident
  y aggregates to total by double
}
fun main(): number {
  be a holds new A { v 7
    w 1 }
  be b holds new B { v 7
    w 9 }
  be m holds Move.merge(Merge, a, b)
  be wide holds new Wide { x 4
    y 5 }
  be narrow holds apply_move(Squeeze, wide)
  return m.v + m.w + narrow.x + narrow.total   // 7 + 1 + 4 + 10 = 22
}`}
</CodeWindow>

## Certified algebra

#### `algebra`

Names an algebra from the certified catalog: `uses algebra Additive`.

#### `uses`

Binds an operation to its algebra; the compiler checks the claim against the catalog.

#### `law`

Declares an algebraic law on a place; a false claim is rejected at compile time.

#### `lawful`

Reduction modifier: the law is declared and verified.

#### `invertible`

Reduction modifier: the reduction is invertible.

#### `solve`

Instantiates a law-verified place as a runnable handle.

#### `fold`

Names a space's fold function: `with fold "sum_f64"`.

<CodeWindow file="magma_solve_full.yon"
            run="yonc magma_solve_full.yon -o magma_solve_full && ./magma_solve_full; echo $?"
            out={["3"]}>
{`world Alg { Code is X }

place AddPlace in Alg with effects {
  operation add(a: number, b: number): number uses algebra Additive
  law commutative
  law associative
  law monotone
}

fun main(): number {
  be m holds solve AddPlace
  be m1 holds Magma.gen(m, 3)
  be m2 holds Magma.gen(m1, 5)
  be m3 holds Magma.gen(m2, 11)
  /* subset-sum: 8 = 3+5 is reachable -> mask 3 */
  return Magma.subsetsum_mask(m3, 8)
}`}
</CodeWindow>

## Functors and directions

#### `functor`

A map between worlds that preserves the categorical structure; composable with `compose`.

#### `compose`

Handle composition with kind discipline: `(compose f with g)(x) = g(f(x))`.

#### `functorial`

Marks an operation that behaves as a functor: lifted automatically along world morphisms.

#### `forward`

Reduction direction: forward.

#### `backward`

Reduction direction: backward.

#### `bi`

Bidirectional reduction. Also a reserved word on its own; see the reference.

<CodeWindow file="functor_compose_inline.yon"
            run="yonc functor_compose_inline.yon -o functor_compose_inline && ./functor_compose_inline; echo $?"
            out={["0"]}>
{`world W { Code is X }
world V { Code is Y }
world U { Code is Z }
fun main(): number {
  be h holds compose (functor (x: number) => x from W to V) with (functor (y: number) => y from V to U)
  return 0
}`}
</CodeWindow>

<CodeWindow file="kw_reduction_modifiers.yon"
            run="yonc kw_reduction_modifiers.yon -o reduction_modifiers && ./reduction_modifiers; echo $?"
            out={["0"]}>
{`world W { Code is X }
place Tally in W with effects { total number
  operation add(x: number): number }
reduction bi lawful invertible Sum of Tally with multishot fold "sum_f64" {
  be seed holds 0
  on add(x: number) {
    return x
  }
}
reduction backward Rewind of Tally {
  be seed holds 0
}
fun main(): number { return 0 }`}
</CodeWindow>

## The explicit topos vocabulary

#### `topos`

The first-class declaration: a category rich enough to do logic inside, with its objects, terminal, morphisms and props in one `where` block.

#### `objects`

Lists the objects of the topos: place declarations.

#### `morphisms`

Lists the maps of the topos: operation signatures.

#### `terminal`

Names the one-point object.

#### `prop`

A subobject classifier map into Omega: `prop is_overdrawn(s): proposition = ...`. Syntactically it signals the categorical intent, a subobject rather than an arbitrary function.

#### `topology`

Equips a place with a Lawvere-Tierney operator j : Omega to Omega, the seed of sheaf semantics.

<CodeWindow file="kw_topos_block.yon"
            run="yonc kw_topos_block.yon -o topos_block && ./topos_block; echo $?"
            out={["42"]}>
{`world Ledger { Code is X }
topos Bank in Ledger where {
  objects {
    place State in Ledger { balance number }
    place Unit1 in Ledger { u number }
  }
  terminal Unit1
  morphisms {
    operation tag(s: State): number
    functorial operation lift(s: State): number
  }
  prop is_overdrawn(s: State): proposition = s.balance < 0
}
topology j of State { return 1 }
fun main(): number {
  be s holds new State { balance 5 }
  be bad holds is_overdrawn(s)
  return if bad then 0 else 42
}`}
</CodeWindow>

#### `morph`

A single functor between topoi: `morph F from A to B { }` with the two-word contextual aspects `on object` and `on morphism ... via ...`.

#### `via`

In `on morphism op via op2`: names the operation that realizes the map.

<CodeWindow file="kw_morph.yon"
            run="yonc kw_morph.yon -o morph && ./morph; echo $?"
            out={["0"]}>
{`world Shop { Code is X }
place Account in Shop { balance number }
place AccountEU in Shop { balance number }
morph LiftEU from Account to AccountEU {
  on object(s: Account): AccountEU {
    return new AccountEU { balance s.balance }
  }
}
fun main(): number { return 0 }`}
</CodeWindow>

#### `each`

In `for each X by fnX` inside a `nat transform`: one component per object of the natural transformation.

<CodeWindow file="nat_transform_functor.yon"
            run="yonc nat_transform_functor.yon -o nat_transform_functor && ./nat_transform_functor; echo $?"
            out={["0"]}>
{`world W { Code is X }
world V { Code is Y }

functor F(x: number) from W to V { return x }
functor G(x: number) from W to V { return x }

nat transform Eta from F to G {
  for each X by F
}

fun main(): number { return 0 }`}
</CodeWindow>

## Categorical constructions

#### `geomorph`

The geometric morphism between worlds: the adjoint pair `pull` (inverse image, f*) and `push` (direct image), with the clauses `adjunction`, `exact pull`, `exact push`.

#### `pull`

Inside a geomorph: the inverse image, the left adjoint.

#### `push`

Inside a geomorph: the direct image, the right adjoint.

#### `adjunction`

Declares the adjoint pairing of the geomorph.

#### `exact`

`exact pull` / `exact push`: the inverse image preserves finite limits.

<CodeWindow file="kw_geomorph_full.yon"
            run="yonc kw_geomorph_full.yon -o geomorph_full && ./geomorph_full; echo $?"
            out={["0"]}>
{`world Shop { Code is X }
place Account in Shop { balance number }
place AccountEU in Shop { balance number }
geomorph Lift from Account to AccountEU {
  adjunction
  exact pull
  exact push
  pull(a: AccountEU): Account {
    be tmp holds a
    return tmp
  }
  push(a: Account): AccountEU {
    be tmp holds a
    return tmp
  }
}
fun main(): number { return 0 }`}
</CodeWindow>

#### `pullback`

The limit: glues two maps over a shared target. As a declaration, `place P = pullback(f, g)` is kernel metadata; the runtime form `pullback(f, g, a, b)` checks the compatibility `f(a) == g(b)` and packs the pair.

#### `pushout`

The colimit: glues two maps under a shared source. The declaration is kernel metadata.

<CodeWindow file="kw_pullback_pushout.yon"
            run="yonc kw_pullback_pushout.yon -o pullback_pushout && ./pullback_pushout; echo $?"
            out={["12"]}>
{`world W { Code is X }
place A in W { v number }
place B in W { v number }
fun f(x: number): number { return x * 2 }
fun g(y: number): number { return y + 6 }
place P = pullback(f, g)
place Q = pushout(f, g)
fun main(): number {
  be p holds pullback(f, g, 6, 6)      // f(6)=12, g(6)=12: compatible
  be a holds __pullback_pi1(p)
  be b holds __pullback_pi2(p)
  return a + b                          // 12
}`}
</CodeWindow>

#### `over`

The slice: `place P over X` declares objects equipped with a chosen map down to X.

## Worlds of errors

#### `error`

`error E extends Base { }`: an error is a place that is a subobject of Base, every E is a Base. A place declares its error morphism with the two-word phrase `on error E`.

#### `extends`

The subobject mono P into B.

<CodeWindow file="error_morphism.yon"
            run="yonc error_morphism.yon -o error_morphism && ./error_morphism; echo $?"
            out={["0"]}>
{`world Db { Code is X }
error Error in Db { message number }
error QueryError in Db extends Error { message number sqlstate number }
place QueryInsert in Db on error QueryError { sql number }
fun handle(e: Error): number { return 1 }
fun on_query_fail(q: QueryError): number {
  return handle(q)
}
fun main(): number { return 0 }`}
</CodeWindow>

## Connectives and type words

These read as English in declarations.

#### `of`

`list of T`, `view of P`, `reduction ... of P`, `map of K to V`.

#### `in`

`place P in W`, `space S in W`, `for every x in e`, `new P in S { }`.

#### `to`

`move m from A to B`, `maps to`, `resolves to`, `map of K to V`.

#### `from`

The source of a move, morph, geomorph or import.

#### `by`

`A maps to B by f`: names the function realizing a clause.

#### `is`

The pattern condition `e is pattern` (a variable, a literal, `present`, `absent`, `unknown`) and the world coordinate clause `Code is X`. Literal and text equality compile to the single content-addressed comparison.

<CodeWindow file="kw_is_literal.yon"
            run="yonc kw_is_literal.yon -o is_literal && ./is_literal; echo $?"
            out={["x is seven", "city is rome", "other is not rome", "30"]}>
{`fun pick(x: number): number visits Output {
  when x is 7 {
    be _ holds String.print("x is seven")
  }
  return 10
}
fun name_check(a: number, b: number): number visits Output {
  be city holds "rome"
  when city is "rome" {
    be _ holds String.print("city is rome")
  }
  be other holds "paris"
  when other is not "rome" {
    be _ holds String.print("other is not rome")
  }
  be y holds (a + b)
  when y is a {
    be _ holds String.print("NEVER: y equals a")
  }
  return 20
}
fun main(): number visits Output {
  be r1 holds pick(7)
  be r2 holds name_check(2, 3)
  return r1 + r2
}`}
</CodeWindow>

#### `with`

`with effects`, `with multishot`, `with fold`, `compose f with g`.

#### `effects`

`place P with effects { }`: the place exposes operations.

#### `requires`

`move m ... requires CAP1, CAP2`: the capabilities a move demands.

#### `init`

`init X as Space`: initializes a Space at program start.

#### `list`

The list type: `list of T`.

#### `map`

The map type: `map of K to V`.

<CodeWindow file="kw_list_here.yon"
            run="yonc kw_list_here.yon -o list_here && ./list_here; echo $?"
            out={["21"]}>
{`fun total(xs: list of number): number {
  be acc holds 0
  for every x in xs when here {
    acc becomes acc + x
  }
  return acc
}
fun main(): number {
  be lst holds List.cons(5, List.cons(7, List.cons(9, List.empty(0))))
  return total(lst)
}`}
</CodeWindow>

#### `multishot`

`with multishot`: the continuation may be resumed more than once.

## Streams and back-pressure

#### `stream`

The stream type, `stream of T`, with its back-pressure modifiers in type position.

#### `buffer`

`buffer N` bounds the stream queue.

#### `drop`

`drop oldest` / `drop newest`: the drop policy; the policy word after `drop` is contextual, not reserved.

<CodeWindow file="kw_stream_policies.yon"
            run="yonc kw_stream_policies.yon -o stream_policies && ./stream_policies; echo $?"
            out={["33"]}>
{`world W { Code is X }
place StreamShape in W { events stream of number buffer 4 drop oldest
  tail stream of number drop newest }
place Plain in W { count number }
fun main(): number {
  be p holds new Plain { count 33 }
  return p.count
}`}
</CodeWindow>

## Three-valued logic and effects

#### `present`

The certain-true value of the Heyting tri-value, and a pattern in `when`/`forces`.

#### `unknown`

The third truth value: not provable, not refutable. An unknown condition decides to false: nothing provable, nothing run.

#### `absent`

The certain-false value as a pattern. A *false* proposition is still `present`, a known falsehood; only `unknown` is not present.

#### `not`

Pattern negation, `e is not pattern`: the Heyting negation of the positive test, computed at runtime through `heyt_not`.

<CodeWindow file="kw_patterns.yon"
            run="yonc kw_patterns.yon -o patterns && ./patterns; echo $?"
            out={["p is not absent", "u is unknown", "6"]}>
{`fun chain_one(a: number, b: number): number visits Output {
  be p holds (a < b)
  when p is not absent {
    be _ holds String.print("p is not absent")
  }
  return 1
}
fun chain_two(d: number): number visits Output {
  be u holds unknown
  when u is unknown {
    be _ holds String.print("u is unknown")
  }
  return d
}
fun chain_three(a: number, b: number): number visits Output {
  be p holds (a < b)
  when p is absent {
    be _ holds String.print("NEVER printed: p is a known truth")
  }
  return 3
}
fun main(): number visits Output {
  be x holds chain_one(3, 5)
  be y holds chain_two(2)
  be z holds chain_three(3, 5)
  return x + y + z
}`}
</CodeWindow>

#### `heyting`

`heyting<N>` / `heyting(v, mask)`: integers in Heyting arithmetic, trits with an Unknown mask; `&?` is trit-wise with mask propagation and the Omega connectives follow the intuitionistic rules.

<CodeWindow file="kw_heyting.yon"
            run="yonc kw_heyting.yon -o heyting && ./heyting; echo $?"
            out={["42"]}>
{`fun main(): number {
  be u holds unknown
  be p holds present
  be both holds p &&? u            // unknown: conjunction with the undecided
  be imp holds u =>? p             // present: anything implies the present
  be dec holds to_bool(imp)
  be h1 holds heyting(5)           // trits 101, all certain
  be h2 holds heyting(5, 2)        // middle trit unknown
  be hand holds h1 &? h2           // trit-wise, the unknown propagates
  return if dec then 42 else 0
}`}
</CodeWindow>

#### `visits`

The effect signature: `fun h(x) visits Output`. Whoever calls must cover the effect, all the way up to `main`.

#### `true`

The boolean literal, in Omega.

#### `false`

The boolean literal, in Omega.

## HoTT: pairs, paths, universes

#### `Pi`

The dependent product: `Pi(x: A). B` is the type of dependent functions. As a comprehension fibre, a Pi chain into `Id` is a mere proposition.

#### `Sigma`

The dependent sum: `Sigma(x: A). B` is the type of dependent pairs, lowered to the honest two-field struct.

#### `Id`

The identity type: `Id(A, x, y)` is the type of paths from x to y.

#### `pair`

The constructor of the Sigma pair.

#### `fst`

First projection of the pair.

#### `snd`

Second projection of the pair.

<CodeWindow file="kw_hott.yon"
            run="yonc kw_hott.yon -o hott && ./hott; echo $?"
            out={["42"]}>
{`fun takes(p: Sigma(x: number). number): number {
  return fst(p) + snd(p)
}
fun proj_sum(a: number, b: number): number {
  be p holds pair(a, b)
  be x holds fst(p)
  be y holds snd(p)
  return x + y
}
fun main(): number {
  be direct holds takes(pair(20, 10))
  return direct + proj_sum(7, 5)        // 30 + 12 = 42
}`}
</CodeWindow>

#### `refl`

The reflexivity path: the proof that a value equals itself. A path value lowers to its *erased witness*, operationally the endpoint value, so `refl(7)` binds and passes like any value. What it never does is decide path equality at runtime: that judgement belongs to the reducer alone.

#### `ind_path`

The J eliminator, the one tool of path induction: to prove something about every path, prove it on `refl`. `ind_path(C, d, p)` computes `d(basepoint)` when the path is `refl` in evidence at the call site. A J stuck on a non-trivial path is rejected at compile time, loudly: the runtime never identifies `loop` with `refl`, so the circle stays a circle.

#### `Type`

The universe of types (`Type_1`, `Type_2`, ... for the levels). A universe-typed parameter compiles to an inert runtime token: types are compile-time citizens, and the runtime never inspects one.

<CodeWindow file="kw_paths.yon"
            run="yonc kw_paths.yon -o paths && ./paths; echo $?"
            out={["42"]}>
{`fun diag(a: number): number { return a * 6 }
fun universe_taker(t: Type): number { return 7 }
fun main(): number {
  be r holds refl(7)                          // a path value, let-bound
  be moved holds ind_path(0, diag, refl(7))   // J computes diag(7) = 42
  return moved
}`}
</CodeWindow>
