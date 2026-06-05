---
id: standard-library
title: "10. A tour of the standard library"
sidebar_position: 10
---

# A tour of the standard library

The stdlib is organized in modules; the full index is in the
[Syntax Reference](../syntax-reference.md). A few highlights, all running
code.

## Collections and streams

`List`, `Map`, `Set`, `HashSet`, `XSet` are immutable collections over the
content-addressed heap. Streams chain with methods — and their combinators
**require inline lambdas** (the fusion happens at emission, so the body must
be visible):

```yon
fun main(): number {
  be l holds List.cons(1, List.cons(2, List.cons(3, List.empty(0))))
  be s holds Seq.from_list(l).map(fun(x) => x * 2).fold(0, fun(a, b) => a + b)
  return s + 30                    // 12 + 30 = 42
}
```

## System: files, environment, arguments

```yon
be _w holds File.write_text("/tmp/out.txt", "ciao")
be back holds File.read_text("/tmp/out.txt")
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

```yon
fun main(): number {
  be m holds HashMap.empty()
  be m2 holds HashMap.set(m, 1, 10)
  be ten holds HashMap.get(m2, 1)
  be g holds Math.gcd(12, 18)                    // 6
  be b holds Bits.band(12, 10)                    // 8
  be vl holds VoyagerList.empty()
  be vl2 holds VoyagerList.append(vl, 18)        // Golay-sealed storage
  be back holds VoyagerList.get(vl2, 0)
  return ten + g + b + back                      // 10+6+8+18 = 42
}
```

## The exotic corner

Three modules are distinctly Yon. `Merkle` builds content-addressed Merkle
trees. `VoyagerList`, above, is a Golay-sealed list — error-correcting
storage, à la Voyager probe (`corrupt_at` exists precisely so you can watch
it heal). And `Magma` (with `solve P`, chapter 5) turns a law-verified place
into a runnable algebraic structure: closure, reachability with certificates,
normal forms, subset-sum and knapsack as algebraic queries over the
Leech-lattice runtime.
