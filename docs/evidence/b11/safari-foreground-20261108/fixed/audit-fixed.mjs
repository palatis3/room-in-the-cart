// Offline receipt/provenance audit; never launches browser/server/native or changes product.
import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';import {dirname,join} from 'node:path';import {fileURLToPath} from 'node:url';import {createHash} from 'node:crypto';
import {verifyForeground} from './frozen/verify-foreground.mjs';
const here=dirname(fileURLToPath(import.meta.url)),sha=b=>createHash('sha256').update(b).digest('hex');
const read=async p=>JSON.parse(await readFile(join(here,p),'utf8'));
const retention=await read('retention.json');for(const f of retention.files){const b=await readFile(join(here,f.retained));assert.equal(b.length,f.bytes);assert.equal(sha(b),f.sha256);}
const m=await read('frozen/manifest.json'),{identity,...payload}=m;assert.equal(sha(JSON.stringify(payload)),identity);assert.equal(identity,'9d8302a00fde50e5e137166a52bd4496745f69e348e23acd974a3a43f794f5ba');
const baseline=JSON.parse(await readFile(join(here,'../baseline/frozen/manifest.json')));assert.equal(m.derivativeOf.manifestIdentity,baseline.identity);
for(const n of ['fixture.mjs','probe.js','observation.mjs','server.mjs','verify-case.mjs','verify-foreground.mjs','verify-pin.mjs']){const h=sha(await readFile(join(here,'frozen',n)));assert.equal(h,m.helpers[n]);assert.equal(h,baseline.helpers[n]);}
const preserved=await read('baseline-preservation.json');for(const f of preserved.files)assert.equal(sha(await readFile(join(here,'../baseline',f.file))),f.sha256);
const build=await read('provenance/build-receipt.json');assert.equal(sha(await readFile(join(here,'provenance/build-receipt.json'))),m.verifiedBuild.sha256);assert.equal(build.commit,'58419f9822b26a93820c2f4cfa4a45e7cd257a11');assert.deepEqual(build.webAssetSHA256,m.bundle);assert.deepEqual(build.sourceSHA256,m.source);assert.deepEqual(build.unitTests,{selected:152,passed:152,failed:0,skipped:0});
const installed=await readFile(join(here,'tests/installed-web-tests.log'),'utf8');assert.equal(sha(Buffer.from(installed)),build.logSHA256);assert.match(installed,/# tests 152\b/);assert.match(installed,/# pass 152\b/);assert.match(installed,/# fail 0\b/);
const negative=await read('tests/original-source-negative-verification.json');assert.equal(negative.exitCode,1);assert.equal(negative.passed,3);assert.equal(negative.failed,9);assert.equal(sha(await readFile(join(here,'tests/original-source-negative.log'))),negative.logSHA256);for(const [file,want]of Object.entries(negative.testSHA256))assert.equal(sha(await readFile(join(here,'tests/portable',file))),want);
const browser=await readFile(join(here,'tests/chromium-passed.log'),'utf8');assert.match(browser,/# tests 14\b/);assert.match(browser,/# pass 14\b/);assert.match(browser,/# fail 0\b/);assert.match(browser,/# Chrome 158\.0\.8127\.18/);
const unavailable=await readFile(join(here,'tests/chromium-initial-missing-browser.log'),'utf8');assert.match(unavailable,/Chromium distribution 'chrome' is not found/);assert.match(unavailable,/# pass 0\b/);assert.match(unavailable,/# fail 2\b/);
const execution=await read('execution-boundary.json'),results=[];
for(const name of ['foreground-same','foreground-revoked']){
 const bytes=await readFile(join(here,name,'receipt.json')),r=JSON.parse(bytes),review=await read(name+'/root-review.json');
 const verdict=verifyForeground(r,identity,name);assert.equal(review.verificationExitCode,0);assert.equal(review.serverStopped,true);assert.equal(review.zeroProductCommands,true);assert.equal(new URL(r.origin).port,String(execution.cases[name].port));assert.equal(execution.cases[name].exitCode,0);assert.equal(execution.cases[name].portClosed,true);
 assert.equal(r.fixture.pendingAuthority,0);assert.equal(r.observations[1].pendingAuthority,1);assert.equal(r.fixture.counts.commandAttempts,0);assert.equal(r.fixture.counts.commandEffects,0);
 const old=JSON.parse(await readFile(join(here,'../baseline',name,'receipt.json')));assert.throws(()=>verifyForeground(old,baseline.identity,name),/private field\/control exposed: ownA/);
 results.push({case:name,receiptSHA256:sha(bytes),verdict,heldPendingAuthority:1,stoppedAndPortClosed:'root-reported; offline origin/receipt consistency verified'});
}
console.log(JSON.stringify({status:'fixed-scoped-pass-and-baseline-failures-confirmed-offline',fixedIdentity:identity,baselineIdentity:baseline.identity,baselineFilesUnchanged:preserved.fileCount,installedUnitTests:152,originalPortableControls:{passed:3,failed:9},chromiumTests:14,missingBrowserAttempt:'separately preserved',results,limits:'Simulator Safari with synthetic API and recorded DOM/native observations; not physical device, App Switcher, continuous-frame, provider or deployment proof.'},null,2));
