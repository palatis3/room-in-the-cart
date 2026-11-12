import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {projectSharedHistory,readSharedRecordHistory} from '../dist/shared-records-history.js';
import {digest} from '../dist/database.js';
import {digest as trackingDigest} from '../dist/shared-demand-tracking.js';
import {ServiceError} from '../dist/errors.js';
const golden=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-records/history-v1.json',import.meta.url),'utf8'));
const foodGolden=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-records/history-food-v1.json',import.meta.url),'utf8'));
const carriedGolden=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-records/history-carried-v1.json',import.meta.url),'utf8'));
const copy=()=>structuredClone(golden.record),asOf=new Date(golden.asOf);
const denied=e=>e instanceof ServiceError&&e.code==='shared_history_unavailable';

test('history fixture preserves complete dated facts, unknown outcome and pending credit without live authority',()=>{
 const record=copy(),result=projectSharedHistory(record,asOf);
 assert.deepEqual(result,golden);assert.equal(result.recordDigest,digest(record));
 assert.equal(record.deliveries.observations[0].body.received.amount.numerator,8);
 assert.equal(record.deliveries.observations[1].body.usable.amount.numerator,6);
 assert.equal(record.deliveries.reservations[0].quantity.amount.numerator,2);
 assert.equal(record.decisions[0].outcome,null);
 assert.deepEqual(record.financialEntries.map(r=>r.kind),['postedCharge','pendingCredit']);
 const next=projectSharedHistory(record,new Date('2026-11-10T15:00:00Z'));
 assert.equal(next.recordDigest,result.recordDigest);assert.notEqual(next.asOf,result.asOf);
 for(const field of ['authorityEpoch','memberId','operationId','replayWindow','consent','clientKey'])assert.ok(!JSON.stringify(result).includes('"'+field+'"'));
 assert.deepEqual(record,copy());
});

test('strict history rejects nested authority, a foreign shop and dangling retained source references',()=>{
 const changes=[r=>{r.authorityEpoch=1;},r=>{r.deliveries.observations[0].body.replayWindow='secret';},
  r=>{r.decisions[0].shopId=r.origin.householdId;},r=>{r.cookSends[0].copyId=r.origin.householdId;},
  r=>{r.deliveries.sources[0].lineId=r.origin.householdId;},r=>{r.mealRevisions=[];}];
 for(const change of changes){const r=copy();change(r);assert.throws(()=>projectSharedHistory(r,asOf),denied);}
});

test('history never silently truncates rows, duplicates identities or oversized content',()=>{
 let r=copy();r.basketRevisions.push(r.basketRevisions[0]);assert.throws(()=>projectSharedHistory(r,asOf),denied);
 r=copy();r.cookSends=Array.from({length:2001},()=>r.cookSends[0]);assert.throws(()=>projectSharedHistory(r,asOf),denied);
 r=copy();r.cookCopies=Array.from({length:120},(_,i)=>({...r.cookCopies[0],copyId:`00000000-0000-4000-8000-${String(1000+i).padStart(12,'0')}`,version:i+1,text:'x'.repeat(16000)}));
 r.cookSends=[];assert.throws(()=>projectSharedHistory(r,asOf),denied);
});

