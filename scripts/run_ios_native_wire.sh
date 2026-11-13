#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077
results_root="$PWD/.build/native-wire-results"
mkdir -p "$results_root"
results="$(mktemp -d "$results_root/attempt.XXXXXX")"
printf 'Native wire public evidence: %s\n' "$results"
# Refuse an inherited temporary root inside the public artifact tree.
python3 - "$results_root" "${TMPDIR:-/tmp}" <<'PYPRIVATE'
from pathlib import Path
import sys
public, temporary = map(lambda s: Path(s).resolve(), sys.argv[1:])
if temporary == public or public in temporary.parents:
    raise SystemExit('Native wire private temporary root must be outside public results.')
PYPRIVATE
state="$(mktemp -d "${TMPDIR:-/tmp}/ritc-native-wire.${results##*/}.XXXXXX")"
cleanup() {
  local status=$? stopped=true retained=true
  if [[ -f "$state/postgres/postmaster.pid" ]]; then
    pg_ctl -D "$state/postgres" -m fast -w stop || status=1
  fi
  if [[ -f "$state/postgres/postmaster.pid" ]]; then
    stopped=false
    status=1
  fi
  if [[ "$status" -eq 0 ]]; then
    if rm -R -- "$state"; then retained=false; else status=1; fi
  fi
  # Private state is never copied into the uploaded results tree. On ephemeral
  # CI runners its retention ends with the runner; this is not a durable backup.
  python3 - "$results" "$state" "$status" "$stopped" "$retained" <<'PYRECEIPT' || status=1
import json, os, pathlib, sys
results, state = map(pathlib.Path, sys.argv[1:3])
receipt = dict(schemaVersion=1, attempt=results.name, exitCode=int(sys.argv[3]),
               postgresStopped=sys.argv[4]=='true', privateStateRetained=sys.argv[5]=='true',
               retention='Private state is local only; ephemeral CI runner teardown removes it. No private state is uploaded.')
if receipt['privateStateRetained'] and state.is_dir():
    os.chmod(state, 0o700)
    (state/'custody.json').write_text(json.dumps(dict(receipt, statePath=str(state), resultsPath=str(results)), indent=2)+'\n')
(results/'cleanup.json').write_text(json.dumps(receipt, indent=2)+'\n')
PYRECEIPT
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export RITC_NATIVE_WIRE_STATE="$state"
export RITC_NATIVE_WIRE_RESULTS="$results"
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
pg_ctl -D "$state/postgres" -l "$state/postgres.log" -w start \
  -o "-h 127.0.0.1 -p $port -c unix_socket_directories="
PGPASSWORD=fixture-only createdb --host=127.0.0.1 --port="$port" --username=postgres ritc_native_wire
TMPDIR="$state" RITC_NATIVE_WIRE_PORT="$port" node service/scripts/test-native-wire.mjs 2>&1 | tee "$results/tests.tap"
