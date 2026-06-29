# Inspiration list — constructs → claims (author's source material)

> Supplied by the author (2026-06-26) as the conceptual backbone of the JP book.
> These are **claims to be verified**, not yet code-sourced verdicts. The
> construct-inventory pass attaches a ✓verified / declared / debt verdict (with
> `file:line` anchor) to each row — see `01-jp-structure.md` once built.
> Ordering runs top → bottom of the dependency graph: Yoneda (the idea) at the top,
> silicon at the bottom. Every construct must be covered in the book **and combined
> with the others in the story**, not only in isolation.

## The feature → claim table

| # | Feature (what it does) | Claim (what it asserts) |
|---|---|---|
| 1 | `place` as a presheaf `Site→Type` | An object has no hidden essence: it *is* its observation profile. Yoneda taken as ontology, not as a lemma. |
| 2 | content-addressing (FNV + byte-compare) | Identity is extensional: two things with the same content are the same thing. Leibniz made silicon — identity of indiscernibles. |
| 3 | `Space` cell (the location) | Individuality is not in the content but in the *where*. Two identical T-Rex are one fossil and two positions: extension ≠ location. |
| 4 | carrier as partial functor, `NoCarrier` | The object precedes the machine. Where an object has no runtime value, the realization does not exist and is refused — not invented. Mathematics comes first. |
| 5 | Heyting Ω (Gödel G3), `=>?` `!?` | Truth is not binary. "Not yet proven" (½) is a legitimate position; denying ignorance produces no knowledge. Intuitionism as the language's epistemology. |
| 6 | `Id`, `refl`, `PathP` | Equality has a geometry: two equal things are joined by a path, not a yes/no. Equality is a space of proofs. |
| 7 | `J` / `ind_path`, β on `refl` | To prove something for all paths it suffices to prove it on the trivial path. Identity is governed by its diagonal case. |
| 8 | `Glue` / `ua` (univalence) | Equivalent types are the same type. Isomorphism is identity — to see an isomorphism is to see an equality. |
| 9 | HIT (S¹, `base`, `loop`) | One can build spaces whose equality is not runtime-decidable — the circle has a non-trivial path no byte-compare sees. Form precedes computation. |
| 10 | η_Σ (surjective pairing) | The mediator of a product is unique, not merely existent. Yon's products are products in the strict categorical sense. |
| 11 | stratified universes, `Type_0 ≠ Type_5` | Concept and instance live on different planes and do not mix. The barrier that stops Girard's paradox at the root. |
| 12 | `world` (`*`, `+`, `/∼`, `subset of`) | Spaces compose as objects of a category: product, coproduct, quotient, subobject. Combining worlds is categorical algebra. |
| 13 | sheafification / descent reject | A whole is determined by its coherent local parts. If the gluing violates the equivalence, the whole does not exist — this is what distinguishes a sheaf from a presheaf, a topos from a collection. |
| 14 | `geom_morphism`, pull/push, f*⊣f∗ | One can transport an entire structure from one world to another, translating its laws. The geometric morphism is the adjunction that preserves logic. |
| 15 | `morph on morphism` | Not only the things, but the behaviour of what governs the things. Arrows have arrows; diagram coherence is enforced, not hoped. |
| 16 | directional subtyping `number <: heyt_int <: prop` | Value flow has a direction. Evolution is not silently reversible. |
| 17 | `place P on error E`, monad `+E` | An error is a place, not a break. An anomaly generates an ecosystem where it lives and is handled — a destination in the type space. |
| 18 | closed arrows (move/functor/view), local capture = error | A behaviour is closed within its boundary. Nothing escapes scope to infect the global — isolation is a type law, not a convention. |
| 19 | compile-time reject, exit 3, "no fake green" | Everything is decided before the machine or refused. If it compiles it is proven; if it isn't provable, it goes silent. The proof is not deferred to runtime. |
| 20 | `type_erase` | Proofs evaporate. The witnesses that guaranteed safety do not survive emission: you pay correctness at compile time, zero runtime overhead. |
| 21 | Leech lattice, 196,560 type-2, X* on MPHF | Closeness between values is real geometric distance, in the densest known structure in 24 dimensions. Not an invented metric — geometry is the index. |
| 22 | Golay (24,12,8), VoyagerList | Data integrity is an algebraic property, not an added checksum. Recovering corrupted bits is decoding, not ad-hoc repair. |
| 23 | mmap as sole primitive, two allocators, no GC, `exit()` | Memory is deterministic by construction. It is not collected, it is terminated. The machine is predictable. |
| 24 | multi-process prefork, no threads | Isolation is ontological, not defensive: Spaces are separated by construction, in different processes. If one dies, the others don't know. |
| 25 | `wire` / DTO over SHM | Crossing a boundary is explicit and by value. Communicating between isolated spaces is a declared act, not implicit shared memory. |
| 26 | `Carrier.t` target-agnostic, emit = printer | Meaning is invariant w.r.t. implementation. The theory does not know whether it runs on MLIR, WASM or assembly: you change the printer, not the mathematics. |
| 27 | single kernel normalizer (Yoneda-principle in the design) | Where there is a choice, one canonical structure only — not parallel ad-hoc mechanisms. Elegance is anti-bug discipline, not aesthetics. |

