import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {tokenHash} from '../dist/database.js';
import {PrivacyMaintenance,PrivacyService} from '../dist/privacy.js';
import {JournalWriterBusy} from '../dist/privacy-journal-durable-contract.js';
import {fixture} from './durable-authority-fixture.mjs';
import {call,progressEvent} from './durable-independent-fixture.mjs';

async function slowWorker(t,{workerRole=true,sourceMs=720,sqlMs=45,providerMs=700}={}) {
  const state=fixture(),acceptance=state.event();
  const setup=state.adapter().port;
  await setup.beforeCommit(acceptance,call());
  state.commit(acceptance);
  await setup.afterCommit(acceptance.eventId,call());
  const target=progressEvent(acceptance),completion=progressEvent(acceptance,'source_completed');
  const job=acceptance.payload.jobId,subject=randomUUID(),receiptToken='R'.repeat(43);
  const initialLogLength=state.logs.length;
  const startedAt=Date.now();
  let now=startedAt,erasureSteps=0,providerCalls=0,jobState='pending',lease=null,leaseUntil=0;
  t.mock.method(Date,'now',()=>now);
  // A protected source round trip takes hundreds of milliseconds, while the
  // authority is closer. Use a virtual clock so deadline boundaries are stable.
  const phaseMs={sourceOrigin:sourceMs,sourceRead:sourceMs,sourceAcceptance:sourceMs,sourceList:sourceMs,ack:sourceMs,
    begin:220,inspect:90,readExact:150,head:90,reserve:180,put:220,publish:200,complete:140};
  for(const [phase,ms] of Object.entries(phaseMs))state.hooks[phase]=()=>{now+=ms;};
  state.authority.reserveWorkerCapacity=async (jobId,kinds)=>{
    assert.equal(jobId,job);
    assert.ok(kinds.length);
    now+=180;
    if(state.uncertainCount())throw new JournalWriterBusy();
    return true;
  };
  const row=(value)=>({rows:[value]});
  const acknowledged=(event)=>state.acknowledgements.some(entry=>entry.identity.eventId===event.eventId);
  const unacknowledged=()=>erasureSteps>0&&!acknowledged(target)||jobState==='complete'&&!acknowledged(completion);
  const claim=(value)=>{lease=value;leaseUntil=now+30_000;};
  const pool={async connect(){return {
    release(){},
    async query(sql,args=[]){
      now+=sqlMs;
      if(sql==='BEGIN'||sql==='COMMIT'||sql==='ROLLBACK'||sql.startsWith('SET LOCAL '))return {rows:[]};
      if(sql.startsWith('SELECT r.rolsuper'))return row({worker:workerRole,application:!workerRole});
      if(sql.startsWith('SELECT ritc.privacy_claim_reconciliation(')){
        if(leaseUntil>now||!unacknowledged())return row({job_id:null});
        if(jobState==='processing')jobState='pending';
        claim(args[0]);
        return row({job_id:job});
      }
      if(sql.startsWith('SELECT ritc.privacy_release_reconciliation(')){
        assert.deepEqual(args,[job,lease]);
        assert.notEqual(jobState,'processing');
        lease=null;leaseUntil=0;
        return {rows:[]};
      }
      if(sql.startsWith('SELECT * FROM ritc.privacy_status_for_journal(')){
        if(args[0]!==job||args[1]!==tokenHash(receiptToken))return {rows:[]};
        const complete=jobState==='complete'&&!unacknowledged();
        return row({archived:false,value:{status:complete?'complete':'pending',providerAccountDeleted:complete}});
      }
      if(sql.startsWith('SELECT * FROM ritc.privacy_cleanup('))return row({receipts_cleared:0,jobs_purged:0});
      if(sql.startsWith('SELECT * FROM ritc.privacy_claim(')){
        if(jobState==='complete'||leaseUntil>now||unacknowledged())return {rows:[]};
        jobState='processing';
        claim(args[0]);
        return row({job_id:job,issuer:'https://fixture.invalid',subject,app_erased:erasureSteps===2});
      }
      if(sql.startsWith('SELECT * FROM ritc.privacy_worker_journal_needs('))return row({target_remaining:erasureSteps===0,pending_needed:true});
      if(sql.startsWith('SELECT ritc.privacy_erase_target(')){
        assert.deepEqual(args,[job,lease]);
        assert.equal(jobState,'processing');
        erasureSteps++;
        if(erasureSteps===1){state.commit(target);return row({erased:false});}
        assert.equal(erasureSteps,2);
        assert.ok(state.acknowledgements.some(entry=>entry.identity.eventId===target.eventId));
        return row({erased:true});
      }
      if(sql.startsWith('SELECT ritc.privacy_finish(')){
        assert.equal(args[0],job);
        assert.equal(args[2],true);
        assert.equal(providerCalls,1);
        jobState='complete';
        lease=null;leaseUntil=0;
        state.commit(completion);
        return row({committed:true});
      }
      throw Error(`Unexpected fixture SQL: ${sql}`);
    },
  };}};
  const provider={async deleteAccount(actual,context){
    assert.equal(actual,subject);
    assert.equal(erasureSteps,2);
    assert.equal(context.signal.aborted,false);
    assert.equal(now<context.deadlineUnixMs,true);
    const exact=state.acknowledgements.find(entry=>entry.identity.eventId===target.eventId);
    assert.equal(exact?.identity.payloadDigest,target.payloadDigest);
    assert.equal(exact?.receipt.record.transition,'commit');
    providerCalls++;
    now+=providerMs;
  }};
  const journal=()=>state.adapter({clock:{now:()=>now}}).port;
  const worker=()=>new PrivacyMaintenance(pool,{provider,journal:journal()});
  const status=(token=receiptToken)=>new PrivacyService({pool},{journal:journal()}).status(job,token);
  return {worker:worker(),newWorker:worker,status,state,target,completion,
    advance(ms){now+=ms;},read(){return {erasureSteps,providerCalls,jobFinished:jobState==='complete',elapsed:now-startedAt,log:state.logs.slice(initialLogLength)};}};
}

