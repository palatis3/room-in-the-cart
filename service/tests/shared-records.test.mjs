import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {projectSharedRecord,readSharedRecordSnapshot} from '../dist/shared-records.js';
import {digest} from '../dist/database.js';
import {demandLineTotals} from '../dist/shared-demand-domain.js';
const golden=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-demand/conservation-v1.json',import.meta.url),'utf8'));
const at='2026-11-09T13:00:00.000Z';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function fixture(){
 const graph=structuredClone(golden.graph),occurrences=new Map();
 for(const c of graph.contributions){const s=c.source;if(s.kind!=='meal'&&s.kind!=='reservation')continue;
  const occurrenceId=s.kind==='meal'?s.occurrenceId:s.originOccurrenceId;
  let row=occurrences.get(occurrenceId);if(!row){row={occurrenceId,revision:1,meal:{title:'Saved meal',day:null,kind:'dinner',portions:8,protected:false,planning:{groups:[],ingredients:[],bindings:[]}}};occurrences.set(occurrenceId,row);}
  const quantity={amount:{numerator:Number(c.quantity.amount.numerator),denominator:Number(c.quantity.amount.denominator)},unit:c.quantity.unit,originalLiteral:c.quantity.originalLiteral};
  row.meal.planning.groups.push({id:s.groupId,name:s.kind==='reservation'?'Lunch':'Dinner',servings:quantity.amount,protected:s.kind==='reservation'});
  row.meal.planning.ingredients.push({id:s.ingredientId,name:c.productName,quantity,groupIds:[s.groupId],exclusions:[]});
  row.meal.planning.bindings.push({id:s.bindingId,groupId:s.groupId,ingredientId:s.ingredientId,quantity});
 }
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:2000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:at,expiresAt:'2026-11-10T13:00:00.000Z'};
 const shop={household_id:graph.householdId,shop_id:graph.shopId,shopper_id:id(900),authority_epoch:7,revision:4,phase:'draft',quote,frozen_revision:null,placed_revision:null,supply_revision:0,demand_revision:graph.revision,demand_review_required:false};
 const lines=[{lineId:graph.lines[0].id,originalItem:'Wraps',packs:2,unitPriceMinor:200,feeEligible:true}];
 const page={schemaVersion:1,shopId:shop.shop_id,shopRevision:shop.revision,authorityEpoch:shop.authority_epoch,status:'enabled',graph,graphDigest:digest(graph),totals:demandLineTotals(graph),legacySources:null};
 const pack_review=[{lineId:lines[0].lineId,usablePerPack:{amount:{numerator:'6',denominator:'1'},unit:'count',originalLiteral:'6 wraps per pack',confirmedConversion:null},acceptUnresolved:false}];
 const snapshot={shopId:shop.shop_id,revision:4,quote,lines};
 return {shop,page,lines,meals:[...occurrences.values()],requestSources:[],graphRow:{revision:graph.revision,predecessor:graph.revision===1?null:graph.revision-1,created_at:at,graph_digest:page.graphDigest,pack_review,predecessor_digest:null},snapshotRow:{revision:4,purpose:'patch',created_at:at,snapshot,digest:digest(snapshot)}};
}
function refresh(f){f.page.graphDigest=digest(f.page.graph);f.graphRow.graph_digest=f.page.graphDigest;f.page.totals=demandLineTotals(f.page.graph);}

