#!/bin/bash
# gate.sh — the suite, hierarchical and sequential (fail-fast).
#
#   gate.sh 0    build + smoke           (~10 s)
#   gate.sh 1    0 + targeted on the dirty files (~1-3 min)
#   gate.sh 2    1 + acceptance          (~3-5 min)   <- default
#   gate.sh 3    2 + full pytest         (parallel + serial phase; the benchmarks
#                only checked for their values, on a small run)
#   gate.sh bench   the measurements alone: the benchmarks at full size, serial,
#                on a quiet machine (before publishing numbers)
#
# While working, the content cache of yonc makes a re-run of tier 1 fast (a
# compilation already made with this toolchain is answered from the cache):
#   YONC_CACHE_DIR="$PWD/.yonc-cache" regression/gate.sh 1
# Gate 3, the proof before a commit, runs without it.
#
# Each level runs only if the previous one is green. No silent skip:
# tier 1 says which targeted tests it picked, and why.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIER="${1:-2}"
# The content cache of yonc is opt-in: YONC_CACHE_DIR=<dir> answers a
# compilation already made with this toolchain from the cache
# (toolchain/yonc_cache_key.py). Off by default: on this machine the time is in
# the system's check of every new binary, which a cached copy pays again.
export YONC_CACHE_DIR="${YONC_CACHE_DIR-}"
if [ "$TIER" = "bench" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  t0=$(date +%s)
  echo "── bench: the measurements (serial, -m bench)"
  "$ROOT/.venv/bin/pytest" "$ROOT/regression/" -q -m bench --skip-ledger "$ROOT/regression/SKIPS.txt" || {
    echo "GATE RED (bench) after $(( $(date +%s) - t0 ))s"; exit 1; }
  echo "bench green ($(( $(date +%s) - t0 ))s)"
  exit 0
fi
PYTEST="$ROOT/.venv/bin/pytest"
# macOS idle sleep (pmset `sleep 1` on the dev machine) freezes the run midway:
# the suite stalls for as long as the machine sleeps and pytest's own clock does
# not even see it. Hold the machine awake for the gate's duration.
if command -v caffeinate >/dev/null 2>&1; then caffeinate -i -w $$ & fi
t0=$(date +%s)
say() { echo "── $*"; }
die() { echo "GATE RED ($1) after $(( $(date +%s) - t0 ))s"; exit 1; }

# --- tier 0: build + smoke ---------------------------------------------
# The suite writes only in its own temp dirs: a file the repo does not track
# that appears during the run is a test writing by a relative path (it would
# end up in a commit one day).
UNTRACKED_BEFORE=$(cd "$ROOT" && git status --porcelain --untracked-files=all | grep '^??' | sort)
say "tier 0: build"
# The verdict is dune's exit code, never its output: what dune prints depends
# on what the cache let it skip, and one tree must give one verdict.
BOUT=$(dune build --root "$ROOT/frontend" 2>&1) || { echo "$BOUT"; die "build"; }
# The runtime and the MLIR lowering are part of the compiler the suite runs:
# built from this tree on every run (each tool rebuilds only what changed,
# headers included), so no verdict rests on a binary built before.
ROUT=$(make -C "$ROOT/runtime" 2>&1) || { echo "$ROUT"; die "build (runtime)"; }
MOUT=$(ninja -C "$ROOT/mlir/build" 2>&1) || { echo "$MOUT"; die "build (MLIR lowering)"; }
say "tier 0: grammar (Menhir on parser.mly, every run, outside the cache)"
# Declared state of the grammar: no conflict, no useless precedence, no unused
# token, no unreachable symbol, no production never reduced. Every
# shift/reduce choice is written in parser.mly; none is left to Menhir.
GDIR=$(mktemp -d)
cp "$ROOT/frontend/parser.mly" "$GDIR/"
GOUT=$(cd "$GDIR" && menhir --interpret parser.mly </dev/null 2>&1); grc=$?
rm -rf "$GDIR"
g_conf=$(echo "$GOUT" | grep -c "conflict")
g_unused=$(echo "$GOUT" | grep -cE "never useful|unused|unreachable|never reduced")
g_warn=$(echo "$GOUT" | grep -c "Warning")
echo "   conflicts $g_conf, useless/unused $g_unused, warnings $g_warn (declared: 0, 0, 0)"
if [ $grc -ne 0 ] || [ "$g_warn" -ne 0 ] || [ "$g_conf" -ne 0 ] || [ "$g_unused" -ne 0 ]; then
  echo "$GOUT"; die "grammar"
fi
say "tier 0: smoke (one example compiles and runs)"
"$ROOT/toolchain/yonc" "$ROOT/examples/vec_basic" -o /tmp/gate_smoke >/dev/null 2>&1 || die "smoke compile"
/tmp/gate_smoke >/dev/null 2>&1
[ $? -eq 62 ] || die "smoke exit (expected 62, vec_basic from the baseline)"
[ "$TIER" = "0" ] && { echo "gate 0 green ($(( $(date +%s) - t0 ))s)"; exit 0; }

# --- tier 1: targeted, from the dirty files ----------------------------
DIRTY=$(cd "$ROOT" && git status --porcelain | awk '{print $2}')
PICK=""
add() { case " $PICK " in *" $1 "*) ;; *) PICK="$PICK $1";; esac; }
for f in $DIRTY; do
  case "$f" in
    frontend/parser.mly|frontend/lexer.mll|frontend/parser_state.ml|frontend/surface_ast.ml|frontend/formatter.ml)
      add regression/test_syntax_triangle.py; add regression/test_canonical_forms.py
      # the formatter is the most demanding gate (round-trip + idempotence
      # + 100% corpus coverage)
      add regression/test_formatter.py ;;
    frontend/tycheck.ml|frontend/desugar.ml|frontend/dispatcher.ml)
      add regression/test_project_diff.py; add regression/test_canonical_forms.py
      add regression/test_projects.py
      # the selfhost is pure bare-file: the mode/world rules bite it first
      add regression/test_yon_selfhost.py; add regression/test_selfhost_emit.py
      add regression/test_selfhost_fixpoint.py ;;
    frontend/emit_mlir.ml|frontend/builtins.ml|frontend/reduce.ml|frontend/carrier.ml)
      add regression/test_projects.py; add regression/test_llvm_ir.py ;;
    frontend/method_sugar.ml|frontend/project.ml|frontend/yoner_emit_mlir.ml)
      add regression/test_project_diff.py; add regression/test_projects.py ;;
    selfhost/*)
      add regression/test_yon_selfhost.py; add regression/test_selfhost_differential.py
      add regression/test_selfhost_fixpoint.py ;;
    runtime/*)
      add regression/test_runtime_units.py ;;
    prelude/*)
      add regression/test_projects.py ;;
    website/docs/book/*)
      add regression/test_syntax_triangle.py; add regression/test_website_surface.py ;;
    website/*)
      # the React pages and components have no compiler behind them: only this
      # gate reads them
      add regression/test_website_surface.py ;;
  esac
done
if [ -n "$PICK" ]; then
  say "tier 1: targeted:$PICK"
  T1=$("$PYTEST" $PICK -q -n "${YON_JOBS:-auto}" --dist loadgroup --skip-ledger "$ROOT/regression/SKIPS.txt" 2>&1); rc=$?
  echo "$T1" | tail -2
  [ $rc -eq 0 ] || die "targeted"
else
  say "tier 1: no dirty file mapped - skip declared"
fi
[ "$TIER" = "1" ] && { echo "gate 1 green ($(( $(date +%s) - t0 ))s)"; exit 0; }

# --- tier 2: acceptance (exit codes + conway + quantizer + cross-space) -
say "tier 2: acceptance"
OUT=$(bash "$ROOT/regression/run_regression.sh" 2>&1 | tail -6)
echo "$OUT"
# every acceptance block must report OK: a failed one prints FAIL and the
# script goes on, so checking only the first line let a red block through
for ok in "REGRESSION OK" "CONWAY-CHAINS OK" "QUANTIZER OK" "CROSS-SPACE OK"; do
  echo "$OUT" | grep -q "$ok" || die "acceptance ($ok missing)"
done
[ "$TIER" = "2" ] && { echo "gate 2 green ($(( $(date +%s) - t0 ))s)"; exit 0; }

# --- tier 3: full pytest ------------------------------------------------
# Two phases. The parallel one runs everything but the serial tests on every
# core (xdist groups keep IPC-name and fixed-/tmp users on one worker, see
# conftest); the serial tests then run alone. The timing tests (`bench`) are not
# here: their values are checked on a small run (test_bench_correct), and the
# measurements are `gate.sh bench`. YON_JOBS overrides the worker count (1 =
# fully serial).
# Both phases check the skip ledger: a skip not declared in SKIPS.txt fails.
JOBS="${YON_JOBS:-auto}"
LEDGER="$ROOT/regression/SKIPS.txt"
# Every world a test starts is released when it ends (runtime: the world's
# reaper removes each name in $TMPDIR/yon-world-<tag>, then the registry): a
# registry born during the suite and still there afterwards is a leaked world.
WORLDS_DIR="${TMPDIR:-/tmp}"
WORLDS_BEFORE=$(ls "$WORLDS_DIR" 2>/dev/null | grep '^yon-world-' | sort)
say "tier 3: full pytest, parallel phase (-n $JOBS)"
T3=$("$PYTEST" "$ROOT/regression/" -q -n "$JOBS" --dist loadgroup -m "not bench and not serial" --skip-ledger "$LEDGER" 2>&1); rc=$?
echo "$T3" | grep -E "FAILED|passed|failed|UNDECLARED|STALE" | tail -12
[ $rc -eq 0 ] || die "full pytest (parallel phase)"
say "tier 3: full pytest, serial phase (no-xdist tests)"
T3B=$("$PYTEST" "$ROOT/regression/" -q -m "serial and not bench" --skip-ledger "$LEDGER" 2>&1); rc=$?
echo "$T3B" | grep -E "FAILED|passed|failed|UNDECLARED|STALE" | tail -12
[ $rc -eq 0 ] || die "full pytest (serial phase)"
leaked=""
for _ in $(seq 50); do       # reapers wake on their launcher's exit: allow 10 s
  leaked=$(comm -13 <(echo "$WORLDS_BEFORE") \
           <(ls "$WORLDS_DIR" 2>/dev/null | grep '^yon-world-' | sort))
  [ -z "$leaked" ] && break
  sleep 0.2
done
[ -z "$leaked" ] || die "worlds not released after the suite: $leaked"
UNTRACKED_NEW=$(comm -13 <(echo "$UNTRACKED_BEFORE") \
  <(cd "$ROOT" && git status --porcelain --untracked-files=all | grep '^??' | sort))
[ -z "$UNTRACKED_NEW" ] || die "the suite wrote into the repo: $UNTRACKED_NEW"
# the cache keeps one toolchain: the entries of any other can never hit again
if [ -n "$YONC_CACHE_DIR" ] && [ -f "$YONC_CACHE_DIR/.toolchain" ]; then
  python3 "$ROOT/toolchain/yonc_cache_key.py" prune "$YONC_CACHE_DIR" "$(cat "$YONC_CACHE_DIR/.toolchain")"
fi
echo "gate 3 green ($(( $(date +%s) - t0 ))s)"
