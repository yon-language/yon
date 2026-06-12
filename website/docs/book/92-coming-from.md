---
id: coming-from
title: "Appendix C. Yon, for those coming from elsewhere"
sidebar_position: 92
---

# Appendix C, Yon, for those coming from elsewhere

Calibrated comparisons. Where a rival is more mature, this page says so.

**From Unison.** Unison content-addresses *code*, definitions are hashes,
renames are free. Yon content-addresses *runtime values*: allocation
itself deduplicates, and deep equality is one comparison (chapter 11).
The ideas rhyme; the object differs. Unison's codebase manager has no Yon
equivalent; Yon's O(1) value equality has no Unison equivalent.

**From Erlang/Elixir.** Erlang is the gold standard of process isolation,
and its messaging (arbitrary terms, distribution across machines,
supervision trees) is far richer than Yon's numeric wire. Yon's trade is
deliberate: kernel processes instead of a VM, a wire the **type checker**
polices (a string in a cross-Space signature does not compile), and
handles that are *meaningless* in the wrong process rather than merely
forbidden. Choose Erlang for distributed systems today; Yon's bet is that
a narrower door makes a stronger wall.

**From Haskell.** Typeclass laws in Haskell are documentation; Yon's
`law` declarations are *checked*, AlgebraVerifier rejects a false
`commutative` at compile time (chapter 5). The price: a closed catalog of
algebras, not arbitrary laws. Where Haskell says "trust the instance",
Yon says "prove it or don't claim it", for the algebras it knows.

**From Lean/Idris/Agda.** Proof assistants verify arbitrary laws, with
your labor. Yon sits at a different point: automatic, bounded
verification, plus something proof assistants don't do: `verify` hands the
verified structure back as a *runnable* object with reachability
certificates (chapter 18). Yon's HoTT layer (chapter 8) is a fragment of
theirs; its topos vocabulary as compiled syntax has no equivalent there.

**From Rust.** Rust earns memory safety through ownership and lifetimes, 
analysis of *who may touch what when*. Yon dissolves the question instead
of answering it: values are immutable content with no identity, so there
is nothing to race on and nothing to alias; the one identity (cells) is
explicit and process-local. Rust's model costs annotations and buys
zero-overhead mutation; Yon's costs mutation-by-default and buys a model
with no aliasing to reason about. Rust's ecosystem and performance story
are vastly more mature; that is not in dispute.

**What has no counterpart anywhere**, stated once and narrowly:
allocation-as-deduplication with O(1) deep equality as a language
guarantee; orbit-canonical collections (equality up to a symmetry group as
storage semantics); `verify` returning verified algebras as runnable
objects; trit-valued integers with per-bit certainty; error-correcting
storage in the standard library; topos constructs as compiled primitives
rather than library encodings.
