<p align="center">
  <img src="website/static/img/yon-logo.svg" width="170" alt="Yon: the conferral mark, Hom(-, A)">
</p>

# Yon

**Yon** is an experimental, topos-oriented programming language: a compiled
language whose semantics are drawn from category theory (elementary topoi,
Heyting algebras, directed type theory) and whose runtime stores every value in
a **content-addressed heap built on the Leech lattice Λ₂₄**, canonicalized under
the Conway group Co₀. Same content, same address: equality is one machine
comparison, deduplication is global, and the heap chain grows without tuning
knobs.

The paradigm in one paragraph: a **world** is a category, a **place** is an
object in it, and a **value** is a section — immutable, identified by its
content. All behaviour lives in **arrows**, and an arrow is declared in the
place it touches, because the house gives it its name. Logic is internal: truth
is the subobject classifier Ω, and `unknown` is a citizen of the Heyting core
rather than an error. Failure is data, not a thrown stack: an arrow that can
fail says so in its type, and the caller answers it with `match`.

The pipeline: OCaml frontend → a custom MLIR `topos` dialect → LLVM → a native
binary, linked against a self-contained C runtime (the xleech allocator with the
vendored mmgroup mathematical core).

## Status

**1.2.1.** The ground truth is the regression suite: **1898 checks green**,
**101 example programs** whose exit codes match a recorded baseline byte for
byte, and **8 cross-Space runtime scenarios**.

Platforms: Linux x86-64 and macOS Apple Silicon, both green. macOS Intel is
untested — expected to work, reports welcome.

## The prelude is written in Yon

The primitives are not compiler magic with a name: they are **places declared
in the language**, in `prelude/`, and the compiler ships them in front of every
compilation.

```
prelude/
  num64/   Int64 (i64), Number (f64)   — the language's default precision
  num32/   Int32 (i32)                 — and the Widen functor toward num64
  text/    String                      — thirteen derived functions over ten wired
  logic/   Boolean, Unit
  err/     Error, DomainError
```

Two consequences worth knowing before reading the code. **Precision is a
world**, not a type parameter: `Int32` and `Int64` live in distinct sites, which
is what makes widening a genuine functor between categories rather than an
internal conversion. And **the boundary with the silicon is readable**: a
function whose body is realized by the compiler declares itself with `is given`,
and the checker verifies that the implementation really exists with the declared
signature — a missing name, a wrong arity or a wrong type are errors, not
comments.

```yon
place String is text {
  fun length(s: String): Number is given          // the axiomatic body
  fun is_empty(s: String): Boolean { return String.length(s) == 0 }
}
```

## Install

One line (macOS arm64, Linux x86-64):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://yon-lang.org/install.sh | bash
```

It checks prerequisites (and prints what to install if something is missing),
builds the three stages from source, and drops a self-contained toolchain into
`~/.yon` — `yonc`, `yon-lsp`, `yon-fmt`, `yon-lint`, `yon-doc`, `yon-pkg` — plus
the VS Code / Cursor extension. Re-runnable; pass `--check` (as
`| bash -s -- --check`) for a dry prerequisites report. For the manual path,
follow [`INSTRUCTIONS.md`](INSTRUCTIONS.md).

## Build and the house rule

[`INSTRUCTIONS.md`](INSTRUCTIONS.md) is the single authoritative walkthrough:
runtime, OCaml frontend, MLIR dialect, then the regression.

The suite is hierarchical and fail-fast, so the cost matches the change:

```bash
regression/gate.sh 0   # build + smoke                       ~10 s
regression/gate.sh 1   # + tests targeted at the dirty files ~1-3 min
regression/gate.sh 2   # + acceptance (exit codes, cross-Space)  ~3-5 min
regression/gate.sh 3   # + the full suite                    ~10 min
```

House rule: tiers 1-2 on every step, tier 3 before a milestone lands. No silent
degradation, in code or in process — and a gate that has never been shown to
fail on the bug it exists for is a reassurance, not a check.

## First program

```bash
toolchain/yonc examples/v1_control_flow -o prog && ./prog
```

The book — 26 chapters plus the reference, every snippet compiled before it was
written — lives in `website/docs/book/` and at **[yon-lang.org](https://yon-lang.org)**.

## Packages

Go-style, registry-less: a package is a git repository with a `yon.toml` at its
root. In your manifest:

```toml
[dependencies]
geometria = { pkg = "user/geometria", version = "1.2" }  # any GitHub account
json      = { pkg = "json" }                             # bare name → yon-language/json
```

`pkg/yon-pkg install` resolves into `yon_modules/` and writes a `yon.lock`.
Official packages live under the `yon-language` organization; anyone can publish
under their own account.

## License

- **Compiler, frontend, MLIR dialect, toolchain: AGPLv3** ([`LICENSE`](LICENSE)).
  Anyone who modifies Yon or serves a modified Yon over a network must publish
  their changes.
- **Runtime: AGPLv3 + linking exception** ([`runtime/LICENSE`](runtime/LICENSE)).
  **Programs you write in Yon are entirely yours**, under any license you
  choose — the exception exists precisely so that using the language never
  encumbers your code.

Third-party: LLVM/MLIR (Apache-2.0 with LLVM exception), mmgroup (BSD-2-Clause),
menhir-generated parser (free of constraints by explicit exception).
