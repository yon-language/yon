# Yon — research language and compiler

A research programming language built on topos theory, category theory, and
intuitionistic logic. Pipeline: OCaml frontend → custom MLIR "topos" dialect →
LLVM → native ELF/ARM64. Content-addressed runtime heap (xleech2).

## Data structures

- **Magma** — a finite commutative algebra: generators under a verified
  operation, with its closure, normal form, and certified laws.
- **Land** — the reachability view of a Magma: whether a target is reachable by
  composing distinct generators (`reach`), and the witnessing certificate
  (`witness`).
- **Route** — a versioned history store (H_0 ⊆ H_1 ⊆ …) with O(1) membership,
  content-addressed Merkle sharing between versions, and historical navigation.
- **Leech-native** — XSet, VoyagerList, Arena (196,560 type-2 vectors, pure
  M24 orbits).
- **Ordinary** — List, HashMap, HashSet, Merkle, Stream, Seq.

## Note on earlier framing

I realized too late that earlier material framed parts of this work in terms of
P=NP. That framing was an overclaim produced by an LLM and is naturally
retracted. The actual intent was experimental: to study how problems that are
NP-hard in the general case behave when restricted to a fixed finite commutative
algebra. On a fixed finite domain the reachable set is bounded by |S|, so such
problems become tractable. This is a property of the finite domain, not a
statement about P vs NP in general. I have no proof of P=NP or P != NP in my
hands.
