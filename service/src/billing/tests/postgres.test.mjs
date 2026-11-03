import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { BillingService } from '../../../dist/billing/service.js';

const runtimeURL=process.env.BILLING_TEST_DATABASE_URL;
const adminURL=process.env.BILLING_TEST_ADMIN_DATABASE_URL;
test('PostgreSQL durable billing / RLS / named seats contract', {skip:!runtimeURL||!adminURL}, async t=>{
  const runtime=new pg.Pool({connectionString:runtimeURL,max:5});
  const admin=new pg.Pool({connectionString:adminURL,max:2});
  const hh=randomUUID(),foreignHH=randomUUID(),purchaser=randomUUID(),second=randomUUID(),child=randomUUID(),foreignAdult=randomUUID();
  const original=BigInt('0x'+randomUUID().replaceAll('-','')).toString();
  const now=new Date(), timestamp=now.getTime();
  let current={environment:'Sandbox',originalTransactionID:original,transactionID:original+'1',appAccountToken:'',productID:'test-only.household',purchasedAt:timestamp-1000,signedAt:timestamp,expiresAt:timestamp+10000,graceExpiresAt:null,status:'active'};
  const fakeApple={
    // This test substitutes only Apple's remote authority. Separate tests exercise actual SDK signature rejection.
    async verifyTransaction(){return {originalTransactionID:current.originalTransactionID,transactionID:original+'1',appAccountToken:current.appAccountToken};},
    async current(){return structuredClone(current);},
    async verifyNotification(){return {notificationID:'00000000-0000-4000-8000-000000000001',transaction:await this.verifyTransaction()};},
  };
  const service=new BillingService(fakeApple);
  const run=async(actor,fn,household=hh,date=now)=>{
    const db=await runtime.connect();
    try{
      await db.query('BEGIN');
      await db.query("SELECT set_config('app.household_id',$1,true)",[household]);
      await db.query('SELECT household_id FROM ritc.household WHERE household_id=$1 FOR UPDATE',[household]);
      const member=(await db.query('SELECT member_id,kind FROM ritc.member WHERE household_id=$1 AND member_id=$2',[household,actor])).rows[0];
      const value=await fn({db,householdId:household,member,now:date});
      await db.query('COMMIT');return value;
    }catch(error){await db.query('ROLLBACK');throw error;}finally{db.release();}
  };
  try{
    await admin.query("INSERT INTO ritc.household(household_id,label) VALUES($1,'Billing fixture'),($2,'Other billing fixture')",[hh,foreignHH]);
    for(const [household,id,kind,alias] of [[hh,purchaser,'adult','Purchaser'],[hh,second,'adult','Second adult'],[hh,child,'child','Child'],[foreignHH,foreignAdult,'adult','Foreign adult']])
      await admin.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state) VALUES($1,$2::uuid,'test-only',$2::text,$3,$4,'active')",[household,id,alias,kind]);

    await t.test('purchase token is server-issued, stable, household-specific and adult-only',async()=>{
      const token=await run(purchaser,ctx=>service.prepare(ctx));
      current.appAccountToken=token.appAccountToken;
      assert.equal((await run(purchaser,ctx=>service.prepare(ctx))).appAccountToken,token.appAccountToken);
      await assert.rejects(()=>run(child,ctx=>service.prepare(ctx)),error=>error.code==='access_ended');
    });
    await t.test('simultaneous delivery / replay yields one immutable receipt and one initial seat',async()=>{
      const [one,two]=await Promise.all([run(purchaser,ctx=>service.verify(ctx,'fixture')),run(purchaser,ctx=>service.verify(ctx,'fixture'))]);
      assert.equal(one.durable,true);assert.equal(two.acceptedTransactionID,one.acceptedTransactionID);
      assert.equal(one.snapshot.seats.length,1);assert.equal(two.snapshot.revision,one.snapshot.revision);
      const receipts=await admin.query('SELECT * FROM ritc.billing_delivery WHERE household_id=$1',[hh]);
      assert.equal(receipts.rowCount,1);
      await assert.rejects(()=>admin.query("UPDATE ritc.billing_delivery SET accepted_at=now() WHERE household_id=$1",[hh]),error=>error.code==='23514');
    });
    await t.test('wrong purchaser / household cannot restore or enumerate receipts',async()=>{
      await assert.rejects(()=>run(second,ctx=>service.prepare(ctx)),error=>error.code==='purchase_context_not_purchaser');
      await assert.rejects(()=>run(second,ctx=>service.verify(ctx,'fixture')),error=>error.code==='purchase_already_bound');
      await assert.rejects(()=>run(foreignAdult,ctx=>service.verify(ctx,'fixture'),foreignHH),error=>error.code==='purchase_already_bound');
      const visible=await run(foreignAdult,ctx=>ctx.db.query('SELECT * FROM ritc.billing_delivery'),foreignHH);
      assert.equal(visible.rowCount,0);
    });
    await t.test('an unseated adult gets only their own Free projection, never the purchaser or paid roster',async()=>{
      const snapshot=await run(second,ctx=>service.snapshot(ctx));
      assert.equal(snapshot.status,'free');assert.equal(snapshot.purchaserID,second);
      assert.equal(snapshot.revision,0);assert.deepEqual(snapshot.seats,[]);
      assert.equal(snapshot.expiresAt,null);assert.equal(snapshot.graceExpiresAt,null);
      assert.equal(JSON.stringify(snapshot).includes(purchaser),false);
    });
    await t.test('two named adults, purchaser-only candidates, no third / child / foreign seat and no shop authority created',async()=>{
      const candidates=await run(purchaser,ctx=>service.seatCandidates(ctx));
      assert.deepEqual(new Set(candidates.adults.map(a=>a.userID)),new Set([purchaser,second]));
      await assert.rejects(()=>run(second,ctx=>service.seatCandidates(ctx)),error=>error.code==='access_ended');
      let snapshot=await run(purchaser,ctx=>service.snapshot(ctx));
      snapshot=await run(purchaser,ctx=>service.replaceSeats(ctx,{revision:snapshot.revision,userIDs:[purchaser,second]}));
      assert.equal(snapshot.seats.length,2);
      for(const userIDs of [[purchaser,second,child],[purchaser,child],[purchaser,foreignAdult],[purchaser,purchaser]])
        await assert.rejects(()=>run(purchaser,ctx=>service.replaceSeats(ctx,{revision:snapshot.revision,userIDs})),error=>error.code==='invalid_command');
      await assert.rejects(()=>run(purchaser,ctx=>service.replaceSeats(ctx,{revision:1,userIDs:[]})),error=>error.code==='refresh_required');
      assert.equal((await admin.query('SELECT * FROM ritc.shop_authority WHERE household_id=$1',[hh])).rowCount,0);
    });
    await t.test('failure after deleting original assignments rolls back all seat changes',async()=>{
      const before=await run(purchaser,ctx=>service.snapshot(ctx));
      await assert.rejects(()=>run(purchaser,async ctx=>{
        const query=ctx.db.query.bind(ctx.db);
        const db={query:async(sql,args)=>{if(sql.startsWith('INSERT INTO ritc.billing_seat'))throw new Error('injected-write-failure');return query(sql,args);}};
        return service.replaceSeats({...ctx,db},{revision:before.revision,userIDs:[second]});
      }),/injected-write-failure/);
      const after=await run(purchaser,ctx=>service.snapshot(ctx));
      assert.deepEqual(after.seats,before.seats);assert.equal(after.revision,before.revision);
    });
    await t.test('same version revalidation advances only lease; time expiry advances revision and denies assistance',async()=>{
      const before=await run(purchaser,ctx=>service.snapshot(ctx));
      const refreshed=await run(second,ctx=>service.snapshot(ctx),hh,new Date(timestamp+1000));
      assert.equal(refreshed.revision,before.revision);assert.ok(Date.parse(refreshed.verifiedAt)>Date.parse(before.verifiedAt));
      const expired=await run(purchaser,ctx=>service.snapshot(ctx),hh,new Date(timestamp+10001));
      assert.equal(expired.status,'expired');assert.ok(expired.revision>before.revision);
      await assert.rejects(()=>run(second,ctx=>service.requirePaidSeat(ctx),hh,new Date(timestamp+10001)),error=>error.code==='membership_inactive');
    });
    await t.test('renewal preserves exactly the two assignments; grace allows then retry denies',async()=>{
      current={...current,transactionID:original+'2',purchasedAt:timestamp+10000,signedAt:timestamp+10001,expiresAt:timestamp+1e8};
      let snapshot=await run(purchaser,ctx=>service.snapshot(ctx),hh,new Date(timestamp+10002));
      assert.equal(snapshot.status,'active');assert.equal(snapshot.seats.length,2);
      current={...current,signedAt:timestamp+10002,status:'grace',graceExpiresAt:timestamp+20000};
      snapshot=await run(purchaser,ctx=>service.snapshot(ctx),hh,new Date(timestamp+10003));assert.equal(snapshot.status,'grace');
      current={...current,signedAt:timestamp+10003,status:'billingRetry'};
      snapshot=await run(purchaser,ctx=>service.snapshot(ctx),hh,new Date(timestamp+10004));assert.equal(snapshot.status,'billingRetry');
      await assert.rejects(()=>run(second,ctx=>service.requirePaidSeat(ctx),hh,new Date(timestamp+10004)),error=>error.code==='membership_inactive');
    });
    await t.test('refund notification is durable and idempotent; stale active status cannot resurrect access',async()=>{
      current={...current,signedAt:timestamp+10005,status:'revoked'};
      await service.notification(runtime,'fixture');await service.notification(runtime,'fixture');
      const snapshot=await run(purchaser,ctx=>service.snapshot(ctx));assert.equal(snapshot.status,'revoked');
      const events=await admin.query("SELECT * FROM ritc.billing_event WHERE household_id=$1 AND kind='notification'",[hh]);assert.equal(events.rowCount,1);
      current={...current,signedAt:timestamp,status:'active',expiresAt:timestamp+1e10};
      const stale=await run(purchaser,ctx=>service.verify(ctx,'fixture'));assert.equal(stale.snapshot.status,'revoked');assert.equal(stale.snapshot.revision,snapshot.revision);
    });
    await t.test('revoked household member is removed with a new snapshot revision, preserving records',async()=>{
      const before=await run(purchaser,ctx=>service.snapshot(ctx));
      await admin.query("UPDATE ritc.member SET state='revoked' WHERE household_id=$1 AND member_id=$2",[hh,second]);
      const after=await run(purchaser,ctx=>service.snapshot(ctx));
      assert.deepEqual(after.seats.map(s=>s.userID),[purchaser]);assert.ok(after.revision>before.revision);
      assert.equal((await admin.query('SELECT * FROM ritc.billing_delivery WHERE household_id=$1',[hh])).rowCount,1);
      await assert.rejects(()=>run(purchaser,ctx=>new BillingService(null).snapshot(ctx)),error=>error.code==='billing_unavailable');
    });
  }finally{await runtime.end();await admin.end();}
});
