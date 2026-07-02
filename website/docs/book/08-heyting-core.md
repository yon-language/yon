---
id: heyting-core
title: "8. The Heyting core"
sidebar_position: 8
---

import HeytingOmega from '@site/src/components/HeytingOmega';

# The Heyting core

Yon's logic is intuitionistic. The proposition type Ω is a Heyting algebra
with three observable states, `present`, `absent`, `unknown`, and
`boolean` is just Ω's classical face.

<HeytingOmega />

<!-- yon-gate: exit 42 -->
```yon
fun main(): number {
  be u holds unknown
  be p holds present
  be both holds p &&? u            // unknown: conjunction with the undecided
  be imp holds u =>? p             // present: anything implies the present
  be dec holds to_bool(imp)
  be h1 holds heyting(5)          // trits 101, all certain
  be h2 holds heyting(5, 2)       // middle trit unknown
  be hand holds h1 &? h2           // trit-wise, unknown propagates
  return if dec then 42 else 0
}
```

The operator families keep the two logics visually distinct:

- `and`/`or`/`not`/`=>` are classical, on booleans;
- `&&? ||? =>? !?` are the Heyting connectives on Ω, `unknown` is not an
  error state, it is a *value*, and it propagates by the algebra's rules
  (`present &&? unknown` is `unknown`; `unknown =>? present` is `present`);
- `&? |? ^? ~?` are **trit-wise** on `heyting<N>`: an integer whose bits
  each carry their own certainty, with an Unknown mask that propagates
  bit by bit. `heyting(v)` has no unknown bits; `heyting(v, mask)` marks
  the masked ones.

Bridges: `to_bool`/`to_prop` move between the faces; `decide` guards on the
undecided.

## Ω as a place to do topology

A `topos` block declares **subobject classifiers** over the objects of its
space (the objects are the place files in that directory), each `prop` is a
map into Ω you can evaluate:

<!-- yon-gate: illustrative -->
```yon
// in the space directory: State.yon
place State { balance number }

// in the same directory: Topos.yon
topos Bank where {
  prop is_overdrawn(s: State): proposition = s.balance < 0
}

// Entry.yon
place Entry { }
fun main(): number {
  be s holds new State { balance 5 }
  be bad holds is_overdrawn(s)
  return if bad then 0 else 42
}
```

And Ω itself carries structure: a **Lawvere-Tierney topology** is an
operator `j : Ω → Ω` (monotone, inflationary, idempotent) declared on a
place, the seed of sheaf semantics:

<!-- yon-gate: illustrative -->
```yon
topology j of P { return 1 }          // a Lawvere-Tierney j : Omega -> Omega
```

## Forcing at a stage

Kripke-Joyal semantics evaluates truth at a stage: a statement may hold
at one object of the site and fail at another. In Yon the stage is a
place, and the statement is a pattern condition, the same patterns that
drive `when`:

```yon
// NodeA.yon, a place file in the site's space directory
place NodeA { value number }

// Entry.yon
place Entry { }
fun guard(): number {
  forces NodeA value is number {
    return 1
  }
  return 0
}
fun main(): number { return 0 }
```

The block runs only where the condition holds at that stage. Patterns
are a variable, a literal, `present`, `absent`, `unknown`, chainable
with `and`/`or`; `forces` adds the stage to the machinery that `when`
already uses.