test('manual12/taco6/quesadilla4/protected2 graph and exact pack basis survive without flattening',()=>{
 const f=fixture(),before=structuredClone(f),r=projectSharedRecord(f,new Date(at));
 assert.deepEqual(f,before);assert.deepEqual(r.record.food.graph,golden.graph);
 assert.deepEqual(r.record.food.totals[0].quantity,{numerator:'12',denominator:'1'});
 assert.equal(r.record.basketLines[0].packs,2);assert.equal(r.record.food.packReview.values[0].usablePerPack.amount.numerator,'6');
 assert.deepEqual(r.record.food.graph.edges,golden.graph.edges);assert.deepEqual(r.record.mealOccurrences,f.meals);
 assert.equal(r.record.food.graph.contributions.find(c=>c.source.kind==='reservation').source.purpose,'School lunch');
});
test('stable record digest excludes fresh observation time; lineage does not claim observation is save time',()=>{
 const f=fixture(),a=projectSharedRecord(f,new Date(at)),b=projectSharedRecord(f,new Date('2026-11-09T14:00:00Z'));
 assert.equal(a.recordDigest,b.recordDigest);assert.notEqual(a.asOf,b.asOf);assert.equal(a.record.lineage.graph.recordedAt,at);
});
test('authority, credentials, actor and command/replay state are not copied into the record',()=>{
 const f=fixture();Object.assign(f.shop,{token:'secret',actor_id:'secret',device_id:'secret',client_key:'secret',role:'organizer',billing:{paid:true}});
 const text=JSON.stringify(projectSharedRecord(f,new Date(at)));for(const value of ['secret','authority_epoch','authorityEpoch','shopper_id','device_id','client_key','billing'])assert.ok(!text.includes(value),value);
});
test('unknown food stays null with exact original literal and explicit accepted unknown pack basis',()=>{
 const f=fixture();f.page.graph.contributions=f.page.graph.contributions.slice(0,1);f.page.graph.contributions[0].quantity=null;
 f.page.graph.contributions[0].originalText='Some wraps — quantity not supplied';f.page.graph.edges=[];f.meals=[];
 f.graphRow.pack_review[0].usablePerPack=null;f.graphRow.pack_review[0].acceptUnresolved=true;refresh(f);
 const r=projectSharedRecord(f,new Date(at));assert.equal(r.record.food.totals[0].quantity,null);assert.equal(r.record.food.graph.contributions[0].originalText,'Some wraps — quantity not supplied');assert.deepEqual(r.record.food.packReview.values,f.graphRow.pack_review);
});
test('accepted request preserves original unparsed quantity and exact accepted line/revision',()=>{
 const f=fixture(),source={...structuredClone(f.page.graph.contributions[0]),id:id(800),source:{kind:'request',requestId:id(801),appliedRequestRevision:3},originalText:'Original requested wraps',quantity:null};
 f.page.graph.contributions.push(source);f.page.graph.usedIds.push(source.id);f.requestSources=[{requestId:id(801),lineId:source.lineId,reviewedRevision:3,originalItem:source.originalText,originalQuantityText:'one packet if available'}];refresh(f);
 const r=projectSharedRecord(f,new Date(at));assert.deepEqual(r.record.requestSources,f.requestSources);assert.equal(r.record.food.totals[0].quantity,null);
 f.requestSources[0].reviewedRevision=4;assert.throws(()=>projectSharedRecord(f,new Date(at)),/shared_record_unavailable/);
});
test('missing pack review is never inferred from current basket or food total',()=>{
 const f=fixture();f.graphRow.pack_review=null;assert.throws(()=>projectSharedRecord(f,new Date(at)),/shared_record_unavailable/);
});
test('wrong pack IDs or duplicates reject the record',()=>{
 for(const edit of [p=>p[0].lineId=id(999),p=>p.push(structuredClone(p[0]))]){const f=fixture();edit(f.graphRow.pack_review);assert.throws(()=>projectSharedRecord(f,new Date(at)),/shared_record_unavailable/);}
});
test('corrupted graph digest and fabricated canonical totals are rejected',()=>{
 const f=fixture();f.page.graphDigest='0'.repeat(64);assert.throws(()=>projectSharedRecord(f,new Date(at)),/shared_record_unavailable/);
 const g=fixture();g.page.totals[0].quantity.numerator='99';assert.throws(()=>projectSharedRecord(g,new Date(at)),/shared_record_unavailable/);
});
test('redacted basis stays visibly review-required without resurrecting old accepted packs/digest',()=>{
 const f=fixture();f.shop.demand_review_required=true;f.page.status='reviewRequired';f.page.graphDigest=null;f.graphRow.graph_digest=null;f.graphRow.pack_review=null;f.snapshotRow.digest='0'.repeat(64);
 const r=projectSharedRecord(f,new Date(at));assert.deepEqual(r.record.food.packReview,{state:'erased',graphRevision:f.page.graph.revision,values:null});assert.equal(r.record.lineage.basket.digest,null);assert.equal(r.record.lineage.basket.integrity,'redacted');
});
test('redacted historical snapshot content is never copied back into the current record',()=>{
 const f=fixture();f.shop.demand_review_required=true;f.page.status='reviewRequired';f.page.graphDigest=null;f.graphRow.graph_digest=null;f.graphRow.pack_review=null;
 f.snapshotRow.snapshot.lines=[{originalItem:'PRIVATE OLD ERASED WORDING'}];f.snapshotRow.digest='0'.repeat(64);
 const r=projectSharedRecord(f,new Date(at));assert.ok(!JSON.stringify(r).includes('PRIVATE OLD ERASED WORDING'));assert.equal(r.record.lineage.basket.integrity,'redacted');
});
test('legacy is explicit with no fabricated graph or pack food quantity',()=>{
 const f=fixture();f.shop.demand_revision=null;f.page.status='legacy';f.page.graph=null;f.page.graphDigest=null;f.page.totals=[];f.page.legacySources={sources:[]};f.graphRow=null;
 const r=projectSharedRecord(f,new Date(at));assert.equal(r.record.food.graph,null);assert.deepEqual(r.record.food.packReview,{state:'notRecorded',graphRevision:null,values:null});
});
test('wrong base, foreign snapshot, unknown private fields and missing meal source reject',()=>{
 const edits=[f=>f.page.shopRevision++,f=>{f.snapshotRow.snapshot.shopId=id(999);f.snapshotRow.digest=digest(f.snapshotRow.snapshot);},f=>f.lines[0].memberName='private',f=>f.meals=[]];
 for(const edit of edits){const f=fixture();edit(f);assert.throws(()=>projectSharedRecord(f,new Date(at)));}
});
test('shopper permission denial happens before any source query',async()=>{
 let reads=0;const repo={requireShopper(){throw new Error('denied');},lines(){reads++;},meals(){reads++;}};
 await assert.rejects(readSharedRecordSnapshot(repo,{db:{query(){reads++;}}},fixture().shop),/denied/);assert.equal(reads,0);
});
test('bound reader uses scoped SELECTs only and returns accepted pack review rather than recomputed guesses',async()=>{
 const f=fixture(),queries=[];const repo={requireShopper(){},lines:async()=>f.lines,meals:async()=>f.meals};
 const ctx={householdId:f.shop.household_id,now:new Date(at),db:{async query(sql,args){queries.push({sql,args});
  assert.match(sql.trim(),/^SELECT/);assert.equal(args[0],f.shop.household_id);assert.equal(args[1],f.shop.shop_id);
  if(sql.includes('SELECT graph,graph_digest,receipt'))return {rows:[{graph:f.page.graph,graph_digest:f.page.graphDigest,receipt:{}}]};
  if(sql.includes('FROM ritc.request_link'))return {rows:[]};
  if(sql.includes('SELECT d.revision'))return {rows:[f.graphRow]};
  if(sql.includes('FROM ritc.shop_snapshot'))return {rows:[f.snapshotRow]};throw new Error('unexpected query');}}};
 const r=await readSharedRecordSnapshot(repo,ctx,f.shop);assert.equal(queries.length,4);assert.deepEqual(r.record.food.packReview.values,f.graphRow.pack_review);
});
