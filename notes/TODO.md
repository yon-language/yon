# Yon — TODO / Roadmap

Working notes on what is planned, grouped by area. Status reflects the current
tree: the compiler pipeline is OCaml frontend → MLIR `topos` dialect → LLVM →
native, with a content-addressed C runtime (xleech2). Regression baseline: 62
in-process examples + the cross-Space suite, all green.

## In progress

- **`spawn { }` MLIR lowering (step 4b)** — wire the language construct to the
  runtime collection primitive (`yon_rt_spawn_open` / `promote` / `child_exit` /
  `join_collect` / `close`). Steps 1–4a are done (tokens, AST/grammar,
  `spawn_index` scoping, runtime primitive fork-tested with zero deadlock / data
  loss); 4b is designed on paper, not yet implemented.
- **Container verification** of the `YON_SATLIB_DIR` `getenv` change in
  `runtime/yon_rt.c` (committed, not yet verified end to end in the container).

## Collections

- **Vec** — dynamic array, mutable in-place on an arena strip. *Done.*
- **IndexedHeapMap** (FxIndexMap) — insertion-ordered, content-addressed key
  interning, Fibonacci open-addressing. *Done.*
- **MemoTable** — memoization cache on the same Fx machinery. *Done.*
- **Deque** — ring buffer on an arena strip. *Done.*
- **PriorityQueue** — binary min-heap on an arena strip. *Done.*
- **FrozenMap** / **FrozenTrie** — frozen/perfect variants, FKS two-level
  perfect hashing, built from an IndexedHeapMap, all on arena strips.
- **Orbit-equivariant encoding → Orbit\* collections** (OrbitVoyager / OrbitMap /
  OrbitSet / OrbitTree) over the Arena's real Co₀/M₂₄ orbits. The encoding
  (key → Leech xcoord, Co₀/M₂₄-equivariant) is the research prerequisite.
- *Dropped:* Vec v2 trie — superseded, the in-place mutable Vec already gives
  amortized O(1) push; a persistent trie is unnecessary unless an immutable
  Vec is wanted.
- *Deferred:* BTreeMap — a key-ordered map is only needed for range queries;
  MerkleTree (content-addressed hash tree) does not cover that case but no
  range-query use has come up. Revisit if it does.

## Language / compiler

- **`while` and `iter N do { }` MLIR lowering** — syntax stubs complete, lowering
  pending.
- **CDT roadmap** (10 steps): terminal/initial object → factorizer → CDT
  declaration syntax → product/coproduct → exponential → CPL element → reduction
  to canonical → generic object → polynomial extension → fibration as an MLIR
  type.
- **LLVM lowering** (#78–80).
- **`yonc` toolchain** (#81).
- **Hermeticity** (#81b).
- **P8–P12**: runtime, tooling, stdlib, verification, ecosystem.

## Docs / showpieces

- Rewrite the removed chapter-19 showpieces once the capabilities they exercised
  are re-wired.

## Research

- **SCT paper (Zenodo)** — §34.6.5 scoped to the Counting Theorem only:
  `|R_orb| ≤ C(n+3,3) = O(n³)`. Core reframe: a problem faithfully mapped onto a
  commutative algebra with a finite domain (`|S| < ∞`) is found in
  `O(|R| × G)`. The relevant APIs are `OrMonoid.*`.
- **Physics research** (arithmetic gas, prime modes, RH spectra) — timestamped on
  Zenodo for priority.
- **Open research program**: conjectures C1–C13.

## Collaboration

- **Agda proofs with Tom** on `cubical.ml`.
- **Open question — Ł₃ placement**: whether Łukasiewicz three-valued logic (an
  MV-algebra) *replaces* the Heyting Ω rather than sitting as a separate MV layer
  beside it. Current leaning is toward replacement; not yet decided.

## Principles (kept, not negotiable)

- Honest technical representation over narrative — claims match what compiles and
  runs.
- Every additive step is verified against the regression baseline before the
  next one.
- One clean change at a time.
- Design on paper before foundational code; declare limits up front; never invent
  an answer the compiler or a test has not confirmed.
