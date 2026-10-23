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

<!-- yon-gate: illustrative -->
```yon
error QueryError { this < Error  sqlstate Number }
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
fun handle(e: Error): Number { return String.length(e.message) }
fun on_query_fail(q: QueryError): Number {
  return handle(q)               // sub-error used where Error is expected
}

fun main(): Number {
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
