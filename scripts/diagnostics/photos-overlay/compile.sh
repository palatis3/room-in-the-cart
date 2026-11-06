#!/bin/bash
set -euo pipefail
args=(
  -c "$EVIDENCE/source/PhotoProbe.swift" -o "$VARIANT_DIR/PhotoProbe.o"
  -module-name PhotoProbe -target arm64-apple-ios17.0
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -swift-version 5
  -Onone -D RELEASE -whole-module-optimization
  -module-cache-path "$VARIANT_DIR/module-cache"
)
if [[ "$VARIANT" == enabled ]]; then args+=(-Xfrontend -enable-cross-import-overlays); fi
printf '%q ' xcrun swiftc "${args[@]}" > "$VARIANT_DIR/apple-command.txt"
printf '\n' >> "$VARIANT_DIR/apple-command.txt"
xcrun swiftc "${args[@]}"
