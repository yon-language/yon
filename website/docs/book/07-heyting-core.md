---
id: heyting-core
title: "7. The Heyting core"
sidebar_position: 7
---

# The Heyting core

Yon's logic is intuitionistic. The proposition type Ω is a Heyting algebra
with three observable states — `present`, `absent`, `unknown` — and
`boolean` is just Ω's classical face.

```yon
fun main(): number {
  be u holds unknown
  be p holds present
  be both holds p &&? u            // unknown: conjunction with the undecided
  be imp holds u =>? p             // present: anything implies the present
  be dec holds to_bool(imp)
  be h1 holds heyt_int(5)          // trits 101, all certain
  be h2 holds heyt_int(5, 2)       // middle trit unknown
  be hand holds h1 &? h2           // trit-wise, unknown propagates
  return if dec then 42 else 0
}
```

The operator families keep the two logics visually distinct:

- `and`/`or`/`not`/`=>` are classical, on booleans;
- `&&? ||? =>? !?` are the Heyting connectives on Ω — `unknown` is not an
  error state, it is a *value*, and it propagates by the algebra's rules
  (`present &&? unknown` is `unknown`; `unknown =>? present` is `present`);
- `&? |? ^? ~?` are **trit-wise** on `heyt_int<N>`: an integer whose bits
  each carry their own certainty, with an Unknown mask that propagates
  bit by bit. `heyt_int(v)` has no unknown bits; `heyt_int(v, mask)` marks
  the masked ones.

Bridges: `to_bool`/`to_prop` move between the faces; `decide` guards on the
undecided.

## Ω as a place to do topology

A `topos` block declares objects together with their **subobject
classifiers** — each `prop` is a map into Ω you can evaluate:

```yon
world Ledger { Code is X }

topos Bank in Ledger where {
  objects {
    place State in Ledger { balance number }
  }
  prop is_overdrawn(s: State): proposition = s.balance < 0
}

fun main(): number {
  be s holds new State { balance 5 }
  be bad holds is_overdrawn(s)
  return if bad then 0 else 42
}
```

And Ω itself carries structure: a **Lawvere–Tierney topology** is an
operator `j : Ω → Ω` (monotone, inflationary, idempotent) declared on a
place — the seed of sheaf semantics:

```yon
topology j of P { return 1 }          // a Lawvere–Tierney j : Omega -> Omega
```
