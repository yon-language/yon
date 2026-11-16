#!/bin/bash
# gate.sh — the suite, hierarchical and sequential (fail-fast).
#
#   gate.sh 0    build + smoke           (~10 s)
#   gate.sh 1    0 + targeted on the dirty files (~1-3 min)
#   gate.sh 1 main    the same, on the files changed since main (so a commit
#                already made is not left without its targeted tests)
#   gate.sh 1 3       the same, on the files changed by the last 3 commits
#   gate.sh 2    1 + acceptance          (~3-5 min)   <- default
#   gate.sh 3    2 + full pytest         (parallel + serial phase; the benchmarks
#                only checked for their values, on a small run)
#   gate.sh bench   the measurements alone: the benchmarks at full size, serial,
#                on a quiet machine (before publishing numbers)
#   gate.sh mlir <base>   the MLIR of the corpus at <base> against the working
#                tree: the programs whose MLIR differs
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
# The starting point of tier 1 (only): a ref (`main`) or a number of commits
# (`3` = HEAD~3). Without it tier 1 looks at the working tree alone.
START="${2:-}"
BASE=""
# The content cache of yonc is opt-in: YONC_CACHE_DIR=<dir> answers a
# compilation already made with this toolchain from the cache
# (toolchain/yonc_cache_key.py). Off by default: on this machine the time is in
# the system's check of every new binary, which a cached copy pays again.
export YONC_CACHE_DIR="${YONC_CACHE_DIR-}"
# The temporary directories of pytest are in notes/tmp/yon-pytest, which git
# ignores and only pytest uses: pytest empties it at the start of each run.
PYTEST_TMP="$ROOT/notes/tmp/yon-pytest"
if [ "$TIER" = "bench" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  t0=$(date +%s)
  echo "── bench: the measurements (serial, -m bench)"
  "$ROOT/.venv/bin/pytest" "$ROOT/regression/" -q --basetemp "$PYTEST_TMP" -m bench --skip-ledger "$ROOT/regression/SKIPS.txt" || {
    echo "GATE RED (bench) after $(( $(date +%s) - t0 ))s"; exit 1; }
  echo "bench green ($(( $(date +%s) - t0 ))s)"
  exit 0
fi
# gate.sh mlir <base>: the MLIR of the whole corpus (meta/ included) at <base>
# and in the working tree, and the programs whose MLIR differs. The base is a
# `git archive` of <base> in notes/tmp, with its own frontend built there; one
# base is kept: building a new one removes the others and their dumps.
if [ "$TIER" = "mlir" ]; then
  REF="${2:?usage: gate.sh mlir <commit-base>}"
  SHA=$(cd "$ROOT" && git rev-parse --short "$REF^{commit}") || exit 1
  TMP="$ROOT/notes/tmp"; BT="$TMP/base-$SHA"
  if [ ! -x "$BT/frontend/_build/default/yoner_emit_mlir.exe" ]; then
    rm -rf "$TMP"/base-* "$TMP"/mlir-*; mkdir -p "$BT"
    (cd "$ROOT" && git archive "$SHA") | tar -x -C "$BT" || exit 1
    (cd "$BT/frontend" && dune build) || { echo "the frontend of $SHA does not build"; exit 1; }
  fi
  (cd "$ROOT/frontend" && dune build) || { echo "the frontend of the working tree does not build"; exit 1; }
  dump() {  # dump <tree> <out>: one .mlir per project of the corpus, a .refused when yonc refuses it
    rm -rf "$2"; mkdir -p "$2"
    for d in "$1"/examples/*/ "$1"/regression/book/jp/*/ "$1"/regression/canonical_forms/*/*/ \
             "$1"/regression/cross_space/ "$1"/regression/wire_pair/ "$1"/regression/spawn_check/ "$1"/meta/; do
      [ -f "$d/yon.toml" ] || continue
      n=$(echo "${d#"$1"/}" | tr '/' '_')
      "$1/toolchain/yonc" --emit=mlir "$d" -o "$2/$n.mlir" >/dev/null 2>&1 \
        || { rm -f "$2/$n.mlir"; : > "$2/$n.refused"; }
    done
  }
  A="$TMP/mlir-$SHA"; W="$TMP/mlir-work"
  dump "$BT" "$A"; dump "$ROOT" "$W"
  same=0; refused=0; listed=0
  for b in $( (ls "$A"; ls "$W") | sort -u); do
    if [ ! -e "$A/$b" ]; then echo "new      $b"; listed=$((listed+1))
    elif [ ! -e "$W/$b" ]; then echo "gone     $b"; listed=$((listed+1))
    elif [ "${b%.refused}" != "$b" ]; then refused=$((refused+1))
    elif cmp -s "$A/$b" "$W/$b"; then same=$((same+1))
    else echo "changed  $b ($(diff "$A/$b" "$W/$b" | grep -c '^[<>]') lines)"; listed=$((listed+1)); fi
  done
  echo "mlir: $SHA -> working tree: $same identical, $refused refused on both sides, $listed listed above"
  exit 0
fi
PYTEST="$ROOT/.venv/bin/pytest"
# macOS idle sleep (pmset `sleep 1` on the dev machine) freezes the run midway:
# the suite stalls for as long as the machine sleeps and pytest's own clock does
# not even see it. Hold the machine awake for the gate's duration.
if command -v caffeinate >/dev/null 2>&1; then caffeinate -i -w $$ & fi
t0=$(date +%s)
say() { echo "── $*"; }
# A red gate keeps what it saw: the whole output of the step that failed and
# the environment it failed in, in a file of its own that nothing deletes
# (YON_GATE_FAILURES, by default notes/gate-failures of the repo, which git
# ignores). A failure that does not come back can be read there afterwards.
FAILDIR="${YON_GATE_FAILURES:-$ROOT/notes/gate-failures}"
keep() {  # keep <step> <output>
  mkdir -p "$FAILDIR" 2>/dev/null || return 0
  local sha f
  sha=$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null)
  f="$FAILDIR/$(date -u +%Y%m%dT%H%M%SZ)_${sha:-nocommit}_$(echo "$1" | tr -c 'A-Za-z0-9' '-' | cut -c1-40).log"
  {
    echo "gate $TIER red at: $1"
    echo "date (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')   elapsed: $(( $(date +%s) - t0 ))s"
    echo "root: $ROOT"
    echo "commit: $(cd "$ROOT" && git log -1 --format='%H %s' 2>/dev/null)"
    echo "dirty files:"; (cd "$ROOT" && git status --porcelain 2>/dev/null | sed 's/^/  /')
    echo "machine: $(uname -a)"
    echo "cpus: $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null)   memory: $(sysctl -n hw.memsize 2>/dev/null || grep MemTotal /proc/meminfo 2>/dev/null)"
    echo "load: $(uptime)"
    echo "fuzz seed of the day (YON_FUZZ_SEED unset): $(date +%Y%m%d)"
    echo "environment:"; env | grep -E '^(YON|YONC|PYTEST|TMPDIR|PATH=)' | sort | sed 's/^/  /'
    echo "jobs: ${JOBS:-${YON_JOBS:-auto}}"
    echo "processes by cpu:"; ps -A -o pcpu,pmem,comm 2>/dev/null | sort -rn | head -12 | sed 's/^/  /'
    echo "──────── output of the step ────────"
    printf '%s\n' "$2"
  } > "$f" 2>/dev/null && echo "   kept: $f"
}
die() {  # die <step> [output]
  [ $# -ge 2 ] && keep "$1" "$2"
  echo "GATE RED ($1) after $(( $(date +%s) - t0 ))s"; exit 1; }

# Resolve the starting point before the build: a wrong argument is an answer
# about the argument, not a partial run of the suite.
if [ -n "$START" ]; then
  case "$START" in
    *[!0-9]*)
      BASE=$(git -C "$ROOT" rev-parse --verify --quiet "${START}^{commit}") || {
        echo "gate: starting point '$START' is not a commit" >&2; exit 2; }
      ;;
    *)
      if [ "$START" -lt 1 ]; then
        echo "gate: the number of commits must be at least 1" >&2; exit 2
      fi
      BASE=$(git -C "$ROOT" rev-parse --verify --quiet "HEAD~${START}^{commit}") || {
        echo "gate: no HEAD~${START}: the history is shorter" >&2; exit 2; }
      ;;
  esac
