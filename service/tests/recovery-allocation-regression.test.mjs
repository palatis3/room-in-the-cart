import test from 'node:test';
import assert from 'node:assert/strict';
import { projectRecovery, canonicalSupply } from '../dist/recovery-domain.js';
import { arrivalCommandSchema } from '../dist/recovery-contracts.js';
import { fixture, id, at, q } from './recovery-fixture.mjs';

const demand = (projection, number) => projection.demands.find(n => n.needId === id(number));
const exact = numerator => ({ numerator: String(numerator), denominator: '1' });

function dinnerPin() {
  const basis = fixture();
  // Explicitly remove lunch's pin: protection must not depend on having a pin.
  basis.reservations = [{ id: id(70), sourceId: id(40), needId: id(30), quantity: q(6) }];
  return basis;
}

test('unpinned protected lunch precedes a required dinner reservation', () => {
  const projection = projectRecovery(dinnerPin(), at);
  assert.deepEqual(demand(projection, 31).allocated, exact(2));
  assert.deepEqual(demand(projection, 30).allocated, exact(4));
  assert.deepEqual(demand(projection, 30).shortfall, exact(2));
  assert.deepEqual(demand(projection, 30).issues, ['reservation_shortfall']);
});

test('excluded pinned dinner gets no allocation and consumes no lunch supply', () => {
  const basis = dinnerPin();
  basis.foods[0].exclusionTags = ['peanut'];
  basis.meals[0].needs[0].exclusions = ['peanut'];
  const projection = projectRecovery(basis, at);
  assert.deepEqual(demand(projection, 30).allocated, exact(0));
  assert.deepEqual(demand(projection, 30).shortfall, exact(6));
  assert.deepEqual(demand(projection, 30).issues, ['exclusion_conflict']);
  assert.equal(projection.allocations.some(edge => edge.needId === id(30)), false);
  assert.deepEqual(demand(projection, 31).allocated, exact(2));
  assert.deepEqual(demand(projection, 32).allocated, exact(4));
});

test('known arrival with unknown received quantity remains representable and unusable', () => {
  const basis = fixture();
  const command = {
    v: 1, clientKey: id(300), replayWindow: id(301), base: basis.base,
    sourceId: id(41), observationId: id(51), predecessorId: null,
    arrivedAt: at, received: null,
  };
  assert.equal(arrivalCommandSchema.safeParse(command).success, true);
  basis.arrivals[1].received = null;
  basis.usable[1].usable = null;
  assert.equal(canonicalSupply(basis, at).length, 1);
  basis.usable[1].usable = q(1);
  assert.throws(() => canonicalSupply(basis, at), e => e.code === 'unverified_arrival');
});

function secondWrapDelivery(basis) {
  basis.base.supplyRevision = 6;
  basis.sources.push({ ...basis.sources[0], id: id(42),
    origin: { ...basis.sources[0].origin, segmentKey: id(242) } });
  basis.arrivals.push({ ...basis.arrivals[0], id: id(52), sourceId: id(42), revision: 5 });
  basis.usable.push({ ...basis.usable[0], id: id(62), sourceId: id(42),
    arrivalObservationId: id(52), revision: 6, usable: q(6) });
}

test('a short full pin cannot borrow a second delivery after lunch takes priority', () => {
  const basis = dinnerPin();
  secondWrapDelivery(basis);
  const projection = projectRecovery(basis, at);
  assert.deepEqual(demand(projection, 31).allocated, exact(2));
  assert.deepEqual(demand(projection, 30).allocated, exact(4));
  assert.deepEqual(demand(projection, 30).shortfall, exact(2));
  assert.equal(projection.allocations.some(edge =>
    edge.needId === id(30) && edge.sourceId === id(42)), false);
  assert.deepEqual(demand(projection, 32).allocated, exact(4));
});

test('partial pin allows only its unreserved remainder to use another delivery', () => {
  const basis = dinnerPin();
  basis.reservations[0].quantity = q(3);
  secondWrapDelivery(basis);
  basis.usable[0].usable = q(3);
  const projection = projectRecovery(basis, at);
  // Lunch consumes two from source40. Only one of the exact three pinned units
  // remains. Three genuinely unreserved dinner units may come from source42.
  assert.deepEqual(demand(projection, 30).allocated, exact(4));
  assert.deepEqual(demand(projection, 30).shortfall, exact(2));
  assert.deepEqual(projection.allocations.filter(edge => edge.needId === id(30)), [
    { needId: id(30), sourceId: id(40), amount: exact(1), unit: 'count' },
    { needId: id(30), sourceId: id(42), amount: exact(3), unit: 'count' },
  ]);
});

test('protected exclusion conflict consumes nothing before a valid required pin', () => {
  const basis = dinnerPin();
  basis.foods[0].exclusionTags = ['peanut'];
  basis.meals[0].needs[1].exclusions = ['peanut'];
  const projection = projectRecovery(basis, at);
  assert.deepEqual(demand(projection, 31).allocated, exact(0));
  assert.deepEqual(demand(projection, 31).issues, ['exclusion_conflict']);
  assert.deepEqual(demand(projection, 30).allocated, exact(6));
  assert.equal(projection.allocations.some(edge => edge.needId === id(31)), false);
});

test('after protected needs, required pinned dinner precedes unpinned required dinner', () => {
  const basis = fixture();
  basis.reservations = [{ id: id(70), sourceId: id(40), needId: id(32), quantity: q(4) }];
  const projection = projectRecovery(basis, at);
  assert.deepEqual(demand(projection, 31).allocated, exact(2));
  assert.deepEqual(demand(projection, 32).allocated, exact(4));
  assert.deepEqual(demand(projection, 30).allocated, exact(0));
});

test('unrelated physical pin and protected allocation survive another dinner recovery', async () => {
  const { previewRecovery } = await import('../dist/recovery-domain.js');
  const { request } = await import('./recovery-fixture.mjs');
  const basis = dinnerPin();
  const review = previewRecovery(basis, request(basis), at);
  const pinEdges = projection => projection.allocations.filter(edge => edge.needId === id(30));
  assert.equal(review.feasible, true);
  assert.deepEqual(pinEdges(review.before), pinEdges(review.after));
  assert.deepEqual(pinEdges(review.after), [
    { needId: id(30), sourceId: id(40), amount: exact(4), unit: 'count' },
  ]);
  assert.deepEqual(demand(review.after, 31).allocated, exact(2));
  assert.deepEqual(demand(review.after, 30).shortfall, exact(2));
});

test('known quantity without arrival instant also stays unavailable until reviewed', () => {
  const basis = fixture();
  assert.equal(arrivalCommandSchema.safeParse({
    v: 1, clientKey: id(300), replayWindow: id(301), base: basis.base,
    sourceId: id(41), observationId: id(51), predecessorId: null,
    arrivedAt: null, received: q(5),
  }).success, true);
  basis.arrivals[1].arrivedAt = null;
  basis.usable[1].usable = null;
  assert.equal(canonicalSupply(basis, at).length, 1);
  basis.usable[1].usable = q(1);
  assert.throws(() => canonicalSupply(basis, at), e => e.code === 'unverified_arrival');
});

test('reservation list order cannot change which protected or pinned need eats first', () => {
  const basis = dinnerPin();
  basis.reservations.push({ id: id(71), sourceId: id(40), needId: id(32), quantity: q(4) });
  const original = projectRecovery(basis, at);
  basis.reservations.reverse();
  assert.deepEqual(projectRecovery(basis, at), original);
  assert.deepEqual(demand(original, 31).allocated, exact(2));
});
