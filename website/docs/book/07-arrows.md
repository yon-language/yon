---
id: arrows
title: "7. Arrows"
sidebar_position: 7
---

# Arrows

Everything that *maps* in Yon is an arrow with a categorical kind. Arrows are
first-class: they bind, compose, and apply, under a kind discipline the
compiler enforces. The kinds live at different *levels* of the structure:

| Kind | Lives between | Categorical reading | You use it to… |
|---|---|---|---|
| `fun` | values | a plain morphism of values | compute; it knows nothing about places |
| `view … of P` | a place → values | an observation out of `P` | read/project, **never** modify |
| `move … from P to Q` | place → place | a morphism of objects | transport sections; the only way content crosses places (and Spaces) |
| `reduction … of P` | `P`'s operations → a value | an algebra / eliminator | interpret a place's effectful operations (a handler) |
| `functor` / `morph … from W to V` | world → world | a functor between categories | translate whole contexts, objects *and* operations |
| `nat transform … from F to G` | functor → functor | a natural transformation (2-cell) | relate two translations, one component per object |
| `geomorph … from P to Q` | site → site | a geometric morphism `f* ⊣ f∗` | change the site itself: pull/push with an adjunction |

One ladder, in words: a `fun` moves *values*; a `view` looks *into* one
place; a `move` carries content *between* places; a `reduction` says what a
place's *operations mean*; a `functor` translates an entire *world*; a
`nat transform` compares two such translations; a `geomorph` relocates the
*logic itself*. Pick the lowest rung that does the job, the type checker
will hold you to it.

## The whole ladder on one domain

```yon
world Bank { Code is X }
place Account in Bank with effects {
  balance number
  operation deposit(v: number): number
}
place Archived in Bank { balance number }

/* fun: a plain morphism of values, knows nothing about places */
fun tax(n: number): number { return n / 10 }

/* view: an observation OUT of a place, read-only by construction */
view Worth of Account { show balance }

/* move: transport BETWEEN places, sections cross, fields map */
move Archive from Account to Archived {
  balance converts to balance by tax
}

/* reduction: an algebra FOR a place's operations, an eliminator */
reduction Sum of Account {
  on deposit(v: number) { return v }
}

fun main(): number {
  be acc holds new Account { balance 400 }
  be vw holds view(s: Account) => s.balance of Account   // observe, don't touch
  be observed holds vw(acc)                              // 400
  be arch holds apply_move(Archive, acc)                 // transport + convert
  be taxed holds arch.balance                            // 40
  with Sum of Account { be _t holds 1 }                  // handle the algebra
  be folder holds reduction(a: number, x: number) => a + x of Account
  return folder(taxed, observed / 200)                   // 40 + 2 = 42
}
```

Note what each arrow *cannot* do, because that is the point. The `view`
cannot write, there is no syntax for it to try. The `move` cannot peek
outside its mapping clauses; it is the capability-gated border crossing.
The `reduction` does not touch sections at all, it gives meaning to
*operations* (`deposit`), which is why it is activated as a handler
(`with Sum of Account`) rather than applied to a value. And the `fun` is
welcome everywhere precisely because it claims nothing: `tax` is just a
morphism of numbers that the move hires for one field.

One level up, between **worlds**, the same discipline repeats, and the
2-cells appear:

```yon
world W { Code is X }
world V { Code is Y }

functor F(x: number) from W to V { return x }
functor G(x: number) from W to V { return x }

nat transform Eta from F to G {
  for each X by F
}

fun main(): number { return 0 }
```

A `functor` translates a whole world (and may declare `law identity`,
`law composition` for the checker); a `nat transform` relates two functors,
giving one component per object of the source world, Eckmann–Hilton
interchange for these 2-cells is inherited by the directed core.

## Declared moves

```yon
world Region { Code is EU, US }
place EUR in Region { balance number }
place USD in Region { balance number }

move EurToUsd from EUR to USD {
  balance converts to balance by scale
}
fun scale(x: number): number { return x * 110 / 100 }

fun main(): number {
  be a holds new EUR { balance 40 }
  be b holds apply_move(EurToUsd, a)
  return b.balance        // 44
}
```

A move's body is a list of **mapping clauses**, `maps to` (rename),
`converts to` (transform `by` a function), `aggregates to` (fold several
sources). The `by` function can be inline: `by fun(x) => x * 2`, and a move
may `requires CAP1, CAP2` (capabilities). A second form merges two places,
field by field:

```yon
fun pick(a: number, b: number): number { return a }
move Merge unifies A, B {
  share v
  conflict on w resolves to pick
}
```

## Reductions

A **reduction** eliminates a place into a value. Declared, it is a bundle of
`on` handlers over the place's operations, activated for a block with
`with R of P`; inline, it is a lambda you can apply directly:

```yon
world W { Code is X }
place Counter in W with effects {
  value number
  operation bump(v: number): number
}

reduction Tally of Counter {
  on bump(v: number) { return v + 1 }
}

fun main(): number {
  with Tally of Counter { be t holds 1 }
  be r holds reduction(acc: number, x: number) => acc + x of Counter
  return r(40, 2)                       // 42
}
```

Modifiers refine the contract: `forward`/`backward`/`bi` (direction),
`lawful`, `invertible`, `with multishot`, and a `fold "sum_f64"` hint.

## Inline handle lambdas, composition, application

```yon
world W { Code is X }
place P in W { v number }
place Q in W { v number }
place R in W { v number }

fun main(): number {
  be m1 holds move(s: P) => new Q { v 1 } from P to Q
  be m2 holds move(s: Q) => new R { v 2 } from Q to R
  be mm holds compose m1 with m2
  be sp holds new P { v 0 }
  be sr holds mm(sp)                       // composed handle, applied
  be vw holds view(s: P) => 40 of P
  be forty holds vw(sp)
  return forty + 4                         // 44
}
```

Each arrow kind has its lambda (`move(..) => e from P to Q`,
`reduction(acc, x) => e of P`, `view(..) => e of P`, `morph`, `functor` with
checkable laws). `compose h1 with h2` is `g ∘ f`, and the **kind discipline
is enforced**: composing two reductions is rejected (the eliminator lands in
`number`), while same-kind composition and post-composing a view/reduction
with a `fun` are fine. A bound or composed handle is applied like a function,
and `apply_move` accepts a locally bound move-lambda.

## Between worlds

A `morph F from W to V` block gives a functor by components
(`on object(...)`, `on morphism op via op2`); a top-level
`functor F(x) from W to V law identity law composition` declares one with
checkable laws (its body is a single `return`); `nat transform t from F to G`
lists the components, one `for each X by fnX` per object. A
`geomorph g from P to Q` carries a `pull(...)` and a `push(...)`, the
geometric morphism, i.e. the adjunction `f* ⊣ f∗` (`adjunction`,
`exact pull` and `exact push` are declarable properties):

```yon
geomorph LiftBody from Account to AccountEU {
  pull(a: AccountEU): Account {
    be tmp holds a
    return tmp
  }
}
```

Views also exist as declarations: `view Pretty of Account { show balance }`,
with `show f = e` computed columns and `as "label"` renames.
