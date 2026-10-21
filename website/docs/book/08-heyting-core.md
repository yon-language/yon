---
id: heyting-core
title: "8. The Heyting core"
sidebar_position: 8
---

import HeytingOmega from '@site/src/components/HeytingOmega';

# The Heyting core

Yon's logic is intuitionistic. The proposition type Ω is a Heyting algebra
with three observable states, `present`, `absent`, `unknown`, and
`Boolean` holds its two decided values: a Boolean enters Ω through the
characteristic mono (`true` is `present`, `false` is `absent`), and nothing
leaves Ω for `Boolean`, because `unknown` would have to become one of two
values that do not mean unknown.

<HeytingOmega />

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be u := unknown
  be p := present
  be both := p &&? u            // unknown: conjunction with the undecided
  be imp := u =>? p             // present: anything implies the present
  be h1 := heyting(5)          // trits 101, all certain
  be h2 := heyting(5, 2)       // middle trit unknown
  be hand := h1 &? h2           // trit-wise, unknown propagates
  return match decide(imp) { Present => 42, Absent => 0, Unknown => 1 }
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

Bridges: `to_prop` sends a Boolean into Ω. The way back is `decide(p)`,
total, which lands in `Decision`, a coproduct of three arms, `Present`,
`Absent` and `Unknown`; a `match` on it answers each arm, the third one
included, and leaving it out is a type error. A proposition is not a
condition: `if p` and `when p` on a proposition are refused, and the message
shows the `match`.

## Ω as a place to do topology

A `topos` block declares **subobject classifiers** over the objects of its
space (the objects are the place files in that directory), each `prop` is a
map into Ω you can evaluate:

<!-- yon-gate: illustrative -->
```yon
// in the space directory: State.yon
place State { balance Number }

// in the same directory: Topos.yon
topos Bank where {
  prop is_overdrawn(s: State) = s.balance < 0
}

// Entry.yon
place Entry { }
fun main(): Number {
  be s := .-> State { balance 5 }
  be bad := is_overdrawn(s)
  return match decide(bad) { Present => 0, Absent => 42, Unknown => 1 }
}
```

And Ω itself carries structure: a **Lawvere-Tierney topology** is an
operator `j : Ω → Ω` (monotone, inflationary, idempotent), the seed of sheaf
semantics. Yon had a `topology` declaration and it has been **retired**: it
parsed, and sheafification was never wired behind it — a keyword that
promises a semantics nobody enforces is worse than its absence. It returns
with the sheaf design, and with something to enforce.

## Forcing at a stage

Kripke-Joyal semantics evaluates truth at a stage: a statement may hold
at one object of the site and fail at another. In Yon the stage is a
place, and the statement is a pattern condition, the same patterns that
drive `when`:

```yon
// NodeA.yon, a place file in the site's space directory
place NodeA { value Number }

// Entry.yon
place Entry { }
fun guard(): Number {
  be r := 0
  forces NodeA value is Number {
    r = 1
  }
  return r
}
fun main(): Number { return 0 }
```

The block runs only where the condition holds at that stage. Patterns
are a variable, a literal, `present`, `absent`, `unknown`, chainable
with `and`/`or`; `forces` adds the stage to the machinery that `when`
already uses.