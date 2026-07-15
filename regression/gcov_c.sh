#!/usr/bin/env bash
# C runtime line coverage (gcov, vendor excluded). Instruments the runtime with
# --coverage, runs the C unit tests linked against it, prints "COV <file>.c <pct>"
# per module, then RESTORES the normal (uninstrumented) build. Self-contained and
# self-restoring (a trap rebuilds clean on exit, even on failure), so it is safe to
# run in a working tree and leaves the runtime as it found it.
#
# Standalone:  bash regression/gcov_c.sh
# Under pytest: regression/test_c_coverage.py (opt-in, pass --gcov)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RT="$ROOT/runtime"
PY="$ROOT/.venv/bin/python"; [ -x "$PY" ] || PY=python3
DEFS="-D_DARWIN_C_SOURCE"; [ "$(uname -s)" = Linux ] && DEFS="-D_GNU_SOURCE"
GCOV="gcov"; command -v xcrun >/dev/null 2>&1 && GCOV="xcrun llvm-cov gcov"
W="$(mktemp)"; printf '#!/bin/sh\nexec clang --coverage "$@"\n' > "$W"; chmod +x "$W"

restore() {
  rm -f "$RT"/*.gcno "$RT"/*.gcda "$RT"/*.gcov "$W"
  make -C "$RT" clean >/dev/null 2>&1
  make -C "$RT" >/dev/null 2>&1
}
trap restore EXIT

make -C "$RT" clean >/dev/null 2>&1
if ! make -C "$RT" CFLAGS="-std=c11 $DEFS -O0 -g --coverage -Ivendor/mmgroup" >/dev/null 2>&1; then
  echo "INSTRUMENTED BUILD FAILED" >&2; exit 2
fi

# Run the C unit self-tests linked with --coverage; each exercises the runtime .o,
# accumulating .gcda next to their .gcno in runtime/.
YONC_CC="$W" "$PY" -m pytest "$ROOT/regression/test_runtime_units.py" -q >/dev/null 2>&1

cd "$RT" || exit 2
for f in yon_rt xleech2_heap xleech2_mphf xleech2_coord yon_arena yon_curtis_canon leech_orbits yon_mmap; do
  pct=$($GCOV "$f.c" 2>/dev/null | grep -A1 "File '$f.c'" | grep -oE 'Lines executed:[0-9.]+' | grep -oE '[0-9.]+')
  [ -n "$pct" ] && echo "COV $f.c $pct"
done