function reader(options={}){
 const record=structuredClone(options.carried?carriedGolden.record:options.enriched?foodGolden.record:golden.record),calls=[],actor='00000000-0000-4000-8000-000000000900',sourceActor='00000000-0000-4000-8000-000000000901';
 const carried=record.stockHistory?.carriedDeliveries??[];
 const carriedSnapshot=c=>({shopId:c.originShopId,revision:c.source.placedRevision,lines:[{lineId:c.source.lineId,originalItem:'Private source basket wording',packs:1,unitPriceMinor:12345,feeEligible:true}],quote:record.basketRevisions[0].quote});
 const ctx={householdId:record.origin.householdId,member:{member_id:actor,kind:'adult',state:'active'},now:asOf,
  db:{query:async(sql,values)=>{
   calls.push({sql,values});assert.match(sql,/^SELECT /);assert.equal(values[0],record.origin.householdId);
   let rows;
   if(sql==='SELECT history_retired_at FROM ritc.shop WHERE household_id=$1 AND shop_id=$2')rows=options.missing?[]:[{history_retired_at:options.retired?asOf:null}];
   else if(sql.startsWith('SELECT DISTINCT p.shop_id'))rows=options.joint||options.jointAllowed?[{shop_id:record.origin.householdId,shopper_id:options.joint?'different-shopper':actor,history_retired_at:null}]:[];
   else if(sql.startsWith('SELECT l.lot_id,l.origin_shop_id'))rows=(record.stockHistory?.lots??[]).map(l=>({lot_id:l.lotId,origin_shop_id:carried.find(c=>c.source.sourceId===l.lotId)?.originShopId??(options.foreignDelivery&&l.deliverySourceId?record.origin.householdId:record.origin.shopId),delivery_source_id:l.deliverySourceId,actor_id:actor,history_retired_at:null}));
   else if(sql.startsWith('SELECT d.source_id,d.shop_id'))rows=carried.map(c=>({source_id:c.source.sourceId,shop_id:c.originShopId,actor_id:sourceActor,snapshot_digest:options.erasedCarried?'0'.repeat(64):digest(carriedSnapshot(c))}));
   else if(sql.startsWith('SELECT DISTINCT e.actor_id'))rows=record.stockHistory?[{actor_id:actor,history_retired_at:options.retiredStock?asOf:null}]:[];
   else if(sql.includes(') retained_sources'))rows=carried.length?[{member_id:sourceActor}]:[];
   else if(sql.startsWith('SELECT DISTINCT member_id'))rows=[{member_id:actor}];
   else if(sql.startsWith('SELECT * FROM ritc.member'))rows=values[1].map(member_id=>({member_id,kind:'adult',state:options.revoked||options.revokedCarried&&member_id===sourceActor?'revoked':'active'}));
   else if(sql.includes('FROM ritc.shop_snapshot'))rows=record.basketRevisions.map(r=>{
    const snapshot={shopId:record.origin.shopId,revision:r.revision,phase:r.phase,quote:r.quote,lines:r.basketLines,mealRefs:[{occurrenceId:record.mealRevisions[0].occurrenceId,revision:options.missingMeal?999:1}],authorityEpoch:123,trackingSeal:{secret:'not portable'}};
    return{revision:r.revision,purpose:r.purpose,created_at:r.recordedAt,snapshot,digest:options.erased?'0'.repeat(64):digest(snapshot)};
   });
   else if(sql.includes('FROM ritc.shared_meal_revision'))rows=record.mealRevisions;
   else if(sql.includes('FROM ritc.dated_cook_copy'))rows=record.cookCopies;
   else if(sql.includes('FROM ritc.cook_copy_send'))rows=record.cookSends;
   else if(sql.startsWith('SELECT d.shop_id AS "originShopId"'))rows=carried.map(c=>({originShopId:c.originShopId,...c.source,retained_snapshot:carriedSnapshot(c),retained_digest:digest(carriedSnapshot(c))}));
   else if(sql.startsWith('SELECT source_id,kind,recorded_at,body'))rows=carried.flatMap(c=>c.observations.map(o=>({source_id:c.source.sourceId,kind:o.kind,recorded_at:o.recordedAt,body:o.body})));
   else if(sql.includes('FROM ritc.delivery_source'))rows=record.deliveries.sources;
   else if(sql.includes('FROM ritc.delivery_observation'))rows=record.deliveries.observations;
   else if(sql.includes('FROM ritc.delivery_ingredient_review'))rows=record.deliveries.matches;
   else if(sql.includes('FROM ritc.delivery_reservation'))rows=record.deliveries.reservations;
   else if(sql.includes('FROM ritc.family_decision'))rows=record.decisions;
   else if(sql.includes('FROM ritc.financial_entry'))rows=record.financialEntries;
   else if(sql.includes('FROM ritc.price_observation')){assert.match(sql,/retired_at IS NULL/);rows=record.priceObservations.map(record=>({record}));}
   else if(sql.includes('FROM ritc.shared_demand_revision'))rows=(record.foodHistory?.demandRevisions??[]).map(r=>({shop_revision:r.shopRevision,predecessor:r.predecessorRevision,created_at:r.recordedAt,graph:r.graph,graph_digest:options.erasedFood?null:digest(r.graph),pack_review:r.packReviews}));
   else if(sql.includes('FROM ritc.shared_tracking_revision'))rows=(record.foodHistory?.trackingRevisions??[]).map(r=>{
    const state={schemaVersion:2,authorityEpoch:2,privacyRevision:0,quoteDigest:digest(record.basketRevisions.find(b=>b.revision===r.shopRevision).quote),...r.food};
    return{shop_revision:r.shopRevision,state,state_digest:trackingDigest(state),projection:null,committed_at:r.recordedAt};
   });
   else if(sql.includes('FROM ritc.pantry_lot'))rows=record.stockHistory?.lots??[];
   else if(sql.includes('FROM ritc.pantry_event'))rows=(record.stockHistory?.events??[]).map(e=>({lot_id:e.lotId,pantry_revision:e.pantryRevision,kind:e.kind,occurrence_id:e.occurrenceId??null,meal_revision:e.mealRevision??null,ingredient_id:e.ingredientId??null,group_id:e.groupId??null,enabled:e.selected??e.matched??null,confirmed_at:e.confirmedAt??null,quantity:e.quantity??null,committed_at:e.recordedAt}));
   else assert.fail(sql);
   return{rows:structuredClone(rows),rowCount:rows.length};
  }} };
 const repo={requireShopper:()=>{if(options.denied)throw new ServiceError(404,'unavailable','Unavailable');},consent:async()=>{if(options.consentEnded)throw new ServiceError(403,'access_ended','Access ended');}};
 const shop={household_id:record.origin.householdId,shop_id:record.origin.shopId,revision:record.shopRevision,phase:record.phase};
 return{calls,run:includeRetirementStatus=>readSharedRecordHistory(repo,ctx,shop,includeRetirementStatus)};
}

