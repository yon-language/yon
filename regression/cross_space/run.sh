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
# Scenario 3: two OS processes talking over a shared-memory Wire.
# The sensor streams readings 1..8 (with close), the dashboard drains
# them and exits with the sum: a true cross-process wire test.
"$YONC" wire_sensor.yon -o "$TMP/wsensor" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: wire_sensor does not compile"; exit 1; }
"$YONC" wire_dashboard.yon -o "$TMP/wdash" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: wire_dashboard does not compile"; exit 1; }
rm -f /dev/shm/yon_stream_9 /tmp/yon_stream_9 2>/dev/null
( timeout 20 ./wsensor >/dev/null 2>&1 & )
sleep 0.4
timeout 20 ./wdash >/dev/null 2>&1; rc=$?
[ "$rc" = "36" ] || { echo "CROSS-SPACE FAIL: wire scenario rc=$rc (expected 36)"; fail=1; }
# Scenario 4: wire subscription. The Sensors Space declares a producer
# (a public function returning stream of number); the subscriber opens
# wire to Sensors, awaits(readings), drains .stream with fold. The
# server is spawned by the runtime on first contact; the channel id is
# the producer's dispatch selector (nominal, no literals anywhere).
"$YONC" sensors.yon -o "$TMP/Sensors_srv" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: sensors does not compile"; exit 1; }
"$YONC" subscriber.yon -o "$TMP/subscriber" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: subscriber does not compile"; exit 1; }
timeout 20 ./subscriber >/dev/null 2>&1; rc=$?
[ "$rc" = "36" ] || { echo "CROSS-SPACE FAIL: subscription scenario rc=$rc (expected 36)"; fail=1; }
rm -rf "$TMP"
[ "$fail" = "0" ] && echo "CROSS-SPACE OK: 4 scenarios (ledger 209/42, remote-call-in-loop 95, wire 36, subscription 36)"
exit $fail
