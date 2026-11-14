#!/bin/bash
set -euo pipefail

case "${1:-full}:$CIRCLE_NODE_TOTAL" in
    full:15)
        if ! [[ "$CIRCLE_NODE_INDEX" =~ ^([0-9]|1[0-4])$ ]]; then
            echo "Invalid parallel node: $CIRCLE_NODE_INDEX" >&2
            exit 2
        fi
        if [[ "$CIRCLE_NODE_INDEX" = 0 ]]; then
            TEST_SHARD=models
        else
            printf -v TEST_SHARD 'ui-%02d' "$CIRCLE_NODE_INDEX"
        fi
        ;;
    smoke:1) test "$CIRCLE_NODE_INDEX" = 0; TEST_SHARD=ui-14 ;;
    *) echo 'Expected 15 full nodes or one explicitly selected smoke node.' >&2; exit 2 ;;
esac
export TEST_SHARD
evidence=.build/circle-evidence
mkdir -p "$evidence" .build/DerivedData/Build
retain_results() {
    # CircleCI uploads a directory one file at a time. Keep each native
    # bundle together and preserve the original test command exit status.
    local status=$? bundle
    shopt -s nullglob
    for bundle in .build/Tests*.xcresult; do
        /usr/bin/ditto -c -k --keepParent "$bundle" "$evidence/$(basename "$bundle").zip" || status=1
    done
    for file in .build/Tests*.log .build/test-*.json; do
        mv "$file" "$evidence/" || status=1
    done
    exit "$status"
}
trap retain_results EXIT

SIMULATOR_ID=$(python3 scripts/circle_ios_simulator.py)
export SIMULATOR_ID
python3 scripts/boot_ios_simulator.py "$SIMULATOR_ID" > "$evidence/boot.log" 2>&1 &
boot_pid=$!
/usr/bin/compression_tool -decode -A lzfse -t 2 -i .build/circle-ios/products.tar.lzfse |
    tar -xf - -C .build/DerivedData/Build
mv .build/DerivedData/Build/test-plan .build/test-plan
jq -e --arg revision "$CIRCLE_SHA1" '.revision == $revision' .build/test-plan/producer.json > /dev/null
EXPECTED_TEST_COUNT=$(jq -er --arg shard "$TEST_SHARD" \
    '.include | select(length == 15) | map(select(.shard == $shard)) | select(length == 1)
     | .[0].expected_count | select(type == "number" and . > 0)' .build/test-plan/manifest.json)
export EXPECTED_TEST_COUNT
cp ".build/test-plan/$TEST_SHARD.txt" "$evidence/"
printf 'CircleCI node %s of %s: %s, %s tests\n' "$CIRCLE_NODE_INDEX" "$CIRCLE_NODE_TOTAL" "$TEST_SHARD" "$EXPECTED_TEST_COUNT"
wait "$boot_pid"
bash scripts/run_ios_test_shard.sh 2>&1 | tee "$evidence/validation.log"