test('authorized Free history uses bounded read-only scope and strips snapshot-only receipts',async()=>{
 const f=reader(),result=await f.run();assert.deepEqual(result.record,{...golden.record,foodHistory:{demandRevisions:[],trackingRevisions:[]},stockHistory:{lots:[],events:[],carriedDeliveries:[]}});
 assert.ok(f.calls.filter(r=>r.sql.includes('LIMIT 2001')).length>=12);
 for(const call of f.calls.filter(r=>!Array.isArray(r.values[1])))assert.equal(call.values[1],golden.record.origin.shopId);
});

test('shopper denial and retired history stop before historical payload reads',async()=>{
 for(const includeRetirementStatus of [false,true]){
  const deniedReader=reader({denied:true,retired:true});
  await assert.rejects(deniedReader.run(includeRetirementStatus),e=>e.status===404&&e.code==='unavailable');
  assert.equal(deniedReader.calls.length,0);
  const missing=reader({missing:true});
  await assert.rejects(missing.run(includeRetirementStatus),e=>e.status===404&&e.code==='unavailable');
  assert.equal(missing.calls.length,1);
  const retired=reader({retired:true});
  const expected=includeRetirementStatus?'shared_history_retired':'unavailable';
  await assert.rejects(retired.run(includeRetirementStatus),e=>e.status===404&&e.code===expected);
  assert.equal(retired.calls.length,1);
 }
});

test('revoked author, ended consent and cross-shop cook source fail before payload reads',async()=>{
 for(const options of [{revoked:true},{consentEnded:true},{joint:true}]){
  const f=reader(options);await assert.rejects(f.run(),e=>e instanceof ServiceError);
  assert.ok(!f.calls.some(c=>c.sql.startsWith('SELECT revision,purpose')));
 }
});

test('erased historical snapshot cannot be reconstructed from retained lines',async()=>{
 const f=reader({erased:true});await assert.rejects(f.run(),denied);
 assert.ok(!f.calls.some(c=>c.sql.includes('FROM ritc.financial_entry')&&!c.sql.startsWith('SELECT DISTINCT')));
});

test('missing historical meal source fails rather than exporting a silently incomplete basket history',async()=>{
 const f=reader({missingMeal:true});await assert.rejects(f.run(),denied);
});