## The three meditations (the conceptual heart — author, verbatim)

### Yoneda — "an object is what is observed of it"

The Yoneda lemma says, in essence: an object is completely determined by the arrows
that go into it (or out of it). There is nothing to an object beyond how the rest of
the category sees it. Formally, the object is naturally isomorphic to the functor of
its morphisms — A ≅ Hom(−, A). The object and "the complete profile of its
observations" are indistinguishable.

In Yon this is not a decorative citation: it is the ontology. A `place` is a
presheaf, `Site → Type` — that is, it *is*, by definition, the assignment of "what
is observed of it from every point of view". There is no hidden essence behind a
`place Dinosaur` that its observations approximate. The observations *are* the
dinosaur. When you declare `place Dinosaur { species, mass, paddock }`, you are not
describing an object that exists elsewhere — you are constituting the object through
its profile.

The point where this becomes vertiginous, and which in the book is the closing of
the arc: Yoneda sits at the top of the diagram (the most abstract idea) but touches
the bottom (the most concrete silicon). Because content-addressing — the lowest,
most hardware thing Yon does — is Yoneda executed.

### Content-addressing — "identity is what is observed, not a label"

A content-addressed system identifies a value by its content, not by an assigned
name or pointer. Hashing of content (FNV-1a 64-bit), and if two hashes coincide,
byte-compare for certainty. Same content → same slot. Two indistinguishable values
cannot have separate identities: the system dedups them into one.

This is the Yoneda lemma made silicon. Yoneda says "an object is its observation
profile"; content-addressing says "a value is its content, and nothing else". They
are the same statement at two different heights of the stack. When Yon hashes a
value and byte-compares it, it is executing, on RAM, the principle that at the top
of the theory is called Yoneda: there is no identity beyond the observable. The
label, the name, the pointer — the things that in OOP give an object identity
regardless of content — in Yon do not exist as sources of identity. Only content
exists.

And here is where Jurassic Park's fourth wall is born, the point the book must make
explode. In OOP, `new Dinosaur()` twice gives you two dinosaurs, even identical
ones, because identity comes from the fresh reference. Hammond counts this way: every
birth is an individual, the number goes up. But in Yon `new Dinosaur { ... }` with
the same content gives you the same slot — a shared fossil. Hammond, in Yon, would
count one where he believes he has two. And here lies the deep thing: is he right or
is Yon right? It depends on what identity is. If identity is the genome (the
content), two clones are the same dinosaur — Yon is right. If identity is "this
animal here, in this paddock" (the location), they are two — and Yon gives you that
with the `Space` cell. JP's drama is that InGen does not distinguish the two levels:
it counts locations believing it counts contents, or vice versa, and the system
collapses into the confusion. Yon forces you to say which identity you mean. This is
"I tried to engineer a park that works": Yon's park does not confuse extension and
location because the language does not allow it.

### Leech lattice — "closeness is real geometry, not an invented metric"

The Leech lattice, Λ₂₄, is the densest known sphere packing in 24 dimensions. Every
point has exactly 196,560 nearest neighbours at the same minimum distance — the
kissing number in 24D, an exact number, not approximated. It is an exceptional
mathematical structure: maximal symmetry (the Conway group Co₀ acts on it), tied to
the Golay code, the sporadic groups, the Monster. Not just any grid: it is the
optimal structure in that dimension.

In Yon, the X* structures (XSet, XRelMap...) are not indexed by arbitrary position
in an array. They are mapped onto the 196,560 type-2 vectors of the Leech lattice,
via a minimal perfect hash (MPHF), bijective — verified, 196,560 of 196,560, zero
collisions. This means the "position" of a value in the structure is a lattice
point, and the distance between two values is the geometric distance in the lattice.

Why it matters philosophically, and why it differs from content-addressing:
content-addressing answers "are they the same?" (identity). The lattice answers "how
close are they?" (proximity). And the answer is not a metric you invented for
convenience — it is real geometry, in the most symmetric and dense structure that
exists in 24 dimensions. When Yon says "these two values are close", it says it with
the weight of Co₀ and the kissing number behind it, not with an arbitrary
`distance()`. In the book, on the silicon plane: InGen's genetic classification of
the dinosaurs is tabular, fragile, arbitrary; Yon's is geometric, and the closeness
between two genomes is their distance on Λ₂₄.

### The thread that binds the three (the heart of the book)

Yoneda at the top and content-addressing at the bottom are the same statement —
identity is the observable, there is no behind. The Leech lattice adds the missing
dimension: not only *who you are* (identity, content-addressing) but *where you are
relative to others* (proximity, geometry). Together they answer the question that
makes Jurassic Park explode: what makes two dinosaurs the same, different, close,
far. Hammond could not answer and the park collapsed. Yon answers by construction —
and "I hope I got it right" is the honesty of one who tried to give that answer in
the type, not in the hope.

## Auditor note (author)

- 196,560 and Golay (24,12,8) are **verified** (`test_mphf`, `test_unit_voyagerlist`)
  — these can be stated with the head held high.
- The Co₀/Monster link is mathematically true [author's note continues — confirm the
  exact honesty boundary: the math is real, but the *book* must mark whether the code
  exercises it or only the MPHF/Golay tests do].
