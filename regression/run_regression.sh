#!/usr/bin/env bash
# Full Yon regression. Compares against baseline_exitcodes.txt.
# Usage: ./run_regression.sh   (from the regression/ dir)
# Portable Linux/macOS: honors the same env vars as yonc
#   YONC_TOPOS_OPT, YONC_LLC, YONC_MLIR_TRANSLATE, YONC_MLIR_OPT,
#   YONC_CC, YONC_MMGROUP_DIR
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FT="$ROOT/runtime"; FE="$ROOT/frontend"; EXD="$ROOT/examples"

# --- mmgroup: env > venv/system python > Linux fallback --------------
MM="${YONC_MMGROUP_DIR:-$(python3 -c 'import mmgroup,os;print(os.path.dirname(mmgroup.__file__))' 2>/dev/null || echo /usr/local/lib/python3.12/dist-packages/mmgroup)}"
# --- topos-opt: env > flat tree > container canonical tree -----------
TOPOS="${YONC_TOPOS_OPT:-}"
[ -z "$TOPOS" ] && [ -x "$ROOT/mlir/build/topos-opt" ] && TOPOS="$ROOT/mlir/build/topos-opt"
[ -z "$TOPOS" ] && TOPOS="$(cd "$(dirname "$0")/.." && pwd)/mlir/build/topos-opt"
# No silent degradation: a missing/broken topos-opt would falsify the
# suite (simple examples pass through the mlir-opt fallback, the topos
# ones do not). Warn loudly.
if [ ! -x "$TOPOS" ]; then
  echo "WARNING: topos-opt not executable: $TOPOS" >&2
  echo "         (wrong YONC_TOPOS_OPT or missing mlir build)" >&2
fi
# --- LLVM tools: env > PATH > versioned (-18) > distro dir > brew ----
find_llvm_tool() {
  for cand in "$1" "$1-18"; do
    command -v "$cand" >/dev/null 2>&1 && { command -v "$cand"; return 0; }
  done
  [ -x "/usr/lib/llvm-18/bin/$1" ] && { echo "/usr/lib/llvm-18/bin/$1"; return 0; }
  if command -v brew >/dev/null 2>&1; then
    bp="$(brew --prefix llvm@18 2>/dev/null || true)"
    [ -n "$bp" ] && [ -x "$bp/bin/$1" ] && { echo "$bp/bin/$1"; return 0; }
  fi
  echo "$1"
}
LLC="${YONC_LLC:-$(find_llvm_tool llc)}"
MLIRTRANS="${YONC_MLIR_TRANSLATE:-$(find_llvm_tool mlir-translate)}"
MLIROPT="${YONC_MLIR_OPT:-$(find_llvm_tool mlir-opt)}"
CC="${YONC_CC:-gcc}"
NOPIE="-no-pie"; [ "$(uname -s)" = "Darwin" ] && NOPIE=""

RTSET="$FT/yon_rt.o $FT/xleech2_coord.o $FT/xleech2_handler_stack.o $FT/xleech2_heap.o $FT/xleech2_mphf.o"
# mmgroup libraries by EXPLICIT PATH (.so on both platforms):
# no -l, no .dylib symlinks, no linker ambiguity.
MMLIBS="$MM/libmmgroup_mat24.so $MM/libmmgroup_mm_op.so"
LOWER="--convert-scf-to-cf --convert-cf-to-llvm --convert-func-to-llvm --convert-arith-to-llvm --reconcile-unrealized-casts"
EMIT="$FE/_build/default/yoner_emit_mlir.exe"
OUT=/tmp/regression_now.txt; > "$OUT"
for f in "$EXD"/*.yon; do
  name=$(basename "$f" .yon)
  rm -f /tmp/rr   # never execute a stale binary when a compile stage fails
  if ! "$EMIT" "$f" 2>/dev/null > /tmp/r.mlir || [ ! -s /tmp/r.mlir ]; then echo "EMITFAIL $name" >>"$OUT"; continue; fi
  if "$TOPOS" --lower-topos-extensions --lower-topos-to-standard /tmp/r.mlir 2>/dev/null >/tmp/r.s1 && \
     "$TOPOS" --lower-topos-to-llvm /tmp/r.s1 2>/dev/null >/tmp/r.s2 && [ -s /tmp/r.s2 ]; then :; \
  else "$MLIROPT" /tmp/r.mlir $LOWER 2>/dev/null >/tmp/r.s2; fi
  if ! "$MLIRTRANS" /tmp/r.s2 --mlir-to-llvmir 2>/dev/null >/tmp/r.ll || \
     ! "$LLC" -filetype=obj /tmp/r.ll -o /tmp/r.o 2>/dev/null || \
     ! "$CC" $NOPIE /tmp/r.o $RTSET $MMLIBS -Wl,-rpath,$MM -lpthread -lm -o /tmp/rr 2>/dev/null; then
    echo "BUILDFAIL $name" >>"$OUT"; continue; fi
  timeout 30 /tmp/rr >/dev/null 2>&1; echo "RAN $name exit=$?" >>"$OUT"
done
sort "$OUT" -o "$OUT"
if diff -q "$ROOT/regression/baseline_exitcodes.txt" "$OUT" >/dev/null; then
  echo "REGRESSION OK: $(wc -l <"$OUT") examples, identical to the baseline."
else
  echo "DIFFERENCES vs baseline:"; diff "$ROOT/regression/baseline_exitcodes.txt" "$OUT"
fi

# Cross-Space suite (multi-process, outside the 112 baseline)
"$(dirname "$0")/cross_space/run.sh" || exit 1
