import test from 'node:test';
import assert from 'node:assert/strict';
import { projectRecovery, previewRecovery } from '../dist/recovery-domain.js';
import { fixture, request, id, at, q } from './recovery-fixture.mjs';

function pinnedExcluded() {
  const basis = fixture();
  basis.reservations = [{ id: id(70), sourceId: id(40), needId: id(30), quantity: q(6) }];
  basis.meals[0].needs[0].exclusions = ['Peanut'];
  return basis;
}

test('mixed-case saved restriction matches an explicit canonical exclusion tag before pinned allocation', () => {
  const basis = pinnedExcluded();
  basis.foods[0].exclusionTags = ['peanut'];
  const original = JSON.stringify(basis);
  const result = projectRecovery(basis, at);
  const dinner = result.demands.find(n => n.needId === id(30));
  assert.deepEqual(dinner.allocated, { numerator: '0', denominator: '1' });
  assert.deepEqual(dinner.issues, ['exclusion_conflict']);
  assert.equal(result.allocations.some(edge => edge.needId === id(30)), false);
  assert.equal(JSON.stringify(basis), original);
});

test('legacy saved exclusion text is checked against entered food labels without treating it as a tag ID', () => {
  const basis = fixture();
  basis.foods[1].name = 'Peanut sauce';
  basis.foods[1].exclusionTags = [];
  basis.meals[1].needs[0].exclusions = ['Peanut'];
  const review = previewRecovery(basis, request(basis), at);
  assert.equal(review.foodConfirmed, false);
  assert.deepEqual(review.after.demands.find(n => n.needId === id(201)).issues, ['exclusion_conflict']);
});

test('case accent and punctuation comparison preserves the original saved text', () => {
  const basis = pinnedExcluded();
  basis.meals[0].needs[0].exclusions = ['PÉANUT Butter'];
  basis.foods[0].name = 'Peanut-butter sauce';
  const original = JSON.stringify(basis);
  const result = projectRecovery(basis, at);
  assert.deepEqual(result.demands.find(n => n.needId === id(30)).issues, ['exclusion_conflict']);
  assert.equal(JSON.stringify(basis), original);
  assert.deepEqual(result.meals[0].needs[0].exclusions, ['PÉANUT Butter']);
});

test('saved phrases match the reviewed ingredient label even when canonical food label is generic', () => {
  const basis = pinnedExcluded();
  basis.meals[0].needs[0].name = 'Peanut sauce';
  basis.foods[0].name = 'Sauce';
  assert.deepEqual(projectRecovery(basis, at).demands.find(n => n.needId === id(30)).issues, ['exclusion_conflict']);
});

test('token matching does not infer ingredient families or partial-word exclusions', () => {
  const basis = fixture();
  basis.meals[1].needs[0].exclusions = ['Nut'];
  basis.foods[1].name = 'Coconut portions';
  assert.equal(previewRecovery(basis, request(basis), at).foodConfirmed, true);
});

test('exclusion tags remain case-insensitive exact terms rather than food-name identity matches', () => {
  const basis = pinnedExcluded();
  basis.foods[0].exclusionTags = ['PEANUT'];
  basis.meals[0].needs[0].exclusions = ['peanut'];
  const result = projectRecovery(basis, at);
  assert.deepEqual(result.demands.find(n => n.needId === id(30)).allocated, { numerator: '0', denominator: '1' });
  assert.deepEqual(result.demands.find(n => n.needId === id(31)).allocated, { numerator: '2', denominator: '1' });
});
