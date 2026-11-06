#!/bin/bash
set -euo pipefail
out=.build/keyboard-events
conditions=$(python3 scripts/plan_ios_fixture_tests.py conditions contributor)
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO -jobs 2 -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$conditions" build-for-testing 2>&1 | tee "$out/build.log"
test_runs=(.build/DerivedData/Build/Products/RoomInTheCart_iphonesimulator*.xctestrun)
test "${#test_runs[@]}" -eq 1
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild -xctestrun "${test_runs[0]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
  -test-enumeration-output-path "$PWD/$out/enumeration.json" test-without-building 2>&1 | tee "$out/enumeration.log"
python3 scripts/plan_ios_fixture_tests.py plan contributor --enumeration "$out/enumeration.json" --output-dir "$out/compiled-plan"
python3 - <<'PY'
import hashlib,json,sys
from pathlib import Path
sys.path.insert(0,'scripts')
from plan_ios_tests import selector as normalize_selector
out=Path('.build/keyboard-events');plan=json.loads((out/'compiled-plan/manifest.json').read_text())
selector='RoomInTheCartUITests/StockReviewUITests/testChangedMealRevisionDisablesPreviewWithoutApplyingBatch'
selected=[t for s in plan['shards'].values() for t in s['test_identifiers']]
assert [normalize_selector(x) for x in selected].count(selector)==1
(out/'selectors.txt').write_text(selector+'\n')
files={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in Path('.build/DerivedData/Build/Products').rglob('*') if p.is_file()}
assert files;(out/'product-sha256.json').write_text(json.dumps(files,indent=2)+'\n')
PY

# Keep the exact frozen binaries separately for later exact-product replay.
tar -czf "$RUNNER_TEMP/keyboard-diagnostic-products.tar.gz" -C .build/DerivedData/Build Products
shasum -a 256 "$RUNNER_TEMP/keyboard-diagnostic-products.tar.gz" > "$out/product-archive.sha256"
