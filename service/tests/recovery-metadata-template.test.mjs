import test from 'node:test';
import assert from 'node:assert/strict';
import { previewRecovery } from '../dist/recovery-domain.js';
import { fixture, request, at, id } from './recovery-fixture.mjs';

test('a fabricated named template cannot acquire accepted provenance or bypass repeat review', () => {
  const basis = fixture(), input = request(basis);
  input.intent.replacement.template = { id: id(91), version: 999 };
  assert.throws(() => previewRecovery(basis, input, at), error => error.code === 'unverified_template');
});

test('even a known template ID is rejected without canonical accepted version and scaled definition', () => {
  const basis = fixture(), input = request(basis);
  basis.knownTemplateIds = [id(91)];
  input.intent.replacement.template = { id: id(91), version: 1 };
  input.intent.agreesToRepeat = true;
  assert.throws(() => previewRecovery(basis, input, at), error => error.code === 'unverified_template');
});

test('Free manual editable-source metadata remains exact in the replacement projection', () => {
  const basis = fixture(), input = request(basis);
  basis.meals[1].notes = 'Old instruction';
  basis.meals[1].sourceURL = 'https://example.invalid/original';
  const fresh = request(basis);
  fresh.intent.replacement.notes = '  Simmer gently.\nSave the sauce separately.  ';
  fresh.intent.replacement.sourceURL = 'https://example.invalid/edited-recipe?version=2';
  fresh.intent.replacement.needs[0].notes = '  Keep this ingredient separate.  ';
  const review = previewRecovery(basis, fresh, at);
  assert.equal(review.feasible, true);
  assert.equal(review.consentSatisfied, true);
  assert.equal(review.after.meals[1].template, null);
  assert.equal(review.after.meals[1].notes, fresh.intent.replacement.notes);
  assert.equal(review.after.meals[1].sourceURL, fresh.intent.replacement.sourceURL);
  assert.equal(review.after.meals[1].needs[0].notes, fresh.intent.replacement.needs[0].notes);
  assert.equal(review.before.meals[1].notes, 'Old instruction');
  assert.equal(basis.meals[1].sourceURL, 'https://example.invalid/original');
  assert.equal(review.after.meals[1].advanceStepsCompleted, false,
    'Preparation prose never proves an advance step completed');
});

test('protected ingredient instructions cannot be silently edited during dinner recovery', () => {
  const basis = fixture(), input = request(basis, 0);
  input.intent.replacement.needs[1].notes = 'Use the protected lunch for dinner';
  assert.throws(() => previewRecovery(basis, input, at), error => error.code === 'protected_need');
});

test('note and source changes are bound into target and exact reviewed intent digests', () => {
  const basis = fixture(), input = request(basis);
  const before = previewRecovery(basis, input, at);
  input.intent.replacement.notes = 'Different reviewed instructions';
  assert.notEqual(previewRecovery(basis, input, at).previewDigest, before.previewDigest);
  basis.meals[1].notes = 'Another actor updated the source instruction';
  assert.throws(() => previewRecovery(basis, input, at), error => error.code === 'stale_target');
});

test('manual repeat is an explicit canonical occurrence choice requiring agreement', () => {
  const basis = fixture(), input = request(basis);
  input.intent.repeatOfOccurrenceId = basis.meals[0].occurrenceId;
  let review = previewRecovery(basis, input, at);
  assert.equal(review.repeatRequired, true);
  assert.equal(review.consentSatisfied, false);
  input.intent.agreesToRepeat = true;
  review = previewRecovery(basis, input, at);
  assert.equal(review.consentSatisfied, true);
  assert.equal(review.after.meals[1].template, null);
  input.intent.repeatOfOccurrenceId = id(999);
  assert.throws(() => previewRecovery(basis, input, at), error => error.code === 'unverified_repeat_source');
});

test('native UTF-8 metadata bounds reject oversized text without silently truncating it', () => {
  for (const change of [
    meal => { meal.notes = 'é'.repeat(4097); },
    meal => { meal.sourceURL = 'é'.repeat(1025); },
    meal => { meal.needs[0].notes = 'é'.repeat(4097); },
  ]) {
    const basis = fixture(), input = request(basis);
    change(input.intent.replacement);
    assert.throws(() => previewRecovery(basis, input, at));
  }
});
