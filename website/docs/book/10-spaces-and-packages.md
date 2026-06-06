---
id: spaces-and-packages
title: "10. Spaces and packages"
sidebar_position: 10
---

# Spaces and packages

A **Space** is a hermetic tenant: a named heap where sections live.

```yon
space EU
space US

world Region { Code is EU, US }
place EUR in Region { balance number }
place USD in Region { balance number }

move EurToUsd from EUR to USD {
  balance converts to balance by scale
}
fun scale(x: number): number { return x * 110 / 100 }

fun main(): number {
  be alice holds new EUR in EU { balance 40 }
  be moved holds apply_move(EurToUsd, alice)
  return moved.balance        // 44: read on the transported instance
}
```

Try to read `alice.balance` directly and the type checker stops you:

```
TYPE ERROR: [TOPOS-E1110] cross-Space field access: 'alice' lives in space
'EU' and its field 'balance' cannot be read directly from outside that
space. Use apply_move(M, alice) to transport it via a declared geometric
morphism, then access the field on the moved instance.
```

That is hermeticity as a *type discipline*: within one binary, visibility,
`internal`, effects and the move/morphism gating decide what crosses
(physically, `YON_BACKEND=separate` opts into one heap per Space). The
strong regime is the **package boundary**.

## Cross-package imports

A package is a directory (`yon.toml` + sources). Importing a function *from a
Space* turns it into a remote arrow:

```yon
// Calc.yon, compiled to ./Calc_srv
fun triple(x: number): number { return x * 3 }
internal fun secret(x: number): number { return x + 1000 }
```

```yon
// Mid.yon, compiled to ./Mid_srv
import calc::triple from Calc
fun addtriple(x: number): number { return triple(x) + 1 }
```

```yon
// a.yon, the entry binary
import mid::addtriple from Mid
fun main(): number { return addtriple(13) }   // 40, across two processes
```

The first call to `addtriple` spawns `./Mid_srv` (convention: `<Space>_srv`
next to the caller, overridable with `YON_SRV_DIR`), which in turn spawns
`./Calc_srv`. Shutdown cascades when the caller exits, and a crashed server
is **transparently recovered**, virgin channel, epoch advanced, one retry.

The wire is deliberately narrow: **only numbers**, at most **4 arguments**,
over a named channel (`/yon_stream_<Space>`). Strings and sections do not
cross, they are process-local handles, and the type checker rejects them in
imported signatures. `internal` functions are not exported at all: from
outside, `secret` does not exist. **Cross-package hermeticity is process
isolation**: the kernel's MMU, not a runtime check.

## Hermetic scopes

Inside a function, `scope { }` gives you the formal version of the same idea:
the block becomes an `IsolatedFromAbove` region in the IR, every outer
binding it uses must enter as an explicit capture, and an implicit reference
is a verifier error:

```yon
fun main(): number {
  be base holds 40
  scope Hermetic {
    be sealed holds base + 2    // `base` enters as an explicit capture
  }
  return base + 2               // 42
}
```
