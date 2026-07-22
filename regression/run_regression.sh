#!/usr/bin/env bash
# Full Yon regression. Compares against baseline_exitcodes.txt.
# Usage: ./run_regression.sh   (from the regression/ dir)
# Portable Linux/macOS: honors the same env vars as yonc
#   YONC_TOPOS_OPT, YONC_LLC, YONC_MLIR_TRANSLATE, YONC_MLIR_OPT,
#   YONC_CC
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FT="$ROOT/runtime"; FE="$ROOT/frontend"; EXD="$ROOT/examples"

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

RTSET="$FT/yon_rt.o $FT/yon_mmap.o $FT/leech_orbits.o $FT/yon_arena.o $FT/yon_curtis_canon.o $FT/xleech2_coord.o $FT/xleech2_heap.o $FT/xleech2_mphf.o $FT/vendor/mmgroup/mat24_tables.o $FT/vendor/mmgroup/mat24_functions.o $FT/vendor/mmgroup/gen_leech.o $FT/vendor/mmgroup/gen_leech3.o $FT/vendor/mmgroup/gen_leech_type.o $FT/vendor/mmgroup/gen_leech_reduce.o $FT/vendor/mmgroup/gen_xi_functions.o $FT/vendor/mmgroup/mm_group_n.o $FT/vendor/mmgroup/mm_index.o"
LOWER="--convert-scf-to-cf --convert-cf-to-llvm --convert-func-to-llvm --convert-arith-to-llvm --reconcile-unrealized-casts"
EMIT="$FE/_build/default/yoner_emit_mlir.exe"
OUT=/tmp/regression_now.txt; > "$OUT"
# An example is a single examples/<name>.yon OR (after the Fase-1b migration)
# a directory examples/<name>/ with a yon.toml — the emit accepts both. The
# old *.yon-only glob silently shrank the gate to ONE file when the corpus
# became directory-projects.
for f in "$EXD"/*.yon "$EXD"/*/; do
  name=$(basename "$f" .yon); name=${name%/}
  rm -f /tmp/rr   # never execute a stale binary when a compile stage fails
  if ! "$EMIT" "$f" 2>/dev/null > /tmp/r.mlir || [ ! -s /tmp/r.mlir ]; then echo "EMITFAIL $name" >>"$OUT"; continue; fi
  if "$TOPOS" --algebra-verifier --lower-topos-extensions --lower-topos-to-standard /tmp/r.mlir 2>/dev/null >/tmp/r.s1 && \
     "$TOPOS" --lower-topos-to-llvm /tmp/r.s1 2>/dev/null >/tmp/r.s2 && [ -s /tmp/r.s2 ]; then :; \
  else "$MLIROPT" /tmp/r.mlir $LOWER 2>/dev/null >/tmp/r.s2; fi
  if ! "$MLIRTRANS" /tmp/r.s2 --mlir-to-llvmir 2>/dev/null >/tmp/r.ll || \
     ! "$LLC" -filetype=obj /tmp/r.ll -o /tmp/r.o 2>/dev/null || \
     ! "$CC" $NOPIE /tmp/r.o $RTSET -lpthread -lm -o /tmp/rr 2>/dev/null; then
    echo "BUILDFAIL $name" >>"$OUT"; continue; fi
  timeout 30 /tmp/rr >/dev/null 2>&1; echo "RAN $name exit=$?" >>"$OUT"
done
sort "$OUT" -o "$OUT"
if diff -q "$ROOT/regression/baseline_exitcodes.txt" "$OUT" >/dev/null; then
  echo "REGRESSION OK: $(wc -l <"$OUT") examples, identical to the baseline."
else
  echo "DIFFERENCES vs baseline:"; diff "$ROOT/regression/baseline_exitcodes.txt" "$OUT"
fi

# Conway-chains runtime suite (decoder certificate, outside the .yon baseline).
# Pins the XLeech2 coordinate decoder against the orders of the sporadic and
# classical groups in the Conway chain (Co2 and Co3 stabilisers: McL, HS,
# U6(2), M23, U4(3):2, 2^10:M22, ...). A sign error in any of the decoder's
# three shapes breaks at least one identity; a failure here falsifies the suite.
CONWAY_SRC="$FT/yon_test_conway_chains.c"
CONWAY_BIN=/tmp/yon_test_conway_chains
if "$CC" -std=c11 -O2 -I"$FT" -I"$FT/vendor/mmgroup" "$CONWAY_SRC" $RTSET -lpthread -lm $NOPIE -o "$CONWAY_BIN" 2>/tmp/conway_cc.txt; then
  if "$CONWAY_BIN" >/tmp/conway_out.txt 2>&1; then
    echo "CONWAY-CHAINS OK: $(grep -c '\[PASS\]' /tmp/conway_out.txt) checks passed."
  else
    echo "CONWAY-CHAINS FAIL:"; cat /tmp/conway_out.txt; exit 1
  fi
else
  echo "CONWAY-CHAINS BUILD FAIL:"; cat /tmp/conway_cc.txt; exit 1
fi

# Quantizer guard (closest type-2, outside the .yon baseline). Pins
# yon_leech2_quantize against the brute-force argmax over all 196560 minimal
# vectors with the identical MPHF-min tie-break, on continuous, integer
# (tie-heavy) and ultra-sparse queries. Exact vector identity, not just score.
QZ_SRC="$FT/yon_test_quantizer.c"
QZ_BIN=/tmp/yon_test_quantizer
if "$CC" -std=c11 -O2 -I"$FT" -I"$FT/vendor/mmgroup" "$QZ_SRC" $RTSET -lpthread -lm $NOPIE -o "$QZ_BIN" 2>/tmp/qz_cc.txt; then
  if "$QZ_BIN" >/tmp/qz_out.txt 2>&1; then
    echo "QUANTIZER OK: $(grep -c '\[PASS\]' /tmp/qz_out.txt) checks passed."
  else
    echo "QUANTIZER FAIL:"; cat /tmp/qz_out.txt; exit 1
  fi
else
  echo "QUANTIZER BUILD FAIL:"; cat /tmp/qz_cc.txt; exit 1
fi

# Cross-Space suite (multi-process, outside the 112 baseline)
"$(dirname "$0")/cross_space/run.sh" || exit 1
