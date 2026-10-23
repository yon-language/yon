---
id: capabilities
title: "20. Capabilities"
sidebar_position: 20
---

# Capabilities

A move can declare more than well-typed fields: it can declare the **authority**
it needs. The declaration is checked at run time but not yet enforced (see
*Status* below).

<!-- yon-gate: illustrative -->
```yon
place EUR { balance Number }
place USD { balance Number }

move EurToUsd from EUR to USD requires MoneyTransfer {
  balance converts to balance by scale
}
fun scale(x: Number): Number { return x * 110 / 100 }

fun main(): Number {
  _g := Cap.grant(169281588)       // register the capability token
  a := .-> EUR { balance 40 }
  b := apply_move(EurToUsd, a)     // the move that names the token
  return b.balance - 2                    // 42
}
```

`requires CAP1, CAP2` names the capabilities a move needs. `Cap.grant`
registers a token in the process, keyed by the FNV-1a hash of its name (the
same hash the compiler emits for the name in `requires`, so a token granted
by hash and a capability named in the arrow line up deterministically across
the toolchain). The number `169281588` is the FNV-1a hash of `MoneyTransfer`.
The model is the capability-security one: **authority travels explicitly**,
attached to the arrow that needs it, never ambient.

## What the reader can verify

The registry is real and observable. `Cap.check(h)` returns `0` before the
token is granted and `1` after:

<!-- yon-gate: exit 1 -->
```yon
fun main(): Number {
  before := Cap.check(169281588)   // 0, not yet granted
  _g := Cap.grant(169281588)
  after := Cap.check(169281588)    // 1, now present
  return before * 10 + after              // 1
}
```

Compile either program with `yonc <dir> -o out && ./out; echo $?`. The first
returns `42`, the second `1`. `Cap.grant`, `Cap.check`, and `Cap.revoke` each
take a token hash and return a number; the registry holds up to 256 distinct
tokens.

## Status

At each `apply_move` the compiler emits a `Cap.check` for every capability the
move `requires`. That call runs, and the token is looked up. The result is not
acted on: a move whose capability is absent is not refused. Remove the
`Cap.grant` line from the first program and it still returns `42`. The
`requires` clause, the token registry and the emitted check exist; the refusal
of a missing token does not exist yet.

The *static* rule (a caller of a `requires` move must itself hold the
capability) is not enforced by the checker either. Capabilities are declared,
not enforced.
