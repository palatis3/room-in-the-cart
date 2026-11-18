#!/bin/bash
set -euo pipefail
fail() { echo "$*" >&2; exit 2; }
lane=${1:?Select one reviewed native lane}
case "$lane" in
    compact-cooking) device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation; expected=3;;
    large-tonight) device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max; expected=2;;
    *) fail 'Unknown native lane';;
esac
case "${BITRISE_GIT_BRANCH:-}" in main|codex/dinner-shopping-integration) ;; *) fail 'Unreviewed branch';; esac
[[ -z ${BITRISE_PULL_REQUEST:-} && -z ${BITRISEIO_PULL_REQUEST_REPOSITORY_URL:-} ]] || fail 'No PR builds'
[[ ${BITRISE_GIT_COMMIT:-} =~ ^[0-9a-f]{40}$ ]] || fail 'Require exact event commit'
[[ $(git rev-parse HEAD) == "$BITRISE_GIT_COMMIT" ]] || fail 'Source commit differs from event'
[[ -z $(git status --porcelain --untracked-files=no) ]] || fail 'Tracked checkout changed'
[[ $(uname -m) == arm64 ]] || fail 'Require Apple Silicon'
for developer in "$(xcode-select -p)" /Applications/Xcode*.app/Contents/Developer; do
    if [[ "$(DEVELOPER_DIR="$developer" xcodebuild -version 2>/dev/null)" == $'Xcode 27.1\nBuild version 27A9275' ]]; then
        export DEVELOPER_DIR="$developer"
        break
    fi
done
[[ $(xcodebuild -version) == $'Xcode 27.1\nBuild version 27A9275' ]] || fail 'Require Xcode 27.1 (27A9275)'
export CI=true TEST_SHARD="$lane" EXPECTED_TEST_COUNT="$expected"
mkdir -p .build/test-plan
cp "scripts/fixtures/bitrise-native/$lane.txt" ".build/test-plan/$lane.txt"
python3 scripts/generate_xcode_project.py --check
xcrun simctl list runtimes --json > .build/native-runtimes.json
python3 - <<'PY'
import json
rows = json.load(open('.build/native-runtimes.json'))['runtimes']
matching = [r for r in rows if r.get('identifier') == 'com.apple.CoreSimulator.SimRuntime.iOS-27-0']
assert len(matching) == 1 and matching[0].get('isAvailable') is True, 'Missing required iOS 27 runtime'
assert matching[0].get('buildversion') == '24A434', 'Unexpected iOS 27 runtime build'
PY
{
    printf 'Source %s\nLane %s\nDevice %s\nConfiguration Debug\nExpected %s\n' "$BITRISE_GIT_COMMIT" "$lane" "$device_type" "$expected"
    xcodebuild -version
    cat ".build/test-plan/$lane.txt"
    shasum -a 256 bitrise.yml scripts/run_bitrise_native_app.sh ".build/test-plan/$lane.txt"
} | tee .build/bitrise-native-receipt.txt
# Own only this device; no runtime installs, global simulator cleanup or sudo.
device=$(xcrun simctl create "RITC native $lane ${BITRISE_BUILD_SLUG:?}" "$device_type" com.apple.CoreSimulator.SimRuntime.iOS-27-0)
export SIMULATOR_ID="$device"
trap 'xcrun simctl delete "$device" || true' EXIT
flags=()
while IFS= read -r method; do flags+=("-only-testing:$method"); done < ".build/test-plan/$lane.txt"
# Compilation targets arm64 simulator products and can start while the owned iPhone boots.
python3 scripts/boot_ios_simulator.py "$device" > .build/NativeBoot.log 2>&1 &
boot_pid=$!
build_status=0
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData \
    "${flags[@]}" -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- build-for-testing 2>&1 | tee .build/NativeBuild.log || build_status=$?
boot_status=0
wait "$boot_pid" || boot_status=$?
cat .build/NativeBoot.log
if ((build_status)); then exit "$build_status"; fi
if ((boot_status)); then exit "$boot_status"; fi
python3 scripts/check_built_app.py .build/DerivedData/Build/Products/Debug-iphonesimulator/RoomInTheCart.app --configuration Debug
bash scripts/run_ios_test_shard.sh
