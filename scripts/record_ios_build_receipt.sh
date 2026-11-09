#!/bin/bash
set -eu

configuration=$1
profile=$2
source_sha=$(git rev-parse --verify HEAD)
evidence_dir=.build/ios-build-evidence
mkdir -p "$evidence_dir"
{
  printf 'source_sha=%s\n' "$source_sha"
  printf 'run_id=%s\n' "$GITHUB_RUN_ID"
  printf 'run_attempt=%s\n' "$GITHUB_RUN_ATTEMPT"
  printf 'configuration=%s\n' "$configuration"
  printf 'profile=%s\n' "$profile"
  printf 'developer_dir=%s\n' "$DEVELOPER_DIR"
  xcodebuild -version
} > "$evidence_dir/receipt.txt"
cat "$evidence_dir/receipt.txt"
