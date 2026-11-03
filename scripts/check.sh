#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v node >/dev/null 2>&1 && [ -d .tools/node-v22.14.0-darwin-arm64/bin ]; then
  export PATH="$PWD/.tools/node-v22.14.0-darwin-arm64/bin:$PATH"
fi
python3 scripts/generate_theme.py --check
python3 scripts/check_localization.py
python3 scripts/test_check_localization.py
python3 scripts/generate_xcode_project.py --check
for manifest in ios/Packages/*/Package.swift; do
  swift test --package-path "$(dirname "$manifest")"
done
npm --prefix web ci --ignore-scripts
npm --prefix web test
npm --prefix service ci --ignore-scripts
npm --prefix service test
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData CODE_SIGN_IDENTITY=- build
python3 scripts/check_built_app.py .build/DerivedData/Build/Products/Debug-iphonesimulator/RoomInTheCart.app --configuration Debug
if [ "${RUN_UI_TESTS:-0}" = "1" ]; then
  : "${IOS_SIMULATOR_DESTINATION:?Set IOS_SIMULATOR_DESTINATION, e.g. platform=iOS Simulator,id=<device UUID>}"
  result_bundle="${TEST_RESULT_BUNDLE:-.build/UITests-$(date +%Y%m%d-%H%M%S).xcresult}"
  xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart \
    -configuration Debug -destination "$IOS_SIMULATOR_DESTINATION" \
    -derivedDataPath .build/DerivedData -resultBundlePath "$result_bundle" -collect-test-diagnostics never \
    CODE_SIGN_IDENTITY=- test
fi
