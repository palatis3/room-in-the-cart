#!/bin/bash
set -euo pipefail
: "${SIMULATOR_ID:?Select an iPhone simulator first}"
: "${TEST_SHARD:?Choose a shard from the build manifest}"
: "${EXPECTED_TEST_COUNT:?Use the count from the build matrix}"
# Verbose system capture can add minutes to a simple local layout failure.
# Hosted/release evidence always keeps the original on-failure policy.
diagnostics="${LOCAL_TEST_DIAGNOSTICS:-on-failure}"
case "$diagnostics" in
    on-failure) ;;
    never)
        if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo 'LOCAL_TEST_DIAGNOSTICS=never is for local investigations only.' >&2
            exit 2
        fi ;;
    *) echo 'LOCAL_TEST_DIAGNOSTICS must be on-failure or never.' >&2; exit 2 ;;
esac
echo "XCTest verbose diagnostics: $diagnostics"
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
        -maximum-test-execution-time-allowance 900 -collect-test-diagnostics "$diagnostics" \
        "${selectors[@]}" test-without-building 2>&1 | tee "$log"
}
result=.build/Tests.xcresult
log=.build/Tests.log
test_status=0
if ! run_tests "$result" "$log"; then
    # Retry only an infrastructure kill before any test has started.
    if ! grep -Fq 'Test crashed with signal kill before establishing connection.' "$log" ||
       grep -Eq '^Test Case |^Restarting after unexpected exit, crash, or test timeout;' "$log"; then
        test_status=1
    else
        xcrun simctl shutdown "$SIMULATOR_ID" || true
        python3 scripts/boot_ios_simulator.py "$SIMULATOR_ID"
        result=.build/Tests-retry.xcresult
        log=.build/Tests-retry.log
        run_tests "$result" "$log" || test_status=$?
    fi
fi
# Readable failed bundles are useful too. The raw result and logs are uploaded
# even if Xcode cannot export JSON after an infrastructure failure.
xcrun xcresulttool get test-results summary --path "$result" --compact > .build/test-summary.json
xcrun xcresulttool get test-results tests --path "$result" --compact > .build/test-details.json
python3 scripts/check_ios_test_results.py --selectors "$selection" --expected-count "$EXPECTED_TEST_COUNT" \
    --summary .build/test-summary.json --tests .build/test-details.json --result-bundle "$result" --test-log "$log"
exit "$test_status"
