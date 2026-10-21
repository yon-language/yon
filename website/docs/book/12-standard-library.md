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

**One collection, one generic type.** Every collection is one place of the
prelude, generic in what it holds: `List<T>`, `HashMap<K, V>`, `HashSet<T>`,
`XRelMap<K, V>`, `Arena<V>`. Its representation (how wide a slot is, how a
value is encoded) is derived from the carrier of its parameters, never
written per type: there is no collection per precision or per element type,
and no type of the same name in two worlds. A lookup answers with a
coproduct, `Lookup<V> { Found(V) :U Absent }`: `match HashMap.get(m, k) {
Found(v) => …, Absent => … }`, so an absent key is never a value in
disguise. The runtime primitives are the places' `is given` bodies; `get` is
written in Yon on top of them.

`List`, `HashMap` and `HashSet` are values over the content-addressed heap:
`HashMap.set` and `HashSet.add` return a new collection and leave the one they
were given as it was, two equal collections are the same handle, and nothing
is ever written in place on their nodes. There is no ceiling on how many
exist. A key is identified by what it is: a scalar by its bits, a `Text` by
its content-addressed handle, so two texts with the same characters are one
key however they were built. `Vec` (its own section below) and
`XSet` change in place.

A `Sequence<T>` is finite and pure: built from a list (`Sequence.from_list`,
`Sequence.range`), it chains `map`, `filter` and `fold`, fused into one loop
when emitted, so their combinators **require inline lambdas** (the body must
be visible). It is a place, `Sequence` with a capital: the lowercase
`sequence` is the keyword of `in sequence over`. A `Stream<T>` is infinite
and pure, an unfold (`Stream.iterate`, read with `take`):

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be l := List.cons(1, List.cons(2, List.cons(3, List.empty(0))))
  be s := Sequence.from_list(l).map(fun(x) => x * 2).fold(0, fun(a, b) => a + b)
  return s + 30                    // 12 + 30 = 42
}
```

## System: files, environment, arguments

<!-- yon-gate: illustrative -->
```yon
be _w := File.write_text("/tmp/out.txt", "ciao")
be readback := File.read_text("/tmp/out.txt")
be home := Env.get("HOME")
be n := Args.count(0)
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
  be m := HashMap.empty()
  be m2 := HashMap.set(m, 1, 10)
  be ten := match HashMap.get(m2, 1) { Found(v) => v, Absent => 0 }
  be g := Math.gcd(12, 18)                    // 6
  be b := Bits.band(12, 10)                    // 8
  be vl := VoyagerList.empty()
  be vl2 := VoyagerList.append(vl, 18)        // Golay-sealed storage
  be readback := VoyagerList.get(vl2, 0)
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
  be a := Vec.push(Vec.push(Vec.push(Vec.empty(), 10), 20), 30)
  be b := Vec.push(Vec.push(a, 40), 50)       // grows past the initial cap of 4
  be c := Vec.set(b, 0, 7)                     // in-place; c is b
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
carrier functor's recursion, not a way around it. Most of the rest is ordinary
Yon: `Number.gcd` is written with Euclid's algorithm, `String.reverse`
character by character. Where the platform already has the function, the
place declares it `is given` instead of writing a second one: `Number.floor`,
`Number.exp`, `Number.sin`, `Number.cos` are the libm functions `Math.*`
names, and `Number.sqrt`, `Number.ln` are libm's on their domain, with a
`DomainError` outside it.

<!-- yon-gate: exit 32 -->
```yon
place Entry {
  fun main(): Number {
    be g := Number.gcd(12, 8)      // 4
    be m := Number.max(3, 7)       // 7
    be f := Number.floor(21.9)     // 21
    return g + m + f
  }
}
```

**Precision is a world, not a type parameter.** `Int64` lives in the world
`Num64`, `Int32` in `Num32` — two distinct categories, so `Widen` between them
is a genuine functor rather than an arrow between two objects of one site. The
bare names in your code mean the 64-bit site, which is the language default.
`Int64` is the ring ℤ/2⁶⁴ at runtime, as the checker proves its laws: its
values are 64-bit integers from end to end, `+`, `-` and `*` wrap modulo 2⁶⁴
(`Int64.max_value() + 1` is `Int64.min_value()`), `/` and `%` truncate, so
`Int64.div(7, 2)` is 3. An integer literal written at an `Int64` is the exact
integer its digits name, past 2⁵³ too (`9007199254740993` stays odd), and
`Int64.to_text` writes the exact digits of any value. An `Int64` is not a
`Number`: no conversion between them is implicit. Where a value travels in a uniform 64-bit slot (a list, a
closure, a coproduct payload, the wire), an `Int64` crosses as its bits and
comes back the same integer.

**Partial functions declare how they fail.** `sqrt` of a negative, `ln` of a
non-positive, division by zero: each is dressed with `on error DomainError`,
and the caller handles the failure by matching on the arms of the coproduct.

<!-- yon-gate: exit 37 -->
```yon
place Entry {
  fun main(): Number {
    be g := Int64.gcd(12, 8)                   // 4
    be d := Int64.div(7, 2)                    // 3, or a DomainError
    be bc := Int64.bit_count(7)                // 3
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
are the whole of it; the other twelve functions are derived above them, in
Yon.
