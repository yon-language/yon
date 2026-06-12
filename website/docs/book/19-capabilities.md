---
id: capabilities
title: "19. Capabilities"
sidebar_position: 19
---

# Capabilities

A move can demand more than well-typed fields: it can demand **authority**.

```yon
world Region { Code is EU, US }
place EUR in Region { balance number }
place USD in Region { balance number }

move EurToUsd from EUR to USD requires MoneyTransfer {
  balance converts to balance by scale
}
fun scale(x: number): number { return x * 110 / 100 }

fun main(): number {
  be _g holds Cap.grant(1991051931)        // grant the capability hash
  be a holds new EUR { balance 40 }
  be b holds apply_move(EurToUsd, a)       // checked at the border
  return b.balance - 2                    // 42
}
```

`requires CAP1, CAP2` names the capabilities a move needs; `Cap.grant`
confers them to the current process (capabilities are FNV-1a hashes of
their names, the same hash the compiler emits, so the check is
deterministic across the toolchain). The intended model is the
capability-security one: **authority travels explicitly**, attached to the
arrow that needs it, never ambient.

Honest status for 1.0: the check is enforced at **runtime** at each
`apply_move` (a denied move is a runtime refusal, not a crash), while the
*static* rule, a caller of a `requires` move must itself declare the
capability, is the production design, not yet wired into the checker.
The syntax and the runtime gate are stable; treat the static half as
arriving, like the Heyting unwrapping of chapter 17.
