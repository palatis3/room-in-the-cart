#!/bin/bash
set -euo pipefail
: "${SIMULATOR_ID:?Use a dedicated diagnostic simulator}"
: "${EVIDENCE:?Use a dedicated evidence directory}"
: "${PRODUCTS:?Use the frozen diagnostic products}"
mkdir -p "$EVIDENCE"
runs=("$PRODUCTS"/FormToggleDiagnostic_iphonesimulator*.xctestrun)
test "${#runs[@]}" -eq 1
test -f "${runs[0]}"
selector=FormToggleDiagnosticUITests/FormToggleDiagnosticUITests/testOneTapAfterInputDoneAndScroll
printf '%s\n' "$selector" > "$EVIDENCE/selectors.txt"
test_exit=0
xcodebuild -xctestrun "${runs[0]}" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -resultBundlePath "$EVIDENCE/Tests.xcresult" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 720 \
  -maximum-test-execution-time-allowance 900 -collect-test-diagnostics never \
  "-only-testing:$selector" test-without-building > "$EVIDENCE/Tests.log" 2>&1 || test_exit=$?
printf '%s\n' "$test_exit" > "$EVIDENCE/xcode-status.txt"
export_exit=0
xcrun xcresulttool get test-results summary --path "$EVIDENCE/Tests.xcresult" --compact > "$EVIDENCE/test-summary.json" || export_exit=$?
xcrun xcresulttool get test-results tests --path "$EVIDENCE/Tests.xcresult" --compact > "$EVIDENCE/test-details.json" || export_exit=$?
# Export even failed attempts. There is no retry and no failed-to-pass conversion.
xcrun xcresulttool export attachments --path "$EVIDENCE/Tests.xcresult" --output-path "$EVIDENCE/attachments" || export_exit=$?
printf '%s\n' "$export_exit" > "$EVIDENCE/export-status.txt"
if (( export_exit != 0 )); then
  printf '%s\n' 'unavailable: xcresult export failed' > "$EVIDENCE/guard-status.txt"
  printf '%s\n' '{"status":"unavailable","reason":"xcresult export failed"}' > "$EVIDENCE/capture-verification.json"
  exit 1
fi
guard_exit=0
python3 scripts/check_ios_test_results.py --selectors "$EVIDENCE/selectors.txt" --expected-count 1 \
  --summary "$EVIDENCE/test-summary.json" --tests "$EVIDENCE/test-details.json" \
  --result-bundle "$EVIDENCE/Tests.xcresult" --test-log "$EVIDENCE/Tests.log" \
  > "$EVIDENCE/verification.txt" 2>&1 || guard_exit=$?
printf '%s\n' "$guard_exit" > "$EVIDENCE/guard-status.txt"
cat "$EVIDENCE/verification.txt"
capture_exit=0
python3 diagnostics/swiftui-toggle/verify-captures.py "$EVIDENCE/attachments" \
  > "$EVIDENCE/capture-verification.json" || capture_exit=$?
test "$test_exit" -eq 0 && test "$guard_exit" -eq 0 && test "$capture_exit" -eq 0
