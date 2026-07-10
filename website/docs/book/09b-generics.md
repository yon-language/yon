---
id: generics
title: "Generics"
sidebar_position: 9.5
---

import CodeWindow from '@site/src/components/CodeWindow';

# Generics

Write a function that hands back what it was given. For a number it reads:

<!-- yon-gate: illustrative -->
```yon
fun id(x: number): number { return x }
```

Now you want it for text. You write it again, character for character the same,
except the word `number` became `text`. The body never looked at the value's
type; the type was only along for the ride. Yet it forced a copy. A generic is
the tool that removes the copy: it lets you leave the type blank and fill it in
later, once per call, instead of once per source file.

## A type left blank

<!-- yon-gate: exit 42 -->
```yon
fun id<T>(x: T): T {
  return x
}
fun main(): number {
  return id(42)
}
```

The `<T>` after the name binds a **type variable**. Read it "for any type `T`".
`T` then stands in the ordinary type positions: the parameter is a `T`, the
return is a `T`, and the two are the *same* `T`, so whatever you put in is what
you get out. The caller never spells `T` out. Writing `id(42)` fixes `T` to
`number` by inference; the very same definition serves `id("ciao")` with `T` at
`text`. One definition, every type.

## More than one blank

A function may leave several types blank, and they vary independently:

<!-- yon-gate: exit 9 -->
```yon
fun first<A, B>(x: A, y: B): A {
  return x
}
fun main(): number {
  be n holds first(7, 99)         // A and B both number
  be t holds first("hi", 5)       // A is text, B is number
  return n + String.length(t)     // 7 + 2 = 9
}
```

`first` keeps its first argument and drops the second, whatever their types.
The two calls fix `(A, B)` to `(number, number)` and to `(text, number)`; the
type variables are resolved per call, not once for the whole program.

## What `T` actually is

Here is the part that separates Yon from most languages with generics. In many
of them a type parameter is *erased*: after type-checking, `T` is gone, every
value becomes a bare pointer, and the type was a compile-time fiction the
running machine never sees. Yon does not erase `T`.

A type variable ranges over the **universe**, the same `Type` / `El` you met in
chapter 9. When you abstract over `T` you are quantifying over the inhabitants
of the universe, and the abstraction stays anchored there. The value itself
still travels as Yon's one uniform carrier (chapter 13), but its type-level
identity is kept in the checker, not thrown away. Abstraction and identity turn
out to live in the same place: the universe.

You can see the anchor most clearly in a generic container.

## Generic containers

A place can carry a type parameter, exactly like a function:

<CodeWindow file="cx_generic_box/"
            run="yonc cx_generic_box/ -o gbox && ./gbox; echo $?"
            out={["42"]}>
{`// s/Box.yon
// Box<T>: a generic container. The field value has the parameter type T,
// which lowers to El(T), an element of the universe, anchored to the types.
place Box<T> { value T }
// Entry.yon
// A generic place Box<T>, instantiated at number, built and read back.
// The field is El(T), an element of the universe, not an erased type; the
// runtime carrier is Yon's uniform value (f64).
place Entry { }

fun main(): number {
  be b holds new Box { value 42 }   // built at T = number
  return b.value                    // -> 42
}`}
</CodeWindow>

`Box<T>` is a container whose field has the parameter type. In the core that
field lowers to `El(T)`, "an element of the type `T`", which is exactly the
universe reading from chapter 9: `T` is a genuine inhabitant, stuck until you
instantiate it. Build a `Box` at `T = number` and the field is a number; read
it back and you get your `42`.

Once `T` is filled, the instantiated type has a name of its own. `Box<number>`
is a **type application**, and it is a distinct type node, so a signature can
ask for precisely it:

<!-- yon-gate: illustrative -->
```yon
// a place needs its space, so this runs inside the project above,
// not as a standalone snippet.
fun unwrap(b: Box<number>): number {
  return b.value
}
```

The angle-bracket form takes as many arguments as the place has parameters:
`Box<number>` fills one, and a two-parameter container is written the same way,
`Pair<number, text>` or `HashMap<text, number>`.

## Generic arrows: methods and functors

Dispatch in Yon is Yoneda (chapter 7): `recv.f(args)` is just `f(recv, args)`.
Arrows are therefore ordinary declarations, and they can be generic too. The
functorial arrow, the `reduction`, carries its type parameters between the name
and its object:

<!-- yon-gate: illustrative -->
```yon
// a fold generic in the type it carries.
reduction Sum<T> of Tally {
  be seed holds 0
}
```

So a type variable can appear in all three of the shapes you have met: a
**function**, a **container** (a place), and an **arrow** (a method or functor).
The same `<...>` binder, the same anchoring to the universe, everywhere.

## What is wired, and what is next

Be precise about the edge. Type application is a real, distinct node: the
checker tells `Box<number>` from `Box<text>` when they appear in a signature,
and a generic function is checked and run at whatever type each call fixes. What
is *not* yet enforced is the element-level check, that a `new Box { value ... }`
agrees with the `T` you instantiated. That step is **monomorphisation**, and it
is the next increment (the parser marks the spot in a comment). Today the field
lowers to `El(T)` over the uniform carrier, so a literal of the wrong shape
still compiles; tomorrow the instantiation checks the argument against `T`. The
type-level story is honest and complete; the value-level gate is declared, open.

That gap is the last thing between generics and the paths of chapter 9, and the
two are one idea seen from two sides. A generic value does not care which type
it sits at. A path is a proof that two types are *genuinely the same*, and
`carry x along e` moves a value across that proof. Both meet at the universe,
which is why the next time you reach for `El` it will already feel familiar.
