#!/bin/bash
set -euo pipefail

mkdir -p .build/circle-ios .build/circle-evidence
simulator=$(python3 scripts/circle_ios_simulator.py)
cat .build/circle-evidence/environment.json
# Start CoreSimulator while Xcode builds. Discovery independently verifies boot.
python3 scripts/boot_ios_simulator.py "$simulator" > .build/circle-evidence/boot.log 2>&1 &
boot_pid=$!
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
    -derivedDataPath .build/DerivedData CODE_SIGN_IDENTITY=- \
    COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES \
    COMPILATION_CACHE_CAS_PATH="$PWD/.build/circle-xcode-cas" build-for-testing \
    2>&1 | tee .build/circle-evidence/build.log
wait "$boot_pid"
python3 scripts/check_built_app.py \
    .build/DerivedData/Build/Products/Debug-iphonesimulator/RoomInTheCart.app --configuration Debug
python3 scripts/discover_ios_tests.py --simulator "$simulator"
# The default GitHub plan has ten UI shards. Repartition the same live
# inventory for the fourteen CircleCI UI nodes plus the one model node.
python3 scripts/plan_ios_tests.py --enumeration .build/test-plan/test-enumeration.json \
    --output-dir .build/test-plan --ui-shards 14
cp .build/circle-evidence/environment.json .build/test-plan/producer.json
jq '.include' .build/test-plan/manifest.json
bash scripts/package_ios_simulator_tests.sh "$PWD/.build/circle-ios/products.tar.lzfse"
