# The linear map — grade vs clade on the Leech lattice

*Result of the 2026-06-27 investigation. Saved because it changes what the
classification chapter (2.3) is allowed to claim.*

## The question

When you place a character vector on the Leech lattice and read its orbit (or the
`of2` relation class of a pair), are you reading the **clade** (who is related to
whom — *which* characters are shared) or merely the **grade** (how advanced — *how
many* derived characters)? Grade looks like phylogeny only on a clean monotone
lineage; it is the pre-cladistic mistake the moment there is branching, convergence
or loss.

## The finding: mode 0 reads the grade (proven)

The first embedding, `Leech.embed(v, 0)` (the "duplicate" mode: each bit → a pair
of ±1 coordinates, then quantize to the nearest type-2 point), **collapses to the
popcount**. Gated, not assumed — `regression/book/jp/probe_linear_clade`:

> six vectors of the SAME popcount (2) but different bit-patterns
> (`3, 5, 17, 2049, 96, 2560`) → `m24_orbit(embed(v,0))` = **`1, 1, 1, 1, 1, 1`**.

Six different patterns, one orbit. The orbit saw only the count. On the 48-taxon
data `taxa_full.json` the orbit is a strict function of popcount, with the one
same-popcount-different-pattern case (2047 vs 3071) collapsing to the same family.
The "tree" was a **grade ladder dressed as a clade tree** — true on a monotone
lineage because there grade = position = clade, false in general.

## The diagnosis: non-linearity

`of2(a,b)` is the leech2 subtype of `a XOR b`, and `a XOR b` between two character
vectors is exactly **which characters differ** (the symmetric difference, the
cladistic distance). So `of2` *can* read "which", on one condition:

> `embed(v) XOR embed(w) = embed(v XOR w)` — i.e. the embedding is **linear** over
> GF(2).

Mode 0 and the quantizer are **non-linear**, so the structural XOR is destroyed in
the embedding and only the count survives. The disease has one name: non-linearity.

## The cure: a linear embedding + the raw subtype

Two additions (runtime `runtime/yon_rt.c`, frontend exposed like the other
`Leech.*`):

- **`Leech.embed(v, 3)`** — the **linear gcode embedding**: put the 12 character
  bits straight into the leech2 gcode field, `v << 12`, with **no quantizer**.
  Linear, so `embed(v) XOR embed(w) = (v XOR w) << 12`.
- **`Leech.pair_subtype(a, b)`** — the **raw** leech2 subtype of `a XOR b`, WITHOUT
  the type-2 gate that `of2` imposes (`of2` returns −1 unless both points are
  type-2; the linear points are not generally type-2). Defined for every pair.

Gated, `regression/book/jp/probe_linear_clade`:

> the SAME six patterns → `pair_subtype(embed(3,3), embed(v,3))` =
> **`0, 34, 70, 34, 68, 70`** — four distinct classes where mode 0 gave one.

The linear map separates patterns the grade collapsed.

## What it reads (precisely, with the boundary)

- **It is a pure function of `v XOR w`.** Proven: `(3,5)` and `(1,7)` both have
  `v XOR w = 6` → both `pair_subtype = 34`. It depends on which characters differ,
  not on the specific vectors.
- **It is not the Hamming distance either.** `v XOR w = 6` (bits 1,2) → 34, but
  `v XOR w = 18` (bits 1,4) → 70: two differences of the **same size** (Hamming 2),
  different classes. So it reads *which* bits, not *how many*. This is the clade
  direction.
- **Its resolution is the Golay class of the difference.** The subtype byte depends
  on the weight class of the Golay codeword of `v XOR w`, ~4 realized values
  (`0x00, 0x22, 0x44, 0x46`). So `v XOR w = 6` and `v XOR w = 2050` both → 34: finer
  than Hamming, **coarser** than the exact pattern. Injecting the cocode as well is
  the next rung if more resolution is needed.

## Consequences for the chapter

- The **orbit / XTower tree** (mode 0) reads the **grade**. The old caption "the
  orbit reads structure, not bit-equality" is wrong in the way that matters — it
  reads the count. To be rewritten: *grade, a count, not a homology.*
- The **relation matrix and the real tree** should be built on the **linear map**
  (`pair_subtype`), which reads which-characters — the clade direction. The tree
  comes from clustering the `pair_subtype` matrix, not from the 12-class M24 orbit.
- **`omega` / `triangle`** need type-2 points (scalar products); the linear points
  are not type-2, so the Co0-invariant lesson stays on type-2 points — it is a
  property of the lattice geometry, shown on valid points, separate from the taxa
  classification.
- **The honest ceiling**, unchanged: even the linear map reads the *unweighted
  symmetric difference of character sets at Golay resolution*, not weighted
  phylogenetics. Clade-direction, not peer-reviewed cladistics; the vectors stay
  illustrative.

## Anchors

- runtime: `yon_rt_leech_embed_bits` mode 3, `yon_rt_leech_pair_subtype` (`yon_rt.c`).
- gate: `regression/book/jp/probe_linear_clade` (the numbers above, native-gated).
- the grade proof: `regression/book/jp/probe_embed_maps`, `taxa_full.json`.
