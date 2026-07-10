---
id: hott-types
title: "9. Types from HoTT"
sidebar_position: 9
---

# Types from HoTT

Yon's type system has a homotopy-type-theoretic layer: universes (`Type`,
`Type_0`, `Type_1`, …), dependent functions and pairs (`Pi(x: A). B`,
`Sigma(x: A). B`), and the identity type `Id(A, x, y)` with its introduction
and eliminator.

```yon
// Entry.yon, at the project root
place Entry { }
fun main(): number {
  be p holds pair(40, 2)
  be x holds fst(p)
  be y holds snd(p)
  be w holds refl(x)             // a path witness x = x
  return x + y                   // 42
}
```

`refl(t)` introduces a path; pairs are the Σ introduction with `fst`/`snd`
projections. The runnable path fragment is wider than that one witness, though:
the *journey vocabulary* in the next section (`back`, `++`, `through`, `span`,
`carry`, `<=>`, and the `match` eliminator) compiles and computes. The bare
J eliminator `ind_path(C, d, p)` stays a proof-layer construct; `match` is the
eliminator you actually run.

## Paths as journeys

`refl(t)` is the simplest path, and it hides a metaphor worth making explicit. A
path is a *journey*: a way of getting from one value to another, or from one type
to another, that the type system can hold as a value. Yon names the cubical
primitives after travel, so the algebra of paths reads as the algebra of
journeys.

- `stay a` is the journey that goes nowhere, `refl(a)`, the proof that `a` stays
  itself.
- `back p` is `p` walked in reverse, `inv(p)`. Reverse a reverse and you are
  home: `back (back p)` is `p`.
- `p ++ q` is `p` *then* `q`, `concat`, one journey followed by another.
- `p through f` carries the path `p` *through* the function `f`, `ap(f, p)`. If
  `p` runs from `a` to `b`, then `p through f` runs from `f a` to `f b`.

These compute. Read a closed path at an endpoint with `@ I0` (its start) or
`@ I1` (its end), and the algebra collapses to an ordinary value:

<!-- yon-gate: exit 22 -->
```yon
fun dbl(n: number): number { return n + n }
fun main(): number {
  be reversed holds back (stay 5)      // inv(refl 5)             = refl 5
  be joined   holds stay 7 ++ stay 7   // concat(refl 7, refl 7)  = refl 7
  be shadow   holds stay 5 through dbl // ap(dbl, refl 5)         = refl 10
  return (reversed @ I0) + (joined @ I0) + (shadow @ I0)   // 5 + 7 + 10 = 22
}
```

A journey can also run between *types*. An equivalence, written `f <=> g`, is a
two-way bridge: the pair of maps together with the coherence that each undoes the
other, and Yon synthesises the trivial coherences for you. Laid down as a path,
an equivalence is univalence in one word, `span e`, which is `ua(e)`. And you can
**carry** a value across the bridge:

<!-- yon-gate: exit 11 -->
```yon
fun succ(n: number): number { return n + 1 }
fun pred(n: number): number { return n - 1 }
fun main(): number {
  be bridge holds succ <=> pred    // the two-way bridge
  return carry 10 along bridge     // transport 10 across it: succ 10 = 11
}
```

`carry x along e` is `transport(ua(e), x)`. When the bridge is `f <=> g` it
computes to `f x`: an equivalence of *types* has become computation on *values*,
univalence made operational. It survives a `be`, so you can name the bridge and
carry across it later.

Finally, a **higher inductive type** carries paths between its own points, and
its eliminator is spelled `match`, the part standing for the whole: one case per
constructor, the result type read off the branches.

<!-- yon-gate: exit 5 -->
```yon
fun main(): number {
  return match hit(north) {
    north => 5,
    south => 5,
    merid(a) => plam i => 5
  }
}
```

`hit(north)` is a point of the suspension (poles `north` and `south`, with
`merid` the meridian path between them); the `merid` branch returns a path, built
with `plam`, a path-lambda over the interval. The eliminator needs no explicit
motive: the branches give it away.

Limits exist in expression form too, a runtime-checked pullback takes a
compatible pair over a cospan:

```yon
// Entry.yon, at the project root
place Entry { }
fun f(x: number): number { return x }
fun g(y: number): number { return y }
fun main(): number {
  be p holds pullback(f, g, 3, 3)   // runtime-checked: f(3) == g(3)
  return 7
}
```

## Comprehension types

The most Yon-flavoured citizen is the **comprehension**:

```yon
// Account.yon, a place file in the site's space directory.
// A separate Entry.yon at the project root supplies main.
place Account { v number }

/* The comprehension type: the subobject of Account carved out by the
 * (here, contractibility-flavoured) fibre. Declaring it type-checks;
 * the coercion runs {a : A where P} <: A (forgetful mono). */
fun takes_sub(s: { a : Account where Pi(x: Account). Pi(y: Account). Id(Account, x, y) }): number {
  return 7
}
```

`{ x : A where P }` is the subobject of `A` carved out by the fibre `P`, a
Σ whose first projection is monic when `P` is a mere proposition. The
**coercion direction is `{x : A where P} <: A`**: a value of the subobject is
silently usable as an `A` (the forgetful mono), applied pervasively by the
type checker. The other direction is a proof obligation, and value-level
*construction* of comprehension values (a surface constructor carrying the
witness) is deliberately post-1.0: in 1.0 the comprehension is a type-level
discipline.

This layer is also where the proof machinery lives: places carry higher
`cell`s (CaTT witnesses), and the compiler extracts Core→CaTT proof terms for
the directed structure, the book's research appendix will return to this.
