import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {PrivacyMaintenance} from '../dist/privacy.js';
import {JournalWriterBusy} from '../dist/privacy-journal-durable-contract.js';
import {fixture} from './durable-authority-fixture.mjs';
import {call,progressEvent} from './durable-independent-fixture.mjs';

async function slowWorker(t,{workerRole=true}={}) {
  const state=fixture(),acceptance=state.event();
  const setup=state.adapter().port;
  await setup.beforeCommit(acceptance,call());
  state.commit(acceptance);
  await setup.afterCommit(acceptance.eventId,call());
  const target=progressEvent(acceptance),completion=progressEvent(acceptance,'source_completed');
  const job=acceptance.payload.jobId,subject=randomUUID();
  const initialLogLength=state.logs.length;
  const startedAt=Date.now();
  let now=startedAt,erasureSteps=0,providerCalls=0,jobFinished=false;
  t.mock.method(Date,'now',()=>now);
  // A protected source round trip takes hundreds of milliseconds, while the
  // authority is closer. Use a virtual clock so deadline boundaries are stable.
  const phaseMs={sourceOrigin:720,sourceRead:720,sourceAcceptance:720,sourceList:720,ack:720,
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
  const pool={async connect(){return {
    release(){},
    async query(sql,args=[]){
      now+=45;
      if(sql==='BEGIN'||sql==='COMMIT'||sql==='ROLLBACK'||sql.startsWith('SET LOCAL '))return {rows:[]};
      if(sql.startsWith('SELECT r.rolsuper'))return row({worker:workerRole,application:!workerRole});
      if(sql.startsWith('SELECT ritc.privacy_claim_reconciliation('))return row({job_id:null});
      if(sql.startsWith('SELECT * FROM ritc.privacy_cleanup('))return row({receipts_cleared:0,jobs_purged:0});
      if(sql.startsWith('SELECT * FROM ritc.privacy_claim('))return row({job_id:job,issuer:'https://fixture.invalid',subject,app_erased:false});
      if(sql.startsWith('SELECT * FROM ritc.privacy_worker_journal_needs('))return row({target_remaining:erasureSteps===0,pending_needed:true});
      if(sql.startsWith('SELECT ritc.privacy_erase_target(')){
        assert.equal(args[0],job);
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
        jobFinished=true;
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
    now+=700;
  }};
  const worker=new PrivacyMaintenance(pool,{provider,journal:state.adapter({clock:{now:()=>now}}).port});
  return {worker,state,target,completion,read(){return {erasureSteps,providerCalls,jobFinished,elapsed:now-startedAt,log:state.logs.slice(initialLogLength)};}};
}

test('one ordinary worker completes its signed deletion chain under protected source latency',async t=>{
  const run=await slowWorker(t);
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

test('a shorter caller deadline still leaves uncertain progress blocked before provider deletion',async t=>{
  const run=await slowWorker(t);
  await assert.rejects(run.worker.run({batchSize:1,timeBudgetMs:5_200}));
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
