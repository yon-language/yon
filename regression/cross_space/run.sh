#!/usr/bin/env bash
# Cross-Space regression suite: builds the Bank service and two clients,
# runs them and checks exit codes and stdout. Fully local (vendored dependency).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
YONC="$DIR/../../toolchain/yonc"
TMP=$(mktemp -d)
cp -r "$DIR/yon_modules" "$TMP/"
cp "$DIR"/*.yon "$TMP/"
cd "$TMP"
fail=0
"$YONC" bank.yon -o "$TMP/Bank_srv" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: bank does not compile"; exit 1; }
"$YONC" main.yon -o "$TMP/ledger" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: ledger does not compile"; exit 1; }
out=$(timeout 20 ./ledger 2>/dev/null); rc=$?
[ "$rc" = "42" ] && [ "$out" = "209" ] || { echo "CROSS-SPACE FAIL: ledger rc=$rc out=$out (expected 42/209)"; fail=1; }
"$YONC" loop_remote.yon -o "$TMP/loopr" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: loop_remote does not compile"; exit 1; }
timeout 20 ./loopr >/dev/null 2>&1; rc=$?
[ "$rc" = "95" ] || { echo "CROSS-SPACE FAIL: loop_remote rc=$rc (expected 95)"; fail=1; }
rm -rf "$TMP"
[ "$fail" = "0" ] && echo "CROSS-SPACE OK: 2 scenarios (ledger 209/42, remote-call-in-loop 95)"
exit $fail
