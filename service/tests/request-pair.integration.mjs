import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import test from 'node:test';
import {admin,call,fixture,head,invited,maintenance,ok,send} from './request-acceptance-undo-fixture.mjs';

async function ask(f,author,item,quantity) {
  const shop=await head(f);
  return ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:item,ownQuantity:quantity,
    authoredAt:new Date().toISOString()},shop.shopRevision,shop.authorityEpoch,author)).request;
}
async function preview(f,r,decision,actor=f.owner) {
  const shop=await head(f);
  return call(actor,f.path+'/previews','POST',{requestId:r.requestId,decision,
    base:{shopRevision:shop.shopRevision,authorityEpoch:shop.authorityEpoch,requestRevision:r.revision}});
}
function decide(other,relationship='sameItem') {
  return {choice:'reviewRequestPair',otherRequestId:other.requestId,otherRequestRevision:other.revision,relationship};
}
function command(f,r,p) {
  return {v:1,shopId:f.shopId,replayWindow:f.owner.window,clientKey:randomUUID(),kind:'request.apply',
    base:{shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,requestRevision:r.revision},
    body:{requestId:r.requestId,previewId:p.previewId,acceptOverage:false,acceptUnknown:false}};
}
function apply(f,c) {return call(f.owner,f.base+'/commands','POST',c);}
async function own(f,who,id) {
  return ok(await call(who,f.base+'/requests/mine')).requests.find(r=>r.requestId===id);
}
async function inbox(f,id) {
  return ok(await call(f.owner,f.path+'/inbox')).requests.find(r=>r.requestId===id);
}
async function edit(f,r,actor,body) {
  const s=await head(f);
  return ok(await send(f,body?'request.edit':'request.withdraw',{requestId:r.requestId,...body},
    s.shopRevision,s.authorityEpoch,actor,{base:{shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,requestRevision:r.revision}})).request;
}
function unchangedBudget(p) {
  assert.deepEqual(p.before,p.after);
  assert.equal(p.requiresOverageAcceptance,false);
  assert.equal(p.requiresUnknownAcceptance,false);
}

test('a shopper reviews two open family requests in an empty shop, with mirrored references and Undo from either side',async()=>{
  const f=await fixture(),a=await invited(f),b=await invited(f);
  ok(await send(f,'shop.patch',{quote:f.quote,lines:[]},1));
  const first=await ask(f,a,'Milk','1 cup for soup'),second=await ask(f,b,'milk','two bottles');
  const before=await head(f);
  async function physicalState(){
    const result=await admin.query(`SELECT (SELECT count(*) FROM ritc.shop_snapshot WHERE household_id=$1) snapshots,
      (SELECT count(*) FROM ritc.pantry_event WHERE household_id=$1) pantry,
      (SELECT count(*) FROM ritc.request_purchase_review WHERE household_id=$1) purchases,
      (SELECT count(*) FROM ritc.shared_demand_revision WHERE household_id=$1) demand,
      (SELECT count(*) FROM ritc.shared_meal_revision WHERE household_id=$1) meals`,[f.h]);
    return result.rows[0];
  }
  const physicalBefore=await physicalState();
  assert.ok(ok(await call(f.owner,f.base+'/bootstrap')).capabilities.includes('request_pair_review'));
  assert.ok(!ok(await call(a,f.base+'/bootstrap')).capabilities.includes('request_pair_review'));
  assert.equal((await preview(f,first,decide(second),a)).status,404);
  const p=ok(await preview(f,first,decide(second)));
  unchangedBudget(p);
  assert.deepEqual(p.requestPairEvidence,{otherRequestId:second.requestId,otherRequestRevision:second.revision,
    item:'milk',quantity:'two bottles',authorAlias:'Other adult',relationship:'sameItem'});
  const mirror=ok(await preview(f,second,decide(first)));
  const c=command(f,first,p), twin=command(f,second,mirror);
  const concurrent=await Promise.all([apply(f,c),apply(f,c),apply(f,twin)]);
  const winner=concurrent[2].status===200?second:first, loser=winner===first?second:first;
  const accepted=winner===first?c:twin;
  const receipt=ok(await apply(f,accepted));
  if(winner===first){
    assert.deepEqual(ok(concurrent[0]),receipt);assert.deepEqual(ok(concurrent[1]),receipt);assert.equal(concurrent[2].status,409);
  }else{
    assert.deepEqual(ok(concurrent[2]),receipt);assert.equal(concurrent[0].status,409);assert.equal(concurrent[1].status,409);
  }
  assert.equal(receipt.disposition,'pending');assert.equal(receipt.requestRevision,winner.revision);
  for(const [request,other,author] of [[first,second,a],[second,first,b]]){
    const recorded=await inbox(f,request.requestId);
    assert.deepEqual(recorded.requestPairs,[{otherRequestId:other.requestId,otherRequestRevision:other.revision,
      relationship:'sameItem',operationId:receipt.operationId}]);
    assert.deepEqual(await own(f,author,request.requestId),request);
  }
  assert.deepEqual(await head(f),before);
  const undo={choice:'undoRequestPair',operationId:receipt.operationId};
  const reverse=ok(await preview(f,loser,undo));
  assert.equal(reverse.requestPairEvidence.otherRequestId,winner.requestId);
  unchangedBudget(reverse);
  const undoCmd=command(f,loser,reverse);
  const undoReceipt=ok(await apply(f,undoCmd));
  assert.deepEqual(ok(await apply(f,undoCmd)),undoReceipt);
  assert.equal((await apply(f,accepted)).status,409);
  assert.equal((await inbox(f,first.requestId)).requestPairs,undefined);
  assert.equal((await inbox(f,second.requestId)).requestPairs,undefined);
  assert.equal((await apply(f,winner===first?twin:c)).status,409);
  const additional=ok(await preview(f,second,decide(first,'additionalQuantity')));
  unchangedBudget(additional);
  const recorded=ok(await apply(f,command(f,second,additional)));
  assert.equal((await inbox(f,first.requestId)).requestPairs[0].relationship,'additionalQuantity');
  assert.equal(recorded.requestRevision,second.revision);
  assert.equal((await apply(f,undoCmd)).status,409);
  assert.deepEqual(await physicalState(),physicalBefore);
  assert.deepEqual(await head(f),before);
  assert.deepEqual(await own(f,a,first.requestId),first);
  assert.deepEqual(await own(f,b,second.requestId),second);
});

