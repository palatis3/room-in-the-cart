import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import test from 'node:test';
import { admin, maintenance, fixture, invited, call, send, ok, head } from './request-acceptance-undo-fixture.mjs';

async function pending(f, author) {
  return ok(await send(f, 'request.send', {
    clientRequestId: randomUUID(), originalItem: 'Milk', ownQuantity: '1 cup for soup',
    authoredAt: new Date().toISOString()
  }, (await head(f)).shopRevision, 1, author)).request;
}
async function previewDecision(f, request, decision, who = f.owner) {
  const shop = await head(f);
  return call(who, f.path + '/previews', 'POST', {
    requestId: request.requestId, decision, base: {shopRevision: shop.shopRevision,
      authorityEpoch: shop.authorityEpoch, requestRevision: request.revision}
  });
}
function applyCommand(f, request, preview) {
  return {v: 1, shopId: f.shopId, replayWindow: f.owner.window, clientKey: randomUUID(),
    kind: 'request.apply', base: {shopRevision: preview.shopRevision, authorityEpoch: preview.authorityEpoch,
      requestRevision: request.revision}, body: {requestId: request.requestId, previewId: preview.previewId,
      acceptOverage:false, acceptUnknown:false}};
}
test('one unbound planned ingredient can explain a separate request without changing the basket, meal or graph', async () => {
  const f = await fixture(), author = await invited(f), ingredientId = randomUUID(), occurrenceId = randomUUID();
  const meal = {title:'Soup', day:null, kind:'dinner', portions:2, protected:true,
    planning:{groups:[], ingredients:[{id:ingredientId, name:'Milk',quantity:null,groupIds:[],exclusions:[]}]}};
  ok(await send(f, 'shop.patch', {quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},1));
  const sent = await pending(f,author);
  const shop=await head(f);
  ok(await send(f,'request.clarify',{requestId:sent.requestId,question:'Which variant?'},shop.shopRevision,shop.authorityEpoch,f.owner,
    {base:{shopRevision:shop.shopRevision,authorityEpoch:shop.authorityEpoch,requestRevision:sent.revision}}));
  const request = ok(await call(author,f.base+'/requests/mine')).requests[0];
  assert.equal(request.status,'clarified');
  const food = ok(await call(f.owner, f.path + '/demand/tracking'));
  const fact = food.state.catalog.find(row => row.source.ingredientId === ingredientId);
  const decision = {choice:'sameItem', target:{kind:'meal',factId:fact.id,factRevision:fact.revision}};
  const preview = ok(await previewDecision(f, request, decision));
  assert.equal(preview.sameItemEvidence.reservationPurpose,'Soup');
  const command = applyCommand(f,request,preview);
  const receipt = ok(await call(f.owner, f.base + '/commands','POST',command));
  assert.equal(receipt.disposition,'handled');
  assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',command)),receipt);
  assert.deepEqual(ok(await call(f.owner, f.path + '/demand/tracking')).state, food.state);
  const own = ok(await call(author, f.base + '/requests/mine')).requests[0];
  assert.equal(own.status, 'handled'); assert.equal(own.purchaseOutcome, undefined);
  assert.equal(own.sameItemOperationId, undefined);
  const frozen=ok(await send(f,'shop.freeze',{},shop.shopRevision));
  ok(await send(f,'shop.reportPlaced',{occurredAt:new Date().toISOString()},frozen.shopRevision));
  assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',command)),receipt);
  const undo = ok(await previewDecision(f, own, {choice:'undoSameItem',operationId:receipt.operationId}));
  const inverse=applyCommand(f,own,undo);
  const inverseReceipt=ok(await call(f.owner,f.base+'/commands','POST',inverse));
  assert.equal(inverseReceipt.disposition,'clarified');
  assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',inverse)),inverseReceipt);
  assert.equal((await call(f.owner,f.base+'/commands','POST',command)).status,409);
  const restored=ok(await call(author,f.base+'/requests/mine')).requests[0];
  assert.equal(restored.status,'clarified');
  assert.equal(restored.clarification,'Which variant?');
  const nextReview=ok(await previewDecision(f,restored,{choice:'dismiss'}));
  ok(await call(f.owner,f.base+'/commands','POST',applyCommand(f,restored,nextReview)));
  const later=ok(await call(author,f.base+'/requests/mine')).requests[0];
  assert.equal((await previewDecision(f,later,{choice:'undoSameItem',operationId:receipt.operationId})).status,409);
  assert.equal(later.status,'dismissed');
});

