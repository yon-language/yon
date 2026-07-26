---
id: functions-and-effects
title: "5. Functions and effects"
sidebar_position: 5
---

# Functions and effects

<!-- yon-gate: exit 42 -->
```yon
fun double(x): Number { return x * 2 }              // param type inferred
fun id<A>(x: A): A { return x }                     // type parameter
internal fun helper(x: Number): Number { return x + 1 }

fun main(): Number {
  be twice holds fun(n: Number) => n * 2            // inline lambda
  be a holds 10 |> double()                         // pipe: 20
  be b holds twice(a) + helper(1)                   // 40 + 2 = 42
  return id(b)
}
```

**Inference.** A parameter may omit its annotation; the signature pre-pass
resolves it from the call sites. Type parameters use angle brackets
(`fun id<A>(x: A): A`).

**Lambdas and pipes.** `fun(x) => e` is the inline lambda. The pipe
`a |> f(args)` passes `a` as the *first* argument of the call. Method
chaining also reads naturally: `recv.m(args)` is `m(recv, args)`. An inline
lambda captures the locals in scope around it, at any nesting depth: a lambda
written inside another sees both the enclosing lambda's parameters and the
surrounding function's locals. (A *morphism* lambda, `move`, `functor`,
`view`, `reduction`, is the deliberate exception: it must be closed, see
[Arrows are closed](/book/arrows#arrows-are-closed).)

**Modifiers.** `internal fun` is not exported across a package boundary, 
from outside, it is indistinguishable from a function that does not exist.
`partial fun` declares a function that may not return:

<!-- yon-gate: illustrative -->
```yon
partial fun spin(n: Number): Number {
  forever { n = n + 1 }
  return n
}
```

## Effects: `visits`

I/O is an effect. The principled printing path is `Output.print`, and a
function that uses it must say so:

<!-- yon-gate: exit 0 -->
```yon
fun announce(msg: String): Unit visits Output {
  return Output.print(msg)
}
fun run(): Unit visits Output {                     // the effect propagates
  return announce("fatto")
}
fun main(): Number visits Output {
  be _u holds run()
  return 0
}
```

Calling a function that `visits E` requires the caller to *cover* `E`, by
declaring `visits E` itself, or by having a handler active. The effect
propagates up the call chain to `main`. This is the algebraic-effects
discipline of Yon: what a function touches is part of its signature, checked
by the compiler.

(The direct builtins `IO.print_num` and `String.print` exist as conveniences
and do not require the clause.)

## Polymorphism

Yon has three forms of polymorphism, and deliberately lacks a fourth.

**Parametric.** Type parameters on functions: `fun id<A>(x: A): A`. No
constraints, no bounds, a type parameter is honest ignorance. The
[Generics](/book/generics) chapter carries this further, to parameters on
places and arrows and how a type variable anchors to the universe.

**Sub-objects.** `this < B` in a place body does *not* declare inheritance: it
declares a **monomorphism** `A → B`, and the checker verifies it
structurally, `A` must carry at least all of `B`'s fields (*subsumption*),
or the mono does not exist and the program is rejected. Where it holds, an
`A` is usable wherever a `B` is expected. Each place is its own file, so the
base and the sub-object live side by side. `s/Error.yon`:

<!-- yon-gate: illustrative -->
```yon
place Error { message Number }
```

`s/SyntaxError.yon` carries the extra field and the function that reads the
base:

<!-- yon-gate: illustrative -->
```yon
place SyntaxError { this < Error message Number  line Number }

fun describe(e: Error): Number { return e.message }   // accepts any sub-object
```

`Entry.yon` builds the sub-object and passes it where an `Error` is expected:

<!-- yon-gate: illustrative -->
```yon
place Entry { }
fun main(): Number {
  be s holds .-> SyntaxError { message 40 line 17 }
  return describe(s) + 2          // 42: SyntaxError used as Error
}
```

Nothing is inherited, there are no methods to inherit, and no overriding,
because places have no behaviour of their own (chapter 0). `this <` is a
*claim about structure* that the compiler checks, exactly like a `law`.

**Coercions along monos.** The same direction appears twice more: the
comprehension `{x : A where P} <: A` (chapter 9) and the `boolean` face of
`proposition` (chapter 8). All Yon subtyping is travel along a declared or
derived monomorphism, never an implicit conversion.

**What is missing, on purpose.** There are no interfaces, traits or
typeclasses, and no virtual dispatch. The Yoneda stance of chapter 0 is the
replacement: a place's interface *is* the bundle of arrows defined on it
(views, moves, reductions), and "implementing an interface" is just
*providing arrows*, which compose, are first-class, and can carry checked
laws, none of which an interface declaration gives you.
