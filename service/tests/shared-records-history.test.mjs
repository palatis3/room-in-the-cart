import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {projectSharedHistory,readSharedRecordHistory} from '../dist/shared-records-history.js';
import {digest} from '../dist/database.js';
import {ServiceError} from '../dist/errors.js';
const golden=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-records/history-v1.json',import.meta.url),'utf8'));
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
 const record=copy(),calls=[],actor='00000000-0000-4000-8000-000000000900';
 const ctx={householdId:record.origin.householdId,member:{member_id:actor,kind:'adult',state:'active'},now:asOf,
  db:{query:async(sql,values)=>{
   calls.push({sql,values});assert.match(sql,/^SELECT /);assert.equal(values[0],record.origin.householdId);
   let rows;
   if(sql.startsWith('SELECT 1 FROM ritc.shop '))rows=options.retired?[]:[{}];
   else if(sql.startsWith('SELECT 1 FROM ritc.cook_copy_pantry_scope'))rows=options.joint?[{}]:[];
   else if(sql.startsWith('SELECT DISTINCT member_id'))rows=[{member_id:actor}];
   else if(sql.startsWith('SELECT * FROM ritc.member'))rows=[{member_id:actor,kind:'adult',state:options.revoked?'revoked':'active'}];
   else if(sql.includes('FROM ritc.shop_snapshot'))rows=record.basketRevisions.map(r=>{
    const snapshot={shopId:record.origin.shopId,revision:r.revision,phase:r.phase,quote:r.quote,lines:r.basketLines,mealRefs:[{occurrenceId:record.mealRevisions[0].occurrenceId,revision:options.missingMeal?999:1}],authorityEpoch:123,trackingSeal:{secret:'not portable'}};
    return{revision:r.revision,purpose:r.purpose,created_at:r.recordedAt,snapshot,digest:options.erased?'0'.repeat(64):digest(snapshot)};
   });
   else if(sql.includes('FROM ritc.shared_meal_revision'))rows=record.mealRevisions;
   else if(sql.includes('FROM ritc.dated_cook_copy'))rows=record.cookCopies;
   else if(sql.includes('FROM ritc.cook_copy_send'))rows=record.cookSends;
   else if(sql.includes('FROM ritc.delivery_source'))rows=record.deliveries.sources;
   else if(sql.includes('FROM ritc.delivery_observation'))rows=record.deliveries.observations;
   else if(sql.includes('FROM ritc.delivery_ingredient_review'))rows=record.deliveries.matches;
   else if(sql.includes('FROM ritc.delivery_reservation'))rows=record.deliveries.reservations;
   else if(sql.includes('FROM ritc.family_decision'))rows=record.decisions;
   else if(sql.includes('FROM ritc.financial_entry'))rows=record.financialEntries;
   else if(sql.includes('FROM ritc.price_observation')){assert.match(sql,/retired_at IS NULL/);rows=record.priceObservations.map(record=>({record}));}
   else assert.fail(sql);
   return{rows:structuredClone(rows),rowCount:rows.length};
  }} };
 const repo={requireShopper:()=>{if(options.denied)throw new ServiceError(404,'unavailable','Unavailable');},consent:async()=>{if(options.consentEnded)throw new ServiceError(403,'access_ended','Access ended');}};
 const shop={household_id:record.origin.householdId,shop_id:record.origin.shopId,revision:record.shopRevision,phase:record.phase};
 return{calls,run:()=>readSharedRecordHistory(repo,ctx,shop)};
}

test('authorized Free history uses bounded read-only scope and strips snapshot-only receipts',async()=>{
 const f=reader();assert.deepEqual(await f.run(),golden);
 assert.ok(f.calls.filter(r=>r.sql.includes('LIMIT 2001')).length>=12);
 for(const call of f.calls.filter(r=>!r.sql.startsWith('SELECT * FROM ritc.member')))assert.equal(call.values[1],golden.record.origin.shopId);
});

test('shopper denial and retired history stop before historical payload reads',async()=>{
 const deniedReader=reader({denied:true});await assert.rejects(deniedReader.run(),e=>e.code==='unavailable');assert.equal(deniedReader.calls.length,0);
 const retired=reader({retired:true});await assert.rejects(retired.run(),e=>e.code==='unavailable');assert.equal(retired.calls.length,1);
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
