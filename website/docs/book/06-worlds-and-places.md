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
from the directory it lives in. Inside a Space directory the toolchain enforces
one place per file, so a Space with several places is a directory with several
files. The space directory
also carries a `Topos.yon` that declares the topos of the site, and an
`Entry.yon` holds the entry place and `main`.

## A place is its structure

A place body declares its **sections**, the fields it stores, and nothing else by
default. An order has a table and a running total, `sala/Order.yon`:

<!-- yon-gate: illustrative -->
```yon
place Order {
  table Number
  total Number
}
```

A place has no hidden state. You create one with the mediating arrow `.->` and
read its sections with a dot. `Entry.yon`:

<!-- yon-gate: illustrative -->
```yon
place Entry { }
fun main(): Number {
  be o := .-> Order { table 5 total 40 }
  be _p := IO.print_num(o.table)
  return o.total + 2                     // 42
}
```

Note the conventions the `.->` shows: a field is written `name type` with no
colon, `.-> P { field value }` fills the sections without an `=`, and access is
the usual dot. What a place does is said by arrows: the arrows that touch a
place are declared in it (the prelude's `String` place declares its own
functions), and the kinds of arrow are the whole of the next chapter.

## Operations: a place's effectful interface

Where a place needs an effectful interface, it lists **operations** alongside
its sections, directly in its body. An order accumulates
items, and a kitchen ticket can be retagged:

<!-- yon-gate: illustrative -->
```yon
place Order {
  table Number
  total Number
  operation add_item(price: Number): Number
}
```

An `operation` is pinned to the place that declares it, and what it *means* is
given later by a `reduction`, in chapter 7. (The `functorial` modifier, which
declared a lifting along world morphisms, is retired: it was an obligation
nobody verified. The lifting itself is the job of a `functor`, which goes
between categories and says so in its clause.)

## Coproducts: the injection is an arrow of the sum

A place can also be the sum of its arms, with `this >`. The prelude's
`Decision` is `place Decision { this > Present :U Absent :U Unknown }`, and its
`Lookup<V>` is `place Lookup<V> { this > Found(V) :U Absent }`. Each arm comes
with an injection, the arrow that takes the arm into the sum, and that arrow
belongs to the sum, not to the arm. So `Absent` is one name for two arrows:
one into `Decision`, one into `Lookup`. A value of each is built and taken
apart by its own sum:

<!-- yon-gate: exit 42 -->
```yon
fun ruling(): Decision { return Absent }
fun lookup(): Lookup<Number> { return Absent }
fun main(): Number {
  be d := match ruling() { Present => 1, Absent => 2, Unknown => 3 }
  be l := match lookup() { Found(v) => v, Absent => 20 }
  be q := match Lookup.Found(20) { Found(v) => v, Absent => 0 }
  return d + l + q                 // 2 + 20 + 20 = 42
}
```

The compiler picks the arrow from the type the value is expected to have:
`return Absent` in `ruling` goes into `Decision`, in `lookup` into `Lookup`.
Where nothing is expected (`be a := Absent`) an arm listed by two sums names
no arrow, and the program is refused (E2004). The compiler does not guess;
the message proposes the qualified form, `Decision.Absent` or `Lookup.Absent`,
which names the sum. A payload arm is qualified the same way:
`Lookup.Found(20)`.

The qualified form reads like a call to a function of the place, and it is
one: the injection is an arrow of the home of the sum. So in the home of a
place **one name names one arrow**. An arm and a function declared in the same
braces with the same name would make `Ask.Yes(4)` mean two things, and the
place is refused (E2005) until one of them is renamed.

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

The names of the library are not redeclared: they are extended with `this <`.
A place of yours named `Error`, `Lookup` or `Math` would take the library's
place for every reader of the name, the library's own code included, so it is
refused (E2006); the message proposes to rename it, or to declare your own
place under the library's, `place AppError { this < Error  code Number }`,
which has the `message` of every `Error` and passes wherever one is expected.

## Worlds compose, but you act on them with arrows

A world is a category, and categories compose the way categories do: products,
coproducts, quotients, sub-objects. That structure is mathematics, not a surface
dialect. Yon gives you no world-algebra to *write* a composite world by hand.
Instead you declare worlds in `yon.toml` and act on and between them with
**arrows**: a `functor` translates one world into another, a `geomorph` relocates
the site by an adjoint pair (`pull`, `push`), and `this <` carves a sub-object. The categorical
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
runtime, and no explicit trigger to write — the `verify` word was retired,
and the verification descends from `uses` by itself:

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
