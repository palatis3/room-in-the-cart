#!/bin/zsh
# Run from a checkout containing the accepted product and this probe.
set -eu -o pipefail
repo=$(git rev-parse --show-toplevel)
here=${0:A:h}
run=$(mktemp -d "${TMPDIR:-/tmp}/ritc-records-files.XXXXXXXX")
echo "Local artifacts: $run"
git -C "$repo" rev-parse HEAD > "$run/commit"
git -C "$repo" archive HEAD ios config shared scripts | tar -xf - -C "$run"
cd "$run"
cat "$here/RecordsFilesProbe.swift" >> ios/UITests/RoomInTheCartUITests.swift
xcrun swiftc ios/Packages/RecordArchive/Sources/RecordArchive/*.swift "$here/main.swift" -o make-files
device=$(xcrun simctl create "RITC Records Files $$" com.apple.CoreSimulator.SimDeviceType.iPhone-17e com.apple.CoreSimulator.SimRuntime.iOS-27-0)
observer=""
cleanup() {
    if [[ -n "$observer" ]]; then kill "$observer" 2>/dev/null || true; fi
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device"
}
trap cleanup EXIT
xcrun simctl bootstatus "$device" -b > boot.log
provider=$(xcrun simctl get_app_container "$device" com.apple.DocumentsApp groups |
    awk -F '\t' '$1=="group.com.apple.FileProvider.LocalStorage" {print $2}')
test -d "$provider"
downloads="$provider/File Provider Storage/Downloads"
mkdir -p "$downloads"
./make-files "$downloads"
xcrun simctl launch "$device" com.apple.DocumentsApp > files-launch.log
shasum -a 256 "$downloads"/N06-*.roomrecovery > fixture-hashes
selector=RoomInTheCartUITests/RoomInTheCartUITests/testRealFilesCancelCorruptAndReimportAfterRelaunch
echo "$selector" > selectors.txt
python3 "$here/check-storage.py" "$device" records.log storage.json &
observer=$!
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart -configuration Debug \
    -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO -jobs 2 -derivedDataPath DD \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -only-testing:"$selector" -resultBundlePath records.xcresult test >records.log 2>&1
wait "$observer"
observer=""
xcrun xcresulttool get test-results summary --compact --path records.xcresult > summary.json
xcrun xcresulttool get test-results tests --compact --path records.xcresult > tests.json
python3 scripts/check_ios_test_results.py --selectors selectors.txt --summary summary.json --tests tests.json \
    --result-bundle records.xcresult --test-log records.log --expected-count 1
