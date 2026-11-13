#!/bin/bash
set -euo pipefail
# The hosted label rolls; never silently use its next default Xcode.
test "${DEVELOPER_DIR:-}" = /Applications/Xcode_27.1.app/Contents/Developer
test "$(uname -m)" = arm64
actual="$(xcodebuild -version)"
printf '%s\n' "$actual"
test "$actual" = $'Xcode 27.1\nBuild version 27A9275'
