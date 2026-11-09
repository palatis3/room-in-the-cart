import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runNativeWireTest } from './run-native-wire-test.mjs';

const invocation = { suite: 'FixtureTests', method: 'testWire', scenario: 'fixture-case',
  env: { SECRET_FIXTURE_TOKEN: 'DO-NOT-RETAIN-ENVIRONMENT' }, unsuccessful: [] };
const passed = "Test Case '-[HouseholdClientTests.FixtureTests testWire]' passed (0.001 seconds).\n";

// Serial within this test: the production API intentionally reads one wrapper-owned root.
test('bounded scenario output, failed controls, identity and collision retention', async () => {
  const root = await mkdtemp(join(tmpdir(), 'ritc-wire-output-'));
  const prior = process.env.RITC_NATIVE_WIRE_RESULTS;
  process.env.RITC_NATIVE_WIRE_RESULTS = root;
  try {
    await runNativeWireTest(invocation, async (tool,args,options) => {
      assert.equal(tool,'swift');assert.equal(options.timeout,180000);assert.equal(options.maxBuffer,2_000_000);
      assert.ok(args.includes('^HouseholdClientTests\\.FixtureTests/testWire$'));
      assert.equal(options.env.SECRET_FIXTURE_TOKEN,invocation.env.SECRET_FIXTURE_TOKEN);
      return {stdout:passed,stderr:'retained diagnostic\n'};
    });
    const first = (await readdir(root))[0];
    const before = await readFile(join(root,first,'receipt.json'));
    await assert.rejects(runNativeWireTest(invocation, async () => {
      throw Object.assign(new Error('PRIVATE EXECUTION METADATA MUST NOT BE PRINTED'),
        { code: 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER', killed: true, signal: 'SIGTERM', stdout:'BEGIN\n'+'x'.repeat(2_000_100), stderr:'tail warning' });
    }), error => {
      assert.ok(error.message.length<4000);
      assert.ok(!error.message.includes('PRIVATE EXECUTION'));
      return true;
    });
    assert.deepEqual(await readFile(join(root,first,'receipt.json')),before);
    const dirs=await readdir(root);assert.equal(dirs.length,2);
    const failed=dirs.find(name=>name!==first);
    const receipt=JSON.parse(await readFile(join(root,failed,'receipt.json'),'utf8'));
    assert.equal(receipt.status,'failed');assert.equal(receipt.outputMayBeIncomplete,true);
    assert.equal(receipt.failure.overflow,true);assert.equal(receipt.failure.killed,true);
    assert.equal(receipt.failure.signal,'SIGTERM');assert.equal(receipt.failure.timedOut,null);
    assert.equal(receipt.streams.stdout.bytes,2_000_000);assert.equal(receipt.streams.stdout.truncated,true);
    assert.match(receipt.streams.stdout.sha256,/^[a-f0-9]{64}$/);
    assert.ok((await readFile(join(root,failed,'stdout.log'),'utf8')).startsWith('BEGIN\n'));
    for(const dir of dirs) for(const name of await readdir(join(root,dir)))
      assert.ok(!(await readFile(join(root,dir,name),'utf8')).includes('DO-NOT-RETAIN-ENVIRONMENT'));
    await assert.rejects(runNativeWireTest(invocation,async()=>({stdout:passed+passed,stderr:''})),
      error => error.code==='WIRE_TERMINAL_COUNT' && error.failure.terminalCount===2);
    const all=await readdir(root);assert.equal(all.length,3);
    const mismatch=all.find(name=>!dirs.includes(name));
    assert.equal(JSON.parse(await readFile(join(root,mismatch,'receipt.json'),'utf8')).failure.code,'WIRE_TERMINAL_COUNT');
    await assert.rejects(runNativeWireTest(invocation,async()=>({stdout:passed.replace('testWire','testOther'),stderr:''})),
      error => error.code==='WIRE_TERMINAL_MISMATCH');
    const blocked=join(root,'not-a-directory');await writeFile(blocked,'occupied');
    process.env.RITC_NATIVE_WIRE_RESULTS=blocked;
    await assert.rejects(runNativeWireTest(invocation,async()=>{
      throw Object.assign(new Error('native private error'),{code:65,signal:null,killed:false,stdout:'first native failure'});
    }), error => error.code===65 && error.failure.killed===false && error.evidenceFailure==='ENOTDIR' &&
      error.message.includes('Native process did not complete successfully') && error.message.includes('Evidence write also failed'));
    await assert.rejects(runNativeWireTest(invocation,async()=>({stdout:passed,stderr:''})),
      error => error.code==='WIRE_EVIDENCE_WRITE' && error.evidenceFailure==='ENOTDIR');
  } finally {
    if(prior===undefined) delete process.env.RITC_NATIVE_WIRE_RESULTS; else process.env.RITC_NATIVE_WIRE_RESULTS=prior;
    await rm(root,{recursive:true,force:true});
  }
});
