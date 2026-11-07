import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const packagePath = fileURLToPath(new URL('../../ios/Packages/HouseholdClient', import.meta.url));
export const nativeWirePassPrefix = 'Native wire XCTest passed ';

export async function runNativeWireTest({ suite, method, scenario, env, unsuccessful }) {
  const selector = `HouseholdClientTests.${suite}/${method}`;
  const args = ['test', '--package-path', packagePath, '--jobs', '2',
    '--filter', `^HouseholdClientTests\\.${suite}/${method}$`];
  if (process.env.RITC_NATIVE_WIRE_SWIFT_BUILD) {
    args.push('--scratch-path', process.env.RITC_NATIVE_WIRE_SWIFT_BUILD, '--skip-build');
  }
  let stdout, stderr;
  try {
    ({ stdout, stderr } = await run('swift', args, {
      env: { ...process.env, ...env },
      timeout: 180000,
      maxBuffer: 2_000_000,
    }));
    const terminal = stdout.split(/\r?\n/).filter(line => /^Test Case .* (passed|failed|skipped) \(/.test(line));
    assert.equal(terminal.length, 1, 'Expected one XCTest terminal result');
    assert.ok(terminal[0].startsWith(`Test Case '-[HouseholdClientTests.${suite} ${method}]' passed (`),
      `Expected ${selector} to pass`);
    console.log(`${nativeWirePassPrefix}${scenario} ${selector}`);
    console.log(terminal[0]);
  } catch (error) {
    const output = [stdout ?? error.stdout, stderr ?? error.stderr].filter(Boolean).join('\n');
    throw new Error(`${scenario}: ${error.message}\n${output.slice(-3500)}\nAPI responses: ${unsuccessful.join(', ')}`);
  }
}
