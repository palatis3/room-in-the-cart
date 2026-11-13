#!/bin/bash
set -euo pipefail

# Build Hub supplies workspace authentication. Never copy it into logs or
# repository secrets. Activation must be a separate step before xcodebuild:
# the CLI publishes its wrapper through GitHub's environment/path files.
: "${RUNNER_TEMP:?Run this on the Bitrise GitHub Actions runner}"
: "${GITHUB_ENV:?GitHub Actions environment file is required}"
: "${GITHUB_PATH:?GitHub Actions path file is required}"
test "$(uname -m)" = arm64
test "$(uname -s)" = Darwin

cache_cli_dir="$RUNNER_TEMP/ritc-bitrise-cache-cli"
mkdir -p "$cache_cli_dir"
archive=bitrise-build-cache_3.19.5_darwin_arm64.tar.gz
curl --fail --silent --show-error --location \
  --retry 3 --retry-max-time 90 --connect-timeout 10 --max-time 60 \
  "https://github.com/bitrise-io/bitrise-build-cache-cli/releases/download/v3.19.5/$archive" \
  --output "$cache_cli_dir/$archive"
(
  cd "$cache_cli_dir"
  echo "95f1c36a64b30f37d7d7527c9840d3c7ccea772e014b617a9f6b5c994558595a  $archive" \
    | shasum -a 256 --check
  tar -xzf "$archive" bitrise-build-cache
)
test "$("$cache_cli_dir/bitrise-build-cache" version)" = 3.19.5
"$cache_cli_dir/bitrise-build-cache" --no-update-check activate xcode --cache --cache-push
