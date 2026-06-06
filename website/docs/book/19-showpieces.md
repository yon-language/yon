---
id: showpieces
title: "19. Showpieces"
sidebar_position: 19
---

# Showpieces

Three short programs that do things you cannot write this way anywhere
else. Each is the capability of an earlier chapter, pushed until it shows.

## Optimization as algebra

`solve` and the Magma machinery (chapter 5) make combinatorial questions
*queries on a verified structure*. Knapsack: each `knap_item(weight, value)`
extends the algebra; `knapsack_mask(capacity)` returns the **certificate**
, the bitmask of chosen items, not just the optimum:

```yon
fun main(): number {
  be c0 holds Magma.from_catalog(0)
  be c1 holds Magma.knap_item(c0, 2, 6)
  be c2 holds Magma.knap_item(c1, 5, 10)
  be c3 holds Magma.knap_item(c2, 4, 5)
  be c4 holds Magma.knap_item(c3, 7, 14)
  be c5 holds Magma.knap_item(c4, 3, 4)
  be org holds Magma.knap_item(c5, 6, 9)
  return Magma.knapsack_mask(org, 12)
}
```

Exit code **10** = binary `1010` = items 1 and 3 (weights 5+7=12, values
10+14=24): the optimal selection, as a number.

Subset-sum reads the same way, generators in, certificate out. Seven
peptide fragments, target mass 298:

```yon
fun main(): number {
  be p0 holds Magma.from_catalog(0)
  be p1 holds Magma.gen(p0, 57)
  be p2 holds Magma.gen(p1, 71)
  be p3 holds Magma.gen(p2, 87)
  be p4 holds Magma.gen(p3, 99)
  be p5 holds Magma.gen(p4, 113)
  be p6 holds Magma.gen(p5, 128)
  be m  holds Magma.gen(p6, 147)
  return Magma.subsetsum_mask(m, 298)
}
```

Exit **49** = `0110001`: fragments 0, 4 and 5 (57+113+128 = 298), the
*first* certificate the engine reaches; any returned mask is a checked
witness, and 0 means "no subset exists", which is a proof of absence over
the generated closure.

## Equality up to symmetry

Chapter 11's orbit canonicalization, observable in four lines: two keys
with **different bytes** but the same Golay orbit. A plain map sees two
keys; the orbital map sees one:

```yon
fun main(): number {
  /* Ten distinct byte-level keys: five base keys, then the same five
   * XOR 65535, different bytes, SAME Golay orbit. */
  be m holds HashMap.empty()
  be m1 holds HashMap.set(m, 5263441, 1)
  be m2 holds HashMap.set(m1, 5287854, 2)        // m1's key XOR 65535
  be plain holds HashMap.size(m2)                // 2: bytes differ

  be o holds HashMap.empty()
  be o1 holds HashMap.orbital_set(o, 5263441, 1)
  be o2 holds HashMap.orbital_set(o1, 5287854, 2) // same orbit: one entry
  be orbital holds HashMap.size(o2)               // 1: orbits collapse

  return plain * 20 + orbital + 1                 // 2*20 + 1 + 1 = 42
}
```

"The same up to symmetry" is not a comparison you run; it is where the
data *lives*. No other language ships this as a collection semantics.
