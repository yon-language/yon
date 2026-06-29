---
id: spaces-and-packages
title: "10. Spaces and packages"
sidebar_position: 10
---

# Spaces and packages

A **Space** is a hermetic tenant: a named heap where sections live. A Space is
not a surface keyword; it is a **directory** under the project root, declared
to a world in `yon.toml`. A **place** is a file inside it, and a place
inherits its world from the directory it lives in. So the project on disk *is*
the ontology:

```
region/
  yon.toml
  Entry.yon          // main, plus the cross-Space move
  eu/                // the Space "eu"
    Topos.yon        // topos RegionTopos where { }
    EUR.yon          // place EUR { balance number }
    USD.yon          // place USD { balance number }
```

```toml
# yon.toml
[package]
name = "region"

[runtime]
backend = "memory"

[world.Region]
spaces  = ["eu"]
objects = ["Money"]
```

```yon
// eu/EUR.yon  (and eu/USD.yon, the same shape)
place EUR {
  balance number
}
```

```yon
// Entry.yon
place Entry { }
fun scale(x: number): number { return x * 110 / 100 }
move EurToUsd from EUR to USD {
  balance converts to balance by scale
}
fun main(): number {
  be alice holds new EUR { balance 40 }
  be moved holds apply_move(EurToUsd, alice)
  return moved.balance        // 44: read on the transported instance
}
```

Try to read `alice.balance` across a Space boundary and the type checker stops
you: a value that lives in one Space cannot have its field read directly from
outside that Space. You must `apply_move(M, alice)` to transport it via a
declared move, then read the field on the moved instance.

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
