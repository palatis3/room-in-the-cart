#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
results="$PWD/.build/native-wire-results"
mkdir -p "$results"
state="$(mktemp -d "${TMPDIR:-/tmp}/ritc-native-wire.XXXXXX")"
cleanup() {
  local status=$?
  if [[ -f "$state/postgres/postmaster.pid" ]]; then
    pg_ctl -D "$state/postgres" -m fast -w stop || status=1
  fi
  if [[ ! -f "$state/postgres/postmaster.pid" ]]; then
    rm -R -- "$state" || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export RITC_NATIVE_WIRE_STATE="$state"
export RITC_NATIVE_WIRE_SWIFT_BUILD="$state/swift"
{
  xcodebuild -version
  swift --version
  node --version
  postgres --version
  openssl version
  swift build --package-path ios/Packages/HouseholdClient --scratch-path "$RITC_NATIVE_WIRE_SWIFT_BUILD" \
    --jobs 2 --build-tests
} 2>&1 | tee "$results/swift-build.log"

port="$(node --input-type=module <<'JS'
import { createServer } from 'node:net';
const server = createServer();
server.listen(0, '127.0.0.1', () => {
  console.log(server.address().port);
  server.close();
});
JS
)"
printf '%s\n' 'fixture-only' > "$state/postgres-password"
initdb -D "$state/postgres" --username=postgres --pwfile="$state/postgres-password" \
  --auth=scram-sha-256 --locale=C --encoding=UTF8
pg_ctl -D "$state/postgres" -l "$results/postgres.log" -w start \
  -o "-h 127.0.0.1 -p $port -c unix_socket_directories="
PGPASSWORD=fixture-only createdb --host=127.0.0.1 --port="$port" --username=postgres ritc_native_wire
TMPDIR="$state" RITC_NATIVE_WIRE_PORT="$port" node service/scripts/test-native-wire.mjs 2>&1 | tee "$results/tests.tap"