test('purchase proof needs a distinct, currently bought request on the same sealed line and revision', async () => {
  const f=await fixture(), author=await invited(f);
  const requester=await invited(f);
  const source=await pending(f,author), selected=await pending(f,requester);
  const linkPreview=ok(await previewDecision(f,source,{choice:'link',lineId:f.basket.lineId,promote:false}));
  const linked=ok(await call(f.owner,f.base+'/commands','POST',applyCommand(f,source,linkPreview)));
  const frozen=ok(await send(f,'shop.freeze',{},linked.shopRevision));
  ok(await send(f,'shop.reportPlaced',{occurredAt:new Date().toISOString()},frozen.shopRevision));
  const shop=await head(f);
  const authorizedBase=revision=>({base:{shopRevision:shop.shopRevision,authorityEpoch:shop.authorityEpoch,requestRevision:revision}});
  const purchase=outcome=>({requestId:source.requestId,lineId:f.basket.lineId,placedRevision:shop.placedRevision,outcome});
  const bought=ok(await send(f,'request.confirmPurchase',purchase('bought'),shop.shopRevision,1,f.owner,authorizedBase(linked.requestRevision)));
  const open=ok(await call(f.owner,f.path+'/inbox')).requests.find(r=>r.requestId===selected.requestId);
  const target={kind:'purchase',sourceRequestId:source.requestId,sourceRequestRevision:bought.requestRevision,
    placedRevision:shop.placedRevision,lineId:f.basket.lineId};
  const review=t=>previewDecision(f,open,{choice:'sameItem',target:t});
  assert.equal((await review({...target,lineId:randomUUID()})).status,409);
  assert.equal((await review({...target,placedRevision:target.placedRevision+1})).status,404);
  assert.equal((await review({...target,sourceRequestId:selected.requestId})).status,404);
  assert.equal((await review({...target,sourceRequestRevision:1})).status,409);
  assert.equal((await previewDecision(f,open,{choice:'sameItem',target},author)).status,404);
  const p=ok(await review(target));
  assert.equal(p.sameItemEvidence.packs,2);
  const cmd=applyCommand(f,open,p);
  const correction=ok(await send(f,'request.confirmPurchase',purchase('notBought'),shop.shopRevision,1,f.owner,authorizedBase(bought.requestRevision)));
  assert.equal((await call(f.owner,f.base+'/commands','POST',cmd)).status,409);
  assert.equal((await review({...target,sourceRequestRevision:correction.requestRevision})).status,409);
  const confirmed=ok(await send(f,'request.confirmPurchase',purchase('bought'),shop.shopRevision,1,f.owner,authorizedBase(correction.requestRevision)));
  const newPreview=ok(await review({...target,sourceRequestRevision:confirmed.requestRevision}));
  const fresh=applyCommand(f,open,newPreview), receipt=ok(await call(f.owner,f.base+'/commands','POST',fresh));
  assert.equal(receipt.disposition,'handled');
  assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',fresh)),receipt);
  assert.deepEqual(await head(f),shop);
  const inbox=ok(await call(f.owner,f.path+'/inbox')).requests;
  assert.equal(inbox.find(r=>r.requestId===open.requestId).purchaseOutcome,undefined);
  assert.equal(inbox.find(r=>r.requestId===source.requestId).purchaseOutcome,'bought');
  const unknown=ok(await send(f,'request.confirmPurchase',purchase('unknown'),shop.shopRevision,1,f.owner,authorizedBase(confirmed.requestRevision)));
  assert.equal((await call(f.owner,f.base+'/commands','POST',fresh)).status,409);
  const own=ok(await call(requester,f.base+'/requests/mine')).requests[0];
  assert.equal(own.status,'pending'); assert.equal(own.ownActionAllowed,true); assert.equal(own.route,'next');
  assert.equal(own.purchaseOutcome,undefined); assert.equal(own.sameItemOperationId,undefined);
  const now=ok(await call(f.owner,f.path+'/inbox')).requests.find(r=>r.requestId===selected.requestId);
  assert.equal(now.sameItemOperationId,undefined);
  assert.equal((await previewDecision(f,now,{choice:'defer'})).status,200);
  const boughtAgain=ok(await send(f,'request.confirmPurchase',purchase('bought'),shop.shopRevision,1,f.owner,authorizedBase(unknown.requestRevision)));
  const finalPreview=ok(await previewDecision(f,now,{choice:'sameItem',target:{...target,sourceRequestRevision:boughtAgain.requestRevision}}));
  const finalCommand=applyCommand(f,now,finalPreview);
  const finalReceipt=ok(await call(f.owner,f.base+'/commands','POST',finalCommand));
  assert.equal(finalReceipt.disposition,'handled');
  ok(await call(author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),
    confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);
  assert.equal((await maintenance.run({batchSize:1})).completed,1);
  const afterErasure=ok(await call(requester,f.base+'/requests/mine')).requests[0];
  assert.equal(afterErasure.status,'pending');
  assert.equal(afterErasure.purchaseOutcome,undefined);
  assert.equal(afterErasure.ownQuantity,now.ownQuantity);
  assert.equal((await call(f.owner,f.base+'/commands','POST',finalCommand)).status,409);
  assert.equal((await admin.query('SELECT FROM ritc.operation_response WHERE household_id=$1 AND operation_id=$2',[f.h,finalReceipt.operationId])).rowCount,0);

});

