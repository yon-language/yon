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
fun main(): number {
  be p holds pair(40, 2)
  be x holds fst(p)
  be y holds snd(p)
  be w holds refl(x)               // a path witness x = x
  return x + y                     // 42
}
```

`refl(t)` introduces a path; pairs are the Σ introduction with `fst`/`snd`
projections. (`ind_path(C, d, p)`, the J eliminator, is in the grammar and
the proof layer, but its emission is not wired in 1.0: the *runnable* HoTT
fragment is `refl`/`pair`/`fst`/`snd`.)

Limits exist in expression form too, a runtime-checked pullback takes a
compatible pair over a cospan:

```yon
fun f(x: number): number { return x }
fun g(y: number): number { return y }
fun main(): number {
  be p holds pullback(f, g, 3, 3)     // runtime-checked: f(3) == g(3)
  return 7
}
```

## Comprehension types

The most Yon-flavoured citizen is the **comprehension**:

```yon
// Account.yon, a place file in the site's space directory
place Account { v number }

/* The comprehension type: the subobject of Account carved out by the
 * (here, contractibility-flavoured) fibre. Declaring it type-checks;
 * the coercion runs {a : A where P} <: A (forgetful mono). */
fun takes_sub(s: { a : Account where Pi(x: Account). Pi(y: Account). Id(Account, x, y) }): number {
  return 7
}

fun main(): number { return 42 }
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
