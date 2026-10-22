---
id: glossary
title: "Appendix A. Glossary"
sidebar_position: 90
---

# Appendix A, Glossary

One sentence each. Left: the word; right: what it means *in Yon*, with the
mathematical reading in parentheses.

**world**, a semantic context that places live in, declared in `yon.toml`
as `[world.Name]`; worlds compose the way categories do (products,
coproducts, quotients, sub-objects), but Yon gives you no world-algebra to
write a composite world by hand, you act on worlds only through arrows (a
category, used as a site).

**place**, an object written one per file inside a Space directory (the
filename is the place name): fields, optionally operations and laws, and the
arrows declared in it; it has no hidden state, and its space is the directory
it lives in (an object of the category).

**section**, a value of a place, immutable and identified by its content
(a generalized element; a section of the corresponding sheaf).

**handle**, the `f64` a variable actually holds for any heap value: the
slot index of its content in the content-addressed heap.

**cell**, the one thing in Yon with identity instead of content: a mutable
register whose current value is a handle; the assignment `x = e` is sugar
over cells.

**arrow**, anything that maps; every arrow has a kind, and the kinds live
at different levels (see chapter 6's ladder).

**move**, an arrow between places that transports sections, mapping fields
clause by clause (a morphism of objects); it may declare `requires CAP`,
a capability that is not yet enforced (chapter 20).

**view**, a read-only arrow out of a place (an observation; part of the
place's presheaf).

**reduction**, an interpretation of a place's operations into a value: its
`on` clauses interpret them, and the inline form is `reduction(..) => e of P`
(an algebra / eliminator; an algebraic-effects handler).

**functor / morph**, an arrow between worlds, translating objects and
operations together, with checkable laws (a functor between categories).

**nat transform**, a family of arrows relating two functors, one component
per object (a natural transformation; a 2-cell).

**geomorph**, a pull/push pair between two sites (in the restaurant, the
`sala` and `cucina` spaces): a geometric morphism, the adjoint pair
`f* ⊣ f∗` (`pull` ⊣ `push`).

**monomorphism (mono)**, an arrow that loses nothing; all Yon subtyping is
travel along a mono: `this <` declares one, comprehension's coercion is
one, `Boolean → Ω` is one.

**subobject**, a part of an object carved out by a property; in Yon, a
comprehension type `{x : A where P}` or the body clause `this < B`.

**Ω (the classifier)**, the type of truth values; in Yon a Heyting algebra
with `present`, `absent`, `unknown` (the subobject classifier of a topos, 
truth values = subobjects).

**prop**, a map into Ω declared in a `topos` block (a characteristic
function of a subobject).

**comprehension**, the type `{x : A where P}`: the subobject of `A` whose
fibre is `P`; usable as an `A` via the forgetful mono.

**Heyting algebra**, intuitionistic truth: conjunction, disjunction and
implication without excluded middle, which is what lets `unknown` be a
citizen.

**topology (Lawvere–Tierney)**, an operator `j : Ω → Ω`, the seed of sheaf
semantics (a modal "locally true"). Yon has no declaration for it (chapter 8).

**Yoneda principle**, a thing is what you can observe of it; in Yon: a
place's interface is its bundle of arrows, and content addressing makes
indiscernibles literally identical (the Yoneda lemma, used as a design
axiom).

**Space**, a hermetic tenant: a directory under the project root, backed at
runtime by its own two heaps (FNV and Leech), freed whole as one region, and,
across packages, its own process; content
crosses through moves, numeric cross-Space calls, and copies on a `Wire<T>`;
only a mobile value crosses (a closure, a cell or a region handle never does).

**content addressing**, the FNV heap's contract: the address of a value
is determined by its bytes, so same content is the same slot and equality
is one comparison.

**FNV heap**, the heap of general values (xleech2): identity by content, an
FNV-1a hash confirmed by a byte comparison; slots allocated in sequence,
196,560 per heap, then a chain.

**Leech heap**, the heap whose places are lattice points: identity by the
point, through a bijection with the 196,560 type-2 vectors, generation after
generation. `LatticePoint`, the nodes of `XRelMap`/`XRelSet` (node k in the
place (k div 196,560, `at_index(k mod 196,560)`), written once) and the X*
tables live here; orbits and canonical forms too.

**Leech lattice (Λ₂₄)**, the 24-dimensional lattice whose 196,560 minimal
vectors are the addresses of the Leech heap and the size of one FNV heap,
and whose symmetries drive orbit canonicalization in the Leech heap.

**Co₀ / M₂₄ orbit**, an equivalence class of contents under the lattice's
symmetry group; `LatticePoint.orbit` returns the orbit of a point, and two
points are equivalent when their orbits are equal.

**frame (`XRelFrame`)**, a partition of the 196,560 points of the shell, a
quotient, represented by its canonical projection `canon` (a point to the
least-index representative of its class, so `canon ∘ canon = canon`).
`discrete` is the finest (the identity), `whole` the coarsest, `refine`
splits by the type against a reference, `curtis` is the 26-octad frame. A
frame made from references never parts `v` from `-v` (chapter 15).

**Golay code (24,12,8)**, the error-correcting code sealing every
`VoyagerList` element: 12 data bits in a 24-bit word, healing up to 3
flips.

**law**, an algebraic property declared on a place's operation and
*verified* at compile time by AlgebraVerifier; a false law does not compile.
The verification follows from `uses algebra` (the former `verify` keyword is
retired).

**effect / visits**, what a function touches, written in its signature and
checked transitively by the compiler (algebraic effects discipline).

**hermeticity**, the guarantee that nothing crosses a boundary except
what is declared: typed inside a binary, process isolation between
binaries.

**epoch**, a channel's incarnation counter; advancing it on recovery makes
stale peers harmless.
