#!/usr/bin/env bash
# Measure HashMap/HashSet against XRelMap/XRelSet on the same keys and write
# the results as JSON (default: website/src/data/maps-compare.json).
#
#   regression/bench/maps_compare/run.sh [OUT.json] [ARENA_BIN_DIR]
#
# One process per (family, key kind, N), the two families alternating at
# every N so that a drift of the machine falls on both. Each process prints
# five ns/op figures (set, get, miss, union, intersect; see gen.py), each the
# minimum of three runs inside it. ARENA_BIN_DIR, when given, holds the
# binaries `arena` and `arena_ops` built from regression/bench/arena and
# regression/bench/arena_ops at a commit that still had Arena (19596c5); they
# are run alternating with xrel_points and xrel_ops, as the reference row for
# the cost of persistence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:-$ROOT/website/src/data/maps-compare.json}"
ARENA="${2:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$ROOT/toolchain/yonc" "$ROOT/regression/bench/maps_compare" -o "$TMP/mc" >/dev/null 2>&1
"$ROOT/toolchain/yonc" "$ROOT/regression/bench/xrel_ops" -o "$TMP/xrel_ops" >/dev/null 2>&1
"$ROOT/toolchain/yonc" "$ROOT/regression/bench/xrel_points" -o "$TMP/xrel_points" >/dev/null 2>&1

ROWS="$TMP/rows.txt"
: > "$ROWS"
for kind in 0 1 2; do
  if [ "$kind" = 0 ]; then sizes="1000 10000 100000 196560"; else sizes="1000 10000 100000 400000"; fi
  for n in $sizes; do
    for fam in 0 1; do
      echo "row $fam $kind $n $("$TMP/mc" "$fam" "$kind" "$n" 2>/dev/null | tr '\n' ' ')" >> "$ROWS"
    done
  done
done
for rep in 1 2 3; do
  echo "ops xrel $("$TMP/xrel_ops" 2>/dev/null | tr '\n' ' ')" >> "$ROWS"
  echo "points xrel $("$TMP/xrel_points" 2>/dev/null | tr '\n' ' ')" >> "$ROWS"
  if [ -n "$ARENA" ]; then
    echo "ops arena $("$ARENA/arena_ops" 2>/dev/null | tr '\n' ' ')" >> "$ROWS"
    echo "points arena $("$ARENA/arena" 2>/dev/null | tr '\n' ' ')" >> "$ROWS"
  fi
done

python3 - "$ROWS" "$OUT" "$(git -C "$ROOT" rev-parse --short HEAD)" \
  "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)" <<'PY'
import json, sys, datetime, statistics
rows, out, commit, machine = sys.argv[1:5]
fam = {"0": "hash", "1": "xrel"}
kind = {"0": "point", "1": "number", "2": "text"}
data = {"machine": machine, "commit": commit,
        "date": datetime.date.today().isoformat(),
        "method": "in-process, net of an exact twin, min of 3 runs per process; ns per op",
        "columns": ["set", "get", "miss", "union", "intersect"],
        "maps": {}, "reference": {}}
ref = {}
for line in open(rows):
    t = line.split()
    if t[0] == "row":
        data["maps"].setdefault(kind[t[2]], {}).setdefault(t[3], {})[fam[t[1]]] = [int(x) for x in t[4:]]
    else:
        ref.setdefault(f"{t[0]}_{t[1]}", []).append([int(x) for x in t[2:]])
for k, runs in ref.items():
    data["reference"][k] = {"median": [int(statistics.median(c)) for c in zip(*runs)], "runs": runs}
with open(out, "w") as f:
    json.dump(data, f, indent=2)
print(out)
PY
