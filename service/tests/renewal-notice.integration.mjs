import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {migrate} from '../scripts/migrate.mjs';
import {renewalContact} from '../dist/billing/renewal-contact.js';
import {maintainRenewalNotices} from '../dist/billing/renewal-worker.js';
import {day} from '../dist/billing/renewal-facts.js';
import {BillingService} from '../dist/billing/service.js';

test('verified payer enrollment and renewal delivery under real app/worker database roles',async t=>{
  const controlURL=new URL(process.env.TEST_ADMIN_DATABASE_URL);
  assert.ok(['localhost','127.0.0.1','[::1]'].includes(controlURL.hostname)&&controlURL.pathname.startsWith('/ritc_'));
  const dbname='ritc_renewal_'+randomUUID().replaceAll('-',''),control=new pg.Pool({connectionString:controlURL.href});
  const urlFor=value=>{const u=new URL(value);u.pathname='/'+dbname;return u.href;};
  const adminURL=urlFor(controlURL),admin=new pg.Pool({connectionString:adminURL}),
    app=new pg.Pool({connectionString:urlFor(process.env.TEST_DATABASE_URL)}),
    worker=new pg.Pool({connectionString:urlFor(process.env.TEST_WORKER_DATABASE_URL)});
  await control.query('CREATE DATABASE '+dbname);
  const issuer='https://issuer.example.invalid',home=randomUUID(),otherHome=randomUUID();
  const payer={id:randomUUID(),subject:randomUUID(),device:randomUUID(),session:randomUUID(),kind:'adult'};
  const other={id:randomUUID(),subject:randomUUID(),device:randomUUID(),session:randomUUID(),kind:'adult'};
  const sends=[],deliveries=new Map();
  let ambiguous=false,delivered=true;
  const provider={ready:async()=>true,delivery:async()=>delivered?'delivered':'failed',
    send:async(key,to,msg)=>{
      if(!deliveries.has(key))deliveries.set(key,randomUUID());
      sends.push({key,to,...msg});
      if(ambiguous)throw Error('provider reply lost');return deliveries.get(key);
    }};
  const config={mode:'send',provider,sandboxHomes:new Set([otherHome])},dark={mode:'off',provider:null,sandboxHomes:new Set()};
  let state={environment:'Production',originalTransactionID:'9134',transactionID:'9135',productID:'annual',appAccountToken:'',
    purchasedAt:Date.now()-day,signedAt:Date.now()-10000,expiresAt:Date.now()+6.9*day,graceExpiresAt:null,status:'active',mxAnnual:true};
  state.noticeFacts={date:state.expiresAt,signedAt:state.signedAt,amountMilli:193400,currency:'MXN'};
  const gateway={current:async()=>structuredClone(state),verifyTransaction:async()=>({originalTransactionID:state.originalTransactionID,
    transactionID:state.transactionID,appAccountToken:state.appAccountToken})};
  const billing=new BillingService(gateway);
  async function run(a,fn,h=home){
    const db=await app.connect();
    try{
      await db.query('BEGIN');
      await db.query("SELECT set_config('app.household_id',$1,true)",[h]);
      await db.query('SELECT household_id FROM ritc.household WHERE household_id=$1 FOR UPDATE',[h]);
      const result=await fn({db,householdId:h,deviceId:a.device,member:{member_id:a.id,kind:a.kind},now:new Date()});
      await db.query('COMMIT');return result;
    }catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
  }
  const contact=(a,enabled,c=config,h=home,sandbox=false)=>run(a,ctx=>renewalContact(ctx,
    {issuer,subject:a.subject,sessionId:a.session},c,sandbox,enabled),h);
  const work=(c=config)=>maintainRenewalNotices(worker,c,gateway,issuer,'run',AbortSignal.timeout(8000));
  const due=()=>admin.query("UPDATE ritc.renewal_contact SET next_check=now()-interval '1 minute'");
  const records=async()=> (await admin.query('SELECT * FROM ritc.renewal_dispatch ORDER BY edition')).rows;
  try{
    await admin.query('CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
    await migrate(adminURL);
    for(const h of [home,otherHome])await admin.query("INSERT INTO ritc.household(household_id,label) VALUES($1,'Test household')",[h]);
    for(const a of [payer,other]){
      await admin.query("INSERT INTO auth.users VALUES($1,$2,now())",[a.subject,a===payer?'current@example.invalid':'other@example.invalid']);
      await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[a.session,a.subject]);
      for(const h of [home,otherHome]){
        await admin.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state) VALUES($1,$2,$3,$4,'Adult','adult','active')",[h,a.id,issuer,a.subject]);
        await admin.query("INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id) VALUES($1,$2,$3,repeat('a',32)||replace(($2::uuid)::text,'-',''),$4)",[h,a.device,a.id,a.session]);
      }
    }
    await t.test('explicit provisional contact and isolated no-send Sandbox',async()=>{
      assert.equal((await contact(payer,undefined,dark)).scope,'unavailable');
      assert.equal((await contact(payer,undefined)).enabled,false);
      assert.deepEqual(await contact(payer,true),{scope:'prospective',emailVerified:true,enabled:true,dispatchEnabled:true});
      assert.equal((await contact({...payer,kind:'child'},undefined)).scope,'unavailable');
      const dry={...dark,sandboxHomes:new Set([otherHome])};
      assert.equal((await contact(payer,true,dry,home,true)).scope,'unavailable');
      assert.deepEqual(await contact(payer,true,dry,otherHome,true),{scope:'prospective',emailVerified:true,enabled:true,dispatchEnabled:false,sandboxOnly:true});
      assert.equal((await contact(payer,undefined,config,otherHome,false)).enabled,false);
      await assert.rejects(()=>app.query('SELECT * FROM ritc.renewal_dispatch'),{code:'42501'});
      await assert.rejects(()=>worker.query('SELECT email FROM auth.users'),{code:'42501'});
      await assert.rejects(()=>app.query('SELECT * FROM ritc.renewal_worker_contact($1,$2)',[randomUUID(),issuer]),{code:'42501'});
    });
    await t.test('only the verified purchaser of the verified series binds; other adults do not inherit',async()=>{
      state.appAccountToken=(await run(payer,ctx=>billing.prepare(ctx))).appAccountToken;
      await run(payer,ctx=>billing.verify(ctx,'test-only'));
      assert.equal((await contact(payer,undefined)).scope,'bound');
      assert.equal((await contact(other,undefined)).scope,'unavailable');
      const rows=await admin.query('SELECT original_id,sandbox_only FROM ritc.renewal_contact ORDER BY sandbox_only');
      assert.deepEqual(rows.rows,[{original_id:'9134',sandbox_only:false},{original_id:null,sandbox_only:true}]);
      const persisted=(await admin.query('SELECT subscription FROM ritc.billing_state')).rows[0].subscription;
      assert.equal(persisted.mxAnnual,true);assert.equal('noticeFacts' in persisted,false);
    });
    await t.test('fresh confirmation, concurrent execution, provider acknowledgment and post-dispatch correction',async()=>{
      await Promise.all([work(),work()]);assert.equal(deliveries.size,1);
      const [first]=await records();
      assert.equal(first.state,'accepted');assert.equal(first.purpose,'reminder');
      assert.ok(sends.every(s=>s.to==='current@example.invalid'&&s.amountMilli===193400));
      await due();await work();assert.equal((await records())[0].state,'delivered');
      const originalDate=state.noticeFacts.date;
      state={...state,signedAt:Date.now(),noticeFacts:{...state.noticeFacts,signedAt:Date.now(),date:originalDate+day,amountMilli:205500}};
      await due();await work();assert.equal(deliveries.size,2);
      const [a,b]=await records();assert.equal(b.purpose,'correction');assert.equal(Number(b.amount_milli),205500);
      assert.equal(a.purge_at.getTime(),b.purge_at.getTime());
      await due();await work();await due();await work();assert.equal(deliveries.size,2);
    });
    await t.test('unknown provider result uses its one stable key only within the guaranteed window',async()=>{
      state.noticeFacts={...state.noticeFacts,signedAt:Date.now(),amountMilli:211000};
      state.signedAt=state.noticeFacts.signedAt;
      ambiguous=true;await due();await work();
      const pending=(await records()).at(-1);assert.equal(pending.state,'attempted');
      assert.equal(deliveries.size,3);
      await due();await work();assert.equal(sends.at(-1).key,pending.id);assert.equal(deliveries.size,3);
      const count=sends.length;
      await admin.query("UPDATE ritc.renewal_dispatch SET first_attempt=now()-interval '25 hours' WHERE id=$1",[pending.id]);
      ambiguous=false;await due();assert.ok((await work()).attention>0);assert.equal(sends.length,count);
    });
    await t.test('a confirmed withdrawal of auto-renew, a late change and an uncertain restoration cannot dispatch',async()=>{
      const old=structuredClone(state),count=sends.length;
      state={...old,noticeFacts:null,autoRenewOff:true};
      await due();await work();assert.equal(sends.length,count);
      state={...old,noticeFacts:{...old.noticeFacts,date:Date.now()+4*day,signedAt:Date.now()}};
      await due();await work();assert.equal(sends.length,count);
      await admin.query('INSERT INTO ritc.renewal_restore_fence VALUES(true,now())');
      state={...old,transactionID:'9140',noticeFacts:{...old.noticeFacts,signedAt:Date.now()}};
      await due();await work();assert.equal(sends.length,count);
      await admin.query('DELETE FROM ritc.renewal_restore_fence');state=old;
    });
    await t.test('withdrawal and provider address changes require new consent; deletion leaves only anonymous oversight',async()=>{
      const before=sends.length;
      assert.equal((await contact(payer,false)).enabled,false);await work();assert.equal(sends.length,before);
      assert.equal((await contact(payer,true)).enabled,true);
      await admin.query("UPDATE auth.users SET email='different@example.invalid' WHERE id=$1",[payer.subject]);
      await admin.query("UPDATE auth.users SET email='current@example.invalid' WHERE id=$1",[payer.subject]);
      assert.equal((await contact(payer,undefined)).enabled,false);
      assert.equal((await contact(payer,true)).enabled,true);
      await due();await work();assert.equal(sends.length,before);
      await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[home,payer.id]);
      assert.equal((await records()).length,0);
      assert.equal((await admin.query('SELECT * FROM ritc.renewal_contact WHERE household_id=$1',[home])).rowCount,0);
      assert.ok((await work(dark)).attention>0);
      assert.deepEqual((await admin.query("SELECT column_name FROM information_schema.columns WHERE table_schema='ritc' AND table_name='renewal_route_loss' ORDER BY column_name")).rows.map(r=>r.column_name),['count','day']);
    });
    await t.test('dark cleanup retires provisional contacts and expired history without provider work',async()=>{
      await contact(other,true,{...dark,sandboxHomes:new Set([otherHome])},otherHome,true);
      await admin.query("UPDATE ritc.renewal_contact SET enrolled_at=now()-interval '31 days'");
      await admin.query(`INSERT INTO ritc.renewal_dispatch
        (household_id,purchaser_id,contact_id,original_id,term,edition,purpose,due_at,amount_milli,signed_at,purge_at)
        VALUES($1,$2,$3,'80001','80002',1,'reminder',now()-interval '31 days',85000,now()-interval '38 days',now()-interval '1 day')`,[otherHome,other.id,randomUUID()]);
      await work(dark);assert.equal((await admin.query('SELECT * FROM ritc.renewal_contact')).rowCount,0);
      assert.equal((await records()).length,0);
    });
  }finally{
    await Promise.all([admin.end(),app.end(),worker.end()]);
    try{await control.query('DROP DATABASE '+dbname);}finally{await control.end();}
  }
});
