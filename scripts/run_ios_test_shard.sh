#!/bin/bash
set -euo pipefail
: "${SIMULATOR_ID:?Select an iPhone simulator first}"
: "${TEST_SHARD:?Choose a shard from the build manifest}"
: "${EXPECTED_TEST_COUNT:?Use the count from the build matrix}"
selection=".build/test-plan/$TEST_SHARD.txt"
test -s "$selection"
test_runs=(.build/DerivedData/Build/Products/RoomInTheCart_iphonesimulator*.xctestrun)
test "${#test_runs[@]}" -eq 1
test -f "${test_runs[0]}"
selectors=()
while IFS= read -r identifier; do
    selectors+=("-only-testing:$identifier")
done < "$selection"
run_tests() {
    local bundle="$1" log="$2"
    xcodebuild -xctestrun "${test_runs[0]}" \
        -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
        -resultBundlePath "$bundle" -parallel-testing-enabled NO \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 720 \
        -maximum-test-execution-time-allowance 900 -collect-test-diagnostics never \
        "${selectors[@]}" test-without-building 2>&1 | tee "$log"
}
result=.build/Tests.xcresult
test_status=0
if ! run_tests "$result" .build/Tests.log; then
    # Retry only an infrastructure kill before any test has started.
    if ! grep -Fq 'Test crashed with signal kill before establishing connection.' .build/Tests.log ||
       grep -Eq '^Test Case .* started\.' .build/Tests.log; then
        test_status=1
    else
        xcrun simctl shutdown "$SIMULATOR_ID" || true
        xcrun simctl bootstatus "$SIMULATOR_ID" -b
        result=.build/Tests-retry.xcresult
        run_tests "$result" .build/Tests-retry.log || test_status=$?
    fi
fi
# Readable failed bundles are useful too. The raw result and logs are uploaded
# even if Xcode cannot export JSON after an infrastructure failure.
xcrun xcresulttool get test-results summary --path "$result" --compact > .build/test-summary.json
xcrun xcresulttool get test-results tests --path "$result" --compact > .build/test-details.json
python3 scripts/check_ios_test_results.py --selectors "$selection" --expected-count "$EXPECTED_TEST_COUNT" \
    --summary .build/test-summary.json --tests .build/test-details.json --result-bundle "$result"
exit "$test_status"
