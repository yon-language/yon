#!/usr/bin/env bash
# Cross-Space regression suite: builds the Bank service and two clients,
# runs them and checks exit codes and stdout. Fully local (vendored dependency).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
YONC="$DIR/../../toolchain/yonc"
TMP=$(mktemp -d)
cp -r "$DIR/yon_modules" "$TMP/"
cp "$DIR"/*.yon "$TMP/"
for project in \
  meteo_svc meteo_sub weather_svc weather_sub \
  weatherbig_svc weatherbig_sub nested_svc nested_sub
do
  cp -r "$DIR/$project" "$TMP/"
done
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
# Scenario 5: wire subscription whose stream element is a PLACE (DTO), not a
# scalar. The Meteo Space declares a producer returning stream of Reading
# (a fixed-size all-scalar place {temp, humidity}); it emits three places. The
# subscriber awaits(samples), drains .stream and folds a + r.temp. Each place
# crosses the process boundary by value: the pump flattens it to bytes, the
# drain rebuilds it in the consumer's own heap. Seal 1 of the wire-DTO wormhole.
rm -f /dev/shm/yon_stream_id_* /tmp/yon_stream_id_* 2>/dev/null
"$YONC" meteo_svc -o "$TMP/Meteo_srv" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: meteo_svc does not compile"; exit 1; }
"$YONC" meteo_sub -o "$TMP/sub_meteo" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: meteo_sub does not compile"; exit 1; }
timeout 20 ./sub_meteo >/dev/null 2>&1; rc=$?
[ "$rc" = "36" ] || { echo "CROSS-SPACE FAIL: DTO-place scenario rc=$rc (expected 36)"; fail=1; }
# Scenario 6: a place with a STRING field crosses the wire. The Weather Space
# declares a producer returning stream of Reading {temp number, label text} and
# emits three. The subscriber awaits(forecasts), drains .stream and folds
# a + r.temp + String.length(r.label). Seal 2 of the wire-DTO wormhole: the
# recursive length-prefixed frame carries the string content by value, rebuilt
# in the consumer's own ds heap; (10+11+15) + length("ok")*3 = 36 + 6 = 42.
rm -f /dev/shm/yon_stream_id_* /tmp/yon_stream_id_* 2>/dev/null
"$YONC" weather_svc -o "$TMP/Weather_srv" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: weather_svc does not compile"; exit 1; }
"$YONC" weather_sub -o "$TMP/sub_weather" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: weather_sub does not compile"; exit 1; }
timeout 20 ./sub_weather >/dev/null 2>&1; rc=$?
[ "$rc" = "42" ] || { echo "CROSS-SPACE FAIL: DTO-string scenario rc=$rc (expected 42)"; fail=1; }
# Scenario 7: a DTO frame larger than the old 256-byte slot cap. The WeatherBig
# Space emits a Note {id number, body text} whose 250-char body makes the frame
# about 270 bytes; the subscriber folds a + n.id + String.length(n.body) = 5 +
# 250 = 255. Under seal 2b this frame could not cross (serialize > slot -> the
# pump truncated); the dense byte ring of seal 2c carries it whole.
rm -f /dev/shm/yon_stream_id_* /tmp/yon_stream_id_* 2>/dev/null
"$YONC" weatherbig_svc -o "$TMP/WeatherBig_srv" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: weatherbig_svc does not compile"; exit 1; }
"$YONC" weatherbig_sub -o "$TMP/sub_weather_big" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: weatherbig_sub does not compile"; exit 1; }
timeout 20 ./sub_weather_big >/dev/null 2>&1; rc=$?
[ "$rc" = "255" ] || { echo "CROSS-SPACE FAIL: DTO-large-frame scenario rc=$rc (expected 255)"; fail=1; }
# Scenario 8: a nested DTO. The Nested Space emits Outer {tag number, inner
# Inner} where Inner {a number, b text}; the subscriber folds
# acc + o.tag + o.inner.a + String.length(o.inner.b) over two pairs = (7+3+2) +
# (8+4+2) = 26. The sub-place's frame is inlined recursively into the parent's
# and rebuilt in the consumer's heap; the schema registry resolves the
# sub-descriptor from the sub-frame's own id.
rm -f /dev/shm/yon_stream_id_* /tmp/yon_stream_id_* 2>/dev/null
"$YONC" nested_svc -o "$TMP/Nested_srv" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: nested_svc does not compile"; exit 1; }
"$YONC" nested_sub -o "$TMP/sub_nested" >/dev/null 2>&1 || { echo "CROSS-SPACE FAIL: nested_sub does not compile"; exit 1; }
timeout 20 ./sub_nested >/dev/null 2>&1; rc=$?
[ "$rc" = "26" ] || { echo "CROSS-SPACE FAIL: nested-DTO scenario rc=$rc (expected 26)"; fail=1; }
rm -rf "$TMP"
[ "$fail" = "0" ] && echo "CROSS-SPACE OK: 8 scenarios (ledger 209/42, remote-call-in-loop 95, wire 36, subscription 36, dto-place 36, dto-string 42, dto-large-frame 255, nested-dto 26)"
exit $fail
