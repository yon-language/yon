---
id: installation
title: "1. Installation"
sidebar_position: 1
slug: /book/installation
---

# Installation

Yon runs on Linux x86-64 and macOS arm64 (Apple Silicon). Prebuilt
binaries and a Homebrew tap are planned; today you build from source:
one round of prerequisites and three builds, the same on both
platforms.

## The one-line installer

The fastest path runs those three builds for you:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://yon-lang.org/install.sh | bash
```

It reports what is missing (it never installs system packages behind your
back), builds the runtime, the frontend and the MLIR dialect, then installs a
self-contained toolchain into `~/.yon` with the CLI on your `PATH` and the
VS Code / Cursor extension wired up. Pass `--check` (as `| bash -s -- --check`)
for a dry prerequisites report. Everything below is what the installer does by
hand, and the path to take when you want each step under your control.

## What you need

- OCaml and `dune` (the compiler frontend)
- LLVM/MLIR 18 (`topos-opt` is an MLIR dialect; `mlir-translate` and
  `llc` come from the same toolchain)
- A C compiler (`gcc` or `clang`) to link the runtime

That is the whole list. The mathematical core of the runtime (Golay
code and Leech lattice, the machinery of the content-addressed heap)
is vendored in the repository under `runtime/vendor/mmgroup`
(BSD-2-Clause) and built with the rest: no Python, no packages to
install, and a Yon binary depends on libc and libpthread only.

Prerequisites, once:

```bash
# macOS
xcode-select --install
brew install opam cmake ninja llvm@18 coreutils

# Linux (Debian/Ubuntu)
apt install llvm-18 mlir-18-tools libmlir-18-dev clang opam cmake ninja-build
```

## Build

Three builds, one per compiler stage:

```bash
git clone https://github.com/yon-language/yon.git
cd yon
(cd runtime && make)            # 1. C runtime (vendored math included)
(cd frontend && dune build)     # 2. compiler frontend and tools
cd mlir                         # 3. the Topos MLIR dialect
cmake -G Ninja -B build \
  -DMLIR_DIR=$(brew --prefix llvm@18 2>/dev/null || echo /usr/lib/llvm-18)/lib/cmake/mlir \
  -DLLVM_DIR=$(brew --prefix llvm@18 2>/dev/null || echo /usr/lib/llvm-18)/lib/cmake/llvm
ninja -C build
cd ..
export PATH="$PWD/toolchain:$PWD/pkg:$PATH"   # yonc and friends live in toolchain/, yon-pkg in pkg/
```

No environment variables are needed: `yonc` locates the LLVM tools on
its own (PATH, the `-18` suffixed names, the distro dir, the Homebrew
keg). Exact platform notes live in the repository: `INSTRUCTIONS.md`
and, for Apple Silicon, `PORTING-MACOS.md`. The acceptance criterion
on every platform is the regression suite:

```bash
cd regression && ./run_regression.sh
# → REGRESSION OK: <N> examples, identical to the baseline.
```

## Verify

Create `hello.yon`:

<!-- yon-gate: exit 0 -->
```yon
fun main(): number {
  be greeting holds "ciao, mondo"   // interned on the heap
  be _ holds String.print(greeting)
  return 0
}
```

Then:

```bash
yonc hello.yon -o hello && ./hello
# ciao, mondo
```

Exit code 0 and the greeting on stdout mean the whole chain works:
frontend, Topos dialect, LLVM, runtime.

## The toolchain

| Command | Role |
| --- | --- |
| `yonc` | end-to-end compiler (`--emit=mlir\|standard\|ll` to inspect stages) |
| `yon-fmt` | code formatter (meaning-preserving, idempotent) |
| `yon-lint` | linter (unused bindings, dead code) |
| `yon-doc` | API reference generator (Markdown from source) |
| `yon-pkg` | git-based package manager (no central registry) |
| `yon-lsp` | language server (diagnostics, hover, symbols, completion, formatting) |

For editors: a VS Code / Cursor extension ships as a `.vsix` with the
GitHub releases (syntax highlighting plus the language server; set
`yon.lspPath` to your built `yon-lsp` binary). Neovim users can source
`lsp/editors/neovim.lua`.

## Dependencies in two minutes

Dependencies are git repositories, declared in `yon.toml` and resolved
into `./yon_modules/` with an exact-commit `yon.lock`:

```toml
[dependencies]
rates = { git = "https://github.com/someone/rates" }
# or pin: { git = "...", version = "1.2.0" }  /  { git = "...", rev = "<sha>" }
```

```bash
yon-pkg install     # resolve, clone, write yon.lock
yon-pkg update      # re-resolve unpinned deps, rotate the lock
```

Then in your code: `import "x/rates"` and call `rates::eur_to_usd(100)`.

Two things to know: the compiler does **not** fetch dependencies on its
own, run `yon-pkg install` after editing `yon.toml`; and `yon-pkg`
never edits your `yon.toml`, it only writes `yon.lock`.
