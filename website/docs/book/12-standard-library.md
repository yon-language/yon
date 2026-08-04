---
id: standard-library
title: "12. A tour of the standard library"
sidebar_position: 12
---

# A tour of the standard library

The stdlib is organized in modules; the full index is in the
[Syntax Reference](../syntax-reference.md). A few highlights, all running
code.

## Collections and streams

`List`, `HashMap`, `HashSet`, `XSet` are immutable collections over the
content-addressed heap; `Vec` is the mutable-array exception (its own section
below). Streams chain with methods, and their combinators
**require inline lambdas** (the fusion happens at emission, so the body must
be visible):

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be l holds List.cons(1, List.cons(2, List.cons(3, List.empty(0))))
  be s holds Seq.from_list(l).map(fun(x) => x * 2).fold(0, fun(a, b) => a + b)
  return s + 30                    // 12 + 30 = 42
}
```

## System: files, environment, arguments

<!-- yon-gate: illustrative -->
```yon
be _w holds File.write_text("/tmp/out.txt", "ciao")
be readback holds File.read_text("/tmp/out.txt")
be home holds Env.get("HOME")
be n holds Args.count(0)
```

Failure is a value: string-producing operations return the `0.0` handle when
the file is missing, the variable unset, the index out of range. Note the
convention in the *system* modules: their no-parameter builtins take a dummy
`0` (`Args.count(0)`, `Time.now_ms(0)`), while the collection constructors
are genuinely zero-argument (`HashMap.empty()`, `VoyagerList.empty()`).

## Numbers, time, randomness, hashing

`Math` is complete (`sqrt` to `tanh`, `gcd`/`lcm`, `pi`, `e`); `Bits` covers
the bitwise toolbox including 64-bit variants and `popcount`; `Time.now_ms/ns`
and `Random.seed/int/range` do what they say; `Crypto.fnv1a`/`hash_int` give
deterministic hashing (FNV-1a, the same the compiler uses for capability
hashes).

## Maps, bits, sealed storage

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be m holds HashMap.empty()
  be m2 holds HashMap.set(m, 1, 10)
  be ten holds HashMap.get(m2, 1)
  be g holds Math.gcd(12, 18)                    // 6
  be b holds Bits.band(12, 10)                    // 8
  be vl holds VoyagerList.empty()
  be vl2 holds VoyagerList.append(vl, 18)        // Golay-sealed storage
  be readback holds VoyagerList.get(vl2, 0)
  return ten + g + b + readback                  // 10+6+8+18 = 42
}
```

A `Vec` is a dynamic array on an arena strip, no `malloc`. `push` appends in
place into spare capacity, or reallocates a doubled strip past capacity and
returns a new handle (so always use the handle `push` returns), handing the
old strip's whole pages back to the OS; `get`/`set` are O(1) and `set` mutates
in place.

<!-- yon-gate: exit 62 -->
```yon
fun main(): Number {
  be a holds Vec.push(Vec.push(Vec.push(Vec.empty(), 10), 20), 30)
  be b holds Vec.push(Vec.push(a, 40), 50)       // grows past the initial cap of 4
  be c holds Vec.set(b, 0, 7)                     // in-place; c is b
  return Vec.size(c) + Vec.get(c, 0) + Vec.get(c, 4)   // 5 + 7 + 50 = 62
}
```

## The exotic corner

Three modules are distinctly Yon. `MerkleTree` builds content-addressed Merkle
trees. `VoyagerList`, above, is a Golay-sealed list, error-correcting
storage, à la Voyager probe (`corrupt_at` exists precisely so you can watch
it heal). And `Magma` (chapter 6) turns a law-verified place
into a runnable algebraic structure: closure, reachability with certificates,
and normal forms.

## The prelude: the primitives are places, written in Yon

The modules above are wired in the compiler. The **prelude** is the other
half, and it is not wired at all: it is Yon source that rides in front of
every compilation, and it declares the primitives as what they are — places.

```
prelude/
  yon.toml          [world.Num64] [world.Num32] [world.Txt] [world.Logic] [world.Err]
  num64/  Number.yon  Int64.yon    num32/  Int32.yon
  text/   String.yon  logic/  Boolean.yon  Unit.yon   err/  Error.yon  DomainError.yon
```

`place Number is number` is a **fusion**: the place is the declared face of a
primitive code, and `is <prim>` says the carrier is axiomatic — the leaf of the
carrier functor's recursion, not a way around it. Everything else is ordinary
Yon: `Number.gcd` is written with Euclid's algorithm, `Number.sqrt` with
Newton's, `String.reverse` character by character.

<!-- yon-gate: exit 32 -->
```yon
place Entry {
  fun main(): Number {
    be g holds Number.gcd(12, 8)      // 4
    be m holds Number.max(3, 7)       // 7
    be f holds Number.floor(21.9)     // 21
    return g + m + f
  }
}
```

**Precision is a world, not a type parameter.** `Int64` lives in the world
`Num64`, `Int32` in `Num32` — two distinct categories, so `Widen` between them
is a genuine functor rather than an arrow between two objects of one site. The
bare names in your code mean the 64-bit site, which is the language default.
Integer arithmetic is exact: on an integer carrier `/` and `%` truncate, so
`Int64.div(7, 2)` is 3.

**Partial functions declare how they fail.** `sqrt` of a negative, `ln` of a
non-positive, division by zero: each is dressed with `on error DomainError`,
and the caller handles the failure by matching on the arms of the coproduct.

<!-- yon-gate: exit 37 -->
```yon
place Entry {
  fun main(): Number {
    be g holds Int64.gcd(12, 8)                   // 4
    be d holds Int64.div(7, 2)                    // 3, or a DomainError
    be bc holds Int64.bit_count(7)                // 3
    return (if g == 4 then 4 else 0)
         + (if bc == 3 then 30 else 0)
         + (match d { Int64 as v => (if v == 3 then 3 else 0),
                      DomainError as e => 99 })
  }
}
```

**The boundary with the silicon is readable.** Where a body genuinely cannot be
written in Yon — measuring a rope, indexing it, allocating one — the prelude
says so with `is given`, and the compiler checks that the wired implementation
exists with exactly that signature. Ten declarations at the top of `String.yon`
are the whole of it; the other thirteen functions are derived above them, in
Yon.
