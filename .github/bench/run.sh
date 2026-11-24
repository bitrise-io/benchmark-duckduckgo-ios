#!/usr/bin/env bash
# Clean Debug, incremental Debug, clean Release simulator builds (port of Bitrise bench_build_suite).
set -eo pipefail
source "$(dirname "$0")/lib.sh"
cd "$IOS_DIR"
LOGS="$BENCH_OUT/logs"; mkdir -p "$LOGS"
COMMON=(-project "$XCODE_PROJECT" -scheme "$SCHEME" -destination "$SIM_DESTINATION"
  -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages"
  -disableAutomaticPackageResolution -skipPackagePluginValidation -skipMacroValidation
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
  COMPILER_INDEX_STORE_ENABLE=NO "${XCB_EXTRA[@]}")

bench_timed() { # $1 = log, rest = command. Prints "<seconds> <exit code>"
  local log="$1"; shift; local start end rc xc
  start=$(now); set +e; "$@" > "$log" 2>&1; rc=$?; set -e; end=$(now)
  xc=$(xc_seconds "$log"); [ -n "$xc" ] || xc=$(python3 -c "print(round($end-$start,3))")
  echo "$xc $rc"
}
reset_dd() { # wipe build products, keep resolved Swift packages
  local keep="${RUNNER_TEMP:?}/SourcePackages.keep" dd="${DERIVED_DATA:?}"
  if [ -d "$dd/SourcePackages" ]; then rm -rf "$keep"; mv "$dd/SourcePackages" "$keep"; fi
  rm -rf "$dd"; mkdir -p "$dd"
  if [ -d "$keep" ]; then mv "$keep" "$dd/SourcePackages"; fi
}
must() { # $1 metric, $2 label, $3 seconds, $4 rc
  if [ "$4" -ne 0 ]; then echo "❌ $1 failed on $2 (exit $4)"; tail -n 80 "$LOGS/$2-$1.log"; exit "$4"; fi
  echo "$1: ${3}s"
  echo "${BENCHMARK_PROJECT},$1,${MACHINE_KEY},$2,$3" >> "$BENCH_OUT/results.csv"
  if [ "$MEASURED" = 1 ]; then echo "$3" >> "$BENCH_OUT/$1.txt"; fi
}

echo "project,metric_key,machine_key,run,duration_sec" > "$BENCH_OUT/results.csv"
: > "$BENCH_OUT/clean_build_sim_debug.txt"; : > "$BENCH_OUT/incremental_build_sim_debug.txt"; : > "$BENCH_OUT/clean_build_sim_release.txt"
for i in $(seq 1 $(( WARMUP_RUNS + BENCHMARK_RUNS ))); do
  run_label "$i"; echo "=== $LABEL ==="
  reset_dd
  read -r S RC < <(bench_timed "$LOGS/$LABEL-clean_build_sim_debug.log" xcodebuild build "${COMMON[@]}" -configuration Debug)
  must clean_build_sim_debug "$LABEL" "$S" "$RC"
  printf '\n// benchmark incremental change %s %s\n' "$LABEL" "${GITHUB_RUN_ID:-local}.${GITHUB_RUN_ATTEMPT:-1}" >> "$INCREMENTAL_TOUCH_FILE"
  read -r S RC < <(bench_timed "$LOGS/$LABEL-incremental_build_sim_debug.log" xcodebuild build "${COMMON[@]}" -configuration Debug)
  git checkout -- "$INCREMENTAL_TOUCH_FILE"
  must incremental_build_sim_debug "$LABEL" "$S" "$RC"
  reset_dd
  read -r S RC < <(bench_timed "$LOGS/$LABEL-clean_build_sim_release.log" xcodebuild build "${COMMON[@]}" -configuration Release)
  must clean_build_sim_release "$LABEL" "$S" "$RC"
done

cat > "$BENCH_OUT/summary.json" <<JSON
{
$(summary_common),
  "benchmark_revision": "${BENCH_COMMIT}",
  "clean_build_sim_debug": $(stats "$BENCH_OUT/clean_build_sim_debug.txt"),
  "incremental_build_sim_debug": $(stats "$BENCH_OUT/incremental_build_sim_debug.txt"),
  "clean_build_sim_release": $(stats "$BENCH_OUT/clean_build_sim_release.txt")
}
JSON
(cd "$BENCH_OUT" && rm -f clean_build_sim_debug.txt incremental_build_sim_debug.txt clean_build_sim_release.txt)
finish
