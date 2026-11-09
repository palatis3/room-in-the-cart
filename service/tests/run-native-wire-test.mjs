import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const run = promisify(execFile);
const packagePath = fileURLToPath(new URL('../../ios/Packages/HouseholdClient', import.meta.url));
export const nativeWirePassPrefix = 'Native wire XCTest passed ';

// The subprocess bound remains 2 MB per stream. Persist only those streams,
// never its environment, credentials, private fixture tree or execFile error dump.
async function retainOutput(root, scenario, selector, stdout, stderr, status, failure = null) {
  if (!root) return; // Direct integration invocations predate the evidence wrapper.
  assert.match(scenario, /^[a-z0-9-]+$/);
  const directory = await mkdtemp(join(root, `scenario-${scenario}-`));
  const receipt = { schemaVersion: 1, scenario, selector, status, failure, outputMayBeIncomplete: status !== 'passed', streams: {} };
  for (const [name, value] of Object.entries({ stdout, stderr })) {
    const bytes = Buffer.from(value ?? '');
    const retained = bytes.subarray(0, 2_000_000);
    await writeFile(join(directory, `${name}.log`), retained, { mode: 0o600, flag: 'wx' });
    receipt.streams[name] = { bytes: retained.length, sha256: createHash('sha256').update(retained).digest('hex'), truncated: bytes.length > retained.length };
  }
  await writeFile(join(directory, 'receipt.json'), JSON.stringify(receipt, null, 2)+'\n', { mode: 0o600, flag: 'wx' });
}

export async function runNativeWireTest({ suite, method, scenario, env, unsuccessful }, execute = run) {
  const selector = `HouseholdClientTests.${suite}/${method}`;
  const args = ['test', '--package-path', packagePath, '--jobs', '2',
    '--filter', `^HouseholdClientTests\\.${suite}/${method}$`];
  if (process.env.RITC_NATIVE_WIRE_SWIFT_BUILD) {
    args.push('--scratch-path', process.env.RITC_NATIVE_WIRE_SWIFT_BUILD, '--skip-build');
  }
  let stdout, stderr, failure;
  try {
    ({ stdout, stderr } = await execute('swift', args, {
      env: { ...process.env, ...env },
      timeout: 180000,
      maxBuffer: 2_000_000,
    }));
    const terminal = stdout.split(/\r?\n/).filter(line => /^Test Case .* (passed|failed|skipped) \(/.test(line));
    if (terminal.length !== 1) {
      throw Object.assign(new Error('Expected one XCTest terminal result'),
        { code: 'WIRE_TERMINAL_COUNT', terminalCount: terminal.length });
    }
    if (!terminal[0].startsWith(`Test Case '-[HouseholdClientTests.${suite} ${method}]' passed (`)) {
      throw Object.assign(new Error('Expected the exact selected XCTest to pass'), { code: 'WIRE_TERMINAL_MISMATCH' });
    }
  } catch (error) {
    stdout ??= error.stdout;
    stderr ??= error.stderr;
    failure = failureDetails(error);
  }
  let evidenceFailure;
  try {
    await retainOutput(process.env.RITC_NATIVE_WIRE_RESULTS, scenario, selector, stdout, stderr,
      failure ? 'failed' : 'passed', failure);
  } catch (error) {
    evidenceFailure = safeCode(error.code);
  }
  if (failure || evidenceFailure) {
    const primary = failure ?? { code: 'WIRE_EVIDENCE_WRITE', reason: 'Could not retain scenario evidence' };
    const output = [stdout, stderr].filter(Boolean).join('\n');
    // Do not serialize execFile's error, cause or environment: its message may
    // duplicate the entire output. A custody failure must not replace native failure.
    throw Object.assign(new Error(`${scenario}: ${primary.reason} (${primary.code}).` +
      (evidenceFailure ? ` Evidence write also failed (${evidenceFailure}).` : '') +
      `\n${output.slice(-3500)}\nAPI responses: ${unsuccessful.join(', ')}`),
      { code: primary.code, failure: primary, evidenceFailure });
  }
  console.log(`${nativeWirePassPrefix}${scenario} ${selector}`);
  console.log(stdout.split(/\r?\n/).find(line => /^Test Case .* passed \(/.test(line)));
}

function safeCode(code) {
  return typeof code === 'number' || (typeof code === 'string' && /^[A-Z0-9_]+$/.test(code)) ? code : 'UNKNOWN';
}
function failureDetails(error) {
  const code = safeCode(error.code);
  const reasons = {
    WIRE_TERMINAL_COUNT: 'Expected one XCTest terminal result',
    WIRE_TERMINAL_MISMATCH: 'Expected the exact selected XCTest to pass',
    ERR_CHILD_PROCESS_STDIO_MAXBUFFER: 'Native output exceeded the subprocess buffer limit',
  };
  return { code, reason: reasons[code] ?? 'Native process did not complete successfully',
    terminalCount: Number.isInteger(error.terminalCount) ? error.terminalCount : null,
    signal: typeof error.signal === 'string' && /^SIG[A-Z0-9]+$/.test(error.signal) ? error.signal : null,
    killed: typeof error.killed === 'boolean' ? error.killed : null,
    // execFile does not distinguish timeout from every other killed process.
    timedOut: typeof error.timedOut === 'boolean' ? error.timedOut : null,
    overflow: code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER' };
}
