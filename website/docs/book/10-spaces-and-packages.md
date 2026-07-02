---
id: spaces-and-packages
title: "10. Spaces and packages"
sidebar_position: 10
---

# Spaces and packages

A **Space** is a hermetic tenant: a named heap where sections live. A Space is
not a surface keyword; it is a **directory** under the project root, declared
to a world in `yon.toml`. A **place** is a file inside it, and a place inherits
its world from the directory it lives in. So the project on disk *is* the
ontology. Here is the restaurant, with its dining room (`sala`) and its kitchen
(`cucina`) as two Spaces:

```
restaurant/
  yon.toml
  Entry.yon          // place Entry { } + top-level fun main()
  sala/              // the Space "sala" (the dining room)
    Topos.yon        // topos SalaTopos where { }
    Order.yon        // place Order { total number }
    ToKitchen.yon    // move ToKitchen from Order to Ticket
  cucina/            // the Space "cucina" (the kitchen)
    Topos.yon        // topos CucinaTopos where { }
    Ticket.yon       // place Ticket { total number }
```

```toml
# yon.toml
[package]
name = "restaurant"

[runtime]
backend = "memory"

[world.Restaurant]
objects = ["Guest"]
spaces  = ["sala", "cucina"]
```

```yon
// sala/Order.yon
place Order {
  total number
}
```

```yon
// cucina/Ticket.yon
place Ticket {
  total number
}
```

An order placed in the dining room becomes a ticket in the kitchen. That
crossing is a `move`, a file in the `sala` Space:

```yon
// sala/ToKitchen.yon
fun withTax(x: number): number { return x * 110 / 100 }
move ToKitchen from Order to Ticket {
  total maps to total by withTax
}
```

The entry place applies it:

```yon
// Entry.yon
place Entry { }
fun main(): number {
  be table4 holds new Order { total 40 }
  be fired holds apply_move(ToKitchen, table4)
  return fired.total          // 44: read on the transported instance
}
```

To run it, save these files under `restaurant/` and compile the directory:

```
./toolchain/yonc restaurant -o /tmp/restaurant && /tmp/restaurant; echo $?
```

The exit code is `44`. The `Order` lives in `sala`; `apply_move(ToKitchen,
table4)` transports it into `cucina` as a `Ticket`, applying `withTax` on the
way, and you read `.total` on the transported instance.

## Hermeticity is physical

Within one binary, what crosses between Spaces is decided by structure: a
`move` (or a `view`, a `geomorph`, a declared arrow) is the crossing, and there
is no arrow that reads a section's field from another Space directly. The move
is the front door.

The strong regime is the **package boundary**, and there hermeticity is not a
type rule at all: it is the operating system. With `backend = "separate"` each
Space compiles to its own process, so a Space is a heap behind a process
boundary. Nothing reaches across except numbers over a named channel, because
nothing else *can*: the kernel's memory protection is the fence. A section in
`cucina` is a handle in the kitchen process; the dining-room process never holds
its address. Hermeticity is the MMU, not a runtime check the program could be
tricked into skipping.

## Cross-package imports

A package is a directory (`yon.toml` + sources). Importing a function *from a
Space* turns it into a remote arrow. Here the kitchen exposes a price function;
the dining room calls it across the boundary:

```yon
// kitchen.yon, compiled to ./Kitchen_srv
fun plate_price(dish: number): number { return dish * 3 }
internal fun recipe_secret(dish: number): number { return dish + 1000 }
fun main(): number { return 0 }
```

```yon
// pass.yon, the entry binary
import kitchen::plate_price from Kitchen
fun main(): number {
  be three_plates holds plate_price(13)
  be _p holds IO.print_num(three_plates)
  return three_plates - 1        // prints 39, across two processes
}
```

Compile each source to its own binary and run the caller:

```
./toolchain/yonc kitchen.yon -o ./Kitchen_srv
./toolchain/yonc pass.yon -o ./pass
./pass; echo $?
```

`pass` prints `39` and exits with `38`. The first call to `plate_price` spawns
`./Kitchen_srv` (convention: `<Space>_srv` next to the caller, overridable with
`YON_SRV_DIR`), asks it to run `plate_price(13)`, and gets `39` back over the
wire. Shutdown cascades when the caller exits.

The wire is deliberately narrow: **only numbers**, at most **4 arguments**, over
a named channel (`/yon_stream_<Space>`). Every value that crosses is an `f64`;
the transport has no other type. Ask for a fifth argument and the compiler stops
you before it builds, reporting that a cross-Space call may take at most 4 number
arguments across a Space boundary.

Strings and sections are process-local handles, so what travels is a number, not
the object. `internal` functions are not exported. The importer of
`recipe_secret` compiles, but the first call gets a refusal from the server
itself: the cross-Space call fails because `Kitchen_srv` reports the operation is
not exported.

**Cross-package hermeticity is process isolation**: the kernel's MMU, not a
type-checker pass.

## Hermetic scopes

Inside a function, `scope { }` gives you the formal version of the same idea:
the block becomes an `IsolatedFromAbove` region in the IR, every outer binding
it uses must enter as an explicit capture, and an implicit reference is a
verifier error:

```yon
// Entry.yon
place Entry { }
fun main(): number {
  be base holds 40
  scope Hermetic {
    be sealed holds base + 2    // `base` enters as an explicit capture
  }
  return base + 2               // 42
}
```

Under a one-Space project this returns `42`. The same fence, three grains: an
arrow between two Spaces in one binary, a process boundary between two packages,
and a region boundary inside one function.
