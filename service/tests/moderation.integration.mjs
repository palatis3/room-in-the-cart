import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {before,after,test} from 'node:test';
import pg from 'pg';
import {HouseholdRepository} from '../dist/repository.js';
import {createHTTPServer} from '../dist/http.js';
import {moderationConfiguration} from '../dist/moderation.js';
import {tokenHash} from '../dist/database.js';

if(!process.env.TEST_ADMIN_DATABASE_URL||!process.env.TEST_DATABASE_URL)throw Error('Disposable PostgreSQL URLs required');
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL});
const app=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
const identities=new Map();
const repo=new HouseholdRepository(app,{allowChildNetwork:true,noticeVersion:'safety-v1',sharedContentSafety:true,moderationRetentionDays:7,
  sessionStatus:{assertLive:async()=>{}}});
const server=createHTTPServer({repository:repo,maxRequestsPerMinute:10000,webOrigin:'https://safety.fixture.invalid',verifier:{
  verify:async token=>{const identity=identities.get(token);assert.ok(identity);return identity;}
}});
let origin;
before(async()=>{await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;});
after(async()=>{await new Promise(resolve=>server.close(resolve));await Promise.all([app.end(),admin.end()]);});

async function fixture(){
  const h=randomUUID(),shop=randomUUID(),request=randomUUID(),grant=randomUUID(),proposal=randomUUID(),actors={};
  await admin.query('INSERT INTO ritc.household(household_id,label) VALUES($1,$2)',[h,'Synthetic household']);
  for(const role of ['shopper','child','cook','stranger']){
    const id=randomUUID(),device=randomUUID(),subject=randomUUID(),token=randomUUID(),secret=randomUUID(),session=randomUUID();
    actors[role]={id,device,subject,token,secret,session};
    identities.set(token,{issuer:'safety.fixture.invalid',subject,sessionId:session,expiresAt:new Date(Date.now()+86400000)});
    await admin.query(`INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute)
      VALUES($1,$2,'safety.fixture.invalid',$3,$4,$5,'active',$6,true)`,[h,id,subject,role,role==='child'?'child':'adult',role==='shopper']);
    await admin.query('INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id) VALUES($1,$2,$3,$4,$5)',[h,device,id,tokenHash(secret),session]);
  }
  const consent=randomUUID(),parent=actors.shopper,child=actors.child;
  await admin.query(`INSERT INTO ritc.guardian_relationship(household_id,child_id,guardian_id,proof_ref) VALUES($1,$2,$3,'fixture')`,[h,child.id,parent.id]);
  await admin.query(`INSERT INTO ritc.consent(household_id,consent_id,child_id,guardian_id,notice_version,verification_ref)
    VALUES($1,$2,$3,$4,'safety-v1','fixture')`,[h,consent,child.id,parent.id]);
  await admin.query('UPDATE ritc.device SET guardian_consent_id=$1 WHERE household_id=$2 AND device_id=$3',[consent,h,child.device]);
  await admin.query(`INSERT INTO ritc.guardian_enrollment(household_id,enrollment_id,guardian_id,guardian_device_id,guardian_issuer,guardian_subject,
    guardian_session,child_id,notice_version,notice_digest,method_version,language,child_location,declaration,state,expires_at,consent_id)
    VALUES($1,$2,$3,$4,'safety.fixture.invalid',$5,$6,$7,'safety-v1',repeat('a',64),'fixture','es','US','parent_or_legal_guardian','active',now()+interval '1 day',$8)`,
    [h,randomUUID(),parent.id,parent.device,parent.subject,parent.session,child.id,consent]);
  await admin.query(`INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote) VALUES($1,$2,$3,'{}')`,[h,shop,parent.id]);
  await admin.query(`INSERT INTO ritc.request(household_id,request_id,author_id,client_request_id,shop_id,original_item,own_quantity,route,status,authored_at,
     revision,clarification,clarification_revision,clarification_author_id)
    VALUES($1,$2,$3,$4,$5,'Milk','2','current','clarified',now(),2,'Which size?',2,$6)`,[h,request,child.id,randomUUID(),shop,parent.id]);
  const projection={language:'en',shopLabel:'Dinner plan',items:[{label:'Apples',amount:'2',unit:'cups',action:'Slice the apples'}]};
  await admin.query(`INSERT INTO ritc.view_grant(household_id,grant_id,shop_id,created_by,recipient_id,mode,projection,projection_author_id,expires_at)
    VALUES($1,$2,$3,$4,$5,'read',$6,$4,now()+interval '1 day')`,[h,grant,shop,parent.id,actors.cook.id,projection]);
  await admin.query(`INSERT INTO ritc.helper_proposal(household_id,proposal_id,grant_id,actor_id,client_key,base_revision,correction,payload_digest)
    VALUES($1,$2,$3,$4,$5,1,'Save one apple',repeat('a',64))`,[h,proposal,grant,actors.cook.id,randomUUID()]);
  const post=async(role,data,headers={})=>{
    const a=actors[role],res=await fetch(origin+'/v1/households/'+h+'/moderation/actions',{method:'POST',
      headers:{Authorization:'Bearer '+a.token,'X-Device-Token':a.secret,'Content-Type':'application/json',...headers},body:JSON.stringify(data)});
    return {status:res.status,body:await res.json()};
  };
  return {h,shop,request,grant,proposal,actors,post};
}
const report=(source,text)=>({clientKey:randomUUID(),action:'report',source,reason:'unsafe',...(text===undefined?{}:{text})});
const block=source=>({clientKey:randomUUID(),action:'block',source});
const question=f=>({kind:'clarification',id:f.request,revision:2,field:'question'});
const instruction=f=>({kind:'instruction',id:f.grant,revision:1,field:'action',index:0});