fi

# --- tier 0: build + smoke ---------------------------------------------
# The suite writes only in its own temp dirs: a file the repo does not track
# that appears during the run is a test writing by a relative path (it would
# end up in a commit one day).
UNTRACKED_BEFORE=$(cd "$ROOT" && git status --porcelain --untracked-files=all | grep '^??' | sort)
say "tier 0: build"
# The verdict is dune's exit code, never its output: what dune prints depends
# on what the cache let it skip, and one tree must give one verdict.
BOUT=$(dune build --root "$ROOT/frontend" 2>&1) || { echo "$BOUT"; die "build" "$BOUT"; }
# The runtime and the MLIR lowering are part of the compiler the suite runs:
# built from this tree on every run (each tool rebuilds only what changed,
# headers included), so no verdict rests on a binary built before.
ROUT=$(make -C "$ROOT/runtime" 2>&1) || { echo "$ROUT"; die "build (runtime)" "$ROUT"; }
MOUT=$(ninja -C "$ROOT/mlir/build" 2>&1) || { echo "$MOUT"; die "build (MLIR lowering)" "$MOUT"; }
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
  echo "$GOUT"; die "grammar" "$GOUT"
fi
say "tier 0: smoke (one example compiles and runs)"
SOUT=$("$ROOT/toolchain/yonc" "$ROOT/examples/vec_basic" -o /tmp/gate_smoke 2>&1) || die "smoke compile" "$SOUT"
/tmp/gate_smoke >/dev/null 2>&1
[ $? -eq 62 ] || die "smoke exit (expected 62, vec_basic from the baseline)"
[ "$TIER" = "0" ] && { echo "gate 0 green ($(( $(date +%s) - t0 ))s)"; exit 0; }

