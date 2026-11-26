import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

export function adultCheckTests({fixture,request,ok,admin,runtime,subscriptions}){
  async function prepared(){
    const f=await fixture(),peer=await f.otherMember(),path=f.shopPath+'/adult-checks';
    assert.equal((await request(peer,path)).status,403);
    assert(!ok(await request(f.owner,f.base+'/bootstrap')).capabilities.includes('adult_checks'));
    const subscription=await f.paid();
    assert.equal(ok(await request(f.owner,path)).recipient,null);
    await f.seats([f.owner.id,peer.id]);
    assert(ok(await request(peer,f.base+'/bootstrap')).capabilities.includes('adult_checks'));
    const dinner=randomUUID(),day='2026-12-02';
    await admin.query(`INSERT INTO ritc.shared_meal_revision(household_id,shop_id,occurrence_id,revision,actor_id,meal)
      VALUES($1,$2,$3,1,$4,$5)`,[f.h,f.shopId,dinner,f.owner.id,{title:'Sopa de frijol',day,kind:'dinner',portions:4,protected:false}]);
    const read=(actor=f.owner)=>request(actor,path);
    const post=(actor,input)=>request(actor,path,'POST',input);
    const current=ok(await read());
    const ask=(kind='attendance')=>({action:'ask',id:randomUUID(),kind,sourceId:kind==='attendance'?dinner:current.items[0].id,
      recipientId:peer.id,shopRevision:current.shopRevision,authorityEpoch:current.authorityEpoch,pairRevision:current.pairRevision,
      expiresAt:new Date(Date.now()+3600000).toISOString()});
    return {...f,peer,dinner,day,read,post,ask,subscription,path};
  }
  test('cooking step shares one approved instruction between named adults, with immutable replies and exact retries',async()=>{
    const f=await prepared(),path=f.shopPath+'/cooking-step';
    const read=actor=>request(actor,path),post=(actor,data)=>request(actor,path,'POST',data);
    const page=ok(await read(f.peer)),before=ok(await request(f.owner,f.shopPath));
    assert(ok(await request(f.peer,f.base+'/bootstrap')).capabilities.includes('cook_step_handoff'));
    const offer={action:'offer',id:randomUUID(),recipientId:f.owner.id,shopRevision:page.shopRevision,authorityEpoch:page.authorityEpoch,
      pairRevision:page.pairRevision,instruction:'Enjuaga el arroz',reviewed:true,expiresAt:new Date(Date.now()+3600000).toISOString()};
    for(const extra of [{reviewed:false},{recipe:'private'},{instruction:'Te voy a matar'}])
      assert.equal((await post(f.peer,{...offer,...extra})).status,422);
    for(const res of await Promise.all([post(f.peer,offer),post(f.peer,offer)]))assert.equal(ok(res).offers.length,1);
    const inbox=ok(await read(f.owner));assert.deepEqual(inbox.offers,[{id:offer.id,instruction:offer.instruction,mine:false,answer:null,expiresAt:offer.expiresAt}]);
    assert(!JSON.stringify(inbox).includes('Sopa'));assert.deepEqual(ok(await f.read(f.owner)).checks,[]);
    assert.equal((await post(f.peer,{...offer,id:randomUUID()})).status,409);
    assert.equal((await post(f.peer,{action:'reply',id:offer.id,answer:'accepted'})).status,404);
    const replies=await Promise.all(['accepted','declined'].map(answer=>post(f.owner,{action:'reply',id:offer.id,answer})));
    assert.deepEqual(replies.map(r=>r.status).sort(),[200,409]);
    const settled=ok(await read(f.peer)).offers[0];assert(settled.mine);assert(settled.answer);
    ok(await post(f.owner,{action:'reply',id:offer.id,answer:settled.answer}));
    assert.deepEqual(ok(await request(f.owner,f.shopPath)),before);
    ok(await post(f.owner,{action:'withdraw',id:offer.id}));assert.deepEqual(ok(await read(f.peer)).offers,[]);
    assert.equal((await post(f.peer,offer)).status,409);
    assert.equal((await admin.query('SELECT step_text FROM ritc.adult_check WHERE check_id=$1',[offer.id])).rows[0].step_text,null);
  });
  test('cooking step expires, hides on revoked access, clears on block, and cannot replay after a changed pair',async()=>{
    const f=await prepared(),path=f.shopPath+'/cooking-step',post=(a,d)=>request(a,path,'POST',d);
    const page=ok(await request(f.owner,path)),offer={action:'offer',id:randomUUID(),recipientId:f.peer.id,shopRevision:page.shopRevision,
      authorityEpoch:page.authorityEpoch,pairRevision:page.pairRevision,instruction:'Start the rice',reviewed:true,expiresAt:new Date(Date.now()+3600000).toISOString()};
    const third=await f.otherMember();
    assert.equal((await request(third,path)).status,403);
    assert.equal((await request(f.peer,path,'GET',undefined,{'X-View-Grant-ID':randomUUID()})).status,404);
    ok(await post(f.owner,offer));
    await admin.query("UPDATE ritc.adult_check SET created_at=now()-interval '2 hours',expires_at=now()-interval '1 second' WHERE check_id=$1",[offer.id]);
    assert.deepEqual(ok(await request(f.peer,path)).offers,[]);
    assert.equal((await post(f.peer,{action:'reply',id:offer.id,answer:'accepted'})).status,404);
    const next={...offer,id:randomUUID()};ok(await post(f.owner,next));
    await admin.query('INSERT INTO ritc.moderation_block(household_id,viewer_id,author_id) VALUES($1,$2,$3)',[f.h,f.peer.id,f.owner.id]);
    await admin.query('DELETE FROM ritc.moderation_block WHERE household_id=$1',[f.h]);
    assert.deepEqual(ok(await request(f.peer,path)).offers,[]);assert.equal((await post(f.owner,next)).status,409);
    const last={...offer,id:randomUUID()};ok(await post(f.owner,last));
    await f.seats([f.owner.id,third.id]);assert.equal((await request(f.peer,path)).status,403);
    await f.seats([f.owner.id,f.peer.id]);assert.equal((await post(f.owner,last)).status,409);
  });
  test('adult checks address one dinner or basket item, admit one immutable reply and review independently of groceries',async()=>{
    const f=await prepared(),shopper=f.owner,peer=f.peer;
    const before=ok(await request(shopper,f.shopPath));
    const empty=ok(await f.read(peer));
    assert.deepEqual([empty.dinners,empty.items,empty.checks,empty.recipient],[[],[],[],null]);
    const ask=f.ask(),cup=f.ask('cupboard');
    assert.equal((await f.post(peer,ask)).status,404);
    assert.equal((await f.post(shopper,{...ask,recipientId:randomUUID()})).status,404);
    assert.equal((await f.post(shopper,{...ask,sourceId:randomUUID()})).status,404);
    assert.equal((await f.post(shopper,{...ask,expiresAt:new Date(Date.now()+8*86400000).toISOString()})).status,422);
    const repeated=await Promise.all([f.post(shopper,ask),f.post(shopper,ask)]);
    for(const result of repeated)assert.equal(ok(result).checks.length,1);
    const pending=ok(await f.read(peer));
    assert.equal(pending.checks[0].label,'Sopa de frijol');assert.equal(pending.checks[0].day,f.day);
    assert.equal(pending.checks[0].answer,null);assert(pending.checks[0].canAnswer);assert.deepEqual(pending.items,[]);
    assert(!JSON.stringify(pending).includes('Fictional line'));assert(!JSON.stringify(pending).includes('portions'));
    assert.equal((await f.post(shopper,{...ask,id:randomUUID()})).status,409);
    ok(await f.post(shopper,cup));
    const reply=(id,answer,extra={})=>({action:'answer',id,answer,...extra});
    assert.equal((await f.post(shopper,reply(ask.id,'out'))).status,404);
    assert.equal((await f.post(peer,reply(ask.id,'enough'))).status,422);
    const race=await Promise.all(['latePlate','out'].map(a=>f.post(peer,reply(ask.id,a))));
    assert.deepEqual(race.map(r=>r.status).sort(),[200,409]);
    const answered=ok(await f.read()).checks.find(c=>c.id===ask.id);
    assert(!answered.reviewed);assert(answered.answeredAt);
    const review={action:'review',id:ask.id,answer:answered.answer,answeredAt:answered.answeredAt};
    assert.equal((await f.post(peer,review)).status,404);
    assert.equal((await f.post(shopper,{...review,answeredAt:new Date(0).toISOString()})).status,409);
    ok(await f.post(peer,reply(ask.id,answered.answer)));
    for(let i=0;i<2;i++)assert(ok(await f.post(shopper,review)).checks.find(c=>c.id===ask.id).reviewed);
    const qty={quantity:{value:'1.500',unit:'liter'}};
    assert.equal((await f.post(peer,reply(cup.id,'cannotCheck',qty))).status,422);
    const stock=ok(await f.post(peer,reply(cup.id,'low',qty))).checks.find(c=>c.id===cup.id);
    assert.equal(stock.label,'Fictional line');assert.equal(stock.shoppingPacks,1);
    assert.deepEqual(stock.quantity,{value:'1.5',unit:'liter'});
    ok(await f.post(peer,reply(cup.id,'low',{quantity:stock.quantity})));
    assert.equal((await f.post(peer,reply(cup.id,'low'))).status,409);
    ok(await f.post(peer,{action:'withdraw',id:cup.id}));
    assert(!ok(await f.read()).checks.some(c=>c.id===cup.id));
    assert.equal((await f.post(peer,reply(cup.id,'low',qty))).status,404);
    assert.deepEqual(ok(await request(shopper,f.shopPath)),before);
  });
  test('adult checks require an eligible workspace even with a paid seat, and strip stale shopper authority',async()=>{
    const f=await prepared();
    const a=f.ask(),incoming=await f.post(f.owner,a);ok(incoming);
    assert.equal((await request(f.peer,f.path,'GET',undefined,{'X-View-Grant-ID':randomUUID()})).status,404);
    await admin.query('UPDATE ritc.member SET can_contribute=false WHERE household_id=$1 AND member_id=$2',[f.h,f.peer.id]);
    assert.equal((await f.read(f.peer)).status,404);
    assert.equal(ok(await f.read()).recipient,null);
    assert(!ok(await request(f.peer,f.base+'/bootstrap')).capabilities.includes('adult_checks'));
    await admin.query('UPDATE ritc.member SET can_contribute=true WHERE household_id=$1 AND member_id=$2',[f.h,f.peer.id]);
    assert.deepEqual(ok(await f.read(f.peer)).checks,[]);
    assert.equal((await f.post(f.owner,a)).status,409);
    await f.transfer(f.owner,f.peer);
    assert.deepEqual(ok(await f.read()).checks,[]);
    assert.equal((await f.post(f.owner,a)).status,404);
    assert.equal((await f.post(f.peer,{action:'answer',id:a.id,answer:'home'})).status,404);
    await admin.query("UPDATE ritc.member SET kind='child' WHERE household_id=$1 AND member_id=$2",[f.h,f.peer.id]);
    assert.equal((await f.read(f.peer)).status,403);
  });
  test('adult checks expire and clear after seat replacement; stale receipts and out-of-scope projections stay closed',async()=>{
    const f=await prepared(),ask=f.ask(),third=await f.otherMember();
    ok(await f.post(f.owner,ask));
    assert.equal((await f.read(third)).status,403);
    assert(!ok(await request(third,f.base+'/bootstrap')).capabilities.includes('adult_checks'));
    const db=await runtime.connect();
    try{
      await db.query('BEGIN');
      await db.query("SELECT set_config('app.household_id',$1,true),set_config('app.content_viewer',$2,true)",[f.h,third.id]);
      assert.equal((await db.query('SELECT 1 FROM ritc.adult_check WHERE household_id=$1',[f.h])).rowCount,0);
    }finally{await db.query('ROLLBACK');db.release();}
    await admin.query('INSERT INTO ritc.moderation_block(household_id,viewer_id,author_id) VALUES($1,$2,$3)',[f.h,f.peer.id,f.owner.id]);
    assert.deepEqual(ok(await f.read()).checks,[]);assert.deepEqual(ok(await f.read(f.peer)).checks,[]);
    await admin.query('DELETE FROM ritc.moderation_block WHERE household_id=$1',[f.h]);
    assert.deepEqual(ok(await f.read(f.peer)).checks,[]);
    assert.equal((await f.post(f.owner,ask)).status,409);
    await admin.query("UPDATE ritc.adult_check SET created_at=now()-interval '2 hours',expires_at=now()-interval '1 second' WHERE check_id=$1",[ask.id]);
    assert.deepEqual(ok(await f.read(f.peer)).checks,[]);
    assert.equal((await f.post(f.peer,{action:'answer',id:ask.id,answer:'home'})).status,404);
    await admin.query('SELECT * FROM ritc.maintenance_prepare_auth(100)');
    assert.equal((await admin.query('SELECT 1 FROM ritc.adult_check WHERE check_id=$1',[ask.id])).rowCount,0);
    const next=f.ask();ok(await f.post(f.owner,next));
    await f.seats([f.owner.id,third.id]);assert.equal((await f.read(f.peer)).status,403);
    await f.seats([f.owner.id,f.peer.id]);assert.deepEqual(ok(await f.read(f.peer)).checks,[]);
    assert.equal((await f.post(f.owner,next)).status,409);
    const current=ok(await f.read()),latest={...f.ask(),pairRevision:current.pairRevision};
    ok(await f.post(f.owner,latest));
    await admin.query('UPDATE ritc.shop SET revision=revision+1 WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId]);
    assert.deepEqual(ok(await f.read(f.peer)).checks,[]);
    assert.equal((await f.post(f.owner,latest)).status,409);
    await admin.query("UPDATE ritc.shop SET phase='frozen' WHERE household_id=$1 AND shop_id=$2",[f.h,f.shopId]);
    assert.equal((await f.read()).status,404);
    assert(!ok(await request(f.peer,f.base+'/bootstrap')).capabilities.includes('adult_checks'));
    await admin.query("UPDATE ritc.shop SET phase='draft' WHERE household_id=$1 AND shop_id=$2",[f.h,f.shopId]);
    const original=subscriptions.get(f.subscription);
    subscriptions.set(f.subscription,{...original,status:'revoked',signedAt:original.signedAt+1});
    assert.equal((await f.read(f.peer)).status,403);
    assert(!ok(await request(f.owner,f.base+'/bootstrap')).capabilities.includes('adult_checks'));
    assert.equal((await admin.query('SELECT 1 FROM ritc.adult_check WHERE household_id=$1 AND (NOT withdrawn OR answer IS NOT NULL OR quantity IS NOT NULL)',[f.h])).rowCount,0);
  });
}
