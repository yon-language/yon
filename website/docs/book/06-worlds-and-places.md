---
id: worlds-and-places
title: "6. Worlds and places"
sidebar_position: 6
---

import OntologyMap from '@site/src/components/OntologyMap';

# Worlds and places

Yon's data model is categorical, and the category is not an abstraction you keep
in your head. It lives on disk. A **world** is a category, a semantic site; a
**place** is an object living in it; a value of a place is a **section**. None of
the three is a surface keyword you write inside a file. A world is declared in
`yon.toml`, a place is a single source file, and the project's layout *is* the
ontology.

<OntologyMap />

The restaurant of the next chapter starts here, as the smallest world with one
place in it. A dining room is a space, a directory named `sala`, and the world it
realizes is declared in `yon.toml`:

```toml
[package]
name = "restaurant"

[runtime]
backend = "memory"

[world.Restaurant]
objects = ["Guest"]
spaces  = ["sala"]
```

The `[world.Restaurant]` table *is* the world: it lists the directories
(`spaces`) whose files realize it, and the objects it carries. A **place** is one
file inside such a directory. Its filename is its name, and it inherits its world
from the directory it lives in. The toolchain enforces one place per file, so a
project with several places is a project with several files. The space directory
also carries a `Topos.yon` that declares the topos of the site, and an
`Entry.yon` holds the entry place and `main`.

## A place is pure structure

A place body declares its **sections**, the fields it stores, and nothing else by
default. An order has a table and a running total, `sala/Order.yon`:

<!-- yon-gate: illustrative -->
```yon
place Order {
  table Number
  total Number
}
```

There are no methods here and no hidden state: a place is pure structure. You
create one with `new`, read its sections with a dot, and that is the whole
surface. `Entry.yon`:

<!-- yon-gate: illustrative -->
```yon
place Entry { }
fun main(): Number {
  be o holds .-> Order { table 5 total 40 }
  be _p holds IO.print_num(o.table)
  return o.total + 2                     // 42
}
```

Note the conventions the `new` shows: a field is written `name type` with no
colon, `.-> P { field value }` fills the sections without an `=`, and access is
the usual dot. What a place cannot do, on its own, is *behave*. Behaviour is not
a method bolted to the object; it lives in arrows, and that is the whole of the
next chapter.

## Operations: a place's effectful interface

Where a place needs an effectful interface, it opens its body with `with
effects` and lists **operations** alongside its sections. An order accumulates
items, and a kitchen ticket can be retagged:

<!-- yon-gate: illustrative -->
```yon
place Order {
  table Number
  total Number
  operation add_item(price: Number): Number
  functorial operation retag(x: Number): Number
}
```

A plain `operation` is pinned to the place that declares it. A `functorial`
operation is lifted along world morphisms by Yoneda, so it travels with the
object's relations instead of with one fixed implementation. That is the Yoneda
principle of chapter 0 made operational: the operation follows the maps into the
object, not a pinned site. What each operation *means* is given later by a
`reduction`, in chapter 7.

## Sub-objects

A place can carve out a sub-object of another with `this <` — the mirror of the coproduct's `this >`: `>` reads "I contain" (⊃), `<` reads "I am contained" (⊂). A VIP order is
still an order, restricted:

<!-- yon-gate: illustrative -->
```yon
place VipOrder {
  this < Order
  table Number
  total Number
}
```

`this <` is the sub-object relation of the category: every `VipOrder` is an
`Order`, and the compiler treats it as one where an `Order` is expected.

## Worlds compose, but you act on them with arrows

A world is a category, and categories compose the way categories do: products,
coproducts, quotients, sub-objects. That structure is mathematics, not a surface
dialect. Yon gives you no world-algebra to *write* a composite world by hand.
Instead you declare worlds in `yon.toml` and act on and between them with
**arrows**: a `functor` translates one world into another, a `geomorph` relocates
the site by an adjunction, and `this <` carves a sub-object. The categorical
operations live in the arrows, where the compiler can check their laws, which is
exactly where chapter 7 picks them up.

## Certified laws: the algebra you declare is the algebra you get

The strongest thing a place can carry is a *law*. Tallying a bill is addition,
and addition is commutative and associative: the order in which the waiter rings
up the courses does not change the total, and neither does the grouping. In most
languages that is a comment, a thing you believe. In Yon you declare it, and the
compiler checks it. `sala/Tally.yon`:

<!-- yon-gate: illustrative -->
```yon
place Tally {
  total Number
  operation add(a: Number, b: Number): Number uses algebra Additive
  law commutative
  law associative
}
```

`law commutative` is not a comment. The algebra verifier checks the declared laws
against the named algebra (`Additive`, `Multiplicative`, `TropicalMax`,
`TropicalMin`, `BooleanOr`, `BooleanAnd`, `Gcd`) and **rejects a false claim** at
compile time. The check is entirely static: a place whose operation names an
algebra carries its laws as verified facts — there is nothing to ask at
runtime, and no `verify` word to say (the explicit trigger is retired; the
verification descends from `uses` by itself):

<!-- yon-gate: illustrative -->
```yon
place Tally {
  operation add(a: Number, b: Number): Number uses algebra Additive
  law commutative
  law associative      // a false claim here is a COMPILE error
}
```

This is the heart of Yon's bet, and it is worth stating plainly: the algebra you
declare is the algebra you get, checked, not trusted. A place is where you write
the claim down, and the compiler is what makes it true.

Chapter 7 gives these places their behaviour, the arrows. Chapter 11 returns to
spaces in full, as the directories where instances actually live and where one
Space begins to talk to another.