test('historical food and stock retain exact partition, protected release and known/unknown/zero chronology',async()=>{
 assert.deepEqual(projectSharedHistory(foodGolden.record,asOf),foodGolden);
 assert.deepEqual((await reader({enriched:true}).run()).record,{...foodGolden.record,stockHistory:{...foodGolden.record.stockHistory,carriedDeliveries:[]}});
 const {foodHistory,stockHistory}=foodGolden.record;
 assert.equal(foodHistory.demandRevisions[0].graph.edges[0].kind,'withinExisting');
 assert.deepEqual(foodHistory.trackingRevisions[1].food.unbound[0].transferred,foodHistory.demandRevisions[0].graph.contributions[1]);
 assert.deepEqual(stockHistory.events.filter(e=>e.kind==='observe').map(e=>e.quantity?.amount.numerator??null),[4,2,null,0]);
 assert.deepEqual(stockHistory.events.filter(e=>e.kind==='reserve').map(e=>e.quantity?.amount.numerator??null),[2,null]);
 assert.equal(golden.record.foodHistory,undefined);assert.equal(golden.record.stockHistory,undefined);
});

test('historical scopes reject wrong graph ancestry, injected authority, invalid stock references and unavailable retained sources',async()=>{
 const mutations=[r=>{r.foodHistory.demandRevisions[1].predecessorRevision=null;},
  r=>{r.foodHistory.trackingRevisions[0].food.authorityEpoch=1;},
  r=>{r.foodHistory.trackingRevisions[0].food.catalog[0].revision=999;},
  r=>{r.stockHistory.events[0].lotId=r.origin.householdId;},
  r=>{r.stockHistory.events[0].pantryRevision=2;},
  r=>{r.foodHistory.demandRevisions[0].packReviews=[];}];
 for(const mutate of mutations){const r=structuredClone(foodGolden.record);mutate(r);assert.throws(()=>projectSharedHistory(r,asOf),denied);}
 for(const options of [{foreignDelivery:true},{retiredStock:true},{erasedFood:true}])await assert.rejects(reader({enriched:true,...options}).run(),denied);
});

test('carried delivery chronology and authorized cross-shop cook copies export no source budget or live authority',async()=>{
 const result=await reader({carried:true,jointAllowed:true}).run();assert.deepEqual(result,carriedGolden);
 const c=result.record.stockHistory.carriedDeliveries[0];assert.equal(c.originShopId,carriedGolden.record.stockHistory.carriedDeliveries[0].originShopId);
 assert.deepEqual(c.observations.filter(o=>o.kind==='usable').map(o=>o.body.usable?.amount.numerator??null),[8,null,0]);
 assert.ok(!JSON.stringify(result).includes('Private source basket wording'));
 assert.equal(foodGolden.record.stockHistory.carriedDeliveries,undefined);
 for(const options of [{joint:true},{revokedCarried:true},{erasedCarried:true}])await assert.rejects(reader({carried:true,...options}).run(),denied);
});

test('carried sources cannot borrow another observation chain, selected-shop identity, or mismatched lot metadata',()=>{
 const changes=[r=>{r.stockHistory.carriedDeliveries[0].originShopId=r.origin.shopId;},
  r=>{r.stockHistory.carriedDeliveries[0].observations[2].body.predecessorId=null;},
  r=>{r.stockHistory.carriedDeliveries[0].observations[1].body.arrivalObservationId=r.deliveries.observations[0].body.observationId;},
  r=>{r.stockHistory.carriedDeliveries[0].observations.reverse();},
  r=>{r.stockHistory.carriedDeliveries[0].source.foodName='Different food';},
  r=>{r.stockHistory.carriedDeliveries[0].source.authorityEpoch=1;}];
 for(const change of changes){const r=structuredClone(carriedGolden.record);change(r);assert.throws(()=>projectSharedHistory(r,asOf),denied);}
 const noObservations=structuredClone(carriedGolden.record);noObservations.stockHistory.carriedDeliveries[0].observations=[];
 assert.doesNotThrow(()=>projectSharedHistory(noObservations,asOf));
});
