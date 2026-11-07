import test from 'node:test';
import assert from 'node:assert/strict';
import { canonicalSupply, projectRecovery } from '../dist/recovery-domain.js';
import { fixture, at, id, q } from './recovery-fixture.mjs';

function correctedIdentity() {
  const basis = fixture();
  basis.sources[1].foodId = id(5); // The same delivery is newly matched to wraps.
  basis.sources[1].identityRevision = 2;
  basis.base.supplyRevision = 5;
  return basis;
}

test('identity correction cannot relabel old usable confirmation as the new food', () => {
  const basis = correctedIdentity();
  assert.equal(canonicalSupply(basis, at).some(lot => lot.sourceId === id(41)), false);
  assert.deepEqual(projectRecovery(basis, at).demands.find(n => n.needId === id(30)).shortfall,
    { numerator: '2', denominator: '1' });
});

test('explicit arrival and usable reconfirmation under corrected identity creates current supply', () => {
  const basis = correctedIdentity();
  basis.base.supplyRevision = 7;
  basis.arrivals.push({ ...basis.arrivals[1], id: id(52), identityRevision: 2,
    revision: 6, predecessorId: id(51), received: q(5) });
  basis.usable.push({ ...basis.usable[1], id: id(62), identityRevision: 2,
    revision: 7, predecessorId: id(61), arrivalObservationId: id(52), usable: q(5) });
  const lot = canonicalSupply(basis, at).find(lot => lot.sourceId === id(41));
  assert.equal(lot.foodId, id(5));
  assert.equal(lot.identityRevision, 2);
  assert.deepEqual(projectRecovery(basis, at).demands.find(n => n.needId === id(30)).shortfall,
    { numerator: '0', denominator: '1' });
  assert.equal(basis.usable[1].identityRevision, 1, 'historical confirmation remains unchanged');
});

test('new-identity usable confirmation cannot refer to the old-identity arrival', () => {
  const basis = correctedIdentity();
  basis.base.supplyRevision = 6;
  basis.usable.push({ ...basis.usable[1], id: id(62), identityRevision: 2,
    revision: 6, predecessorId: id(61) });
  assert.throws(() => canonicalSupply(basis, at), e => e.code === 'identity_mismatch');
});

test('future or zero identity revisions reject rather than acquiring current identity', () => {
  for (const revision of [0, 3]) {
    const basis = fixture();
    basis.arrivals[1].identityRevision = revision;
    assert.throws(() => canonicalSupply(basis, at));
  }
});

test('unchanged source identity keeps original usable supply and never renames history', () => {
  const basis = fixture();
  const original = JSON.stringify(basis);
  const lot = canonicalSupply(basis, at).find(lot => lot.sourceId === id(41));
  assert.equal(lot.foodId, id(6));
  assert.equal(lot.identityRevision, 1);
  assert.equal(JSON.stringify(basis), original);
});
