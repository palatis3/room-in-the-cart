#!/bin/bash
set -euo pipefail
out=.build/spanish-done
products=.build/spanish-done-products/Build/Products
python3 diagnostics/spanish-done/run.py verify-runtime
simulator=$(python3 -c 'import json; print(json.load(open(".build/spanish-done/identity.json"))["simulatorID"])')
# Original core Debug scheme: no fixture conditions or test-source substitutions.
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
  -jobs 2 -derivedDataPath .build/spanish-done-products CODE_SIGN_IDENTITY=- \
  build-for-testing 2>&1 | tee "$out/build.log"
test_runs=("$products"/RoomInTheCart_iphonesimulator*.xctestrun)
test "${#test_runs[@]}" -eq 1
test -f "${test_runs[0]}"
xcodebuild -xctestrun "${test_runs[0]}" -destination "platform=iOS Simulator,id=$simulator" \
  -parallel-testing-enabled NO -enumerate-tests -test-enumeration-style flat \
  -test-enumeration-format json -test-enumeration-output-path "$PWD/$out/enumeration.json" \
  test-without-building 2>&1 | tee "$out/enumeration.log"
python3 diagnostics/spanish-done/run.py freeze
tar -czf "$out/products.tar.gz" -C .build/spanish-done-products/Build Products
shasum -a 256 "$out/products.tar.gz" > "$out/products.tar.gz.sha256"
