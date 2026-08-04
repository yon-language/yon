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
and a place can declare its error morphism with `on error`. Each error and
each place is its own file, so the declarations sit side by side in the space.
`s/Error.yon` and `s/QueryError.yon`:

<!-- yon-gate: illustrative -->
```yon
error Error { message Number }
```

<!-- yon-gate: illustrative -->
```yon
error QueryError { this < Error message Number  sqlstate Number }
```

A place names the error it can raise. `s/QueryInsert.yon`:

<!-- yon-gate: illustrative -->
```yon
place QueryInsert on error QueryError { sql Number }
```

`Entry.yon` reads a sub-error where the base is expected and returns 42:

<!-- yon-gate: illustrative -->
```yon
place Entry { }
fun handle(e: Error): Number { return e.message }
fun on_query_fail(q: QueryError): Number {
  return handle(q)               // sub-error used where Error is expected
}

fun main(): Number {
  be q holds .-> QueryError { message 40  sqlstate 23505 }
  return on_query_fail(q) + 2    // 42
}
```

`on error` is checked like everything else: the named error must be a
declared error place, and a handler written against `Error` accepts every
sub-error, subsumption doing for failures exactly what it does for data.
An error is a section: it carries fields, it is content-addressed, it can
cross a `move`. Nothing is thrown; errors travel by the same arrows as
everything else.

## Failure is a value

At the stdlib boundary, absence is in-band (chapter 12): a missing file, an
unset variable, an out-of-range index all return the `0.0` handle. You test
it like any number. The compiler does its part *before* runtime: a false
`law` is rejected by AlgebraVerifier, a missing subsumption mono is rejected by
the checker, a string in a cross-Space signature never compiles, entire
categories of "going wrong" are moved from runtime to the type checker.

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

## On the horizon

The third shape is the most Yon of all and is openly *in progress*: the
Heyting unwrapping. Ω already has the three states (chapter 8); the plan is
a result discipline where an operation's outcome is **Provato / Assurdo /
Indeterminato**, proven, absurd, undecided, so "it failed" and "it has
not decided yet" stop being the same thing. The trit machinery
(`heyting`) is operational today; the surface unwrapping construct is
still ahead, and this book will gain a section when it lands.
