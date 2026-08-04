---
id: topos-oriented-programming
title: "0. Topos-Oriented Programming"
sidebar_position: 0
slug: /book/topos-oriented-programming
description: "What topos-oriented programming means in Yon: subobject classifier, comprehension types, functors with checked laws, and an intuitionistic core, compiled to native code."
---

# Topos-Oriented Programming

Yon is built on one wager: that the right organizing notion for programs is
not the *object* of OOP, nor the *function* of FP, but the **site**, a
category equipped with a notion of locality, the home of topos theory. We
call the resulting paradigm **Topos-Oriented Programming** (TOP). This
chapter says what that means in practice, before the rest of the book shows
it construct by construct.

## The shift

In OOP an object is a box of mutable state with methods attached; identity
is primary, content is incidental. TOP inverts this completely:

- A **world** is a category, a semantic context, not a namespace. Worlds
  compose the way categories do (products, coproducts, quotients,
  sub-objects), but that composition is mathematics, not a surface dialect:
  you declare worlds in `yon.toml` and act between them with arrows, never
  with a world-algebra written by hand (chapter 6).
- A **place** is an object *in* a world. It has no methods and no hidden
  state; it is pure structure.
- A value is a **section** of a place, immutable content, identified by
  that content (chapter 14).
- All behaviour lives in **arrows**: moves, views, reductions, morphisms
  between worlds (chapter 7). Nothing "happens to" a value; arrows take you
  from one value to another.
- **Identity is the exception**, not the rule: it exists only where you ask
  for it (a Space cell, chapter 14), never by default.
- Even **logic is internal**: truth is the subobject classifier Ω, a `prop`
  is a map into it, and the logic you get is the Heyting algebra of the
  topos (chapter 8), `unknown` is a citizen, not an error.

## The Yoneda principle

Yon's design manifesto is *Yoneda-grounded* (the project's coherence
document is literally titled "Yoneda-∞-ω"). The Yoneda lemma says an object
is completely determined by its relationships, by the maps into it. As a
design principle, this becomes: **a thing is what you can observe of it**.

Three places where this is load-bearing in the implementation, not just
philosophy:

1. **Functorial operations** (chapter 6) are lifted along world morphisms,
   the operation travels with the object's *relations*, not with a pinned
   implementation. The compiler's world-inference and effect-propagation
   rules are written and audited as "Yoneda-coherent": if `f` calls `g` and
   `g` visits a world, `f` transitively does.
2. **There are no typeclasses.** Where Haskell would attach an instance,
   Yon attaches arrows: a place's interface *is* the bundle of moves, views
   and reductions defined on it, its presheaf of observations.
3. **Content addressing is extensionality made physical** (chapter 13):
   two values indistinguishable by observation are not only equal, they
   are *the same slot*. When `String.equal` compares two handles it is
   checking Yoneda-style indiscernibility in O(1):

<!-- yon-gate: exit 42 -->
```yon
fun main(): Number {
  be a holds "ab"
  be b holds String.concat("a", "b")   // built by a different route
  be same holds String.equal(a, b)     // same content, same slot
  return if same then 42 else 0
}
```

The first two are mathematics carried into the type checker; the third is
the same idea carried into the allocator. (We flag the distinction
deliberately: where this book leans on an analogy rather than a theorem, it
says so.)

## What the compiler does with it

The categorical structure is not decoration, the optimizer consumes it.
The `structural-value-numbering` pass performs a *structure-guided* global value
numbering: pure operations with the same structural fingerprint share one
computation, so three syntactic copies of `(3 + 4) * 2` in the source
become one computation in the IR, collapse by structure, before any
classical optimization runs. The same philosophy returns at every level:
**Co₀-orbit canonicalization** collapses heap contents equivalent under the
Leech-lattice symmetries (chapter 15), η/unit rules collapse trivial
coherence cells, and verified laws (chapter 6) license algebraic rewrites
that an unverified `add` could never justify.

That is the thesis of Topos-Oriented Programming in one line: **declare the
structure honestly, and the structure does work for you**, in the type
checker, in the optimizer, in the allocator, at runtime.
