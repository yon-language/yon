<p align="center">
  <img src="website/static/img/yon-logo.svg" width="150" alt="Yon logo: the conferral mark, Hom(-, A)">
</p>

<h1 align="center">Yon</h1>

<p align="center">
  A compiled, experimental programming language whose semantics come from category theory,<br>
  running on a content-addressed heap built on the Leech lattice.
</p>

<p align="center">
  <a href="https://yon-lang.org">Book</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="examples/">Examples</a> ·
  <a href="#status">Status</a>
</p>

---

Yon starts from one question: what does a programming language look like if
the categorical vocabulary is the *surface*, not a library on top of it? A
**world** is a category, a **place** is an object in it, a **value** is a section
of a place, and all behaviour lives in **arrows**. Logic is internal: truth is
the subobject classifier Ω of a Heyting algebra, so `unknown` is an ordinary
truth value rather than an error or a null.

Underneath, every value lives in a **content-addressed heap**. Equal content
gets the same address, so equality is a single machine comparison and
deduplication is global. A heap holds 196,560 contents, the number of minimal
vectors of the Leech lattice Λ₂₄, and chains into a new heap when it fills. The
values that are lattice points (the X* structures, `LatticePoint`) are compared
up to the lattice's symmetries: M₂₄ orbits and Co₀ canonical forms.

Yon compiles to native code: OCaml frontend → a custom MLIR dialect (`topos`)
→ LLVM → a binary linked against a small, self-contained C runtime.

## A taste

```yon
place Tree { this > Leaf(Number) :U Node(Tree, Tree) }

place Entry {
  // A function out of a coproduct answers every arm.
  fun total(t: Tree): Number {
    return match t {
      Leaf { _1 as v }         => v,
      Node { _1 as l _2 as r } => total(l) + total(r)
    }
  }

  fun main(): Number {
    // Equal subtrees share one address: the heap is content-addressed.
    be t := .-> Node { _1 .-> Leaf { _1 20 } _2 .-> Leaf { _1 20 } }

    // `unknown` is a truth value, not an error: deciding it has three outcomes.
    be p := unknown
    be bonus := match decide(p ||? (!? p)) { Present => 0, Absent => 0, Unknown => 2 }

    return total(t) + bonus   // 42
  }
}
```

`Tree` is declared as the coproduct of its two arms, and `total` is the fold
over it. The last two lines show the logic at work: in a Heyting algebra the
excluded middle `p or not p` does not hold when `p` is unknown, and `decide`
makes the caller handle that case explicitly.

A Yon program is a directory with a `yon.toml`. Compile and run one with:

```bash
toolchain/yonc examples/inductive_tree -o tree && ./tree; echo $?
```

## Ideas the language is built on

- **Places and arrows.** A type is a place, a function is an arrow, and an
  arrow is declared in the place it touches: the place gives it its name
  (`String.length`, `Int64.gcd`). Sums are written
  as coproducts (`this > A :U B`), subtypes as monomorphisms (`this < Base`).
- **Failure is a value.** An arrow that can fail says so in its type, and the
  error is a coproduct that the caller resolves with `match`. Nothing is thrown.
- **Precision is a world.** `Int32` and `Int64` live in separate sites
  (`prelude/num32`, `prelude/num64`), so widening is an actual functor between
  categories rather than an implicit conversion.
- **The prelude is written in Yon.** `Number`, `String`, `Boolean`, the error
  places and the collections are declared in [`prelude/`](prelude/). A function
  the compiler implements is marked `is given`, and the checker verifies that
  the implementation exists with exactly that signature.
- **Collections are values.** `HashMap`, `HashSet` and friends are persistent:
  an insertion returns a new collection backed by the same content-addressed
  heap. Mutation exists, but only as an explicit local cell (`be x := e`,
  then `x = e`).
- **Spaces.** A program can be split into Spaces, separate processes that talk
  over shared memory and a typed wire protocol. Values cross by content, and a
  closure that captures a mutable cell is rejected if it tries to leave the
  activation that owns it.
