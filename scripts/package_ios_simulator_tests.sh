#!/bin/bash
# Preserve all runtime bundles and symbols. Only top-level compiler outputs are redundant
# when consumers run the already-linked app and test targets.
set -eo pipefail
archive=${1:?Pass the absolute output archive path}
plan_dir="$PWD/.build"
cd "$plan_dir/DerivedData/Build"
exclusions=()
shopt -s nullglob
for compiler_product in Products/Debug-iphonesimulator/*.o Products/Debug-iphonesimulator/*.swiftmodule; do
    exclusions+=(--exclude "$compiler_product")
done
tar -cf - "${exclusions[@]}" Products -C "$plan_dir" test-plan |
    /usr/bin/compression_tool -encode -A lzfse -t 2 -o "$archive"
