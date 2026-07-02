---
id: capabilities
title: "19. Capabilities"
sidebar_position: 19
---

# Capabilities

A move can demand more than well-typed fields: it can demand **authority**.

<!-- yon-gate: illustrative -->
```yon
place EUR { balance number }
place USD { balance number }

move EurToUsd from EUR to USD requires MoneyTransfer {
  balance converts to balance by scale
}
fun scale(x: number): number { return x * 110 / 100 }

fun main(): number {
  be _g holds Cap.grant(169281588)       // register the capability token
  be a holds new EUR { balance 40 }
  be b holds apply_move(EurToUsd, a)     // the move that names the token
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
fun main(): number {
  be before holds Cap.check(169281588)   // 0, not yet granted
  be _g holds Cap.grant(169281588)
  be after holds Cap.check(169281588)    // 1, now present
  return before * 10 + after              // 1
}
```

Compile either program with `yonc <dir> -o out && ./out; echo $?`. The first
returns `42`, the second `1`. `Cap.grant`, `Cap.check`, and `Cap.revoke` each
take a token hash and return a number; the registry holds up to 256 distinct
tokens.

## Honest status for 1.0

At each `apply_move` the compiler emits a `Cap.check` for every capability the
move `requires`. That call runs, and the token is looked up. What is not yet
wired is the consequence: the checked result is computed and not acted on, so a
move whose capability is absent is not refused today. Remove the `Cap.grant`
line from the first program and it still returns `42`. The `requires` clause,
the token registry, and the emitted check are stable; the gate that turns a
missing token into a refusal is the next step, not this one.

The *static* half is design in the same sense. The intended rule (a caller of a
`requires` move must itself hold the capability) is the production shape, not
yet enforced by the checker. Both halves are the model; both arrive together,
like the Heyting unwrapping of chapter 18. The syntax you write today is the
syntax authority will travel on when the gate closes.
