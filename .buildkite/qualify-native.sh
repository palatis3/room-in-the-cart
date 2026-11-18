#!/bin/bash
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }
: "${RITC_CANDIDATE_BRANCH:?Supply the candidate branch in this repository}"
: "${RITC_CANDIDATE_SHA:?Supply its full commit SHA}"

case "${BUILDKITE_SOURCE:-}" in ui|api) ;; *) fail "Manual Buildkite builds only";; esac
[[ ${BUILDKITE_PULL_REQUEST:-false} == false ]] || fail "Pull-request builds are disabled"
case "${BUILDKITE_BRANCH:-}" in main|codex/buildkite-native-qualification) ;; *) fail "Select the qualification pipeline branch";; esac
git check-ref-format "refs/heads/$RITC_CANDIDATE_BRANCH" || fail "Invalid candidate branch"
[[ "$RITC_CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "Expected a full lowercase commit SHA"
# The build form accepts one KEY=value per line. A list is space separated;
# Xcode receives each validated selector as its own argument.
if [[ -n ${RITC_TEST_IDS:-} ]]; then
    [[ -z ${RITC_TEST_ID:-} ]] || fail "Choose RITC_TEST_IDS or RITC_TEST_ID"
    [[ "$RITC_TEST_IDS" != *$'\n'* ]] || fail "Put the selectors on one line"
    IFS=' ' read -r -a methods <<< "$RITC_TEST_IDS"
    expected=${RITC_TEST_COUNT:?Supply the number of selected methods}
else
    methods=("${RITC_TEST_ID:?Supply one method or a manifest in RITC_TEST_IDS}")
    expected=${RITC_TEST_COUNT:-1}
fi
[[ "$expected" =~ ^[1-8]$ ]] || fail "Choose one to eight methods"
[[ "$expected" == "${#methods[@]}" ]] || fail "RITC_TEST_COUNT must match the number of selectors"
selector_pattern='^RoomInTheCart(UI)?Tests/[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+$'
seen=' '
flags=()
for method in "${methods[@]}"; do
    [[ "$method" =~ $selector_pattern ]] || fail "Select exact app or UI test methods"
    [[ "$seen" != *" $method "* ]] || fail "Duplicate selector: $method"
    seen+="$method "
    flags+=("-only-testing:$method")
done

controller=$(git rev-parse HEAD)
# Fetch only a branch of the public first-party repository, without a CI Git credential.
git -c credential.helper= fetch --quiet --no-tags --depth=1 https://github.com/palatis3/room-in-the-cart.git "refs/heads/$RITC_CANDIDATE_BRANCH"
[[ $(git rev-parse FETCH_HEAD) == "$RITC_CANDIDATE_SHA" ]] || fail "The branch tip differs from the reviewed SHA"
git switch --quiet --detach "$RITC_CANDIDATE_SHA"

# Hosted images use different Xcode application names. Match the reviewed version by value.
for developer in "$(xcode-select -p)" /Applications/Xcode*.app/Contents/Developer; do
    if [[ "$(DEVELOPER_DIR="$developer" xcodebuild -version 2>/dev/null)" == $'Xcode 27.1\nBuild version 27A9275' ]]; then
        export DEVELOPER_DIR="$developer"
        break
    fi
done
[[ $(uname -m) == arm64 && "$(xcodebuild -version)" == $'Xcode 27.1\nBuild version 27A9275' ]] || fail "Select the Xcode 27.1 (27A9275) hosted image"

export TEST_SHARD=qualification EXPECTED_TEST_COUNT="$expected"
runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0
mkdir -p .build/test-plan
printf '%s\n' "${methods[@]}" > .build/test-plan/qualification.txt
{
    printf 'Control SHA %s\nCandidate %s at %s\nRuntime %s\nExpected tests %s\n' "$controller" "$RITC_CANDIDATE_BRANCH" "$RITC_CANDIDATE_SHA" "$runtime" "$expected"
    printf 'Selector %s\n' "${methods[@]}"
    xcodebuild -version
} | tee .build/qualification.txt

device=$(xcrun simctl create "RITC qualification ${BUILDKITE_JOB_ID:?}" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")
export SIMULATOR_ID="$device"
trap 'xcrun simctl delete "$device" || true' EXIT
python3 scripts/boot_ios_simulator.py "$device" &
boot=$!
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart -configuration Debug \
    -destination "platform=iOS Simulator,id=$device" -derivedDataPath .build/DerivedData \
    "${flags[@]}" -jobs 6 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- build-for-testing
python3 scripts/check_built_app.py .build/DerivedData/Build/Products/Debug-iphonesimulator/RoomInTheCart.app --configuration Debug
wait "$boot"
bash scripts/run_ios_test_shard.sh
