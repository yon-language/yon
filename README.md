<p align="center">
  <img src="website/static/img/logo.svg" width="170" alt="Yon: the conferral mark, Hom(-, A)">
</p>

# Yon

**Yon** is an experimental, topos-oriented programming language: a
compiled language whose semantics are drawn from category theory
(elementary topoi, Heyting algebras, directed type theory) and whose
runtime stores every value in a **content-addressed heap built on the
Leech lattice Λ₂₄**, with canonicalization under the Conway group Co₀.
Same content, same address: equality is one machine comparison,
deduplication is global, and the heap chain grows without tuning knobs.

The pipeline: OCaml frontend → custom MLIR "topos" dialect → LLVM →
native binary, linked against a self-contained C runtime (xleech allocator with the vendored mmgroup mathematical core).

## Status

**1.0 baseline**. The ground truth is the
regression suite: **112 examples + 2 cross-Space scenarios**, exit
codes identical across platforms.

Platforms: Linux x86-64 and macOS Apple Silicon; the regression suite runs green on both.
macOS Intel: untested (expected to work; reports welcome).

## Install

One line (macOS arm64, Linux x86-64):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://yon-lang.org/install.sh | bash
```

It checks prerequisites (and prints what to install if something is missing),
builds the three stages from source, and drops a self-contained toolchain into
`~/.yon` with `yonc`, `yon-lsp`, `yon-fmt`, `yon-lint` and `yon-pkg` on your
`PATH`, plus the VS Code / Cursor extension. Re-runnable; pass `--check` (as
`| bash -s -- --check`) for a dry prerequisites report. For the manual,
step-by-step path, follow `INSTRUCTIONS.md`.

## Build

Follow **`INSTRUCTIONS.md`** — the single authoritative walkthrough
(runtime, OCaml frontend, MLIR dialect,
then the regression). The acceptance criterion on every platform:

```
cd regression && ./run_regression.sh
→ REGRESSION OK: 112 examples, identical to the baseline.
→ CROSS-SPACE OK: 2 scenarios
```

House rule: run the regression before every push. No silent
degradation, in code or in process.

## First program

```bash
toolchain/yonc examples/v1_control_flow.yon -o prog && ./prog
```

The book (23 chapters + appendices, every snippet compiled before it
was written) lives in `website/docs/book/` and at **yon-lang.org**.

## Packages

Go-style, registry-less: a package is a git repository with a
`yon.toml` at its root. In your manifest:

```toml
[dependencies]
geometria = { pkg = "user/geometria", version = "1.0" }  # any GitHub account
json      = { pkg = "json" }                             # bare name → yon-language/json
```

`pkg/yon-pkg install` resolves into `yon_modules/` and writes a
`yon.lock`. Official packages live under the `yon-language` organization;
anyone can publish under their own account.

## License

- **Compiler, frontend, MLIR dialect, toolchain: AGPLv3** (`LICENSE`).
  Anyone who modifies Yon or serves a modified Yon over a network must
  publish their changes.
- **Runtime: AGPLv3 + linking exception** (`runtime/LICENSE`).
  **Programs you write in Yon are entirely yours**, under any license
  you choose — the exception exists precisely so that using the
  language never encumbers your code.

Third-party: LLVM/MLIR (Apache-2.0 with LLVM exception),
mmgroup (BSD-2-Clause), menhir-generated parser (free of constraints
by explicit exception).