test('two identical meal names retain distinct sources, race refreshes review, erasure retires only the linked proof', async () => {
  const f=await fixture(), author=await invited(f);
  const meal=(ingredient,amount,name='Milk')=>({title:'Breakfast '+amount,day:null,kind:'dinner',portions:2,protected:false,
    planning:{groups:[],ingredients:[{id:ingredient,name,quantity:{amount:{numerator:amount,denominator:1},
      unit:'cup',originalLiteral:amount+' cups'},groupIds:[],exclusions:[]}]}});
  const ingredientA=randomUUID(),ingredientB=randomUUID(),occurrenceA=randomUUID(),occurrenceB=randomUUID();
  const patch=async (occurrenceId,baseMealRevision,value)=>{
    const s=await head(f);
    return send(f,'shop.patch',{quote:s.quote,lines:s.lines,mealEdit:{occurrenceId,baseMealRevision,meal:value}},s.shopRevision);
  };
  ok(await patch(occurrenceA,null,meal(ingredientA,1)));
  ok(await patch(occurrenceB,null,meal(ingredientB,2)));
  const req=await pending(f,author);
  const fact=async id=>ok(await call(f.owner,f.path+'/demand/tracking')).state.catalog.find(row=>row.source.ingredientId===id);
  const match=(r,food)=>previewDecision(f,r,{choice:'sameItem',target:{kind:'meal',factId:food.id,factRevision:food.revision}});
  const before=await fact(ingredientA), stale=ok(await match(req,before));
  ok(await patch(occurrenceA,before.revision,meal(ingredientA,3)));
  assert.equal((await call(f.owner,f.base+'/commands','POST',applyCommand(f,req,stale))).status,409);
  const revised=await fact(ingredientA), p=ok(await match(req,revised));
  assert.equal(p.sameItemEvidence.quantity,'3 cups');
  const cmd=applyCommand(f,req,p);
  const receipt=ok(await call(f.owner,f.base+'/commands','POST',cmd));
  const readOwn=async()=>ok(await call(author,f.base+'/requests/mine')).requests[0];
  ok(await patch(occurrenceB,(await fact(ingredientB)).revision,meal(ingredientB,1)));
  assert.equal((await readOwn()).status,'handled');
  ok(await patch(occurrenceA,revised.revision,meal(ingredientA,3,'Lactose-free milk')));
  const reopened=await readOwn();
  assert.equal(reopened.status,'pending');
  assert.equal(reopened.sameItemOperationId,undefined);
  assert.equal((await match(reopened,await fact(ingredientA))).status,409);
  assert.equal((await previewDecision(f,reopened,{choice:'undoSameItem',operationId:receipt.operationId})).status,409);
  const originalShopper=f.owner, newShopper=await invited(f);
  const current=await head(f);
  ok(await send(f,'shop.transferAuthority',{newShopperId:newShopper.id},current.shopRevision,current.authorityEpoch));
  f.owner=newShopper;
  const alternate=await fact(ingredientB), second=ok(await match(reopened,alternate));
  const secondCommand=applyCommand(f,reopened,second);
  ok(await call(f.owner,f.base+'/commands','POST',secondCommand));
  // Erase the original meal author after a different shopper recorded the match.
  ok(await call(originalShopper,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),
    statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,
      organizer:'transfer',organizerMemberId:newShopper.id,shops:[],eraseChildProfiles:[]}]}),202);
  assert.equal((await maintenance.run({batchSize:1})).completed,1);
  assert.equal((await readOwn()).status,'pending');
  assert.equal((await call(f.owner,f.base+'/commands','POST',secondCommand)).status,409);
  assert.equal((await admin.query('SELECT 1 FROM ritc.preview WHERE household_id=$1 AND preview_id=$2',[f.h,second.previewId])).rowCount,0);
});
