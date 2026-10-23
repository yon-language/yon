---
id: generics
title: "10. Generics"
sidebar_position: 10
---

# Generics

Write a function that hands back what it was given. For a number it reads:

<!-- yon-gate: illustrative -->
```yon
fun id(x: Number): Number { return x }
```

Now you want it for text. You write it again, character for character the same,
except the word `Number` became `Text`. The body never looked at the value's
type; the type was only along for the ride. Yet it forced a copy. A generic is
the tool that removes the copy: it lets you leave the type blank and fill it in
later, once per call, instead of once per source file.

## A type left blank

<!-- yon-gate: exit 42 -->
```yon
fun id<T>(x: T): T {
  return x
}
fun main(): Number {
  return id(42)
}
```

The `<T>` after the name binds a **type variable**. Read it "for any type `T`".
`T` then stands in the ordinary type positions: the parameter is a `T`, the
return is a `T`, and the two are the *same* `T`, so whatever you put in is what
you get out. The caller never spells `T` out. Writing `id(42)` fixes `T` to
`Number` by inference; the very same definition serves `id("ciao")` with `T` at
`Text`. One definition, every type. That is why the body may do nothing with a
`T` but pass it on: a `T` has no fields, cannot be called, added or compared
with a literal, since any of these would hold at some types and not at others;
the checker refuses them. The only total `T -> T` is the identity.

## More than one blank

A function may leave several types blank, and they vary independently:

<!-- yon-gate: exit 9 -->
```yon
fun first<A, B>(x: A, y: B): A {
  return x
}
fun main(): Number {
  n := first(7, 99)         // A and B both Number
  t := first("hi", 5)       // A is Text, B is Number
  return n + String.length(t)     // 7 + 2 = 9
}
```

`first` keeps its first argument and drops the second, whatever their types.
The two calls fix `(A, B)` to `(Number, Number)` and to `(Text, Number)`; the
type variables are resolved per call, not once for the whole program. This is
where generics earn their keep: a function whose logic does not depend on the
type is written once and checked at every type it is used at.

## What `T` actually is

Here is the part that separates Yon from most languages with generics. In many
of them a type parameter is *erased*: after type-checking, `T` is gone, every
value becomes a bare pointer, and the type was a compile-time fiction the
running machine never sees. Yon does not erase `T`.

A type variable ranges over the **universe**, the same `Type` / `El` you met in
chapter 9. When you abstract over `T` you are quantifying over the inhabitants
of the universe, and the abstraction stays anchored there. The value itself
still travels as Yon's one uniform carrier (chapter 14), but its type-level
identity is kept in the checker, not thrown away.

## You rarely write a container

The textbook next step is "now make a generic container". In Yon you usually do
not, because the containers already exist and are built in. `Wire<T>`, the
channel, is a generic type in its own right (chapter 17); `Vec`, `List`, `HashMap`, and
`HashSet` (chapters 12 and 15) are the standard containers, each holding Yon's
uniform value. When you want "a sequence of numbers" or "a map from text", you
reach for those. They are generic where it counts and you never had to write
them.

So a generic of your own is worth reaching for in one narrower place: a **domain
object** whose *meaning* is parametric.

## Generic places

A place is a domain object, a file with fields and arrows, not a container. You
give it a type parameter when the object is the same whatever type flows through
it. An envelope that carries a payload across Spaces (chapter 17) is the honest
shape:

<!-- yon-gate: illustrative -->
```yon
// a domain object parametric over its payload; declared once, used at each type.
place Envelope<T> { payload T }
```

The syntax mirrors a function's: `<T>` binds the variable, and the field's type
is that variable. `Envelope<Number>` is a **type application**, a distinct type
the checker tracks, so a signature can ask for exactly it and read `payload` back
as a `Number`. You write the structure and its arrows once; the checker keeps
`Envelope<Number>` and `Envelope<Text>` apart in every signature. The
angle-bracket form takes one argument per parameter, so a two-parameter object
is `Pair<Number, Text>`, the same way `HashMap<Text, Number>` names its two.

The runtime carrier is uniform (chapter 14), and there is no per-instantiation
specialisation (**monomorphisation**): a generic place gives *type-level*
precision in signatures, not a specialised runtime layout. The field-level check
that a value handed to `Envelope<Number>` really is a number is not performed. Reach for a
generic place when a domain object is genuinely parametric; reach for the
built-in containers when you just need to hold values.

## Generic arrows

Dispatch in Yon is Yoneda (chapter 7): `recv.f(args)` is just `f(recv, args)`.
Arrows are ordinary declarations, so they take type parameters too. The
functorial arrow, the `reduction`, carries its parameters between the name and
its object:

<!-- yon-gate: illustrative -->
```yon
// a fold generic in the type it carries.
reduction Sum<T> of Tally {
  seed := 0
}
```

So a type variable can appear in all three shapes: a **function**, a **place**,
and an **arrow**. The same `<...>` binder, the same anchoring to the universe.

## What is wired

Keep the edge sharp. Generic **functions** are checked and run at whatever type
each call fixes; that is the part you will use every day. **Type application**
is a real, distinct node, so `Envelope<Number>` and `Envelope<Text>` are told
apart in a signature. The value-level check that a place instance agrees with
the `T` it was given is not performed (Appendix B).

That gap is the last thing between generics and the paths of chapter 9, and the
two are one idea seen from two sides. A generic value does not care which type
it sits at; a path is a proof that two types are *genuinely the same*, and
`carry x along e` moves a value across that proof. Both meet at the universe,
which is why the next time you reach for `El` it will already feel familiar.
