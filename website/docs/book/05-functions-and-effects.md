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
  be twice := fun(n: Number) => n * 2            // inline lambda
  be a := 10 |> double()                         // pipe: 20
  be b := twice(a) + helper(1)                   // 40 + 2 = 42
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
surrounding function's locals. One limit: a lambda that captures a *mutable*
local (one reassigned with `=`, or a cell made with `Space.make`) holds that
cell, which dies when the call returns, so such a lambda cannot leave the call:
returning it, directly or inside another value, storing it in a cell, or
sending it to another Space is rejected. Apply it, or pass it down, within the
call. The same rule holds for the *morphism* lambdas, `move`, `functor`,
`view`, `reduction`: see [Arrows are closed](/book/arrows#arrows-are-closed).

**Modifiers.** Inside a place, an `internal fun` is reachable only from the
funs of that place; a call from anywhere else is a type error that names its
house. An `internal` function is never exported across a package boundary.

## Failure is a coproduct: `on error`

A function that can fail says *how*, in its signature. `on error E` makes the
return type the coproduct `T + E`: the function returns either a `T` or an
`E`, and the caller cannot forget the second case, because there is nothing to
forget — it is in the type.

Raising is **returning**: build a section of the error place with the
mediatrice and hand it back. There is no second control-flow mechanism, no
unwinding, no hidden path.

<!-- yon-gate: exit 30 -->
```yon
place Entry {
  fun half(n: Number) on error DomainError: Number {
    return if n < 0 then .-> DomainError { message "half of a negative" }
           else n / 2
  }
  fun main(): Number {
    be a := half(0 - 4)
    return match a { Number as v => 1, DomainError as e => 30 }
  }
}
```

Handling is `match`, one arm per side of the coproduct, and the witness binder
(`DomainError as e`) names the value on the arm that matched. The error places
themselves live in the prelude: `Error` is the root, and a concrete error
declares itself into it from below with the mono `this < Error` — the
open-world direction, so `Error` never enumerates its children and never
changes.

**When a body is not writable in Yon**, the signature says that too. `is given`
declares an axiomatic body — Java's `native` — and the compiler verifies that
the wired implementation exists with exactly that signature. It is the brother
of `is <prim>`: that one says the *carrier* is a leaf of the recursion, this
one says the *body* is. The primitives of the runtime are the library's, so
`is given` is written in the prelude only; in any other file it is refused
(E2007), and a function of yours has its body in Yon. The prelude's
`prelude/num64/Math.yon` is the face of the mathematical functions:

<!-- yon-gate: illustrative -->
```yon
place Math {
  fun floor(x: Number): Number is given
  fun sqrt(x: Number): Number is given
  // ... the other functions of the runtime on Number
}
```

(A program calls them without declaring anything: `examples/kw_given`, which
the keyword chapter runs.)

A primitive binds to its `is given` declaration, not to its name. A function
with a body is never replaced by a primitive that answers to the same name:
if `Number.floor` were written `{ return Math.floor(n) + 7 }`, a call would
run that body. And `is given` with a body in the same declaration is refused
(E1001): one says the body is the compiler's, the other that it is this one.

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
  be _u := run()
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
constraints, no bounds: inside the body `A` is abstract, known only from the
arrows that pass it, so a value of type `A` can only be passed on. No field,
no call, no arithmetic, no comparison with a literal reveals it, and the
checker refuses each; every call fixes `A` for itself. The
[Generics](/book/generics) chapter carries this further, to parameters on
places and arrows and how a type variable anchors to the universe.

**Sub-objects.** `this < B` in a place body does *not* declare inheritance: it
declares a **monomorphism** `A → B`, and the checker verifies it
structurally, `A` must carry at least all of `B`'s fields (*subsumption*),
or the mono does not exist and the program is rejected. Where it holds, an
`A` is usable wherever a `B` is expected. The base here is the prelude's
`place Error { message Text }`, the root of the errors. A library place is
never redeclared: a place of yours that means to be one declares itself under
it (a user place that takes a library name is refused, E2006).
`s/SyntaxError.yon` carries only its extra field; `message` it has from
`Error`:

<!-- yon-gate: illustrative -->
```yon
place SyntaxError { this < Error  line Number }
```

`Entry.yon` builds the sub-object and passes it where an `Error` is expected:

<!-- yon-gate: illustrative -->
```yon
place Entry { }
fun describe(e: Error): Number { return String.length(e.message) }   // accepts any sub-object
fun main(): Number {
  be s := .-> SyntaxError { message "unexpected }" line 30 }
  return describe(s) + s.line     // 12 + 30 = 42: SyntaxError used as Error
}
```

Nothing is inherited and nothing is overridden: `this <` is a mono, not a
subclass. `this <` is a
*claim about structure* that the compiler checks, exactly like a `law`.

**Coercions along monos.** The same direction appears twice more: the
comprehension `{x : A where P} <: A` (chapter 9) and the `Boolean` face of
Ω (chapter 8). All Yon subtyping is travel along a declared or
derived monomorphism, never an implicit conversion.

**What is missing, on purpose.** There are no interfaces, traits or
typeclasses, and no virtual dispatch. The Yoneda stance of chapter 0 is the
replacement: a place's interface *is* the bundle of arrows defined on it
(views, moves, reductions), and "implementing an interface" is just
*providing arrows*, which compose, are first-class, and can carry checked
laws, none of which an interface declaration gives you.