test('pairing uses distinct request IDs, rechecks edits and access, and removes references and receipts on withdrawal',async()=>{
  const f=await fixture(),a=await invited(f),b=await invited(f);
  const first=await ask(f,a,'Beans',null),second=await ask(f,a,' BEANS ','4 cups'),third=await ask(f,b,'Eggs',null);
  assert.equal((await preview(f,first,decide(first))).status,404);
  assert.equal((await preview(f,first,decide(third))).status,409);
  const foreign=await fixture(),other=await ask(foreign,foreign.owner,'Beans',null);
  assert.equal((await preview(f,first,decide(other))).status,404);
  const stale=ok(await preview(f,first,decide(second)));
  const edited=await edit(f,second,a,{originalItem:'Beans',ownQuantity:'1 can'});
  assert.equal((await apply(f,command(f,first,stale))).status,409);
  const current=ok(await preview(f,first,decide(edited)));
  const c=command(f,first,current),receipt=ok(await apply(f,c));
  const undo=ok(await preview(f,edited,{choice:'undoRequestPair',operationId:receipt.operationId}));
  const s=await head(f);
  ok(await send(f,'shop.transferAuthority',{newShopperId:b.id},s.shopRevision,s.authorityEpoch));
  assert.equal((await apply(f,c)).status,404);
  assert.equal((await apply(f,command(f,edited,undo))).status,404);
  f.owner=b;
  const transferred=ok(await preview(f,first,{choice:'undoRequestPair',operationId:receipt.operationId}));
  assert.equal(transferred.requestPairEvidence.quantity,'1 can');
  await edit(f,edited,a);
  assert.equal((await inbox(f,first.requestId)).requestPairs,undefined);
  assert.deepEqual(await own(f,a,first.requestId),first);
  assert.equal((await admin.query('SELECT FROM ritc.operation_response WHERE household_id=$1 AND operation_id=$2',[f.h,receipt.operationId])).rowCount,0);
  assert.equal((await admin.query('SELECT FROM ritc.preview WHERE household_id=$1 AND preview_id=ANY($2::uuid[])',[f.h,[current.previewId,undo.previewId,transferred.previewId]])).rowCount,0);
});

