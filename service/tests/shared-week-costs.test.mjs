import assert from 'node:assert/strict';
import test from 'node:test';
import {sharedWeekCostVersion} from '../dist/shared-week-costs.js';

function version(quantities) {
  return sharedWeekCostVersion({
    revision: 3,
    original: true,
    currency: 'USD',
    observed_at: '2026-10-01T14:00:00Z',
    captured_at: new Date('2026-10-01T15:00:00Z'),
    expires_at: '2026-10-01T18:00:00Z',
    commitments: null,
    pair_id: null,
    selected: null,
    lines: quantities.map(([packs, unitPriceMinor], index) => ({
      lineId: String(index), originalItem: 'Whole packs', packs, unitPriceMinor,
    })),
  }, true);
}

test('whole-pack subtotals stay exact at the shop contract limits', () => {
  // shop.create and shop.patch allow 200 lines, each with 10,000 packs at up to 1,000,000,000 minor units.
  const largest = version(Array.from({length: 200}, () => [10_000, 1_000_000_000]));
  assert.equal(largest.pricedLines, 200);
  assert.equal(largest.knownItemSubtotalMinor, 2_000_000_000_000_000);
  assert.equal(version([[1, null], [2, 0]]).knownItemSubtotalMinor, 0);
  assert.equal(version([[1, null]]).knownItemSubtotalMinor, null);
});

test('an aggregate outside JavaScript’s exact integer range stays unknown', () => {
  assert.equal(version([[2, Number.MAX_SAFE_INTEGER]]).knownItemSubtotalMinor, null);
  assert.equal(version([[1, Number.MAX_SAFE_INTEGER], [1, 1]]).knownItemSubtotalMinor, null);
});