# --- tier 1: targeted, from the dirty files or a starting point --------
# A starting point widens the set to the commits already made: the files
# that differ from it (the working tree included) and the untracked ones.
# The tests are the same map either way, so a committed change is not left
# without its targeted tests.
if [ -n "$BASE" ]; then
  say "tier 1: starting point $START ($(git -C "$ROOT" rev-parse --short "$BASE"))"
  DIRTY=$(
    { git -C "$ROOT" diff --name-only "$BASE" --
      git -C "$ROOT" ls-files --others --exclude-standard
    } | sed '/^$/d' | sort -u
  )
else
  DIRTY=$(git -C "$ROOT" status --porcelain | awk '{print $2}')
fi
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
  T1=$("$PYTEST" $PICK -q --basetemp "$PYTEST_TMP" -rfE -n "${YON_JOBS:-auto}" --dist loadgroup --skip-ledger "$ROOT/regression/SKIPS.txt" 2>&1); rc=$?
  echo "$T1" | tail -2
  [ $rc -eq 0 ] || die "targeted" "$T1"
else
  say "tier 1: no dirty file mapped - skip declared"
fi
[ "$TIER" = "1" ] && { echo "gate 1 green ($(( $(date +%s) - t0 ))s)"; exit 0; }

# --- tier 2: acceptance (exit codes + conway + quantizer + cross-space) -
say "tier 2: acceptance"
FULL=$(bash "$ROOT/regression/run_regression.sh" 2>&1)
OUT=$(echo "$FULL" | tail -6)
echo "$OUT"
# every acceptance block must report OK: a failed one prints FAIL and the
# script goes on, so checking only the first line let a red block through
for ok in "REGRESSION OK" "CONWAY-CHAINS OK" "QUANTIZER OK" "CROSS-SPACE OK"; do
  echo "$OUT" | grep -q "$ok" || die "acceptance ($ok missing)" "$FULL"
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
T3=$("$PYTEST" "$ROOT/regression/" -q --basetemp "$PYTEST_TMP" -rfE -n "$JOBS" --dist loadgroup -m "not bench and not serial" --skip-ledger "$LEDGER" 2>&1); rc=$?
echo "$T3" | grep -E "FAILED|passed|failed|UNDECLARED|STALE" | tail -12
[ $rc -eq 0 ] || die "full pytest (parallel phase)" "$T3"
say "tier 3: full pytest, serial phase (no-xdist tests)"
T3B=$("$PYTEST" "$ROOT/regression/" -q --basetemp "$PYTEST_TMP" -rfE -m "serial and not bench" --skip-ledger "$LEDGER" 2>&1); rc=$?
echo "$T3B" | grep -E "FAILED|passed|failed|UNDECLARED|STALE" | tail -12
[ $rc -eq 0 ] || die "full pytest (serial phase)" "$T3B"
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
