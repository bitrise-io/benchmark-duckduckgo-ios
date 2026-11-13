#!/usr/bin/env bash
# build-for-testing + test-without-building on a booted simulator (port of Bitrise bench_test_suite).
set -eo pipefail
source "$(dirname "$0")/lib.sh"
cd "$IOS_DIR"
LOGS="$BENCH_OUT/logs"; mkdir -p "$LOGS" "$RUNNER_TEMP/xcresults"

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,os,sys
d=json.load(sys.stdin)["devices"]
for r in sorted([r for r in d if "iOS" in r], reverse=True):
    for dev in d[r]:
        if dev["name"]==os.environ["SIM_DEVICE_NAME"]: print(dev["udid"]); sys.exit()
')
if [ -z "$UDID" ]; then echo "No '$SIM_DEVICE_NAME' simulator on this image"; xcrun simctl list devices available; exit 1; fi
echo "Booting $UDID (not timed)"; xcrun simctl boot "$UDID" || true; xcrun simctl bootstatus "$UDID" -b

SKIP=(); while IFS= read -r t; do [ -n "$t" ] && SKIP+=("-skip-testing:$t"); done <<< "$SKIP_TESTS"
echo "Skipping ${#SKIP[@]} test entries"

bench_timed() { local log="$1"; shift; local start end rc xc
  start=$(now); set +e; "$@" > "$log" 2>&1; rc=$?; set -e; end=$(now)
  xc=$(xc_seconds "$log"); [ -n "$xc" ] || xc=$(python3 -c "print(round($end-$start,3))"); echo "$xc $rc"; }
reset_dd() { local keep="${RUNNER_TEMP:?}/SourcePackages.keep" dd="${DERIVED_DATA:?}"
  if [ -d "$dd/SourcePackages" ]; then rm -rf "$keep"; mv "$dd/SourcePackages" "$keep"; fi
  rm -rf "$dd"; mkdir -p "$dd"; if [ -d "$keep" ]; then mv "$keep" "$dd/SourcePackages"; fi; }

echo "project,metric_key,machine_key,run,duration_sec,exit_code" > "$BENCH_OUT/results.csv"
: > "$BENCH_OUT/build_for_testing_sim.txt"; : > "$BENCH_OUT/test_without_building_sim.txt"
FAILS=0
for i in $(seq 1 $(( WARMUP_RUNS + BENCHMARK_RUNS ))); do
  run_label "$i"; echo "=== $LABEL ==="
  reset_dd
  read -r S RC < <(bench_timed "$LOGS/$LABEL-build_for_testing_sim.log" xcodebuild build-for-testing \
    -project "$XCODE_PROJECT" -scheme "$SCHEME" -destination "id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
    -disableAutomaticPackageResolution -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    COMPILER_INDEX_STORE_ENABLE=NO DDG_SLOW_COMPILE_CHECK_THRESHOLD=250)
  if [ "$RC" -ne 0 ]; then echo "❌ build-for-testing failed on $LABEL"; tail -n 80 "$LOGS/$LABEL-build_for_testing_sim.log"; exit "$RC"; fi
  echo "build_for_testing_sim: ${S}s"
  echo "${BENCHMARK_PROJECT},build_for_testing_sim,${MACHINE_KEY},$LABEL,$S,0" >> "$BENCH_OUT/results.csv"
  [ "$MEASURED" = 1 ] && echo "$S" >> "$BENCH_OUT/build_for_testing_sim.txt"

  RESULT="$RUNNER_TEMP/xcresults/$LABEL.xcresult"
  read -r S RC < <(bench_timed "$LOGS/$LABEL-test_without_building_sim.log" xcodebuild test-without-building \
    -project "$XCODE_PROJECT" -scheme "$SCHEME" -destination "id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" -resultBundlePath "$RESULT" -collect-test-diagnostics never "${SKIP[@]}")
  echo "test_without_building_sim: ${S}s (exit $RC)"
  echo "${BENCHMARK_PROJECT},test_without_building_sim,${MACHINE_KEY},$LABEL,$S,$RC" >> "$BENCH_OUT/results.csv"
  if [ "$RC" -ne 0 ]; then
    awk '/^Failing tests:/{p=1} p' "$LOGS/$LABEL-test_without_building_sim.log" | head -n 40 || true
    [ "$MEASURED" = 1 ] && FAILS=$(( FAILS + 1 ))
  fi
  [ "$MEASURED" = 1 ] && echo "$S" >> "$BENCH_OUT/test_without_building_sim.txt"
done

cat > "$BENCH_OUT/summary.json" <<JSON
{
$(summary_common),
  "suite": "test",
  "benchmark_revision": "${BENCH_COMMIT}",
  "skipped_tests": ${#SKIP[@]},
  "measured_runs_with_test_failures": ${FAILS},
  "build_for_testing_sim": $(stats "$BENCH_OUT/build_for_testing_sim.txt"),
  "test_without_building_sim": $(stats "$BENCH_OUT/test_without_building_sim.txt")
}
JSON
(cd "$BENCH_OUT" && rm -f build_for_testing_sim.txt test_without_building_sim.txt)
finish
if [ "$FAILS" -gt 0 ]; then echo "❌ $FAILS measured run(s) had test failures"; exit 1; fi
