import test from 'node:test';
import assert from 'node:assert/strict';
import { projectRecovery, previewRecovery } from '../dist/recovery-domain.js';
import { fixture, request, id, at } from './recovery-fixture.mjs';

function lateCurrentFood() {
  const basis = fixture();
  basis.meals[0].due = '2026-11-10T15:00:00.000Z';
  basis.meals[0].needs.forEach(n => n.due = basis.meals[0].due);
  basis.arrivals[0].arrivedAt = '2026-11-10T16:00:00.000Z';
  return basis;
}

test('physically available late food covers still-open needs without changing their saved deadlines', () => {
  const basis = lateCurrentFood();
  const original = JSON.stringify(basis);
  const projection = projectRecovery(basis, at);
  const tuesday = projection.demands.find(n => n.needId === id(30));
  const lunch = projection.demands.find(n => n.needId === id(31));
  assert.deepEqual(tuesday.allocated, { numerator: '4', denominator: '1' });
  assert.deepEqual(tuesday.shortfall, { numerator: '2', denominator: '1' });
  assert.deepEqual(lunch.allocated, { numerator: '2', denominator: '1' });
  assert.equal(tuesday.due, '2026-11-10T15:00:00.000Z');
  assert.equal(tuesday.deadlineStatus, 'pastDue');
  assert.equal(lunch.deadlineStatus, 'pastDue');
  assert.equal(projection.meals[0].due, basis.meals[0].due);
  assert.equal(JSON.stringify(basis), original);
});

test('late currently available fallback food is physical coverage, never on-time feasibility', () => {
  const basis = fixture();
  basis.arrivals[1].arrivedAt = '2026-11-11T18:30:00.000Z';
  const result = previewRecovery(basis, request(basis), '2026-11-11T19:00:00.000Z');
  assert.equal(result.foodConfirmed, true);
  assert.equal(result.timingConfirmed, false);
  assert.equal(result.feasible, false);
  assert.equal(result.consentSatisfied, false);
  assert.equal(result.after.meals[1].due, basis.meals[1].due);
  assert.equal(result.after.demands.find(n => n.needId === id(201)).deadlineStatus, 'pastDue');
});

test('future evidence stays unavailable even for overdue open needs', () => {
  const basis = lateCurrentFood();
  basis.arrivals[0].arrivedAt = '2026-11-10T18:00:00.000Z';
  const projection = projectRecovery(basis, at);
  assert.deepEqual(projection.demands.find(n => n.needId === id(31)).allocated,
    { numerator: '0', denominator: '1' });
  assert.equal(projection.demands.find(n => n.needId === id(31)).deadlineStatus, 'pastDue');
});

test('unknown deadline remains explicit without erasing physical food coverage', () => {
  const basis = fixture();
  basis.meals[1].due = null;
  basis.meals[1].needs.forEach(n => n.due = null);
  const result = previewRecovery(basis, request(basis), at);
  const replacement = result.after.demands.find(n => n.needId === id(201));
  assert.equal(result.foodConfirmed, true);
  assert.equal(result.timingConfirmed, false);
  assert.equal(replacement.due, null);
  assert.equal(replacement.deadlineStatus, 'unknown');
});