test('erasing the other author removes open previews, pair receipts and Undo material while keeping the survivor intact',async()=>{
  const f=await fixture(),a=await invited(f),b=await invited(f);
  const first=await ask(f,a,'Rice',null),second=await ask(f,b,'Rice','2 cups');
  const p=ok(await preview(f,first,decide(second))),c=command(f,first,p);
  const receipt=ok(await apply(f,c));
  const undo=ok(await preview(f,second,{choice:'undoRequestPair',operationId:receipt.operationId}));
  const uc=command(f,second,undo),undone=ok(await apply(f,uc));
  const pending=ok(await preview(f,first,decide(second,'additionalQuantity')));
  ok(await call(b,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),
    confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);
  assert.equal((await maintenance.run({batchSize:1})).completed,1);
  assert.deepEqual(await own(f,a,first.requestId),first);
  assert.equal((await apply(f,c)).status,409);assert.equal((await apply(f,uc)).status,409);
  assert.equal((await admin.query('SELECT FROM ritc.request_pair_review WHERE household_id=$1',[f.h])).rowCount,0);
  assert.equal((await admin.query('SELECT FROM ritc.preview WHERE household_id=$1 AND preview_id=ANY($2::uuid[])',[f.h,[p.previewId,undo.previewId,pending.previewId]])).rowCount,0);
  assert.equal((await admin.query('SELECT FROM ritc.operation_response WHERE household_id=$1 AND operation_id=ANY($2::uuid[])',[f.h,[receipt.operationId,undone.operationId]])).rowCount,0);
});

test('existing unknown or over-budget groceries do not require a purchase acceptance for either classification or Undo',async()=>{
  const f=await fixture(),a=await invited(f);
  const first=await ask(f,a,'Pears',null),second=await ask(f,a,'Pears','6');
  for(const [budget,lines,status] of [[{...f.quote,capMinor:1},[f.basket],'overCap'],[f.quote,[{...f.basket,unitPriceMinor:null}],'unresolved']]){
    ok(await send(f,'shop.patch',{quote:budget,lines},(await head(f)).shopRevision));
    const p=ok(await preview(f,first,decide(second,'additionalQuantity')));
    assert.equal(p.before.status,status);unchangedBudget(p);
    const receipt=ok(await apply(f,command(f,first,p)));
    const undo=ok(await preview(f,second,{choice:'undoRequestPair',operationId:receipt.operationId}));
    assert.equal(undo.before.status,status);unchangedBudget(undo);
    ok(await apply(f,command(f,second,undo)));
  }
});


test('a clarified obligation stays editable and each pair depends only on its own two author grants and revisions',async()=>{
  const f=await fixture(),a=await invited(f),b=await invited(f),thirdAuthor=await invited(f);
  let first=await ask(f,a,'Flour','one bag');
  const second=await ask(f,b,'Flour',null),third=await ask(f,thirdAuthor,'Flour','2 cups');
  const s=await head(f),base={shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,requestRevision:first.revision};
  ok(await send(f,'request.clarify',{requestId:first.requestId,question:'Which flour?'},s.shopRevision,s.authorityEpoch,f.owner,{base}));
  first=await own(f,a,first.requestId);
  const p=ok(await preview(f,first,decide(second)));
  const c=command(f,first,p),receipt=ok(await apply(f,c));
  assert.equal(receipt.disposition,'clarified');
  const alternate=ok(await preview(f,first,decide(third,'additionalQuantity')));
  ok(await apply(f,command(f,first,alternate)));
  assert.deepEqual(await own(f,a,first.requestId),first);
  assert.equal(first.ownActionAllowed,true);assert.equal(first.clarification,'Which flour?');
  assert.equal((await inbox(f,first.requestId)).requestPairs.length,2);
  await admin.query('UPDATE ritc.member SET can_contribute=false WHERE household_id=$1 AND member_id=$2',[f.h,b.id]);
  assert.equal((await apply(f,c)).status,404);
  assert.equal((await preview(f,first,{choice:'undoRequestPair',operationId:receipt.operationId})).status,404);
  assert.equal((await inbox(f,second.requestId)).requestPairs,undefined);
  assert.deepEqual((await inbox(f,first.requestId)).requestPairs.map(x=>x.otherRequestId),[third.requestId]);
  await edit(f,third,thirdAuthor,{originalItem:'Other flour',ownQuantity:'2 cups'});
  assert.equal((await inbox(f,first.requestId)).requestPairs,undefined);
  assert.deepEqual(await own(f,a,first.requestId),first);
});
