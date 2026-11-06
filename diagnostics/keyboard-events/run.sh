#!/bin/bash
set -euo pipefail
out=.build/keyboard-events
export TEST_RUNNER_RITC_KEYBOARD_DIAGNOSTIC=1
test_runs=(.build/DerivedData/Build/Products/RoomInTheCart_iphonesimulator*.xctestrun)
test "${#test_runs[@]}" -eq 1
selector=$(cat "$out/selectors.txt")
# No retries or changes to XCTest's existing idleness and 720/900-second limits.
xcrun simctl spawn "$SIMULATOR_ID" log stream --style compact --level debug \
  --predicate 'subsystem == "dev.roominthecart.keyboarddiagnostic"' \
  > "$out/events.log" 2> "$out/event-capture.stderr" &
capture_pid=$!
finish_capture() {
  kill "$capture_pid" 2>/dev/null || true
  wait "$capture_pid" 2>/dev/null || true
}
trap finish_capture EXIT
status=0
xcodebuild -xctestrun "${test_runs[0]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -resultBundlePath "$out/Tests.xcresult" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 720 \
  -maximum-test-execution-time-allowance 900 -collect-test-diagnostics never \
  "-only-testing:$selector" test-without-building 2>&1 | tee "$out/Tests.log" || status=$?
capture_alive=0
kill -0 "$capture_pid" 2>/dev/null && capture_alive=1
printf '%s\n' "$capture_alive" > "$out/capture-alive-before-stop.txt"
finish_capture
trap - EXIT
# Reconcile persisted events independently after the stream has stopped.
# The simulator is fresh and this is the only diagnostic-enabled app run.
export_status=0
xcrun simctl spawn "$SIMULATOR_ID" log show --last 25m --info --debug --style compact --timezone UTC \
  --predicate 'subsystem == "dev.roominthecart.keyboarddiagnostic"' \
  > "$out/events-export.log" 2> "$out/event-export.stderr" || export_status=$?
printf '%s\n' "$export_status" > "$out/event-export-exit.txt"
printf '%s\n' "$status" > "$out/xcodebuild-exit.txt"
python3 - <<'PY'
import hashlib,json
from pathlib import Path
out=Path('.build/keyboard-events')
for name in ['source-sha256.json','product-sha256.json']:
 expected=json.loads((out/name).read_text())
 assert all(Path(p).is_file() and hashlib.sha256(Path(p).read_bytes()).hexdigest()==digest for p,digest in expected.items()),name
(out/'frozen-inputs-unchanged.json').write_text(json.dumps({'source':True,'products':True,'diagnosticOnly':True})+'\n')
PY
xcrun xcresulttool get test-results summary --path "$out/Tests.xcresult" --compact > "$out/test-summary.json"
xcrun xcresulttool get test-results tests --path "$out/Tests.xcresult" --compact > "$out/test-details.json"
strict=0
python3 scripts/check_ios_test_results.py --selectors "$out/selectors.txt" --expected-count 1 \
  --summary "$out/test-summary.json" --tests "$out/test-details.json" --result-bundle "$out/Tests.xcresult" --test-log "$out/Tests.log" > "$out/strict.log" 2>&1 || strict=$?
printf '%s\n' "$strict" > "$out/strict-exit.txt"
# Even a passing XCTest is inconclusive if the diagnostic stream is absent.
if (( capture_alive != 1 )) || ! grep -q 'event=observer.installed' "$out/events.log"; then
  printf '%s\n' 'Diagnostic event stream was not captured.' > "$out/capture-incomplete.txt"
  exit 1
fi
if (( status != 0 || strict != 0 )); then exit 1; fi