- **Paths and identity.** The kernel includes identity and path types, cubical
  operations, transport and univalence between isomorphic inductive types.
  This part is real and tested but only partly exposed in the surface
  language; see [Status](#status).

## Status

Yon is a research language under active development (version 1.2 in
progress). It is not ready for production use, and the syntax still changes.

The regression suite is the source of truth. As of 2026-10-21, `regression/gate.sh 3`
reports:

| | |
|---|---|
| pytest | **1676 passed**, 10 skipped (each one declared in a register), **85 expected failures** |
| example programs | **101**, every exit code identical to a recorded baseline |
| cross-Space scenarios | **8**, multi-process, over shared memory and the wire |
| self-hosting | the frontend for a core subset, written in Yon, reproduces itself byte for byte |

The 85 expected failures are known defects found in audits, each pinned by a
strict probe that will fail the suite the day the defect is fixed without the
probe being updated. Most live in `regression/test_audit_probes.py` and
`regression/test_soundness_probes.py`.

Platforms: macOS on Apple Silicon and Linux x86-64. macOS on Intel is untested.

## Install

On macOS arm64 or Linux x86-64:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://yon-lang.org/install.sh | bash
```

The script checks prerequisites (and tells you what is missing), builds from
source, and installs the toolchain into `~/.yon`: `yonc`, `yon-lsp`, `yon-fmt`,
`yon-lint`, `yon-doc`, `yon-pkg`, and the VS Code / Cursor extension. Run it
with `| bash -s -- --check` to only check prerequisites.

## Build from source

Prerequisites: LLVM/MLIR 18, OCaml 5.1 with `dune` and `menhir`, CMake, Ninja.

```bash
# macOS
brew install opam cmake ninja llvm@18 coreutils
# Debian / Ubuntu
apt install llvm-18 mlir-18-tools libmlir-18-dev clang opam cmake ninja-build

opam init -y && opam switch create 5.1.1 && eval $(opam env)
opam install dune menhir -y
```

Then, from the repository root (`LLVM_PREFIX` is `$(brew --prefix llvm@18)` on
macOS and `/usr/lib/llvm-18` on Linux):

```bash
make -C runtime                                    # C runtime
(cd frontend && dune build)                        # OCaml frontend
cmake -G Ninja -S mlir -B mlir/build \
  -DMLIR_DIR=$LLVM_PREFIX/lib/cmake/mlir \
  -DLLVM_DIR=$LLVM_PREFIX/lib/cmake/llvm
ninja -C mlir/build                                # the topos MLIR dialect
regression/gate.sh 2                               # build, smoke, acceptance
```

No Python is needed to build: the mmgroup core is vendored under
`runtime/vendor/`. `yonc` finds the LLVM tools by itself; the `YONC_LLC`,
`YONC_MLIR_TRANSLATE`, `YONC_CC` and `YONC_TOPOS_OPT` variables override them.

## Testing

The gate is hierarchical and stops at the first failure, so the cost matches
the change. The suite runs on its own Python environment; `python-flint` (Arb)
is the oracle of the numeric tests and is needed by nothing else:

```bash
python3 -m venv .venv && .venv/bin/pip install -r regression/requirements.txt
regression/gate.sh 0   # build + smoke                              ~10 s
regression/gate.sh 1   # + tests targeted at the files you changed  ~1-3 min
regression/gate.sh 2   # + acceptance: examples and cross-Space      ~3-5 min
regression/gate.sh 3   # + the full suite                           ~13 min
```

Beyond unit tests, the suite includes kernel oracles, a surface fuzzer, a
differential check between the native compiler and the self-hosted one, a
formatter round-trip that must preserve the emitted MLIR, and a check that
keeps the lexer, the example corpus and the book in agreement on every keyword.

## Repository layout

```
frontend/     OCaml: lexer, parser, type checker, kernel, MLIR emission, LSP, formatter, linter
mlir/         the topos dialect and its lowering passes
runtime/      C runtime: content-addressed heap, arenas, Spaces, wire protocol (+ vendored mmgroup)
prelude/      the standard places, written in Yon
toolchain/    yonc and the yon driver
selfhost/     the Yon frontend written in Yon
examples/     example programs; 101 of them have a recorded expected exit code
regression/   the test suite and gate.sh
website/      the book (Docusaurus), published at yon-lang.org
lsp/, pkg/    editor integration and the package tool
```

## Documentation

The book lives in [`website/docs/book/`](website/docs/book/) and at
[yon-lang.org](https://yon-lang.org): 23 chapters and four appendices, from
installation to Spaces, the Heyting core, identity types and the heap.
Code blocks are compiled by the suite unless marked as illustrative.

## Packages

There is no central registry: a package is a git repository with a `yon.toml`
at its root.

```toml
[dependencies]
geometry = { pkg = "user/geometry", version = "1.2" }   # any GitHub account
json     = { pkg = "json" }                             # bare name → yon-language/json
```

`pkg/yon-pkg install` resolves dependencies into `yon_modules/` and writes a
`yon.lock`.

## License

- **Compiler, frontend, MLIR dialect, toolchain:** AGPLv3 ([`LICENSE`](LICENSE)).
- **Runtime:** AGPLv3 with a linking exception
  ([`runtime/LICENSE`](runtime/LICENSE)). Programs you write in Yon are yours,
  under any license you choose.

Third-party components: LLVM/MLIR (Apache-2.0 with LLVM exception), mmgroup
(BSD-2-Clause), and the Menhir-generated parser (no constraints, by explicit
exception).
