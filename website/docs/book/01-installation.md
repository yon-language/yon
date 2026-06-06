---
id: installation
title: "1. Installation"
sidebar_position: 1
slug: /book/installation
---

# Installation

Yon runs on Linux x86-64 and macOS arm64 (Apple Silicon). Prebuilt
binaries and a Homebrew tap are planned; today you build from source,
which takes a working toolchain and a few minutes.

## What you need

- OCaml and `dune` (the compiler frontend)
- LLVM/MLIR 18 (`topos-opt` is an MLIR dialect; `mlir-translate` and
  `llc` come from the same toolchain)
- A C compiler (`gcc` or `clang`) to link the runtime
- The `mmgroup` Python package: the runtime links `libmmgroup_mat24`
  and `libmmgroup_mm_op` from its wheel (Conway group machinery for
  the Leech-lattice heap)

Platform notes, exact versions and flags live in the repository:
`INSTRUCTIONS.md` and, for Apple Silicon, `PORTING-MACOS.md`.

## Build

```bash
git clone https://github.com/yon-language/yon.git
cd yon
(cd frontend && dune build)     # compiler frontend and tools
make                            # C runtime
# MLIR dialect: see INSTRUCTIONS.md / PORTING-MACOS.md for your platform
export PATH="$PWD/toolchain:$PATH"
```

## Verify

Create `hello.yon`:

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
| `yon-lsp` | language server (diagnostics, hover, symbols, completion) |

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
