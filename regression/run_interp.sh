#!/usr/bin/env bash
# Interpreter-path baseline: run every example through eval_runner (the OCaml
# kernel/Reduce interpreter) and record its exit value. This is the judge for
# changes to the reduction kernel (subst, beta, the de Bruijn migration of
# reduce), which the native exit-code regression does NOT exercise.
# Output: sorted "INTERP <name> exit=<n>" (or =ERR / =TIMEOUT) to $OUT.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXD="$ROOT/examples"
OUT="${1:-/tmp/interp_now.txt}"
EVR="$(find "$ROOT/frontend/_build" -name eval_runner.exe 2>/dev/null | head -1)"
: > "$OUT"
for f in "$EXD"/*.yon; do
  name=$(basename "$f" .yon)
  line=$(timeout 30 "$EVR" "$f" 2>/dev/null | grep -E "^EXIT " | tail -1)
  if [ -z "$line" ]; then
    rc=$?
    if [ "$rc" = "124" ]; then echo "INTERP $name exit=TIMEOUT" >>"$OUT";
    else echo "INTERP $name exit=ERR" >>"$OUT"; fi
  else
    echo "INTERP $name exit=${line#EXIT }" >>"$OUT"
  fi
done
sort "$OUT" -o "$OUT"
