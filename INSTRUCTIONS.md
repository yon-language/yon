# Yon 1.0 — building from source

**This document is the authoritative walkthrough.** PORTING-MACOS.md is
rationale and troubleshooting: if the two diverge, this one wins.

Layout: `runtime/` (C), `frontend/` (OCaml), `mlir/` (Topos dialect),
`toolchain/yonc` (end-to-end compiler), `regression/` (the criterion of
truth), `examples/`, `website/` (the book), `docs/`.

The acceptance criterion, identical on every platform:

```
cd regression && ./run_regression.sh
→ REGRESSION OK: 112 examples, identical to the baseline.
→ CROSS-SPACE OK: 2 scenarios (ledger 209/42, remote-call-in-loop 95)
```

---

## 1. No Python required

The mmgroup mathematical core (Golay code, Leech lattice: the heart of
the content-addressed heap) is VENDORED under `runtime/vendor/mmgroup`
(BSD-2-Clause, see PROVENANCE.md there). `make` builds it with the
rest of the runtime. No venv, no pip, no wheel surgery, no shared
library paths: a Yon binary depends on libc and libpthread only.

## 2. macOS (Apple Silicon) — VALIDATED: 112 + cross-Space green

Prerequisites, once:

```bash
xcode-select --install
brew install opam cmake ninja llvm@18 coreutils   # coreutils: provides `timeout` for the regression
opam init -y && opam switch create 5.1.1 && eval $(opam env)
opam install dune menhir -y
```

Build, in order, each step green before the next:

```bash
# runtime
cd runtime && make CC=clang && cd ..

# frontend
cd frontend && dune build && cd ..

# MLIR dialect
export LLVM_PREFIX=$(brew --prefix llvm@18)
cd mlir
cmake -G Ninja -B build \
  -DMLIR_DIR=$LLVM_PREFIX/lib/cmake/mlir \
  -DLLVM_DIR=$LLVM_PREFIX/lib/cmake/llvm
ninja -C build
cd ..

# `timeout` for the regression (GNU coreutils)
export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"

# the test that counts
cd regression && ./run_regression.sh
```

No environment variables are needed: `yonc` and the regression locate
the LLVM tools on their own (PATH, then the `-18` suffixed names, then
the distro dir, then the Homebrew keg). The `YONC_*` variables
(`YONC_LLC`, `YONC_MLIR_TRANSLATE`, `YONC_CC`, `YONC_TOPOS_OPT`, ...)
remain available as overrides if you want to force a non-standard
toolchain.

```bash
# example override: a custom LLVM build
export YONC_LLC=/opt/llvm-18/bin/llc
```

macOS notes already handled in the sources: `-D_DARWIN_C_SOURCE` (BSD
APIs under -std=c11), the `MAP_ANONYMOUS→MAP_ANON` shim, `-no-pie`
omitted on Darwin by `yonc`, RPC2 reply-channel names within the 31-char
shm limit. Known residual hazard: a QUEUE name (`/yon_stream_` + Space
name) can still exceed the limit for Space names beyond ~15 characters —
documented limit, explicit error.

---

## 3. Linux (x86-64, distro LLVM 18)

```bash
# prerequisites (apt): llvm-18 mlir-18-tools libmlir-18-dev clang opam cmake ninja-build
cd runtime && make && cd ..
cd frontend && dune build && cd ..
cd mlir
cmake -G Ninja -B build \
  -DMLIR_DIR=/usr/lib/llvm-18/lib/cmake/mlir \
  -DLLVM_DIR=/usr/lib/llvm-18/lib/cmake/llvm
ninja -C build
cd ..
cd regression && ./run_regression.sh   # no env vars needed, see above
```

---

## 4. Compile a program

```bash
toolchain/yonc examples/v1_control_flow.yon -o prog && ./prog
```

The complete book is in `website/docs/book/` (or `npm install &&
npm run build` inside `website/` for the site). Benchmarks and their
method: Appendix D of the book.
