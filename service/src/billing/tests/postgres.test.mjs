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
    async verifyNotification(){return {kind:'subscription',notificationID:'00000000-0000-4000-8000-000000000001',transaction:await this.verifyTransaction()};},
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
    await t.test('concurrent signed consent deliveries commit one receipt per environment without changing household access', async () => {
      const id = randomUUID(), signedAt = Date.now();
      const receipt = environment => ({verifyNotification:async () => ({kind:'RESCIND_CONSENT',notificationID:id,environment,signedAt})});
      const consent = new BillingService(null, undefined, {primary:receipt('Production'),sandbox:receipt('Sandbox')});
      const state = async () => (await admin.query(`SELECT household_id,member_id,state FROM ritc.member
        WHERE household_id=ANY($1::uuid[]) ORDER BY household_id,member_id`, [[hh, foreignHH]])).rows;
      const before = await state(), paid = await run(purchaser,ctx=>service.snapshot(ctx));
      try {
        const replies = await Promise.all(['primary','primary','reviewSandbox'].map(route => consent.notification(runtime, 'verified', route)));
        assert.deepEqual(replies, Array(3).fill({accepted:true}));
        const rows = (await admin.query('SELECT environment,signed_at FROM ritc.apple_consent_notification WHERE notification_id=$1 ORDER BY environment',[id])).rows;
        assert.deepEqual(rows.map(row=>[row.environment,row.signed_at.getTime()]), [['Production',signedAt],['Sandbox',signedAt]]);
        assert.deepEqual(await state(), before);
        assert.deepEqual(await run(purchaser,ctx=>service.snapshot(ctx)), paid);
        await assert.rejects(()=>runtime.query('SELECT * FROM ritc.apple_consent_notification'), error=>error.code==='42501');
        await assert.rejects(()=>runtime.query('DELETE FROM ritc.apple_consent_notification'), error=>error.code==='42501');
        await assert.rejects(()=>consent.notification({query:async()=>{throw Error('uncommitted receipt');}},'verified'),/uncommitted receipt/);
      } finally {
        await admin.query('DELETE FROM ritc.apple_consent_notification WHERE notification_id=$1',[id]);
      }
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
    await t.test('review and ordinary households reconcile only in their assigned Apple environments', async () => {
      const productionToken = (await run(foreignAdult, ctx => service.prepare(ctx), foreignHH)).appAccountToken;
      const reviewToken = current.appAccountToken;
      const statusReads = [];
      function gateway(environment, token) {
        return {
          async verifyTransaction(signed) {
            const [signedEnvironment, appAccountToken] = signed.split('/');
            if (signedEnvironment !== environment) throw Error('wrong signing environment');
            return { originalTransactionID: original, transactionID: original+'3', appAccountToken };
          },
          async verifyNotification(signed) {
            return { kind:'subscription', notificationID: randomUUID(), transaction: await this.verifyTransaction(signed) };
          },
          async current(id) {
            assert.equal(id, original);
            statusReads.push(environment);
            return { ...current, environment, appAccountToken: token, transactionID: original+'3',
              purchasedAt: timestamp+20000, signedAt: timestamp+20001, expiresAt: timestamp+1e8, status: 'active' };
          },
        };
      }
      const production = gateway('Production', productionToken);
      const dual = new BillingService(production, { sandbox: gateway('Sandbox', reviewToken), householdIDs: new Set([hh]) });
      const reviewReceipt = 'Sandbox/'+reviewToken;
      const ordinaryReceipt = 'Production/'+productionToken;
      await assert.rejects(() => run(foreignAdult, ctx => dual.verify(ctx, 'Sandbox/'+productionToken), foreignHH), /wrong signing environment/);
      await assert.rejects(() => run(purchaser, ctx => dual.verify(ctx, 'Production/'+reviewToken)), /wrong signing environment/);
      await assert.rejects(() => dual.notification(runtime, reviewReceipt), /wrong signing environment/);
      await assert.rejects(() => dual.notification(runtime, ordinaryReceipt, 'reviewSandbox'), /wrong signing environment/);
      // Both notifications authenticate to the endpoint, but name an account in the other environment.
      await assert.rejects(() => dual.notification(runtime, 'Sandbox/'+productionToken, 'reviewSandbox'), error=>error.code==='purchase_already_bound');
      await assert.rejects(() => dual.notification(runtime, 'Production/'+reviewToken), error=>error.code==='purchase_already_bound');
      assert.deepEqual(statusReads, []);
      assert.equal((await admin.query('SELECT 1 FROM ritc.billing_state WHERE household_id=$1', [foreignHH])).rowCount, 0);
      const ordinary = await run(foreignAdult, ctx => dual.verify(ctx, ordinaryReceipt), foreignHH);
      const review = await run(purchaser, ctx => dual.verify(ctx, reviewReceipt));
      assert.deepEqual([ordinary.snapshot.householdID, review.snapshot.householdID], [foreignHH, hh]);
      await dual.notification(runtime, ordinaryReceipt);
      await dual.notification(runtime, reviewReceipt, 'reviewSandbox');
      await run(purchaser, ctx => dual.snapshot(ctx));
      await run(foreignAdult, ctx => dual.replaceSeats(ctx, { revision: ordinary.snapshot.revision, userIDs: [foreignAdult] }), foreignHH);
      assert.deepEqual(statusReads, ['Production','Sandbox','Production','Sandbox','Sandbox','Production']);
      const receipts = await admin.query('SELECT environment, household_id FROM ritc.billing_delivery WHERE transaction_id=$1 ORDER BY environment', [original+'3']);
      assert.deepEqual(receipts.rows, [{ environment:'Production', household_id:foreignHH }, { environment:'Sandbox', household_id:hh }]);
      await assert.rejects(() => new BillingService(production).notification(runtime, reviewReceipt, 'reviewSandbox'), error=>error.code==='billing_unavailable');
      await assert.rejects(() => run(purchaser, ctx => new BillingService(production).snapshot(ctx)), error=>error.code==='purchase_already_bound');
    });
  }finally{await runtime.end();await admin.end();}
});
