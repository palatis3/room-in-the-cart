import assert from 'node:assert/strict';
import {randomBytes, randomUUID} from 'node:crypto';
import test from 'node:test';
import {admin, call, fixture, head, invited, maintenance, ok, send} from './request-acceptance-undo-fixture.mjs';

test("erasing the reported purchaser preserves another shopper's bought observation and retires its attributed replay", async () => {
  const f = await fixture(), buyer = await invited(f), requester = await invited(f);
  async function request(actor, name) {
    return ok(await send(f, 'request.send', {clientRequestId: randomUUID(), originalItem: name,
      ownQuantity: '1', authoredAt: new Date().toISOString()}, (await head(f)).shopRevision, 1, actor)).request;
  }
  const target = await request(requester, 'Wraps'), source = await request(buyer, 'Beans');
  const current = await head(f);
  const base = {shopRevision: current.shopRevision, authorityEpoch: current.authorityEpoch, requestRevision: target.revision};
  const review = ok(await call(f.owner, f.path + '/previews', 'POST', {requestId: target.requestId, base,
    decision: {choice: 'link', lineId: f.basket.lineId, promote: false}}));
  const linked = ok(await send(f, 'request.apply', {requestId: target.requestId, previewId: review.previewId,
    acceptOverage: false, acceptUnknown: false}, base.shopRevision, base.authorityEpoch, f.owner, {base}));
  const frozen = ok(await send(f, 'shop.freeze', {}, linked.shopRevision));
  ok(await send(f, 'shop.reportPlaced', {occurredAt: new Date().toISOString()}, frozen.shopRevision));
  const placed = await head(f);
  const inbox = async () => ok(await call(f.owner, f.path + '/inbox')).requests;
  const author = (await inbox()).find(r => r.requestId === source.requestId);
  const command = {v: 1, shopId: f.shopId, replayWindow: f.owner.window, clientKey: randomUUID(),
    kind: 'request.confirmPurchase', base: {shopRevision: placed.shopRevision, authorityEpoch: placed.authorityEpoch,
      requestRevision: linked.requestRevision}, body: {requestId: target.requestId, lineId: f.basket.lineId,
      placedRevision: placed.placedRevision, outcome: 'bought', reportedPurchaser: {kind: 'requestAuthor',
      requestId: author.requestId, requestRevision: author.revision, expectedAlias: author.authorAlias}}};
  const receipt = ok(await call(f.owner, f.base + '/commands', 'POST', command));
  assert.equal((await inbox()).find(r => r.requestId === target.requestId).reportedPurchaser, author.authorAlias);
  ok(await call(buyer, '/v1/privacy/deletions', 'POST', {clientKey: randomUUID(),
    statusToken: randomBytes(32).toString('base64url'), confirm: true,
    households: [{householdId: f.h, organizer: 'none', shops: [], eraseChildProfiles: []}]}), 202);
  assert.equal((await maintenance.run({batchSize: 1})).completed, 1);
  assert.equal((await call(f.owner, f.base + '/commands', 'POST', command)).status, 409);
  const after = (await inbox()).find(r => r.requestId === target.requestId);
  assert.equal(after.purchaseOutcome, 'bought');
  assert.equal(after.purchaseRecordedBy, 'Shopper');
  assert.equal(after.reportedPurchaser, undefined);
  const own = ok(await call(requester, f.base + '/requests/mine')).requests.find(r => r.requestId === target.requestId);
  assert.equal(own.purchaseOutcome, 'bought');
  assert.equal(own.reportedPurchaser, undefined);
  const retained = await admin.query('SELECT 1 FROM ritc.request_purchase_buyer WHERE household_id=$1 AND operation_id=$2',
    [f.h, receipt.operationId]);
  assert.equal(retained.rowCount, 0);
});
