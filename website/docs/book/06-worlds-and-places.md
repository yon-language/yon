---
id: worlds-and-places
title: "6. Worlds and places"
sidebar_position: 6
---

# Worlds and places

Yon's data model is categorical. A **world** is a category, a semantic site;
a **place** is an object living in it; a value of a place is a **section**.

```yon
world Shop { Code is X }

place Account in Shop {
  balance number
  owner String
}

fun main(): number {
  be a holds new Account { balance 40 owner "ada" }
  be _p holds String.print(a.owner)
  return a.balance + 2
}
```

Note the surface conventions: place fields are `name type` (no colon), and
`new P { field value }` assigns without `=`. Field access is the usual dot.

A world's body lists its inhabitants as `Name is descriptor`, an enumeration
(`Status is on, off, error`), a primitive (`Code is text`), or a generator
(`Color is by F`). Worlds compose categorically:

```yon
world Currency { Code is EUR, USD }
world Status { State is on, off }
world Pair = Currency * Status        // product
world Either = Currency + Status      // coproduct
world Sub subset of Currency          // sub-world
world Anon = Currency / SameZone      // quotient by an equivalence
```

An operation can also be declared `functorial`, lifted along world
morphisms by Yoneda, so it travels with the object instead of being pinned
to one place:

```yon
place Counter in W with effects {
  v number
  functorial operation tag(x: number): number
}
```

## Operations and certified laws

With `with effects`, a place exposes **operations** (1-cells), and can bind
them to a *catalog algebra* whose laws the compiler verifies:

```yon
world Algebra { Code is X }

place Tally in Algebra with effects {
  total number
  operation add(a: number, b: number): number uses algebra Additive
  law commutative
  law associative
}

fun main(): number {
  be m holds solve Tally                  // the verified place, as a Magma
  be _g1 holds Magma.gen(m, 5)
  be _g2 holds Magma.gen(m, 7)
  be ok holds Magma.reachable(m, 12)      // 5 + 7
  return if ok then 42 else 0
}
```

`law commutative` is not a comment: the MagmaSolve pass checks the declared
laws against the algebra (`Additive`, `Multiplicative`, `TropicalMax`,
`TropicalMin`, `BooleanOr`, `BooleanAnd`, `Gcd`) and **rejects a false
claim** at compile time. `solve P` then hands you the verified structure as a
runnable Magma: generators, closure, reachability with certificates, and
normal forms.

This is the heart of Yon's bet: the algebra you declare is the algebra you
get, checked, not trusted.