async function asOperator(sql,values=[]){
  const c=await admin.connect();
  try{await c.query('BEGIN');await c.query('SET LOCAL ROLE ritc_moderator');const result=await c.query(sql,values);await c.query('COMMIT');return result;}
  catch(error){await c.query('ROLLBACK');throw error;}finally{c.release();}
}
test('configuration defaults off and enabled collection requires approved retention',()=>{
  assert.deepEqual(moderationConfiguration({}),{});
  assert.throws(()=>moderationConfiguration({SHARED_CONTENT_SAFETY_ENABLED:'true'}));
  assert.deepEqual(moderationConfiguration({SHARED_CONTENT_SAFETY_ENABLED:'true',MODERATION_OPERATOR_APPROVAL:'fixture',MODERATION_RETENTION_DAYS:'7'}),
    {sharedContentSafety:true,moderationRetentionDays:7});
});
test('child can privately report their clarification, replay once and block its actual sender',async()=>{
  const f=await fixture(),payload=report(question(f));
  const [a,b]=await Promise.all([f.post('child',payload),f.post('child',payload)]);
  assert.equal(a.status,200,JSON.stringify(a.body));assert.deepEqual(a,b);assert.deepEqual(Object.keys(a.body).sort(),['receiptId','status']);
  const row=(await admin.query('SELECT author_id,reporter_id,excerpt FROM ritc.moderation_case WHERE case_id=$1',[a.body.receiptId])).rows[0];
  assert.deepEqual(row,{author_id:f.actors.shopper.id,reporter_id:f.actors.child.id,excerpt:null});
  assert.equal((await f.post('child',{...payload,reason:'other'})).status,409);
  assert.equal((await f.post('stranger',report(question(f)))).status,404);
  assert.equal((await f.post('child',report({...question(f),revision:1}))).status,409);
  assert.equal((await f.post('child',report(question(f),'Different text'))).status,409);
  await admin.query('UPDATE ritc.shop SET shopper_id=$1 WHERE household_id=$2 AND shop_id=$3',[f.actors.stranger.id,f.h,f.shop]);
  const key=block(question(f));const blocked=await f.post('child',key);assert.equal(blocked.status,200,JSON.stringify(blocked.body));assert.deepEqual(await f.post('child',key),blocked);
  const edge=(await admin.query('SELECT viewer_id,author_id FROM ritc.moderation_block WHERE household_id=$1',[f.h])).rows;
  assert.deepEqual(edge,[{viewer_id:f.actors.child.id,author_id:f.actors.shopper.id}]);
  const seen=await repo.transaction(f.h,async db=>(await db.query("SELECT ritc.shared_content_visible($1,$2,$3,'clarification',$4,2,2) AS visible",[f.h,f.actors.child.id,f.actors.shopper.id,f.request])).rows[0].visible);
  assert.equal(seen,false);
});
test('read-only cook can report the selected line only and cannot reach request, wrong grant or private data',async()=>{
  const f=await fixture(),scope={'X-View-Grant-ID':f.grant},payload=report(instruction(f),'Slice the apples');
  assert.equal((await f.post('cook',report({...instruction(f),index:1}),scope)).status,404);
  assert.equal((await f.post('cook',report(question(f)),scope)).status,404);
  assert.equal((await f.post('cook',payload,{'X-View-Grant-ID':randomUUID()})).status,403);
  const a=await f.post('cook',payload,scope);assert.equal(a.status,200,JSON.stringify(a.body));
  const c=(await asOperator('SELECT * FROM ritc.moderation_queue() WHERE case_id=$1',[a.body.receiptId])).rows[0];
  assert.equal(c.excerpt,'Slice the apples');assert.equal(c.sender_known,true);assert.ok(!('reporter_id' in c));assert.ok(!('household_id' in c));
  await assert.rejects(()=>app.query('SELECT * FROM ritc.moderation_queue()'),{code:'42501'});
  await assert.rejects(()=>app.query('SELECT excerpt FROM ritc.moderation_case'),{code:'42501'});
  await assert.rejects(()=>asOperator('SELECT original_item FROM ritc.request'),{code:'42501'});
  assert.equal((await asOperator("SELECT ritc.moderation_resolve($1,'remove') AS result",[a.body.receiptId])).rows[0].result,'remove');
  assert.equal((await f.post('cook',report(instruction(f)),scope)).status,404);
  assert.equal((await asOperator("SELECT ritc.moderation_resolve($1,'remove') AS result",[a.body.receiptId])).rows[0].result,'remove');
  await assert.rejects(()=>asOperator("SELECT ritc.moderation_resolve($1,'suspend')",[a.body.receiptId]));
});
test('legacy wording stays reportable without guessing a sender; removal covers later status revisions',async()=>{
  const f=await fixture();await admin.query('UPDATE ritc.request SET clarification_author_id=NULL WHERE household_id=$1 AND request_id=$2',[f.h,f.request]);
  assert.equal((await f.post('child',block(question(f)))).body.error.code,'sender_unavailable');
  const a=await f.post('child',report(question(f)));assert.equal(a.status,200);
  await assert.rejects(()=>asOperator("SELECT ritc.moderation_resolve($1,'suspend')",[a.body.receiptId]));
  await asOperator("SELECT ritc.moderation_resolve($1,'remove')",[a.body.receiptId]);
  await admin.query('UPDATE ritc.request SET revision=3 WHERE household_id=$1 AND request_id=$2',[f.h,f.request]);
  assert.equal((await f.post('child',report({...question(f),revision:3}))).status,404);
});
test('a resolved suspension covers the same account across households; case expires and prunes without resurrecting removed content',async()=>{
  const f=await fixture(),other=await fixture(),source={kind:'suggestion',id:f.proposal,field:'correction',revision:1};
  const a=await f.post('shopper',report(source));assert.equal(a.status,200,JSON.stringify(a.body));
  await admin.query('UPDATE ritc.member SET subject=$1 WHERE household_id=$2 AND member_id=$3',[f.actors.cook.subject,other.h,other.actors.cook.id]);
  await asOperator("SELECT ritc.moderation_resolve($1,'suspend')",[a.body.receiptId]);
  const suspended=await repo.transaction(other.h,async db=>(await db.query('SELECT ritc.content_account_suspended($1,$2) AS value',[other.h,other.actors.cook.id])).rows[0].value);
  assert.equal(suspended,true);
  await admin.query("UPDATE ritc.moderation_case SET created_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE case_id=$1",[a.body.receiptId]);
  await admin.query("UPDATE ritc.moderation_receipt SET expires_at=now()-interval '1 day' WHERE receipt_id=$1",[a.body.receiptId]);
  const pruned=(await asOperator('SELECT * FROM ritc.moderation_prune()')).rows[0];assert.ok(Number(pruned.expired_cases)>=1);assert.ok(Number(pruned.expired_receipts)>=1);
  assert.equal((await admin.query('SELECT 1 FROM ritc.moderation_case WHERE case_id=$1',[a.body.receiptId])).rowCount,0);
  assert.equal((await admin.query('SELECT 1 FROM ritc.moderation_removal WHERE household_id=$1 AND source_id=$2',[f.h,f.proposal])).rowCount,1);
});
test('contributor browser reporting requires CSRF and its own current request in the authorized household',async()=>{
  const f=await fixture(),foreign=await fixture(),child=f.actors.child;
  const session=await repo.startWebSession(f.h,identities.get(child.token),{pairedDeviceToken:child.secret,ownRequestsOnly:true});
  const action=report(question(f));
  const send=async(h,data,csrf)=>{
    const response=await fetch(origin+'/v1/households/'+h+'/moderation/actions',{method:'POST',headers:{
      Cookie:'ritc_session='+session.cookie,Origin:'https://safety.fixture.invalid','Content-Type':'application/json',...(csrf?{'X-CSRF-Token':csrf}:{})
    },body:JSON.stringify(data)});
    return {status:response.status,body:await response.json()};
  };
  assert.equal((await send(f.h,action)).body.error.code,'csrf_failed');
  assert.equal((await send(foreign.h,report(question(foreign)),session.csrf)).status,404);
  assert.equal((await send(f.h,report(instruction(f)),session.csrf)).status,404);
  assert.equal((await send(f.h,action,session.csrf)).status,200);
  await admin.query('UPDATE ritc.consent SET revoked_at=clock_timestamp() WHERE household_id=$1 AND child_id=$2',[f.h,child.id]);
  assert.equal((await send(f.h,action,session.csrf)).status,403);
});
test('account erasure removes selected evidence, private receipts and block relationships',async()=>{
  const f=await fixture(),payload=report(question(f),'Which size?');
  const reported=await f.post('child',payload),blocked=await f.post('child',block(question(f)));
  assert.equal(reported.status,200);assert.equal(blocked.status,200);
  await admin.query('SELECT ritc.privacy_erase_extension($1,$2)',[f.h,f.actors.child.id]);
  for(const table of ['moderation_case','moderation_block','moderation_receipt']){
    assert.equal((await admin.query('SELECT 1 FROM ritc.'+table+' WHERE household_id=$1',[f.h])).rowCount,0);
  }
});
test('disabled intake returns an unavailable response without a report or block',async()=>{
  const f=await fixture();
  repo.options.sharedContentSafety=false;
  try{
    assert.equal((await f.post('child',report(question(f)))).body.error.code,'moderation_unavailable');
    assert.equal((await f.post('child',block(question(f)))).body.error.code,'moderation_unavailable');
    for(const table of ['moderation_case','moderation_block','moderation_receipt'])
      assert.equal((await admin.query('SELECT 1 FROM ritc.'+table+' WHERE household_id=$1',[f.h])).rowCount,0);
  }finally{repo.options.sharedContentSafety=true;}
});
test('successor shopper can include only a chosen dated-copy excerpt and removal preserves the sealed numeric order',async()=>{
  const f=await fixture(),old=f.actors.cook,window=randomUUID(),copy=randomUUID(),occurrence=randomUUID(),snapshot={lines:2,total:3750};
  await admin.query("INSERT INTO ritc.replay_window(household_id,window_id,member_id,device_id,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[f.h,window,old.id,old.device]);
  await admin.query(`INSERT INTO ritc.operation(household_id,operation_id,actor_id,device_id,client_key,window_id,kind,shop_id,payload_digest,response_scope)
    VALUES($1,$2,$3,$4,$5,$6,'cookCopy.save',$7,repeat('a',64),'shopper')`,[f.h,copy,old.id,old.device,randomUUID(),window,f.shop]);
  await admin.query("INSERT INTO ritc.shop_snapshot(household_id,shop_id,revision,purpose,snapshot,digest,operation_id) VALUES($1,$2,1,'placed',$3,repeat('f',64),$4)",[f.h,f.shop,snapshot,copy]);
  await admin.query('UPDATE ritc.shop SET phase=\'placed\',placed_revision=1 WHERE household_id=$1 AND shop_id=$2',[f.h,f.shop]);
  await admin.query('INSERT INTO ritc.shared_meal_revision(household_id,shop_id,occurrence_id,revision,actor_id) VALUES($1,$2,$3,1,$4)',[f.h,f.shop,occurrence,old.id]);
  await admin.query('INSERT INTO ritc.cook_copy_series VALUES($1,$2,$3,1)',[f.h,f.shop,occurrence]);
  await admin.query(`INSERT INTO ritc.dated_cook_copy(household_id,shop_id,copy_id,occurrence_id,meal_revision,version,shop_revision,placed_revision,authority_epoch,supply_revision,language,reviewed_text,actor_id,created_at)
    VALUES($1,$2,$3,$4,1,1,1,1,1,0,'en','Bake the apples. Keep two slices for lunch.',$5,now())`,[f.h,f.shop,copy,occurrence,old.id]);
  const ref={kind:'cookCopy',id:copy,revision:1,field:'text'};
  assert.equal((await f.post('stranger',report(ref))).status,404);
  assert.equal((await f.post('shopper',report(ref,'Edited excerpt'))).status,409);
  const a=await f.post('shopper',report(ref,'Keep two slices for lunch.'));assert.equal(a.status,200,JSON.stringify(a.body));
  assert.equal((await asOperator('SELECT excerpt FROM ritc.moderation_queue() WHERE case_id=$1',[a.body.receiptId])).rows[0].excerpt,'Keep two slices for lunch.');
  assert.ok(Number((await asOperator('SELECT * FROM ritc.moderation_workload()')).rows[0].pending)>0);
  await asOperator("SELECT ritc.moderation_resolve($1,'remove')",[a.body.receiptId]);
  assert.equal((await f.post('shopper',report(ref))).status,404);
  assert.deepEqual((await admin.query('SELECT snapshot FROM ritc.shop_snapshot WHERE household_id=$1 AND shop_id=$2',[f.h,f.shop])).rows[0].snapshot,snapshot);
});
