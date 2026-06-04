#!/usr/bin/env bash
# Build completo del runtime canonico (yon_rt.o include yon_rt_hsh.c).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/runtime" && make clean >/dev/null 2>&1; make
echo "Runtime built: $(ls "$ROOT"/runtime/*.o | wc -l) oggetti."
