---
id: installation
title: "1. Building from source"
sidebar_position: 1
slug: /book/installation
---

# Building from source

Yon is built from its sources: there is no release yet, and no installer. It
is developed on macOS (Apple Silicon).

## What you need

- OCaml 5.1, through opam, with `dune` and `menhir` (the compiler frontend)
- LLVM and MLIR 18 (`topos-opt` is an MLIR dialect; `mlir-translate` and
  `llc` come from the same toolchain)
- CMake and Ninja, to build the dialect
- A C compiler (`gcc` or `clang`) to link the runtime
- Python 3, for the regression suite (the build itself does not use it)

How you get them is up to you and your system. The mathematical core of the
runtime (Golay code and Leech lattice, the machinery of the Leech heap and its
structures) is vendored in the repository under `runtime/vendor/mmgroup`
(BSD-2-Clause) and built with the rest, and a Yon binary depends on libc and
libpthread only.

## Build

Three builds, one per compiler stage. `LLVM_PREFIX` is the directory where
LLVM 18 is installed:

```bash
git clone https://github.com/yon-language/yon.git
cd yon
(cd runtime && make)            # 1. C runtime (vendored math included)
(cd frontend && dune build)     # 2. compiler frontend and tools
cd mlir                         # 3. the Topos MLIR dialect
cmake -G Ninja -B build \
  -DMLIR_DIR=$LLVM_PREFIX/lib/cmake/mlir \
  -DLLVM_DIR=$LLVM_PREFIX/lib/cmake/llvm
ninja -C build
cd ..
export PATH="$PWD/toolchain:$PWD/pkg:$PATH"   # yonc and friends live in toolchain/, yon-pkg in pkg/
```

`yonc` finds the LLVM tools on its own, on the `PATH` or under their `-18`
names; the `YONC_LLC`, `YONC_MLIR_TRANSLATE`, `YONC_CC` and `YONC_TOPOS_OPT`
variables override them. The acceptance criterion is the regression suite:

```bash
cd regression && ./run_regression.sh
# → REGRESSION OK: <N> examples, identical to the baseline.
```

## Verify

Create `hello.yon`:

<!-- yon-gate: exit 0 -->
```yon
fun main: Number {
  greeting := "ciao, mondo"   // interned on the heap
  _ := Text.print(greeting)
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

## Editor support

For **VS Code / Cursor**, build the extension's `.vsix` and install it:

```bash
cd lsp/editors/vscode
npm install
npx --yes @vscode/vsce package                 # -> yon-lang-<version>.vsix
code --install-extension yon-lang-*.vsix        # or: cursor --install-extension yon-lang-*.vsix
```

You get syntax highlighting plus everything the language server does from one
place: diagnostics (compiler errors *and* linter warnings), formatting, hover,
document symbols and completion. If `yon-lsp` is not on your `PATH`, set
`yon.lspPath` to its absolute path in the editor settings (`yon.lint.enable` and
`yon.format.enable` toggle those two features). Neovim users can source
`lsp/editors/neovim.lua`.

## Dependencies in two minutes

Dependencies are git repositories, declared in `yon.toml` and resolved
into `./yon_modules/` with an exact-commit `yon.lock`:

```toml
[dependencies]
rates = { git = "https://github.com/someone/rates" }
# or pin: { git = "...", version = "1.2.1" }  /  { git = "...", rev = "<sha>" }
```

```bash
yon-pkg install     # resolve, clone, write yon.lock
yon-pkg update      # re-resolve unpinned deps, rotate the lock
```

Then in your code: `import "x/rates"` and call `rates::eur_to_usd(100)`.

Two things to know: the compiler does **not** fetch dependencies on its
own, run `yon-pkg install` after editing `yon.toml`; and `yon-pkg`
never edits your `yon.toml`, it only writes `yon.lock`.
