---
id: hott-types
title: "9. Types from HoTT"
sidebar_position: 9
---

# Types from HoTT

Yon's type system has a homotopy-type-theoretic layer: universes (`Type`,
`Type_0`, `Type_1`, …), dependent functions and pairs (`Πx : A, B`,
`Σx : A, B`), and the identity type, written `x = y`, with the carrier
inferred from the endpoints, with its introduction and eliminator.

<!-- yon-gate: fragment -->
```yon
// Entry.yon, at the project root
place Entry { }
fun main: Number {
  p := pair(40, 2)
  x := fst(p)
  y := snd(p)
  w := clear x             // a path witness x = x
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
fun coherence(a: Number): f(a) = a {   // f(a) = a, carrier inferred
  return clear                              // reflexivity of the endpoint: f(a) computes to a
}
fun main: Number { return 0 }
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
fun main: Number {
  reversed := back clear 5        // inv(clear 5)              = clear 5
  joined   := clear 7 ++ clear 7  // concat(clear 7, clear 7)  = clear 7
  shadow   := clear 5 through dbl // ap(dbl, clear 5)          = clear 10
  return (reversed @ I0) + (joined @ I0) + (shadow @ I0)   // 5 + 7 + 10 = 22
}
```

A journey can also run between *types*. An equivalence, written `f <=> g`, is a
two-way bridge: the pair of maps together with the coherence that each undoes the
other, and Yon synthesises the trivial coherences for you. Laid down as a path,
an equivalence is univalence itself, `ua(e)`. And you can **carry** a value
across the bridge (here on `Int64`, where `succ` and `pred` really undo each
other; on `Number`, a float, `(n + 1) - 1` is not always `n`):

<!-- yon-gate: exit 11 -->
```yon
fun succ(n: Int64): Int64 { return n + 1 }
fun pred(n: Int64): Int64 { return n - 1 }
fun main: Number {
  bridge := succ <=> pred    // the two-way bridge
  y := carry 10 along bridge // transport 10 across it: succ 10 = 11
  return if y == 11 then 11 else 0
}
```

`carry x along e` is `transport(ua(e), x)`. When the bridge is `f <=> g` it
computes to `f x`: an equivalence of *types* has become computation on *values*,
univalence made operational. It survives a `:=`, so you can name the bridge and
carry across it later.

Finally, a **higher inductive type** carries paths between its own points, and
its eliminator is spelled `match`, the part standing for the whole: one case per
constructor, the result type read off the branches.

<!-- yon-gate: exit 5 -->
```yon
fun quota(p: Suspension<Number>): Number {
  return match p {
    north => 5,
    south => 5,
    merid as a => walk i => 5
  }
}
fun main: Number {
  return quota(north)
}
```

`north` is a point of the suspension (poles `north` and `south`, with `merid` the
meridian path between them); the `merid` branch is a path between what the match gives
at the two poles, built with `walk`, a path-lambda over the interval, and the kernel's
conversion checks its ends. Giving the poles two values with no path between them is
refused.

The higher inductive types of the prelude live in `prelude/hit/`, one file each, and the
kernel reads them from there: `S1.yon` (the circle), `S2.yon` (the sphere),
`Suspension.yon` (the suspension of a type), `PropTrunc.yon` (propositional truncation),
`SetTrunc.yon` (set truncation), `Pushout.yon` (the pushout), and `Quotient.yon` (the
quotient by a relation). `hit.yon` in the same directory declares the topos `Hit` where
they live, not a type of its own. Each of the seven is a place with a `this >` clause for
its points and a law for each path: the arms are the points, the laws are the cells.

A place's parameters can stand for terms as well as types, written with their type between the
angle brackets. The quotient and the pushout are declared so, in `prelude/hit/Quotient.yon`
and `prelude/hit/Pushout.yon`:

```
// prelude/hit/Quotient.yon
place Quotient<A, r : (A, A) -> Type> { this > inj A
  law quot ∀a : A ∀b : A, (a, b) ↦ r → a ↪ inj = b ↪ inj }

// prelude/hit/Pushout.yon
place Pushout<A, B, C, f : A -> B, g : A -> C> { this > inl B :U inr C
  law glue ∀a : A, a ↦ f ↪ inl = a ↦ g ↪ inr }
```

The argument is the name of a fun of that type, as in `Pushout<Number, Number, Number, Frecce.uno,
Frecce.due>`, and the name is its identity: two funs with the same body make two types. The
parameter is read in the laws, by the kernel, and does not exist at run time: the laws declare,
and the funs apply them through the cells.

A relation is a fun whose result is a type, and that type may be a path:

<!-- yon-gate: fragment -->
```yon
place Entry {
  fun lower(s: String): String { return String.concat(s, "") }
  fun same_case(a: String, b: String): Type { return a ↦ lower = b ↦ lower }
  fun domain_of(s: String): Number { return String.length(s) }
  fun domain(e: Quotient<String, same_case>): Number {
    return match e { inj as s => s ↦ lower ↦ domain_of,
                     quot as (a, b, prova) => (domain_of, prova) ↦ ap }
  }
  fun main: Number { return 0 }
}
```

The branch of `quot` receives the witness of the relation as a path, and `ap` carries it through
`domain_of`. A branch without `lower` is refused: the relation says nothing about `a` and `b`
themselves.

## Comprehension types

The most Yon-flavoured citizen is the **comprehension**:

<!-- yon-gate: fragment -->
```yon
// w/Account.yon, a place file in the site's space directory.
// A separate Entry.yon at the project root supplies main.
place Account { v Number }

/* The comprehension type: the subobject of Account carved out by the
 * (here, contractibility-flavoured) fibre. Declaring it type-checks;
 * the coercion runs {a : A where P} <: A (forgetful mono). */
fun takes_sub(s: { a : Account where Πx : Account, Πy : Account, x = y }): Number {
  return 7
}
```

`{ x : A where P }` is the subobject of `A` carved out by the fibre `P`, a
Σ whose first projection is monic when `P` is a mere proposition. The
**coercion direction is `{x : A where P} <: A`**: a value of the subobject is
silently usable as an `A` (the forgetful mono), applied pervasively by the
type checker. The other direction is a proof obligation. There is no surface
constructor that builds a comprehension value with its witness: the
comprehension is a type-level discipline.

This layer is also where the proof machinery lives: places carry higher
`cell`s (CaTT witnesses), and the frontend has a Core→CaTT translation for the
directed structure (`frontend/catt_r_yon.ml`).
