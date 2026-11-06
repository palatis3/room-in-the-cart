#!/bin/bash
set -euo pipefail
out=.build/keyboard-history
export TEST_RUNNER_RITC_KEYBOARD_DIAGNOSTIC=1

if [[ "${1:-}" == collect ]]; then
  test -f "$out/invocation-started.json"
  # Fresh owned simulator: include the entire <=40m test step plus bounded collection.
  # This bound changes only log collection, never XCTest execution allowances.
  export_status=0
  xcrun simctl spawn "$SIMULATOR_ID" log show --last 55m --info --debug --style compact --timezone UTC \
    --predicate 'subsystem == "dev.roominthecart.keyboarddiagnostic"' \
    > "$out/events-export.log" 2> "$out/event-export.stderr" || export_status=$?
  printf '%s\n' "$export_status" > "$out/event-export-exit.txt"
  # Analysis records product/source freeze even when xcresult export is unavailable.
  analysis=0
  python3 diagnostics/keyboard-history/analyze.py > "$out/analysis.log" 2>&1 || analysis=$?
  printf '%s\n' "$analysis" > "$out/analysis-exit.txt"
  summary_status=0
  xcrun xcresulttool get test-results summary --path "$out/Tests.xcresult" --compact > "$out/test-summary.json" 2> "$out/summary-export.stderr" || summary_status=$?
  tests_status=0
  xcrun xcresulttool get test-results tests --path "$out/Tests.xcresult" --compact > "$out/test-details.json" 2> "$out/tests-export.stderr" || tests_status=$?
  printf '%s\n' "$summary_status" > "$out/summary-export-exit.txt"
  printf '%s\n' "$tests_status" > "$out/tests-export-exit.txt"
  strict=1
  if (( summary_status == 0 && tests_status == 0 )); then
    strict=0
    python3 scripts/check_ios_test_results.py --selectors "$out/selectors.txt" --expected-count 6 \
      --summary "$out/test-summary.json" --tests "$out/test-details.json" --result-bundle "$out/Tests.xcresult" \
      --test-log "$out/Tests.log" > "$out/strict.log" 2>&1 || strict=$?
  fi
  printf '%s\n' "$strict" > "$out/strict-exit.txt"
  if (( analysis != 0 || strict != 0 || export_status != 0 )); then exit 1; fi
  test -f "$out/xcodebuild-exit.txt" && test "$(cat "$out/xcodebuild-exit.txt")" = 0
  exit
fi

test "${1:-}" = execute
test ! -e "$out/invocation-started.json"
test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"
test_runs=(.build/DerivedData/Build/Products/RoomInTheCart_iphonesimulator*.xctestrun)
test "${#test_runs[@]}" -eq 1
test -f "${test_runs[0]}"
python3 diagnostics/keyboard-history/analyze.py --preflight
selectors=()
while IFS= read -r identifier; do selectors+=("-only-testing:$identifier"); done < "$out/selectors.txt"
test "${#selectors[@]}" -eq 6
python3 - <<'PY'
import datetime,json
from pathlib import Path
Path('.build/keyboard-history/invocation-started.json').write_text(json.dumps({'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'diagnosticOnly':True,'releaseAcceptance':False,'maximumXcodebuildInvocations':1})+'\n')
PY
xcrun simctl spawn "$SIMULATOR_ID" log stream --style compact --level debug \
  --predicate 'subsystem == "dev.roominthecart.keyboarddiagnostic"' \
  > "$out/events.log" 2> "$out/event-capture.stderr" &
capture_pid=$!
printf '%s\n' "$capture_pid" > "$out/capture-pid.txt"
finish_capture() {
  capture_alive=0
  kill -0 "$capture_pid" 2>/dev/null && capture_alive=1
  printf '%s\n' "$capture_alive" > "$out/capture-alive-before-stop.txt"
  kill "$capture_pid" 2>/dev/null || true
  wait "$capture_pid" 2>/dev/null || true
}
trap finish_capture EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
status=0
# Exactly one invocation; original quiescence, selectors, and720/900s limits.
xcodebuild -xctestrun "${test_runs[0]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -resultBundlePath "$out/Tests.xcresult" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 720 \
  -maximum-test-execution-time-allowance 900 -collect-test-diagnostics never \
  "${selectors[@]}" test-without-building 2>&1 | tee "$out/Tests.log" || status=$?
printf '%s\n' "$status" > "$out/xcodebuild-exit.txt"
exit "$status"
