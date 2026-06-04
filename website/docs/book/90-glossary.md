---
id: glossary
title: "Appendix A. Glossary"
sidebar_position: 90
---

# Appendix A — Glossary

One sentence each. Left: the word; right: what it means *in Yon*, with the
mathematical reading in parentheses.

**world** — a semantic context that places live in; worlds compose by
product, coproduct, quotient and sub-world (a category, used as a site).

**place** — a pure structure declared in a world: fields, optionally
operations and laws; it has no methods and no hidden state (an object of
the category).

**section** — a value of a place, immutable and identified by its content
(a generalized element; a section of the corresponding sheaf).

**handle** — the `f64` a variable actually holds for any heap value: the
slot index of its content in the content-addressed heap.

**cell** — the one thing in Yon with identity instead of content: a mutable
register whose current value is a handle; `becomes` is sugar over cells.

**arrow** — anything that maps; every arrow has a kind, and the kinds live
at different levels (see chapter 6's ladder).

**move** — an arrow between places that transports sections, mapping fields
clause by clause (a morphism of objects; the only border crossing).

**view** — a read-only arrow out of a place (an observation; part of the
place's presheaf).

**reduction** — an interpretation of a place's operations into a value,
activated as a handler with `with R of P` (an algebra / eliminator; an
algebraic-effects handler).

**functor / morph** — an arrow between worlds, translating objects and
operations together, with checkable laws (a functor between categories).

**nat_transform** — a family of arrows relating two functors, one component
per object (a natural transformation; a 2-cell).

**geomorph** — a pull/push pair between places-as-sites (a geometric
morphism: the adjunction `f* ⊣ f∗`).

**monomorphism (mono)** — an arrow that loses nothing; all Yon subtyping is
travel along a mono: `extends` declares one, comprehension's coercion is
one, `boolean → proposition` is one.

**subobject** — a part of an object carved out by a property; in Yon, a
comprehension type `{x : A where P}` or a `place ... extends` declaration.

**Ω (the classifier)** — the type of truth values; in Yon a Heyting algebra
with `present`, `absent`, `unknown` (the subobject classifier of a topos —
truth values = subobjects).

**prop** — a map into Ω declared in a `topos` block (a characteristic
function of a subobject).

**comprehension** — the type `{x : A where P}`: the subobject of `A` whose
fibre is `P`; usable as an `A` via the forgetful mono.

**Heyting algebra** — intuitionistic truth: conjunction, disjunction and
implication without excluded middle, which is what lets `unknown` be a
citizen.

**topology (Lawvere–Tierney)** — an operator `j : Ω → Ω` declared on a
place; the seed of sheaf semantics (a modal "locally true").

**Yoneda principle** — a thing is what you can observe of it; in Yon: a
place's interface is its bundle of arrows, and content addressing makes
indiscernibles literally identical (the Yoneda lemma, used as a design
axiom).

**Space** — a hermetic tenant: a named heap plus, across packages, a
process; content crosses only through moves and the numeric wire.

**content addressing** — the allocator's contract: the address of a value
is determined by its bytes, so same content is the same slot and equality
is one comparison.

**Leech lattice (Λ₂₄)** — the 24-dimensional lattice whose geometry sizes
the heap (196,560 slots — its kissing number) and whose symmetries drive
orbit canonicalization.

**Co₀ / M₂₄ orbit** — an equivalence class of contents under the lattice's
symmetry group; the orbital collections store one representative per orbit.

**Golay code (24,12,8)** — the error-correcting code sealing every
`VoyagerList` element: 12 data bits in a 24-bit word, healing up to 3
flips.

**law** — an algebraic property declared on a place's operation and
*verified* at compile time by MagmaSolve; a false law does not compile.

**solve** — the keyword that hands you a law-verified place as a runnable
algebraic structure (a Magma with closure, reachability, certificates).

**effect / visits** — what a function touches, written in its signature and
checked transitively by the compiler (algebraic effects discipline).

**hermeticity** — the guarantee that nothing crosses a boundary except
what is declared: typed inside a binary, process isolation between
binaries.

**epoch** — a channel's incarnation counter; advancing it on recovery makes
stale peers harmless.