test('one ordinary worker completes its signed deletion chain with a full final acknowledgement window',async t=>{
  const run=await slowWorker(t,{sourceMs:400});
  const result=await run.worker.run({batchSize:1,timeBudgetMs:20_000});
  const observed=run.read();
  assert.equal(result.completed,1);
  assert.equal(observed.erasureSteps,2);
  assert.equal(observed.providerCalls,1);
  assert.equal(observed.jobFinished,true);
  assert.ok(observed.elapsed<20_000);
  t.diagnostic(`Modeled worker elapsed time: ${observed.elapsed}ms`);
  assert.equal(run.state.uncertainCount(),0);
  assert.deepEqual(run.state.records.map(record=>record.event.payload.kind),['acceptance','acceptance','target_erased','source_completed']);
  assert.deepEqual(run.state.acknowledgements.slice(1).map(entry=>entry.identity.eventId),[run.target.eventId,run.completion.eventId]);
  assert.equal(observed.log.filter(phase=>phase==='enter:sourceAcceptance').length,3);
});

test('an in-flight deadline still leaves uncertain progress blocked before provider deletion',async t=>{
  const run=await slowWorker(t);
  const origin=run.state.hooks.sourceOrigin;
  run.state.hooks.sourceOrigin=(context)=>{
    if(run.state.uncertainCount())run.advance(20_000);
    else origin(context);
  };
  await assert.rejects(run.worker.run({batchSize:1,timeBudgetMs:20_000}));
  assert.equal(run.state.uncertainCount(),1);
  assert.equal(run.state.receiptFor(run.target.eventId,'commit'),undefined);
  assert.equal(run.state.acknowledgements.length,1);
  assert.equal(run.read().erasureSteps,1);
  assert.equal(run.read().providerCalls,0);
  assert.equal(run.read().jobFinished,false);
});

test('a corrupted independent admission response keeps the exact signed source acknowledgement pending',async t=>{
  const run=await slowWorker(t);
  run.state.faults.receipt='signature';
  await assert.rejects(run.worker.run({batchSize:1,timeBudgetMs:20_000}),/requires explicit fenced reconciliation/);
  assert.ok(run.state.receiptFor(run.target.eventId,'commit'));
  assert.equal(run.state.uncertainCount(),1);
  assert.equal(run.state.acknowledgements.length,1);
  assert.equal(run.read().providerCalls,0);
  assert.equal(run.read().jobFinished,false);
});

