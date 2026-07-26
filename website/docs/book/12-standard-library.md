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
it heal). And `Magma` (with `verify P`, chapter 6) turns a law-verified place
into a runnable algebraic structure: closure, reachability with certificates,
and normal forms.
