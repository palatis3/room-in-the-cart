import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {checkout} from '../dist/checkout.js';
import {parseCommand} from '../dist/contracts.js';
import {randomUUID} from 'node:crypto';
const fixture=JSON.parse(await readFile(new URL('../../shared/fixtures/checkout.json',import.meta.url),'utf8'));
for(const vector of fixture.cases)test('independent checkout vector: '+vector.id,()=>{
  function evaluate(input) {
    const quote={currency:'USD',scope:vector.scope,capScope:vector.capScope,complete:input.complete,capMinor:vector.capCents,
      fee:input.fee.kind==='fixed'?{kind:'fixed',amountMinor:input.fee.cents}:{kind:'threshold',thresholdMinor:input.fee.thresholdCents,belowMinor:input.fee.belowThresholdCents,aboveMinor:0},
      taxesMinor:input.taxCents,discountsMinor:input.discountCents,depositsMinor:input.depositCents,observedAt:'2026-01-01T00:00:00Z',expiresAt:'2026-01-02T00:00:00Z'};
    return checkout(input.lines.map(l=>({lineId:l.id,originalItem:'Fixture',packs:1,unitPriceMinor:l.cents,feeEligible:l.eligible})),quote);
  }
  const before=evaluate(vector.before),after=evaluate(vector.after),expected=vector.expected;
  assert.equal(before.totalMinor,expected.beforeCents);assert.equal(after.totalMinor,expected.afterCents);
  assert.equal(before.totalMinor!==null&&after.totalMinor!==null?after.totalMinor-before.totalMinor:null,expected.changeCents);
  assert.equal(after.lowerBoundMinor,expected.afterLowerCents);assert.equal(after.upperBoundMinor,expected.afterUpperCents);
  assert.equal(after.overCapMinor,expected.overCents);assert.equal(after.wholeCheckoutWithinCap,expected.wholeCheckoutWithinCap);
  assert.equal(after.status,{within:'withinCap',over:'overCap',scopeMismatch:'scopeMismatch',unresolved:'unresolved'}[expected.capStatus]);
});
test('typed command boundary rejects forged actors, totals and unrecognized command kinds',()=>{
  const base={v:1,replayWindow:randomUUID(),clientKey:randomUUID(),shopId:randomUUID(),kind:'request.send',base:{shopRevision:0,authorityEpoch:0},body:{clientRequestId:randomUUID(),originalItem:'Fixture cereal',ownQuantity:'one box',authoredAt:new Date().toISOString()}};
  assert.equal(parseCommand(base).body.route,'current');
  for(const input of [{...base,actorId:randomUUID()},{...base,kind:'admin.grant'},{...base,body:{...base.body,totalMinor:1}},{...base,body:{...base.body,originalItem:'x'.repeat(241)}}])assert.throws(()=>parseCommand(input));
});
