---
id: hott-types
title: "9. Types from HoTT"
sidebar_position: 9
---

# Types from HoTT

Yon's type system has a homotopy-type-theoretic layer: universes (`Type`,
`Type_0`, `Type_1`, …), dependent functions and pairs (`Pi(x: A). B`,
`Sigma(x: A). B`), and the identity type — written `Same(X, Y)` at the surface,
with the carrier inferred from the endpoints — with its introduction and
eliminator. The explicit form `Id(A, x, y)`, carrier written out, stays
available in the lower stratum for when the endpoints do not determine it.

```yon
// Entry.yon, at the project root
place Entry { }
fun main(): Number {
  be p holds pair(40, 2)
  be x holds fst(p)
  be y holds snd(p)
  be w holds clear x             // a path witness x = x
  return x + y                   // 42
}
```

`clear t` introduces a path (the surface spelling of reflexivity; `refl(t)`
remains the KERNEL form, spoken by Yon0 and the cubical layer); the proof that
two sides are the same *by computation* is bare `clear` — reflexivity of the
endpoint inferred from the goal, gated exactly as the kernel `refl` written by
hand. Pairs are the Σ introduction with `fst`/`snd`
projections. The runnable path fragment is wider than that one witness, though:
the *journey vocabulary* in the next section (`back`, `++`, `through`, `carry`,
`carry`, `<=>`, and the `match` eliminator) compiles and computes. Path
induction is `induct(d, p)`; the bare J eliminator `ind_path(C, d, p)` stays a
proof-layer construct in the lower stratum, and `match` is the eliminator you
actually run.

A proof reads the same way. `coherence` claims `f(a)` and `a` are the same, and
bare `clear` supplies the trivial reason — the compiler checks that the two sides
really do reduce to one value before it accepts it:

<!-- yon-gate: exit 0 -->
```yon
fun f(x: Number): Number { return x }
fun coherence(a: Number): Same(f(a), a) {   // Id(number, f(a), a), carrier inferred
  return clear                              // reflexivity of the endpoint: f(a) computes to a
}
fun main(): Number { return 0 }
```

## Paths as journeys

`clear t` is the simplest path, and it hides a metaphor worth making explicit. A
path is a *journey*: a way of getting from one value to another, or from one type
to another, that the type system can hold as a value. Yon names the cubical
primitives after travel, so the algebra of paths reads as the algebra of
journeys.

- `clear a` is the journey that goes nowhere, the trivial path, the proof that
  `a` is clearly itself (kernel: `refl(a)`).
- `back p` is `p` walked in reverse, `inv(p)`. Reverse a reverse and you are
  home: `back (back p)` is `p`.
- `p ++ q` is `p` *then* `q`, `concat`, one journey followed by another.
- `p through f` carries the path `p` *through* the function `f`, `ap(f, p)`. If
  `p` runs from `a` to `b`, then `p through f` runs from `f a` to `f b`.

These compute. Read a closed path at an endpoint with `@ I0` (its start) or
`@ I1` (its end), and the algebra collapses to an ordinary value:

<!-- yon-gate: exit 22 -->
```yon
fun dbl(n: Number): Number { return n + n }
fun main(): Number {
  be reversed holds back clear 5        // inv(clear 5)              = clear 5
  be joined   holds clear 7 ++ clear 7  // concat(clear 7, clear 7)  = clear 7
  be shadow   holds clear 5 through dbl // ap(dbl, clear 5)          = clear 10
  return (reversed @ I0) + (joined @ I0) + (shadow @ I0)   // 5 + 7 + 10 = 22
}
```

A journey can also run between *types*. An equivalence, written `f <=> g`, is a
two-way bridge: the pair of maps together with the coherence that each undoes the
other, and Yon synthesises the trivial coherences for you. Laid down as a path,
an equivalence is univalence itself, `ua(e)`. And you can **carry** a value
across the bridge:

<!-- yon-gate: exit 11 -->
```yon
fun succ(n: Number): Number { return n + 1 }
fun pred(n: Number): Number { return n - 1 }
fun main(): Number {
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
fun main(): Number {
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

## Comprehension types

The most Yon-flavoured citizen is the **comprehension**:

```yon
// Account.yon, a place file in the site's space directory.
// A separate Entry.yon at the project root supplies main.
place Account { v Number }

/* The comprehension type: the subobject of Account carved out by the
 * (here, contractibility-flavoured) fibre. Declaring it type-checks;
 * the coercion runs {a : A where P} <: A (forgetful mono). */
fun takes_sub(s: { a : Account where Pi(x: Account). Pi(y: Account). Id(Account, x, y) }): Number {
  return 7
}
```

`{ x : A where P }` is the subobject of `A` carved out by the fibre `P`, a
Σ whose first projection is monic when `P` is a mere proposition. The
**coercion direction is `{x : A where P} <: A`**: a value of the subobject is
silently usable as an `A` (the forgetful mono), applied pervasively by the
type checker. The other direction is a proof obligation, and value-level
*construction* of comprehension values (a surface constructor carrying the
witness) is deliberately later: today the comprehension is a type-level
discipline.

This layer is also where the proof machinery lives: places carry higher
`cell`s (CaTT witnesses), and the compiler extracts Core→CaTT proof terms for
the directed structure, the book's research appendix will return to this.
