import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {admin,runtime,worker,repo,maintenance,actor,call,ok,enroll,q,empty,line,fixture,send,source,draft,preview,apply,adopt,invited,count,head,acceptRequest,setup,candidate,review,undoCommand,own,state,append} from './request-acceptance-undo-fixture.mjs';

// Reacceptance must append a new generation, never recycle the retired source.
async function assertReacceptedGeneration(f,retired){
 const after=ok(await call(f.owner,f.path+'/demand')).graph,requestId=f.target.request.requestId;
 const rows=after.contributions.filter(c=>c.source.kind==='request'&&c.source.requestId===requestId);
 assert.equal(rows.length,2);const active=rows.filter(c=>c.removedAt===null);assert.equal(active.length,1);
 assert.equal(active[0].source.appliedRequestRevision,f.target.request.revision);
 assert.equal(active[0].originalText,f.target.request.originalItem);
 assert.ok(!retired.usedIds.includes(active[0].id));assert.ok(after.usedIds.includes(active[0].id));
 for(const row of retired.contributions)assert.deepEqual(after.contributions.find(c=>c.id===row.id),row);
 assert.ok(retired.usedIds.every(id=>after.usedIds.includes(id)));
 return after;
}

for(const kind of ['legacy','tracked'])for(const choice of ['add','link'])test(`request Undo ${kind} ${choice}: actual history, read-only Cancel, whole transition and later survivors`,async()=>{
 const f=await setup(kind,choice),apple={lineId:randomUUID(),originalItem:'Later apples',packs:1,unitPriceMinor:75,feeEligible:true},occurrenceId=randomUUID();await append(f,apple);await append(f,null,{occurrenceId,baseMealRevision:null,meal:{title:'Later dinner',day:null,kind:'dinner',portions:2,protected:false}});
 const original=await state(f),c=ok(await candidate(f));assert.deepEqual(await state(f),original);assert.equal(c.foodBefore.kind,kind==='tracked'?'partition':'legacy');assert.equal(c.requestUndo.originalQuantityText,original.own.ownQuantity);assert.equal(c.requestUndo.current.status,'added');assert.equal(c.requestUndo.restored.status,'pending');
 const previewed=ok((await review(f,c)).response);assert.deepEqual(await state(f),original,'Cancel leaves every persistent operation effect unchanged');
 const command=undoCommand(f,previewed),receipt=ok(await call(f.owner,f.base+'/commands','POST',command)),after=await state(f);
 assert.equal(receipt.operationId,previewed.operationId);assert.equal(after.own.status,'pending');assert.equal(after.own.revision,original.own.revision+1);assert.equal(after.own.originalItem,original.own.originalItem);assert.equal(after.own.ownQuantity,original.own.ownQuantity);assert.equal(after.own.authoredAt,original.own.authoredAt);assert.deepEqual(after.shop.meals,original.shop.meals);assert.deepEqual(after.shop.quote,original.shop.quote);assert.deepEqual(after.shop.lines.find(l=>l.lineId===apple.lineId),apple);
 assert.equal(after.links.length,0);assert.equal(after.inverses,1);assert.equal(after.operations,original.operations+1);assert.equal(after.graphs,original.graphs+(kind==='tracked'?1:0));assert.equal(after.snapshots,original.snapshots+1);assert.equal(after.shop.lines.some(l=>l.lineId===f.basket.lineId),true);
 assert.equal(JSON.stringify(after.own).includes('totalMinor'),false);assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',command)),receipt);assert.deepEqual(await state(f),after);
 if(kind==='tracked'){const snapshots=(await admin.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2 AND revision=ANY($3::integer[])',[f.h,f.shopId,[f.target.receipt.shopRevision-1,f.target.receipt.shopRevision]])).rows;assert.ok(snapshots.every(s=>s.snapshot.tracking?.schemaVersion===2));}
});
for(const status of ['clarified','deferred'])test('request Undo restores actual '+status+' outcome and route at a new revision',async()=>{const f=await setup('legacy','link',status),p=ok((await review(f)).response),before=await own(f);ok(await call(f.owner,f.base+'/commands','POST',undoCommand(f,p)));const after=await own(f);assert.equal(after.status,status);assert.equal(after.route,status==='deferred'?'next':'current');assert.equal(after.revision,before.revision+1);assert.equal(after.clarification,f.target.request.clarification);});
for(const kind of ['legacy','tracked'])test(kind+' Undo lost reply and original Add replay after later reacceptance never reapply effects',async()=>{
 const f=await setup(kind),p=ok((await review(f)).response),command=undoCommand(f,p),receipt=ok(await call(f.owner,f.base+'/commands','POST',command));
 const retired=kind==='tracked'?ok(await call(f.owner,f.path+'/demand')).graph:null;
 const originalTarget=f.target;const current=await own(f),s=await head(f);const edited=ok(await send(f,'request.edit',{requestId:current.requestId,originalItem:'Later author wording',ownQuantity:'later amount'},s.shopRevision,s.authorityEpoch,f.author,{base:{shopRevision:s.shopRevision,authorityEpoch:s.authorityEpoch,requestRevision:current.revision}})).request;
 f.target=await acceptRequest(f,edited,'link');const accepted=retired?await assertReacceptedGeneration(f,retired):null;const before=await state(f);
 assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',command)),receipt);assert.deepEqual(ok(await call(f.owner,f.base+'/commands','POST',originalTarget.command)),originalTarget.receipt);assert.deepEqual(await state(f),before);if(accepted)assert.deepEqual(ok(await call(f.owner,f.path+'/demand')).graph,accepted);
 assert.equal((await call(f.owner,f.base+'/commands','POST',{...command,body:{...command.body,quote:{...command.body.quote,capMinor:1}}})).status,409);assert.deepEqual(await state(f),before);
});
test('request Undo exact late-operation failure rolls back link, graph, status, inverse and preview consumption',async()=>{
 const f=await setup(),p=ok((await review(f)).response),command=undoCommand(f,p),before=await state(f);const fn='request_undo_failure_'+randomBytes(6).toString('hex');
 await admin.query(`CREATE FUNCTION ritc.${fn}() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.operation_id='${p.operationId}'::uuid THEN RAISE EXCEPTION 'injected request undo rollback';END IF;RETURN NEW;END$$; CREATE TRIGGER ${fn} BEFORE INSERT ON ritc.operation FOR EACH ROW EXECUTE FUNCTION ritc.${fn}()`);
 try{assert.equal((await call(f.owner,f.base+'/commands','POST',command)).status,503);assert.deepEqual(await state(f),before);assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.request_acceptance_preview WHERE household_id=$1 AND preview_id=$2',[f.h,p.previewId])).rows[0].n,1);}finally{await admin.query(`DROP TRIGGER ${fn} ON ritc.operation;DROP FUNCTION ritc.${fn}()`);}
 ok(await call(f.owner,f.base+'/commands','POST',command));assert.equal((await state(f)).inverses,1);
});
test('request Undo held preview requires unchanged request, live author, device and exact acknowledgments',async()=>{
 const f=await setup(),c=ok(await candidate(f)),r=await review(f,c),p=ok(r.response),command=undoCommand(f,p),before=await state(f);
 assert.equal((await call(f.owner,f.path+'/requests/operation-undo-previews','POST',{...r.input,packs:[]})).status,409);
 const second=await actor(f.owner.subject);await enroll(second,f.h);assert.equal((await call(second,f.base+'/commands','POST',{...command,replayWindow:second.window})).status,409);
 await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[f.h,f.author.id]);assert.equal((await call(f.owner,f.base+'/commands','POST',command)).status,409);
 assert.equal(await count(f,'request_acceptance_inverse'),0);assert.deepEqual(await head(f),before.shop);
});
test('request Undo preview expiry keeps original created/expires constraint and consumes nothing',async()=>{const f=await setup(),p=ok((await review(f)).response),before=await state(f);await admin.query("UPDATE ritc.request_acceptance_preview SET created_at=created_at-interval '11 minutes',expires_at=expires_at-interval '11 minutes' WHERE household_id=$1 AND preview_id=$2",[f.h,p.previewId]);assert.equal((await call(f.owner,f.base+'/commands','POST',undoCommand(f,p))).status,409);assert.deepEqual(await state(f),before);});
test('request Undo retired-link erasure scrubs private legacy acceptance history and preserves independent same-label line',async()=>{
 const f=await setup('legacy'),p=ok((await review(f)).response),command=undoCommand(f,p);ok(await call(f.owner,f.base+'/commands','POST',command));const other={lineId:randomUUID(),originalItem:f.target.decision.line.originalItem,packs:1,unitPriceMinor:60,feeEligible:true};await append(f,other);
 ok(await call(f.author,'/v1/privacy/deletions','POST',{clientKey:randomUUID(),statusToken:randomBytes(32).toString('base64url'),confirm:true,households:[{householdId:f.h,organizer:'none',shops:[],eraseChildProfiles:[]}]}),202);assert.equal((await maintenance.run({batchSize:1})).completed,1);
 assert.equal((await call(f.owner,f.base+'/commands','POST',command)).status,409);const rows=(await admin.query('SELECT certificate,certificate_digest FROM ritc.request_acceptance_effect WHERE household_id=$1',[f.h])).rows;assert.ok(rows.every(r=>r.certificate===null&&r.certificate_digest===null));
 const snapshots=(await admin.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows;assert.ok(snapshots.every(s=>s.snapshot.lines.filter(l=>l.lineId===f.target.decision.line.lineId).every(l=>l.originalItem==='Removed item')));
 assert.deepEqual((await head(f)).lines.find(l=>l.lineId===other.lineId),other);assert.equal((await admin.query('SELECT count(*)::int n FROM ritc.request_acceptance_source_member WHERE household_id=$1 AND member_id=$2',[f.h,f.author.id])).rows[0].n,1);
});
test('request Undo ledger is tenant scoped, immutable and live links have no general runtime DELETE grant',async()=>{
 const f=await setup('legacy'),other=await fixture(),db=await runtime.connect();try{await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[other.h]);assert.equal((await db.query('SELECT 1 FROM ritc.request_acceptance_effect WHERE household_id=$1',[f.h])).rowCount,0);await db.query('ROLLBACK');
 for(const sql of ['UPDATE ritc.request_acceptance_effect SET certificate=NULL,certificate_digest=NULL WHERE household_id=$1','DELETE FROM ritc.request_acceptance_source_member WHERE household_id=$1','DELETE FROM ritc.request_link WHERE household_id=$1']){await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[f.h]);await assert.rejects(db.query(sql,[f.h]),e=>e.code==='42501'||e.code==='23514');await db.query('ROLLBACK');}}
 finally{await db.query('ROLLBACK');db.release();}assert.equal((await state(f)).links.length,1);
});
for(const kind of ['legacy','tracked'])test(kind+' request Undo preserves actual protected meal ingredient and independent basket line',async()=>{
 const f=await fixture(),occurrenceId=randomUUID(),ingredientId=randomUUID();
 const meal={title:'Protected lunch',day:null,kind:'lunch',portions:2,protected:true,planning:{groups:[],ingredients:[{id:ingredientId,name:'Wraps',quantity:{amount:{numerator:2,denominator:1},unit:'count',originalLiteral:'2 lunch wraps'},groupIds:[],exclusions:[]}]}};
 ok(await send(f,'shop.patch',{quote:f.quote,lines:[f.basket],mealEdit:{occurrenceId,baseMealRevision:null,meal}},1));
 if(kind==='tracked'){
  const page=ok(await call(f.owner,f.path+'/demand')),input=draft(f);input.base.shopRevision=2;input.packs[0].usablePerPack=q(10);
  for(const x of page.legacySources.sources)input.change.contributions.push({id:x.id,lineId:f.basket.lineId,source:x.source,productKey:'wraps',productName:x.productName,originalText:x.originalText,quantity:x.quantity,sourceExclusions:x.sourceExclusions,exclusions:[],contains:[],removedAt:null});
  ok((await apply(f,input,ok(await preview(f,input)))).response);
 }
 f.author=await invited(f);const s=await head(f),request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Guest wraps',ownQuantity:'two guest wraps',authoredAt:new Date().toISOString()},s.shopRevision,1,f.author)).request;f.target=await acceptRequest(f,request,'add');
 const before=await head(f),food=ok(await call(f.owner,f.path+'/demand')),p=ok((await review(f)).response);ok(await call(f.owner,f.base+'/commands','POST',undoCommand(f,p)));
 const after=await head(f),remaining=ok(await call(f.owner,f.path+'/demand'));assert.deepEqual(after.meals,before.meals);assert.deepEqual(after.lines,[f.basket]);
 if(kind==='tracked'){const protectedBefore=food.graph.contributions.filter(c=>c.source.kind==='reservation');assert.equal(protectedBefore.length,1);assert.deepEqual(remaining.graph.contributions.filter(c=>c.source.kind==='reservation'),protectedBefore);}
 else assert.deepEqual(remaining.legacySources.sources.filter(c=>c.source.kind==='reservation'),food.legacySources.sources.filter(c=>c.source.kind==='reservation'));
});

test('acceptance-time late failure rolls back actual status, link, certificate and basket before retry',async()=>{
 const f=await fixture();f.author=await invited(f);const request=ok(await send(f,'request.send',{clientRequestId:randomUUID(),originalItem:'Rollback request',ownQuantity:null,authoredAt:new Date().toISOString()},1,1,f.author)).request,before=await head(f),fn='request_accept_failure_'+randomBytes(6).toString('hex');
 await admin.query(`CREATE FUNCTION ritc.${fn}() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.kind='request.apply' AND NEW.shop_id='${f.shopId}'::uuid THEN RAISE EXCEPTION 'injected acceptance rollback';END IF;RETURN NEW;END$$; CREATE TRIGGER ${fn} BEFORE INSERT ON ritc.operation FOR EACH ROW EXECUTE FUNCTION ritc.${fn}()`);
 try{await assert.rejects(acceptRequest(f,request,'add'));assert.deepEqual(await head(f),before);assert.equal(await count(f,'request_acceptance_effect'),0);assert.equal(await count(f,'request_link'),0);assert.equal(await count(f,'shop_snapshot'),1);assert.equal(ok(await call(f.author,f.base+'/requests/mine')).requests[0].status,'pending');}
 finally{await admin.query(`DROP TRIGGER ${fn} ON ritc.operation;DROP FUNCTION ritc.${fn}()`);}
 f.target=await acceptRequest(f,request,'add');assert.equal(await count(f,'request_acceptance_effect'),1);assert.equal((await own(f)).status,'added');
});
test('a held first Apply cannot remove a later reacceptance after another Undo committed',async()=>{
 const f=await setup(),held=undoCommand(f,ok((await review(f)).response)),fresh=undoCommand(f,ok((await review(f)).response));ok(await call(f.owner,f.base+'/commands','POST',fresh));
 const retired=ok(await call(f.owner,f.path+'/demand')).graph,pending=await own(f);f.target=await acceptRequest(f,pending,'link');const accepted=await assertReacceptedGeneration(f,retired),before=await state(f);assert.equal((await call(f.owner,f.base+'/commands','POST',held)).status,409);assert.deepEqual(await state(f),before);assert.deepEqual(ok(await call(f.owner,f.path+'/demand')).graph,accepted);
});
