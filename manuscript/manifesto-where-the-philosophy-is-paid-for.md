<!-- DRAFT — manifesto material for the final Iteration (Iteration 7, "the mathematics
     demands the courage to face its implications"). Author's prose, the heart of the
     manifesto ("tienila"). De-em-dashed per the locked style rule. The "fist of
     functions / verify the foundation in Yon" parts are FRONTIER/aim, marked as such in
     the prose and in the honesty footer — never present them as done. -->

# Where the philosophy is paid for

Every safe language is safe on its surface and pays for it underneath. Rust's
memory-safety is guaranteed by a standard library shot through with `unsafe`: raw
pointers, manual lifetimes, the very operations the surface forbids. Haskell's
immutability is realized by a runtime, written in C, that mutates thunks in place
without ceremony. Java's managed heap is C++ doing the most unmanaged things imaginable
with memory. None of them is safe all the way down, and none of them pretends to be.
Safety is not a property that pervades every layer; it is a property one layer provides
by spending the freedom of the layer below. A narrow core, written in an unsafe
language, takes on the dirt once, under control, so that no one above ever has to.

Yon is no exception, and the book will not pretend it is. Its surface is immutable,
content-addressed, decided at compile time or refused. Underneath, the C runtime mutates
`g_space_cells` in place, aliases through pointers, casts, calls `mmap`. The mathematics,
the places, the paths, the proofs, does not descend to the silicon; it evaporates at
`type_erase`, having already done its work, and what reaches LLVM is load, store, branch.
The philosophy is entirely compile-time. The silicon carries the result of having
honoured it, not the philosophy itself, because a machine that does not mutate memory
does not compute.

So the frontier is not to make the lower layers be Yon (that is impossible, and wanting
it confuses the guarantee with the mechanism that provides it). The frontier is to widen
Yon's reach over itself, and to lock its invariants into the layers below: to host the
compiler in Yon, so the language that proves things proves things about its own
translation; to derive more of the runtime through the target-agnostic `Carrier`, so
less of it is C written by hand; and, the distant aim, to give the irreducible silicon
core a specification in Yon, checked by Yon's own dependent types, so that what must be
trusted shrinks from a runtime to a fist of functions, trusted because verified rather
than merely tested.

The dirt never disappears, and it does not pretend to. It becomes traceable: a named,
inspectable handful you can point at, rather than a diffuse runtime you must hope about.
The surface of trust contracts toward a point, and a dependently-typed language is the
rare kind that can, in principle, draw the proof of its own foundation inside itself.

---

## Honesty footer (verification, book-wright 2026-06-27)

Grounded today:
- **C runtime mutates `g_space_cells` in place** — ✓ `runtime/yon_rt.c:6450`
  (`g_space_cells[id].value = new_value`).
- **`mmap` sole primitive, no GC, `exit()`** — ✓ (#23, `xleech2_heap.c`, `yon_rt.c`).
- **The mathematics evaporates at `type_erase`** — ✓ (#20, `frontend/type_erase.ml`,
  oracle `test_type_erase.ml`).
- **What reaches LLVM is load/store/branch** — ✓ (the emitted MLIR for our chapters is
  `arith.*`/`func.call` lowering to LLVM; the topos/proof layer is gone by then).
- **Target-agnostic `Carrier`** — ✓ (#26, `frontend/carrier.ml`, emission = a printer).
- Rust `unsafe` / Haskell's C runtime mutating thunks / Java's C++ heap — standard,
  well-documented facts about each system.

FRONTIER / aim (NOT done — keep marked as such, never asserted as achieved):
- **Host the compiler in Yon (self-hosting).** NB: `regression/test_yon_selfhost.py`
  exists — verify its actual scope before claiming any self-host status; do not overclaim.
- **Derive more of the runtime through `Carrier`** — future work.
- **Specify the silicon core in Yon, checked by dependent types** — the explicitly
  "distant aim". The "who verifies the verifier?" regress is real: "traceable" means the
  trusted surface becomes small, named, and inspectable, NOT that trust is eliminated.
  Say it exactly that way.
