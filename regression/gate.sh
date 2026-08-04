#!/bin/bash
# gate.sh — the suite, hierarchical and sequential (fail-fast).
#
#   gate.sh 0    build + smoke           (~10 s)
#   gate.sh 1    0 + targeted on the dirty files (~1-3 min)
#   gate.sh 2    1 + acceptance          (~3-5 min)   <- default
#   gate.sh 3    2 + full pytest         (~10 min)    <- end of a stone
#
# Each level runs only if the previous one is green. No silent skip:
# tier 1 says which targeted tests it picked, and why.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIER="${1:-2}"
PYTEST="$ROOT/.venv/bin/pytest"
t0=$(date +%s)
say() { echo "── $*"; }
die() { echo "GATE RED ($1) after $(( $(date +%s) - t0 ))s"; exit 1; }

# --- tier 0: build + smoke ---------------------------------------------
say "tier 0: build"
dune build --root "$ROOT/frontend" 2>&1 | grep -E "^File|Error" && die "build"
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
      # + 100% corpus coverage): 4s at tier 1, 11 minutes at tier 3
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
      # gate reads them, and it is where `fun main(): number` survived
      add regression/test_website_surface.py ;;
  esac
done
if [ -n "$PICK" ]; then
  say "tier 1: targeted:$PICK"
  T1=$("$PYTEST" $PICK -q 2>&1); rc=$?
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
echo "$OUT" | grep -q "REGRESSION OK" || die "acceptance"
[ "$TIER" = "2" ] && { echo "gate 2 green ($(( $(date +%s) - t0 ))s)"; exit 0; }

# --- tier 3: full pytest ------------------------------------------------
say "tier 3: full pytest"
T3=$("$PYTEST" "$ROOT/regression/" -q 2>&1); rc=$?
echo "$T3" | grep -E "FAILED|passed|failed" | tail -6
[ $rc -eq 0 ] || die "full pytest"
echo "gate 3 green ($(( $(date +%s) - t0 ))s)"
