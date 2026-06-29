---
id: worlds-and-places
title: "6. Worlds and places"
sidebar_position: 6
---

# Worlds and places

Yon's data model is categorical. A **world** is a category, a semantic site;
a **place** is an object living in it; a value of a place is a **section**.

None of the three is a surface keyword. A world is declared in `yon.toml`, a
place is a single source file, and the project on disk *is* the ontology. Here
is the smallest world with one place in it:

```
shop/
  yon.toml
  Entry.yon          // place Entry, plus main
  store/             // the Space "store", realizing world Shop
    Topos.yon        // topos ShopTopos where { }
    Account.yon      // place Account { ... }
```

```toml
# yon.toml
[package]
name = "shop"

[runtime]
backend = "memory"

[world.Shop]
spaces  = ["store"]
objects = ["Money"]
```

```yon
// store/Account.yon
place Account {
  balance number
  owner String
}
```

```yon
// Entry.yon
place Entry { }
fun main(): number {
  be a holds new Account { balance 40 owner "ada" }
  be _p holds String.print(a.owner)
  return a.balance + 2                      // 42
}
```

The `[world.Shop]` table *is* the world Shop: it lists the directories
(`spaces`) whose files realize it, and the objects it carries. A **place** is
one file inside such a directory; its filename is its name, and it inherits its
world from the directory it lives in (the toolchain enforces one place per
file, so a project with several places is a project with several files). The
space directory carries a `Topos.yon` declaring the topos of that site, and
`Entry.yon` holds the entry place and `main`. Chapter 10 returns to Spaces in
full; here the point is only that worlds and places are declared by structure,
not by a surface block.

Note the surface conventions visible in `main`: place fields are `name type`
(no colon), and `new P { field value }` assigns without `=`. Field access is
the usual dot.

A place body declares its **data members**, fields like `balance number`, and
nothing else by default. There are no methods and no hidden state: a place is
pure structure. Behaviour lives in arrows (chapter 7) and, where a place needs
its own effectful interface, in operations.

## Operations and functorial lifting

A place that carries effectful operations opens its body with `with effects`.
Then it may list **operations** (1-cells) alongside its fields:

```yon
// store/Counter.yon
place Counter with effects {
  v number
  functorial operation tag(x: number): number
}
```

A plain `operation` is pinned to the place that declares it. A `functorial`
operation is lifted along world morphisms by Yoneda, so it travels with the
object's relations instead of with one fixed implementation. That is the
Yoneda principle of chapter 0 made operational: the operation follows the maps
into the object, not a pinned site.

## Worlds compose, but you act on them with arrows

A world is a category, and categories compose the way categories do: products,
coproducts, quotients, sub-objects. That structure is mathematics, not a
surface dialect. Yon gives you no world-algebra to *write* a composite world;
instead you declare worlds in `yon.toml` and act on and between them with
**arrows** (chapter 7). A `functor` (or `morph`) translates one world into
another; a `geomorph` relocates the site itself by an adjunction; and at the
level of a single place, `place A subcontains B` carves out a sub-object of
`B`. The categorical operations live in the arrows, where the compiler can
check their laws, not in a notation for assembling worlds by hand.

## Certified laws

With `with effects` a place exposes operations, and an operation can bind to a
*catalog algebra* whose laws the compiler verifies:

```yon
// algebra/Tally.yon
place Tally with effects {
  total number
  operation add(a: number, b: number): number uses algebra Additive
  law commutative
  law associative
}
```

```yon
// Entry.yon  (in a project whose yon.toml declares [world.Algebra] over the
//             space holding Tally)
place Entry { }
fun main(): number {
  be m holds verify Tally                  // the verified place, as a Magma
  be c holds Magma.is_commutative(m)       // checked against the algebra
  be a holds Magma.is_associative(m)
  return if c and a then 42 else 0
}
```

`law commutative` is not a comment: the AlgebraVerifier pass checks the
declared laws against the algebra (`Additive`, `Multiplicative`, `TropicalMax`,
`TropicalMin`, `BooleanOr`, `BooleanAnd`, `Gcd`) and **rejects a false claim**
at compile time. `verify P` then hands you the verified structure as a runnable
Magma: generators (`Magma.gen`), closure size (`Magma.closure_size`), the
checked algebraic laws (`Magma.is_commutative`, `Magma.is_associative`), and
normal forms (`Magma.normal_form`).

This is the heart of Yon's bet: the algebra you declare is the algebra you
get, checked, not trusted.
