#!/bin/bash
# gate.sh — la suite, gerarchica e sequenziale (fail-fast).
#
#   gate.sh 0    build + fumo            (~10 s)
#   gate.sh 1    0 + mirati sui file sporchi (~1-3 min)
#   gate.sh 2    1 + acceptance           (~3-5 min)   ← default
#   gate.sh 3    2 + pytest completo      (~10 min)    ← fine pietra
#
# Ogni livello gira SOLO se il precedente è verde. Nessuno skip silenzioso:
# il tier 1 dice quali mirati ha scelto e perché.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIER="${1:-2}"
PYTEST="$ROOT/.venv/bin/pytest"
t0=$(date +%s)
say() { echo "── $*"; }
die() { echo "✗ GATE ROSSO ($1) dopo $(( $(date +%s) - t0 ))s"; exit 1; }

# ─── tier 0: build + fumo ───────────────────────────────────────────────
say "tier 0: build"
dune build --root "$ROOT/frontend" 2>&1 | grep -E "^File|Error" && die "build"
say "tier 0: fumo (un esempio compila e gira)"
"$ROOT/toolchain/yonc" "$ROOT/examples/vec_basic" -o /tmp/gate_smoke >/dev/null 2>&1 || die "fumo compile"
/tmp/gate_smoke >/dev/null 2>&1
[ $? -eq 62 ] || die "fumo exit (atteso 62, vec_basic da baseline)"
[ "$TIER" = "0" ] && { echo "✓ gate 0 verde ($(( $(date +%s) - t0 ))s)"; exit 0; }

# ─── tier 1: mirati dai file sporchi ────────────────────────────────────
DIRTY=$(cd "$ROOT" && git status --porcelain | awk '{print $2}')
PICK=""
add() { case " $PICK " in *" $1 "*) ;; *) PICK="$PICK $1";; esac; }
for f in $DIRTY; do
  case "$f" in
    frontend/parser.mly|frontend/lexer.mll|frontend/parser_state.ml|frontend/surface_ast.ml|frontend/formatter.ml)
      add regression/test_syntax_triangle.py; add regression/test_canonical_forms.py
      # il formatter è il gate piu esigente (round-trip + idempotenza + 100%
      # copertura corpus): al tier 1 costa 4s, al tier 3 costa 11 minuti
      add regression/test_formatter.py ;;
    frontend/tycheck.ml|frontend/desugar.ml|frontend/dispatcher.ml)
      add regression/test_project_diff.py; add regression/test_canonical_forms.py
      add regression/test_projects.py
      # il selfhost è file-nudo puro: le regole di modo/world lo mordono per primo
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
      add regression/test_syntax_triangle.py ;;
  esac
done
if [ -n "$PICK" ]; then
  say "tier 1: mirati:$PICK"
  T1=$("$PYTEST" $PICK -q 2>&1); rc=$?
  echo "$T1" | tail -2
  [ $rc -eq 0 ] || die "mirati"
else
  say "tier 1: nessun file sporco mappato — salto dichiarato"
fi
[ "$TIER" = "1" ] && { echo "✓ gate 1 verde ($(( $(date +%s) - t0 ))s)"; exit 0; }

# ─── tier 2: acceptance (exit 101 + conway + quantizer + cross-space) ──
say "tier 2: acceptance"
OUT=$(bash "$ROOT/regression/run_regression.sh" 2>&1 | tail -6)
echo "$OUT"
echo "$OUT" | grep -q "REGRESSION OK" || die "acceptance"
[ "$TIER" = "2" ] && { echo "✓ gate 2 verde ($(( $(date +%s) - t0 ))s)"; exit 0; }

# ─── tier 3: pytest completo ────────────────────────────────────────────
say "tier 3: pytest completo"
T3=$("$PYTEST" "$ROOT/regression/" -q 2>&1); rc=$?
echo "$T3" | grep -E "FAILED|passed|failed" | tail -6
[ $rc -eq 0 ] || die "pytest completo"
echo "✓ gate 3 verde ($(( $(date +%s) - t0 ))s)"