test('a non-worker database role cannot enter deletion processing',async t=>{
  const run=await slowWorker(t,{workerRole:false});
  await assert.rejects(run.worker.run({batchSize:1,timeBudgetMs:20_000}),/requires the separate non-owner/);
  assert.equal(run.read().erasureSteps,0);
  assert.equal(run.read().providerCalls,0);
  assert.equal(run.state.uncertainCount(),0);
});


test('slow source completion stays pending without a claim and the next worker acknowledges it without calling the provider',async t=>{
  const run=await slowWorker(t,{sqlMs:145,providerMs:1_800});
  const first=await run.worker.run({batchSize:1,timeBudgetMs:20_000});
  t.diagnostic(`Modeled first worker returned at ${run.read().elapsed}ms`);
  assert.equal(first.completed,0);
  assert.equal(first.journalDeferred,1);
  assert.equal(run.read().jobFinished,true);
  assert.equal(run.read().providerCalls,1);
  assert.equal(run.state.uncertainCount(),0);
  assert.equal(run.state.receiptFor(run.completion.eventId,'commit'),undefined);
  assert.deepEqual(run.state.acknowledgements.slice(1).map(entry=>entry.identity.eventId),[run.target.eventId]);

  const mutations=run.state.mutations;
  for(let attempt=0;attempt<2;attempt++)assert.deepEqual(await run.status(),{status:'pending',providerAccountDeleted:false});
  await assert.rejects(run.status('S'.repeat(43)),error=>error.status===404);
  assert.equal(run.state.mutations,mutations);
  assert.equal(run.state.uncertainCount(),0);

  const constrained=await run.newWorker().run({batchSize:1,timeBudgetMs:20_000,deadlineUnixMs:Date.now()+3_000});
  assert.equal(constrained.journalDeferred,1);
  assert.equal(run.state.uncertainCount(),0);
  assert.equal(run.read().providerCalls,1);

  const secondStarted=run.read().elapsed;
  const second=await run.newWorker().run({batchSize:1,timeBudgetMs:20_000});
  t.diagnostic(`Modeled follow-up worker reconciled in ${run.read().elapsed-secondStarted}ms`);
  assert.equal(second.journalDeferred,0);
  assert.equal(run.read().providerCalls,1);
  assert.equal(run.state.uncertainCount(),0);
  assert.deepEqual(run.state.acknowledgements.slice(1).map(entry=>entry.identity.eventId),[run.target.eventId,run.completion.eventId]);
  assert.deepEqual(await run.status(),{status:'complete',providerAccountDeleted:true});
});


test('a target committed near the outer deadline waits for its processing lease to expire before reconciliation',async t=>{
  const run=await slowWorker(t,{sourceMs:400,sqlMs:100});
  const first=await run.worker.run({batchSize:1,timeBudgetMs:20_000,deadlineUnixMs:Date.now()+6_800});
  assert.equal(first.journalDeferred,1);
  assert.equal(run.read().erasureSteps,1);
  assert.equal(run.read().providerCalls,0);
  assert.equal(run.state.uncertainCount(),0);
  assert.equal(run.state.receiptFor(run.target.eventId,'commit'),undefined);

  const beforeExpiry=await run.newWorker().run({batchSize:1,timeBudgetMs:20_000});
  assert.equal(beforeExpiry.completed,0);
  assert.equal(run.read().providerCalls,0);
  assert.equal(run.state.acknowledgements.length,1);
  run.advance(30_000);
  await run.newWorker().run({batchSize:1,timeBudgetMs:20_000});
  assert.ok(run.state.receiptFor(run.target.eventId,'commit'));
  assert.equal(run.state.acknowledgements.filter(entry=>entry.identity.eventId===run.target.eventId).length,1);
  assert.equal(run.state.uncertainCount(),0);
  await run.newWorker().run({batchSize:1,timeBudgetMs:20_000});
  assert.equal(run.read().providerCalls,1);
  assert.deepEqual(await run.status(),{status:'complete',providerAccountDeleted:true});
});
