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

## 1. Python environment (local venv + mmgroup)

From the project root (macOS and Linux alike):

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install mmgroup
# verify: native libraries AND headers must be present
MM=$(python3 -c 'import mmgroup,os;print(os.path.dirname(mmgroup.__file__))')
ls "$MM" | grep -i 'mat24\|mm_op'
ls "$MM/dev/headers" | head -3
```

If `dev/headers` is missing, your platform's wheel is incomplete:
`pip install mmgroup --no-binary :all:` (requires cython).

**From here on, every command assumes the venv is active** — the
Makefile and `yonc` locate mmgroup by asking `python3`.

## 1b. macOS only: repair the mmgroup wheel's install_name

The macOS wheel's `.so` files carry the GitHub CI runner's absolute
path baked in as their install_name: without this one-time surgery,
every Yon binary aborts at runtime
(`dyld: Library not loaded: /Users/runner/...`).

```bash
MM=$(python3 -c 'import mmgroup,os;print(os.path.dirname(mmgroup.__file__))')
install_name_tool -id "@rpath/libmmgroup_mat24.so" "$MM/libmmgroup_mat24.so"
install_name_tool -id "@rpath/libmmgroup_mm_op.so" "$MM/libmmgroup_mm_op.so"
install_name_tool -change "/Users/runner/work/mmgroup/mmgroup/src/mmgroup/libmmgroup_mat24.so" \
  "@rpath/libmmgroup_mat24.so" "$MM/libmmgroup_mm_op.so"
codesign -f -s - "$MM/libmmgroup_mat24.so" "$MM/libmmgroup_mm_op.so"
python3 -c "import mmgroup; print('mmgroup ok')"
```

(If `otool -L` shows a different runner path, use the exact string you
see. Redo this step whenever the wheel is reinstalled.)

---

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

# environment for yonc (add to your shell profile if you like)
export YONC_LLC=$LLVM_PREFIX/bin/llc
export YONC_MLIR_TRANSLATE=$LLVM_PREFIX/bin/mlir-translate
export YONC_CC=clang
export YONC_TOPOS_OPT=$(pwd)/mlir/build/topos-opt
export YONC_MMGROUP_DIR=$(python3 -c 'import mmgroup,os;print(os.path.dirname(mmgroup.__file__))')
export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"   # `timeout`

# the test that counts
cd regression && ./run_regression.sh
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
export YONC_TOPOS_OPT=$(pwd)/mlir/build/topos-opt
cd regression && ./run_regression.sh
```

---

## 4. Compile a program

```bash
toolchain/yonc examples/v1_control_flow.yon -o prog && ./prog
```

The complete book is in `website/docs/book/` (or `npm install &&
npm run build` inside `website/` for the site). Benchmarks and their
method: Appendix D of the book.
