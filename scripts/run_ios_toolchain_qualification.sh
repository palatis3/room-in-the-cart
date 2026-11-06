#!/bin/bash
set -euo pipefail
out=.build/toolchain-qualification
products=.build/DerivedData/Build/Products
helper=scripts/qualify_ios_toolchain.py
case "${1:?Choose build-debug, build-release, inventory, package, restore, or run}" in
build-debug|build-release)
    simulator=$(python3 "$helper" verify-runtime build)
    configuration=Debug
    scheme=RoomInTheCart
    if [[ "$1" == build-release ]]; then
        configuration=Release
        scheme=RoomInTheCart-Performance
    fi
    build=(xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme "$scheme"
        -configuration "$configuration" -destination "platform=iOS Simulator,id=$simulator"
        -parallel-testing-enabled NO -jobs 2 -derivedDataPath .build/DerivedData)
    if [[ "$1" == build-release ]]; then
        build+=(-enableCodeCoverage NO -enableAddressSanitizer NO -enableThreadSanitizer NO -enableUndefinedBehaviorSanitizer NO)
    fi
    build+=(CODE_SIGN_IDENTITY=- build-for-testing)
    "${build[@]}" 2>&1 | tee "$out/$configuration-build.log"
    python3 scripts/check_built_app.py "$products/$configuration-iphonesimulator/RoomInTheCart.app" --configuration "$configuration"
    ;;
inventory)
    simulator=$(python3 "$helper" verify-runtime build)
    runs=("$products"/RoomInTheCart_iphonesimulator*.xctestrun)
    test "${#runs[@]}" -eq 1 && test -f "${runs[0]}"
    # One full enumeration only. Install the known Debug host up front; no retry/recovery branch.
    xcrun simctl install "$simulator" "$products/Debug-iphonesimulator/RoomInTheCart.app"
    xcodebuild -xctestrun "${runs[0]}" -destination "platform=iOS Simulator,id=$simulator" \
        -parallel-testing-enabled NO -enumerate-tests -test-enumeration-style flat \
        -test-enumeration-format json -test-enumeration-output-path "$PWD/$out/debug-enumeration.json" \
        test-without-building 2>&1 | tee "$out/enumeration.log"
    python3 "$helper" inventory
    executable="$products/Release-iphonesimulator/RoomInTheCartUITests-Runner.app/PlugIns/RoomInTheCartUITests.xctest/RoomInTheCartUITests"
    python3 scripts/plan_ios_performance_tests.py "$executable" > "$out/release-inventory.json"
    python3 "$helper" freeze
    ;;
package)
    python3 "$helper" frozen
    tar -czf "$RUNNER_TEMP/qualification-products.tar.gz" -C .build/DerivedData/Build Products
    tar -czf "$RUNNER_TEMP/qualification-inputs.tar.gz" -C "$out" \
        frozen.json debug-inventory-proof.json debug-enumeration.json release-inventory.json
    ;;
restore)
    mkdir -p .build/DerivedData/Build "$out"
    tar -xzf "$RUNNER_TEMP/qualification-products.tar.gz" -C .build/DerivedData/Build
    tar -xzf "$RUNNER_TEMP/qualification-inputs.tar.gz" -C "$out"
    python3 "$helper" frozen
    ;;
run)
    name=${2:?Choose fixed case}
    case "$name" in
        ui06) count=5; allowance=720; maximum=900; scheme=RoomInTheCart; bundle=dev.roominthecart.app.debug ;;
        spanish) count=4; allowance=720; maximum=900; scheme=RoomInTheCart; bundle=dev.roominthecart.app.debug ;;
        scroll) count=1; allowance=900; maximum=1200; scheme=RoomInTheCart-Performance; bundle=dev.roominthecart.app ;;
        *) exit 2 ;;
    esac
    directory="$out/$name"
    python3 "$helper" frozen
    simulator=$(python3 "$helper" preflight "$name")
    if xcrun simctl get_app_container "$simulator" "$bundle" app >/dev/null 2>&1; then
        echo 'Fresh owned simulator unexpectedly contains the test app' >&2
        exit 1
    fi
    if [[ "$name" == scroll ]]; then
        xcrun simctl pbcopy "$simulator" < ios/UITests/Fixtures/ReleaseLedger500.txt
    fi
    runs=("$products"/"${scheme}"_iphonesimulator*.xctestrun)
    test "${#runs[@]}" -eq 1 && test -f "${runs[0]}"
    selectors=()
    while IFS= read -r identifier; do selectors+=("-only-testing:$identifier"); done < "$directory/selectors.txt"
    # Atomic marker prevents any second invocation in the same artifact directory.
    (set -o noclobber; printf '%s\n' "${selectors[@]}" > "$directory/invocation.txt")
    status=0
    xcodebuild -xctestrun "${runs[0]}" -destination "platform=iOS Simulator,id=$simulator" \
        -parallel-testing-enabled NO -test-timeouts-enabled YES \
        -default-test-execution-time-allowance "$allowance" -maximum-test-execution-time-allowance "$maximum" \
        -resultBundlePath "$directory/Tests.xcresult" -collect-test-diagnostics never \
        "${selectors[@]}" test-without-building 2>&1 | tee "$directory/Tests.log" || status=$?
    printf '%s\n' "$status" > "$directory/xcodebuild-exit.txt"
    # Preserve independently useful exports even when another export/check fails.
    validation=0
    exports=(summary tests)
    if [[ "$name" == scroll ]]; then exports+=(metrics); fi
    for kind in "${exports[@]}"; do
        case "$kind" in summary) file=test-summary;; tests) file=test-details;; metrics) file=metrics;; esac
        xcrun xcresulttool get test-results "$kind" --path "$directory/Tests.xcresult" --compact \
            > "$directory/$file.json" || validation=1
    done
    xcrun xcresulttool export attachments --path "$directory/Tests.xcresult" \
        --output-path "$directory/attachments" || validation=1
    if [[ "$name" == scroll ]]; then
        xcrun xcresulttool export metrics --path "$directory/Tests.xcresult" \
            --output-path "$directory/metrics-csv" || validation=1
    fi
    python3 scripts/check_ios_test_results.py --selectors "$directory/selectors.txt" --expected-count "$count" \
        --summary "$directory/test-summary.json" --tests "$directory/test-details.json" \
        --result-bundle "$directory/Tests.xcresult" --test-log "$directory/Tests.log" \
        > "$directory/strict-check.log" 2>&1 || validation=1
    cat "$directory/strict-check.log"
    if [[ "$name" == scroll ]]; then
        # Exact existing calibration path: required metrics/cardinality/finite checks and SQLite readback.
        # No --baseline: new environment is UNAPPROVED and cannot satisfy release acceptance.
        if container=$(xcrun simctl get_app_container "$simulator" "$bundle" data); then
            python3 scripts/check_ios_performance.py scroll --evidence "$directory" \
                --fixture ios/UITests/Fixtures/ReleaseLedger500.txt \
                --store "$container/Library/Application Support/RoomInTheCart/ledger.sqlite" \
                > "$directory/structural-calibration.log" 2>&1 || validation=1
            cat "$directory/structural-calibration.log"
        else
            validation=1
        fi
    fi
    # Only issue a completion report after every export and existing strict gate succeeded.
    python3 "$helper" frozen || validation=1
    if [[ "$status" -eq 0 && "$validation" -eq 0 ]]; then
        python3 "$helper" finish "$name"
    else
        exit 1
    fi
    ;;
*) exit 2 ;;
esac
