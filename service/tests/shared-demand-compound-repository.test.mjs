import test from 'node:test';
import assert from 'node:assert/strict';
import {readTrackingHistory,loadRequestUndoTrackingMapping} from '../dist/shared-demand-tracking-repository.js';
import {recordFoodOperationEffect} from '../dist/shared-demand-repository.js';
import {mealComponentForTracking} from '../dist/shared-demand-tracking-meal.js';
import {digest} from '../dist/database.js';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const shop={shop_id:id(2),revision:4,authority_epoch:1};
const repo={options:{trackingV2:true},requireShopper(){},requireDraft(){}};
test('history route is content-free operation metadata, including erased request compound',async()=>{
 const rows=[{operation_id:id(3),kind:'shop.patch',shop_revision:2,committed_at:new Date('2026-11-10T12:00:00Z'),retained:true,reversed:false},
  {operation_id:id(4),kind:'request.apply',shop_revision:3,committed_at:new Date('2026-11-10T12:00:01Z'),retained:false,reversed:false}];
 const result=await readTrackingHistory(repo,{householdId:id(1),db:{async query(sql,args){assert.deepEqual(args,[id(1),id(2)]);assert.match(sql,/o\.kind/);return{rows};}}},shop);
 assert.deepEqual(result.items.map(x=>[x.reviewRoute,x.status]),[['tracking','current_preview_required'],['requestAcceptance','unavailable']]);
 assert.equal(JSON.stringify(result).includes('evidence'),false);
});
test('unknown recorded operation kind cannot fall back to food-only Undo',async()=>{
 await assert.rejects(()=>readTrackingHistory(repo,{householdId:id(1),db:{async query(){return{rows:[{kind:'future.operation'}]};}}},shop),e=>e.code==='tracking_history_route_unavailable');
});
test('request mapping loads first exact row and never skips redaction to select later reconstructed authority',async()=>{
 let calls=0;
 await assert.rejects(()=>loadRequestUndoTrackingMapping({householdId:id(1),db:{async query(sql,args){calls++;assert.deepEqual(args,[id(1),id(2),3]);
  assert.match(sql,/ORDER BY t\.shop_revision ASC LIMIT 1/);assert.doesNotMatch(sql,/state IS NOT NULL/);return{rows:[{state:null,state_digest:null}]};}}},shop,3),e=>e.code==='tracking_history_unavailable');
 assert.equal(calls,1);
});
for(const create of [false,true])test(`first-adoption ${create?'creation':'edit'} records the same immutable meal component as ordinary post-adoption flow`,async()=>{
 const occurrence=id(40),old={household_id:id(1),shop_id:id(2),occurrence_id:occurrence,revision:2,actor_id:id(8),meal:{title:'Dinner',day:null,kind:'dinner',portions:2,protected:false}};
 const next={...old.meal,title:'Reviewed dinner'},queries=[];let effect,mealEffect,creation;
 const ctx={householdId:id(1),member:{member_id:id(9)},db:{async query(sql,args){queries.push(sql);
  if(sql.startsWith('SELECT snapshot,digest'))return{rows:[]};
  if(sql.startsWith('INSERT INTO ritc.shared_food_operation_effect')){effect=args;return{rows:[]};}
  if(sql.startsWith('SELECT * FROM ritc.shared_meal_revision'))return{rows:[old]};
  if(sql.startsWith('INSERT INTO ritc.shared_meal_occurrence_identity'))return{rows:[{occurrence_id:occurrence}]};
  if(sql.startsWith('INSERT INTO ritc.shared_food_meal_creation_effect')){creation={household_id:args[0],shop_id:args[1],operation_id:args[2],occurrence_id:args[3],base_shop_revision:args[4],result_meal_revision:args[5],absence_digest:args[6],result_meal_digest:args[7],first_operation_id:args[2],first_shop_revision:args[5]};return{rows:[]};}
  if(sql.startsWith('INSERT INTO ritc.shared_food_meal_effect')){mealEffect={household_id:args[0],shop_id:args[1],operation_id:args[2],occurrence_id:args[3],before_meal_revision:args[4],result_meal_revision:args[5],before_meal_digest:args[6],result_meal_digest:args[7],proposal_kind:args[8],proposal_id:args[9],proposal_digest:args[10]};return{rows:[]};}
  if(sql.startsWith('SELECT * FROM ritc.shared_food_meal_effect'))return{rows:mealEffect?[mealEffect]:[]};
  if(sql.startsWith('SELECT e.*,i.first_operation_id'))return{rows:creation?[creation]:[]};
  throw new Error('Unexpected query in bounded component fixture');
 }}};
 await recordFoodOperationEffect(ctx,shop,{mode:'adopt',action:{kind:'shop.patch',body:{quote:{currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:'2026-11-10T11:00:00Z',expiresAt:'2026-11-10T13:00:00Z'},lines:[],mealEdit:{occurrenceId:occurrence,baseMealRevision:create?null:2,meal:next}}}},id(3),0,1);
 assert.equal(effect[7],'first_adoption');assert.deepEqual(effect.slice(5,7),[0,1]);assert.equal(Boolean(creation),create);assert.equal(Boolean(mealEffect),!create);
 assert.ok(queries.findIndex(x=>x.startsWith('INSERT INTO ritc.shared_food_operation_effect'))<queries.findIndex(x=>x.startsWith('INSERT INTO ritc.shared_food_meal_')));
 const component=await mealComponentForTracking(ctx,shop,id(3));assert.equal(component.kind,'meal');assert.equal(component.occurrenceId,occurrence);
 const lineage={householdId:id(1),shopId:id(2),operationId:id(3),occurrenceId:occurrence,beforeRevision:create?null:2,afterRevision:5,
  beforeDigest:create?creation.absence_digest:mealEffect.before_meal_digest,afterDigest:create?creation.result_meal_digest:mealEffect.result_meal_digest,
  proposalKind:null,proposalId:null,proposalDigest:null};
 assert.equal(component.componentDigest,digest(lineage));
});
