// Shared actual-HTTP setup for live erasure and signed-restore controls. No SQL
// creates source/member provenance; SQL below only observes authoritative rows.
import assert from 'node:assert/strict';
import {randomUUID,randomBytes,createHash} from 'node:crypto';
export const labelDigest=value=>createHash('sha256').update('ritc:tracking-basket-label:v1:'+value,'utf8').digest('hex');
export function trackingPrivacyFixtures(api){
 const {fixture,source,q,empty,draft,page,baseOf,applyIntent,invited,send,ok,call,admin}=api;
 const action=(f,state)=>({kind:'shop.patch',body:{quote:f.quote,lines:state.basket.map(l=>({lineId:l.id,originalItem:l.name,packs:l.packs,unitPriceMinor:l.priceMinor,feeEligible:l.feeEligible}))}});
 async function transfer(f,next,organizer=f.owner){const p=await page(f);ok(await send(f,'shop.transferAuthority',{newShopperId:next.id},p.shopRevision,p.authorityEpoch,organizer));f.owner=next;}
 async function erase(f,actor,organizer=false){const request={clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:organizer?'transfer':'none',...(organizer?{organizerMemberId:f.owner.id}:{}),shops:[],eraseChildProfiles:[]}]};ok(await call(actor,'/v1/privacy/deletions','POST',request),202);return request;}
 async function linkAuthor(){
  const f=await fixture(),owner=f.owner,eraser=await invited(f);let revision=1;
  // withinExisting requires an authoritative demand and an existing supply;
  // two manual supply rows cannot stand in for real meal demand provenance.
  for(const title of ['Independent first meal','Independent second meal']){
   const occurrenceId=randomUUID(),groupId=randomUUID(),ingredientId=randomUUID(),bindingId=randomUUID();
   const quantity={amount:{numerator:3,denominator:1},unit:'count',originalLiteral:'3 wraps'};
   const meal={title,day:null,kind:'dinner',portions:3,protected:false,planning:{groups:[{id:groupId,name:title,servings:{numerator:3,denominator:1},protected:false}],ingredients:[{id:ingredientId,name:'Wraps',quantity,groupIds:[groupId],exclusions:[]}],bindings:[{id:bindingId,groupId,ingredientId,quantity}]}};
   ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},revision++));
  }
  const p=await page(f);assert.equal(p.state.catalog.length,2);
  const supply={...source(f),productName:'Independent supply',originalText:'Independent twelve'};
  const [demand1,demand2]=p.state.catalog.map(fact=>({...source(f,fact.quantity),id:fact.id,source:fact.source,originalText:fact.originalText,sourceExclusions:fact.sourceExclusions}));
  assert.ok([demand1,demand2].every(c=>c.source.kind==='meal'));
  const edge=(d,evidence)=>({id:randomUUID(),kind:'withinExisting',demandId:d.id,supplyId:supply.id,quantity:q(3),confirmation:{productMatchConfirmed:true,confirmedAt:new Date().toISOString(),evidence}});
  const retained=edge(demand1,'Retained author review'),removed=edge(demand2,'Link-only author private review');
  const input={...draft(f,supply),base:baseOf(p)};input.change.contributions=[supply,demand1,demand2];input.change.edges=[retained];input.action.body.lines=[{...f.basket,packs:3}];await applyIntent(f,input);
  // A real retired line/source proves erasure does not retimestamp unrelated history.
  const current=await page(f),retiredLine={lineId:randomUUID(),originalItem:'Independent retired line',packs:1,unitPriceMinor:100,feeEligible:true},retired={...source({...f,basket:retiredLine},q(1)),productKey:'retired',productName:'Retired food',originalText:'Retired one'};
  const addAction=action(f,current.state);addAction.body.lines.push(retiredLine);
  await applyIntent(f,{mode:'change',base:baseOf(current),change:{...empty(),lines:[{id:retiredLine.lineId,name:retiredLine.originalItem,unit:'count',originalOrder:1,trashedAt:null}],contributions:[retired]},unboundFactIds:[],action:addAction,packs:[...current.state.packReviews,{lineId:retiredLine.lineId,usablePerPack:q(1),acceptUnresolved:false}]});
  const withRetired=await page(f),removeAction=action(f,withRetired.state);removeAction.body.lines=removeAction.body.lines.filter(l=>l.lineId!==retiredLine.lineId);
  await applyIntent(f,{mode:'change',base:baseOf(withRetired),change:{...empty(),removeSourceIds:[retired.id]},unboundFactIds:[],action:removeAction,packs:withRetired.state.packReviews.filter(p=>p.lineId!==retiredLine.lineId)});
  await transfer(f,eraser,owner);const linked=await page(f);
  const committed=await applyIntent(f,{mode:'change',base:baseOf(linked),change:{...empty(),edges:[removed]},unboundFactIds:[],action:action(f,linked.state),packs:linked.state.packReviews});
  const origins=(await admin.query('SELECT entity_kind,entity_id FROM ritc.shared_demand_source_member WHERE household_id=$1 AND shop_id=$2 AND member_id=$3',[f.h,f.shopId,eraser.id])).rows;
  assert.deepEqual(origins,[{entity_kind:'edge',entity_id:removed.id}],'the erased author owns the relationship only, not either surviving source');
  await transfer(f,owner,owner);const before=await page(f);
  return {f,eraser,before,retained,removed,committed,retiredLineId:retiredLine.lineId};
 }
 async function legacyLabel(){
  const f=await fixture(),eraser=f.owner,owner=await invited(f),secret='Legacy cafe\u0301 private label',independent='Independent renamed staple';
  f.basket={...f.basket,originalItem:secret};const retiredLine={...f.basket,lineId:randomUUID()};
  ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket,retiredLine]},1));
  // Provenance must already exist before a different actor adopts the food graph.
  const index=(await admin.query('SELECT line_id,label_digest FROM ritc.shared_tracking_basket_origin WHERE household_id=$1 AND shop_id=$2 AND member_id=$3',[f.h,f.shopId,eraser.id])).rows;
  assert.ok(index.some(r=>r.line_id===f.basket.lineId&&r.label_digest===labelDigest(secret)));
  assert.notEqual(labelDigest(secret),labelDigest(secret.normalize('NFC')),'normalization cannot silently alter the hash domain');
  await transfer(f,owner,eraser);const p=await page(f);
  const original={...source(f),productName:secret,originalText:secret},retired={...source({...f,basket:retiredLine}),productName:secret,originalText:secret};
  const input={...draft(f,original),base:baseOf(p)};input.change.lines=[{id:f.basket.lineId,name:secret,unit:'count',originalOrder:0,trashedAt:null},{id:retiredLine.lineId,name:secret,unit:'count',originalOrder:1,trashedAt:null}];input.change.contributions=[original,retired];input.action.body.lines=[f.basket,retiredLine];input.packs=[{lineId:f.basket.lineId,usablePerPack:q(6),acceptUnresolved:false},{lineId:retiredLine.lineId,usablePerPack:q(6),acceptUnresolved:false}];const adopted=await applyIntent(f,input);
  const now=await page(f),survivor={...source(f),productName:independent,originalText:'Twelve independent units'};
  await applyIntent(f,{mode:'change',base:baseOf(now),change:{...empty(),lines:[{...now.state.graph.lines.find(l=>l.id===f.basket.lineId),name:independent}],contributions:[survivor],removeSourceIds:[original.id,retired.id]},unboundFactIds:[],action:{kind:'shop.patch',body:{quote:f.quote,lines:[{...f.basket,originalItem:independent}]}},packs:[input.packs[0]]});
  const before=await page(f);assert.ok(JSON.stringify(before.state).includes(secret),'retired rows really retain copied text before erasure');
  return {f,eraser,secret,independent,before,survivor,original,retired,retiredLineId:retiredLine.lineId,adopted};
 }
 async function assertProjection(fixtureCase,db=admin){
  const {f,before}=fixtureCase,row=(await db.query('SELECT projection FROM ritc.shared_tracking_revision WHERE household_id=$1 AND shop_id=$2 ORDER BY shop_revision DESC LIMIT 1',[f.h,f.shopId])).rows[0],s=row.projection.state;
  const stored=(await db.query('SELECT graph FROM ritc.shared_demand_revision WHERE household_id=$1 AND shop_id=$2 ORDER BY revision DESC LIMIT 1',[f.h,f.shopId])).rows[0].graph;
  assert.deepEqual(s.graph.usedIds,before.state.graph.usedIds);assert.deepEqual(stored.usedIds,before.state.graph.usedIds);
  assert.equal(s.graph.lines.find(l=>l.id===fixtureCase.retiredLineId).trashedAt,before.state.graph.lines.find(l=>l.id===fixtureCase.retiredLineId).trashedAt,'unrelated/retained tombstone timestamp is immutable');
  if(fixtureCase.removed){
   assert.deepEqual(s.graph.edges,[fixtureCase.retained]);assert.deepEqual(stored.edges,[fixtureCase.retained]);
   assert.deepEqual(s.graph.contributions,before.state.graph.contributions,'all endpoint and retired source facts survive byte-for-byte');assert.deepEqual(stored.contributions,before.state.graph.contributions);
   for(const table of ['shared_tracking_revision','shared_tracking_adoption','shared_tracking_preview','shared_demand_revision','shop_snapshot','operation_response'])assert.ok(!JSON.stringify((await db.query('SELECT to_jsonb(t) value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes(fixtureCase.removed.confirmation.evidence),table);
  }else{
   assert.deepEqual(s.graph.contributions.find(c=>c.id===fixtureCase.survivor.id),fixtureCase.survivor);
   assert.equal(s.basket.find(l=>l.id===f.basket.lineId).name,fixtureCase.independent);assert.equal(stored.lines.find(l=>l.id===f.basket.lineId).name,fixtureCase.independent);
   // These manual fields were typed independently, not synthesized from the
   // basket. Equal wording is a negative control for false copy attribution.
   assert.deepEqual(s.graph.contributions,before.state.graph.contributions);
   assert.deepEqual(stored.contributions,before.state.graph.contributions);
   for(const old of [fixtureCase.original,fixtureCase.retired]){const actual=s.graph.contributions.find(c=>c.id===old.id);assert.equal(actual.productName,fixtureCase.secret);assert.equal(actual.originalText,fixtureCase.secret);}
   const noCopiedLabel=(values,where)=>assert.ok(values.every(value=>value!==fixtureCase.secret),where);
   for(const row of (await db.query('SELECT state,projection,evidence FROM (SELECT state,projection,NULL::jsonb AS evidence FROM ritc.shared_tracking_revision WHERE household_id=$1 UNION ALL SELECT NULL,NULL,evidence FROM ritc.shared_tracking_adoption WHERE household_id=$1) copies',[f.h])).rows){
    assert.equal(row.evidence,null,'first-adoption effect payload is invalidated');const state=row.state??row.projection?.state;if(state){noCopiedLabel(state.basket.map(l=>l.name),'tracking basket labels');noCopiedLabel(state.graph.lines.map(l=>l.name),'tracking graph line labels');}
   }
   for(const row of (await db.query('SELECT graph FROM ritc.shared_demand_revision WHERE household_id=$1',[f.h])).rows)noCopiedLabel(row.graph.lines.map(l=>l.name),'canonical historical graph line labels');
   for(const row of (await db.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1',[f.h])).rows){noCopiedLabel(row.snapshot.lines.map(l=>l.originalItem),'historical basket labels');assert.equal(row.snapshot.trackingSeal,undefined);}
   noCopiedLabel((await db.query('SELECT original_item FROM ritc.basket_line WHERE household_id=$1',[f.h])).rows.map(l=>l.original_item),'current basket labels');
   for(const table of ['shared_tracking_preview','operation_response'])assert.ok(!JSON.stringify((await db.query('SELECT to_jsonb(t) value FROM ritc.'+table+' t WHERE household_id=$1',[f.h])).rows).includes(fixtureCase.secret),table);
  }
  assert.equal((await db.query('SELECT count(*)::int n FROM ritc.shared_tracking_basket_origin WHERE household_id=$1 AND member_id=$2',[f.h,fixtureCase.eraser.id])).rows[0].n,0,'target short-label hashes are erased after projection');
  assert.ok((await db.query('SELECT count(*)::int n FROM ritc.shared_tracking_basket_origin WHERE household_id=$1 AND member_id=$2',[f.h,f.owner.id])).rows[0].n>0,'other members retain their own origin evidence');
  assert.equal((await db.query('SELECT evidence FROM ritc.shared_tracking_adoption WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows[0].evidence,null);
  return s;
 }
 async function recover(c){const p=await page(c.f);assert.equal(p.status,'reviewRequired');const packs=c.before.state.packReviews;await applyIntent(c.f,{mode:'recover',base:baseOf(p),packs});const after=await page(c.f);assert.equal(after.status,'enabled');assert.ok(after.freezeReview);assert.deepEqual(after.state.graph.usedIds,c.before.state.graph.usedIds);if(c.removed)assert.deepEqual(after.state.graph.edges,[c.retained]);else assert.equal(after.state.basket.find(l=>l.id===c.f.basket.lineId).name,c.independent);return after;}
 return {linkAuthor,legacyLabel,erase,assertProjection,recover};
}
