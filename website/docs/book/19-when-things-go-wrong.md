---
id: when-things-go-wrong
title: "19. When things go wrong"
sidebar_position: 19
---

# When things go wrong

Yon has no exceptions, no unwinding, no `try`/`catch`, deliberately. A
non-local jump teleports control across the very boundaries the language
spends its whole design defending. Failure in Yon takes three shapes, all of
them *values or declarations*.

## Errors are places

An `error` declaration is a place whose meaning is failure. Errors form
their own sub-object hierarchy with `this <` (chapter 5's monomorphisms),
and a place can declare its error morphism with `on error`. The root is the
prelude's `place Error { message Text }`: it never lists its sub-errors and
never changes, and a new error declares itself from below. Each error and
each place is its own file, so the declarations sit side by side in the space.
`s/QueryError.yon` has `message` from `Error` and adds its own field:

<!-- yon-gate: fragment -->
```yon
error QueryError { this < Error  sqlstate Number }
```

A place names the error it can raise. `s/QueryInsert.yon`:

<!-- yon-gate: fragment
error QueryError { this < Error  sqlstate Number }
-->
```yon
place QueryInsert on error QueryError { sql Number }
```

`Entry.yon` reads a sub-error where the base is expected and returns 42:

<!-- yon-gate: fragment
error QueryError { this < Error  sqlstate Number }
-->
```yon
place Entry { }
fun handle(e: Error): Number { return Text.length(e.message) }
fun on_query_fail(q: QueryError): Number {
  return handle(q)               // sub-error used where Error is expected
}

fun main: Number {
  q := .-> QueryError { message "duplicate key"  sqlstate 29 }
  return on_query_fail(q) + q.sqlstate    // 13 + 29 = 42
}
```

`on error` is checked like everything else: the named error must be a
declared error place, and a handler written against `Error` accepts every
sub-error, subsumption doing for failures exactly what it does for data.
An error is a section: it carries fields, it is content-addressed, it can
cross a `move`. Nothing is thrown; errors travel by the same arrows as
everything else.

## An error leaves by `escape`

A fun with `on error E` returns `T + E`, the coproduct of its success and its
error. Inside such a fun, `escape` reads a value of `S + E` as an `S`: the
checker eliminates it with the `match` you would write, the success goes on
with the rest of the body, and the error leaves the fun as its own. It is the
bind of the monad `(-) + E`, and `escape` marks the site where it happens.
`Number.sqrt` is `on error DomainError`:

<!-- yon-gate: exit 3 -->
```yon
place Entry { }
fun k(x: Number) on error DomainError: Number {
  y := escape Number.sqrt(x)    // sqrt(4) = 2, or the error leaves k
  return y + 1
}

fun main: Number {
  return match k(4) { Number as v => v, DomainError as d => 99 }
}
```

`escape` is a prefix, like `not`: `escape Number.sqrt(x) + 1` is
`(escape Number.sqrt(x)) + 1`. The values are read from left to right and the
first error wins. In a loop with a partial step the first error leaves the
loop and the fun. A fun that declares a larger error lets a smaller one
through, along its `this <`: a `DomainError` leaves a fun `on error Error` as
an `Error`.

The value a fun returns needs no `escape`: `return Number.sqrt(x)` in a fun
`on error DomainError` returns the error as it is, and an `escape` there is
refused with code `E2013`, as an `escape` on a value that cannot fail. Without
`escape` a value of `S + E` stays a value: `y := Number.sqrt(x)` binds `y` to
the coproduct, to look at later with `match`. Read where an `S` is wanted
without `escape`, it is refused with code `E2012`, and the message says the
two ways: write `escape`, or handle the error with `match`. Where the error
has no way out (a fun that declares no `on error`, an error its signature does
not contain, a lambda, a producer, a spawn), `escape` is refused with code
`E2011`.

<!-- yon-gate: refuses write escape, or handle the error with match -->
```yon
place Entry { }
fun f(x: Number) on error DomainError: Number {
  return Number.sqrt(x) + 1
}

fun main: Number {
  return match f(4) { Number as v => v, DomainError as d => 99 }
}
```

## Failure is a value

At the stdlib boundary, absence is in-band (chapter 12): a missing file, an
unset variable, an out-of-range index all return the `0.0` handle. You test
it like any number. The compiler does its part *before* runtime: a false
`law` is rejected by AlgebraVerifier, a missing subsumption mono is rejected by
the checker, and a cross-Space call is checked against the types of the
remote signature: an argument the call cannot carry is refused before the
program builds.

## When another process fails

Cross-Space, failure is a process matter, and chapter 17's machinery handles
the recoverable case: a crashed server is respawned on a virgin channel with
the epoch advanced, and the call retried once, transparently. When the
failure is *not* recoverable (the server binary is missing, the operation
was never exported), the runtime says so plainly:

```
error: cross-Space call failed, Space server './Bank_srv' did not
answer or the operation is not exported
```

## Undecided is not failed

Ω has three values (chapter 8), so "it failed" and "it has not been decided"
are two different outcomes. `decide(p)` turns a proposition into a value of the
prelude place `Decision`, the coproduct `Present :U Absent :U Unknown`, and a
`match` answers each arm, the third one included.
