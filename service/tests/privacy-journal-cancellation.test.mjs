import test from 'node:test';
import assert from 'node:assert/strict';
import {generateKeyPairSync,randomUUID} from 'node:crypto';
import {chmod,mkdtemp,open,readFile,rm,writeFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
const moduleURL=process.env.PRIVACY_JOURNAL_CANCELLATION_MODULE?pathToFileURL(process.env.PRIVACY_JOURNAL_CANCELLATION_MODULE):new URL('../dist/privacy-journal.js',import.meta.url);
const {createLocalPrivacyJournal,journalHash,verifyPrivacyJournal}=await import(moduleURL.href);
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function held(){let entered,release;const reached=new Promise(resolve=>{entered=resolve;}),done=new Promise(resolve=>{release=resolve;});return{reached,release,async wait(){entered();await done;}};}
function call(milliseconds=2000){const controller=new AbortController();return{controller,attemptId:randomUUID(),deadlineUnixMs:Date.now()+milliseconds,signal:controller.signal};}
async function optional(path){try{return await readFile(path);}catch(error){if(error.code==='ENOENT')return null;throw error;}}
async function fixture(t){
 const root=await mkdtemp('/tmp/ritc-local-journal-cancellation-');await chmod(root,0o700);
 const {privateKey}=generateKeyPairSync('ed25519'),privateKeyPath=root+'/key.pem';await writeFile(privateKeyPath,privateKey.export({format:'pem',type:'pkcs8'}),{mode:0o600});
 const pins={lineage:randomUUID(),schemaDigest:'b'.repeat(64),configurationId:'local-cancellation-fixture',keyId:'synthetic-only-key'},file=root+'/journal/journal.ndjson',checkpointPath=root+'/head.json';
 const gates=[],writers=new Set(),hooks={},outbox=new Map(),acks=new Map(),queries=[],acquisitions=[],released=[];
 const source={
  origin:{lineage:pins.lineage,schema_digest:pins.schemaDigest,configuration_id:pins.configurationId,fenced:false},
  async query(sql,args=[]){
   queries.push({sql,args});
   if(sql.startsWith('SELECT lineage'))return{rows:[structuredClone(this.origin)]};
   if(sql.startsWith('UPDATE ritc.privacy_journal_origin')){this.origin.fenced=true;return{rows:[],rowCount:1};}
   if(sql.startsWith('SELECT event_id,payload,payload_digest')||sql.startsWith('SELECT payload,payload_digest')){
    if(hooks.read)await hooks.read(sql,args);const value=outbox.get(args[0]);return{rows:value?[{event_id:value.eventId,payload:value.payload,payload_digest:value.payloadDigest}]:[],rowCount:value?1:0};
   }
   if(sql.startsWith('SELECT 1 FROM ritc.privacy_journal_outbox'))return{rows:outbox.has(args[0])?[{}]:[],rowCount:outbox.has(args[0])?1:0};
   if(sql.startsWith('SELECT e.event_id')){
    if(hooks.list)await hooks.list();return{rows:[...outbox.values()].filter(value=>!acks.has(value.eventId)&&(!args.length||value.payload.jobId===args[0])).map(value=>({event_id:value.eventId}))};
   }
   if(sql.startsWith('SELECT ritc.privacy_journal_acknowledge')){
    // Eligibility is tested at dispatch, before any held acknowledgement can finish.
    const head=JSON.parse(await readFile(checkpointPath,'utf8')),records=(await readFile(file,'utf8')).trimEnd().split('\n').map(JSON.parse);
    assert.ok(head.seq>=args[2]);assert.equal(head.hash,journalHash(records[head.seq-1]));assert.equal(args[3],journalHash(records[args[2]-1]));assert.equal(args[1],outbox.get(args[0]).payloadDigest);
    if(hooks.ack)await hooks.ack(sql,args);const prior=acks.get(args[0]);if(prior)assert.deepEqual(prior,args);acks.set(args[0],args);return{rows:[{}],rowCount:1};
   }
   throw Error('Unexpected fixture source query');
  },
  async connect(){const index=acquisitions.length;acquisitions.push(index);if(hooks.acquire)await hooks.acquire(index);let returned=false;return{query:(sql,args)=>this.query(sql,args),release(){assert.equal(returned,false);returned=true;released.push(index);}};},
 };
 const configuration={...pins,source,directory:root+'/journal',checkpointPath,privateKeyPath};
 const f={root,pins,file,checkpointPath,source,configuration,outbox,acks,queries,hooks,acquisitions,released,
  gate(){const value=held();gates.push(value);return value;},
  event(kind='acceptance',jobId=randomUUID()){const payload={version:1,eventId:randomUUID(),lineage:pins.lineage,schemaDigest:pins.schemaDigest,configurationId:pins.configurationId,jobId,kind,data:{}};return{eventId:payload.eventId,payloadDigest:journalHash(payload),payload};},
  async writer(extra={}){const value=await createLocalPrivacyJournal({...configuration,...extra});writers.add(value);return value;},
  async close(writer){await writer.close();writers.delete(writer);},
  async snapshot(){return{file:await optional(file),head:await readFile(checkpointPath),queries:queries.length,acks:acks.size};},
  async unchanged(before){assert.deepEqual(await optional(file),before.file);assert.deepEqual(await readFile(checkpointPath),before.head);assert.equal(queries.length,before.queries);assert.equal(acks.size,before.acks);},
 };
 t.after(async()=>{for(const gate of gates)gate.release();for(const writer of writers)await writer.close().catch(()=>{});await rm(root,{recursive:true,force:true});});return f;
}
async function prepared(f){const writer=await f.writer(),event=f.event();await writer.port.beforeCommit(event);f.outbox.set(event.eventId,event);return{writer,event};}
const cancelled=/abort|cancel|deadline/i;

test('legacy one-argument writer and owner fence still produce a verifiable durable journal',async t=>{
 const f=await fixture(t),{writer,event}=await prepared(f);await writer.port.afterCommit(event.eventId);const head=await writer.fence();assert.equal(f.acquisitions.length,0);assert.equal(f.acks.size,1);assert.deepEqual(verifyPrivacyJournal(await readFile(f.file),{...f.pins,publicKey:writer.publicKey,head}).events,[event]);
});
test('already ended caller operations dispatch no SQL or filesystem mutation and do not poison a healthy writer',async t=>{
 for(const operation of ['beforeCommit','afterCommit','acknowledgeJob'])for(const ending of ['abort','deadline'])await t.test(operation+':'+ending,async t=>{
  const f=await fixture(t),writer=await f.writer(),event=f.event(),context=call();if(ending==='abort')context.controller.abort(Error('synthetic caller cancelled'));else context.deadlineUnixMs=Date.now()-1;const before=await f.snapshot();
  await assert.rejects(writer.port[operation](operation==='beforeCommit'?event:operation==='afterCommit'?event.eventId:event.payload.jobId,context),cancelled);await f.unchanged(before);await writer.port.beforeCommit(f.event());
 });
});
test('queueing cannot refresh an absolute deadline, including caller context mutation while queued',async t=>{
 const f=await fixture(t),{writer,event}=await prepared(f),gate=f.gate();f.hooks.read=()=>gate.wait();const active=writer.port.afterCommit(event.eventId,call());await gate.reached;const before=await f.snapshot(),queued=call(35),waiting=writer.port.beforeCommit(f.event(),queued);queued.deadlineUnixMs=Date.now()+60_000;queued.signal=new AbortController().signal;
 await assert.rejects(waiting,/deadline/i);await f.unchanged(before);delete f.hooks.read;gate.release();await active;await writer.port.beforeCommit(f.event(),call());
});
test('queued cancellation stays bound to the original signal and dispatches no later job lookup',async t=>{
 const f=await fixture(t),{writer,event}=await prepared(f),gate=f.gate();f.hooks.read=()=>gate.wait();const active=writer.port.afterCommit(event.eventId,call());await gate.reached;const before=await f.snapshot(),queued=call(),waiting=writer.port.acknowledgeJob(event.payload.jobId,queued);queued.signal=new AbortController().signal;queued.controller.abort(Error('original caller cancelled'));
 await assert.rejects(waiting,cancelled);await f.unchanged(before);delete f.hooks.read;gate.release();await active;await writer.port.beforeCommit(f.event(),call());
});
test('abort during committed-source read prevents append and allows a safe exact retry after read settles',async t=>{
 const f=await fixture(t),{writer,event}=await prepared(f),gate=f.gate(),context=call();f.hooks.read=()=>gate.wait();const before=await f.snapshot(),pending=writer.port.afterCommit(event.eventId,context);await gate.reached;context.controller.abort(Error('read caller cancelled'));await assert.rejects(pending,cancelled);assert.deepEqual(await optional(f.file),before.file);assert.deepEqual(await readFile(f.checkpointPath),before.head);assert.equal(f.acks.size,0);
 delete f.hooks.read;gate.release();await writer.port.afterCommit(event.eventId,call());assert.equal(f.acks.size,1);assert.equal(f.released.length,f.acquisitions.length);
});
test('connection arriving after abort is released unused rather than dispatching the queued source read',async t=>{
 const f=await fixture(t),{writer,event}=await prepared(f),gate=f.gate(),context=call();f.hooks.acquire=()=>gate.wait();const before=await f.snapshot(),pending=writer.port.afterCommit(event.eventId,context);await gate.reached;context.controller.abort(Error('acquisition caller cancelled'));await assert.rejects(pending,cancelled);await f.unchanged(before);delete f.hooks.acquire;gate.release();await writer.port.afterCommit(event.eventId,call());assert.equal(f.released.length,f.acquisitions.length);assert.equal(f.queries.filter(q=>q.sql.startsWith('SELECT event_id')).length,1);
});
test('aborted acknowledgement connection acquisition never dispatches SQL even after durable commit/head',async t=>{
 const f=await fixture(t),{writer,event}=await prepared(f),gate=f.gate(),context=call();f.hooks.acquire=index=>index===1?gate.wait():undefined;const pending=writer.port.afterCommit(event.eventId,context);await gate.reached;assert.equal(JSON.parse(await readFile(f.checkpointPath,'utf8')).seq,2);const durable=await f.snapshot();context.controller.abort(Error('ack connection caller cancelled'));await assert.rejects(pending,cancelled);delete f.hooks.acquire;gate.release();await writer.port.beforeCommit(f.event(),call());assert.equal(f.queries.filter(q=>q.sql.includes('privacy_journal_acknowledge')).length,0);assert.equal(f.acks.size,0);assert.ok(durable.file.length>0);await writer.port.afterCommit(event.eventId,call());assert.equal(f.acks.size,1);
});
test('issued fsync can finish after abort/deadline, but cannot dispatch checkpoint/COMMIT or permit a fresh writer',async t=>{
 for(const ending of ['abort','deadline'])await t.test(ending,async t=>{
  const f=await fixture(t),writer=await f.writer(),event=f.event(),gate=f.gate(),context=call(ending==='deadline'?50:2000),probe=await open(f.root+'/probe','w'),prototype=Object.getPrototypeOf(probe),sync=prototype.sync,write=prototype.writeFile;await probe.close();let syncs=0,commits=0,observedSignal;
  const syncMock=t.mock.method(prototype,'sync',async function(...args){const value=await sync.apply(this,args);if(++syncs===1)await gate.wait();return value;});
  const writeMock=t.mock.method(prototype,'writeFile',async function(data,options){observedSignal??=options?.signal;return write.call(this,data,options);});
  try{const pending=writer.port.beforeCommit(event,context).then(()=>{commits++;});await gate.reached;if(ending==='abort')context.controller.abort(Error('append caller cancelled'));await assert.rejects(pending,cancelled);assert.ok(observedSignal instanceof AbortSignal);assert.equal(observedSignal.aborted,true);assert.equal(commits,0);assert.equal(JSON.parse(await readFile(f.checkpointPath,'utf8')).seq,0);gate.release();await assert.rejects(writer.port.beforeCommit(f.event(),call()),/explicit fenced recovery/);assert.equal(syncs,1);assert.equal(commits,0);assert.equal(f.acks.size,0);assert.equal(await optional(f.checkpointPath+'.pending'),null);}finally{gate.release();syncMock.mock.restore();writeMock.mock.restore();}
  await f.close(writer);await assert.rejects(f.writer(),/Uncheckpointed tail/);f.source.origin.fenced=true;const recovery=await f.writer({mode:'recover_fenced'}),head=await recovery.fence();assert.equal(verifyPrivacyJournal(await readFile(f.file),{...f.pins,publicKey:recovery.publicKey,head}).events.length,0);
 });
});
test('cancellation injected before first append side effect leaves writer usable without a tail',async t=>{
 const f=await fixture(t),context=call();let first=true;const writer=await f.writer({fault:point=>{if(point==='before_intent_sync'&&first){first=false;context.controller.abort(Error('pre-write caller cancelled'));}}}),before=await f.snapshot();await assert.rejects(writer.port.beforeCommit(f.event(),context),cancelled);await f.unchanged(before);await writer.port.beforeCommit(f.event(),call());
});
test('cancellation after synced intent and before checkpoint poisons tail and never claims COMMIT',async t=>{
 const f=await fixture(t),context=call();const writer=await f.writer({fault:point=>{if(point==='after_intent_sync')context.controller.abort(Error('checkpoint caller cancelled'));}});let commit=false;await assert.rejects(writer.port.beforeCommit(f.event(),context).then(()=>{commit=true;}),cancelled);assert.equal(commit,false);assert.equal(JSON.parse(await readFile(f.checkpointPath,'utf8')).seq,0);assert.equal(await optional(f.checkpointPath+'.pending'),null);await assert.rejects(writer.port.beforeCommit(f.event()),/explicit fenced recovery/);assert.equal(f.acks.size,0);
});
test('acknowledgement already dispatched with durable commit/head may finish late, without a false successful caller result',async t=>{
 const f=await fixture(t),{writer,event}=await prepared(f),gate=f.gate(),context=call();f.hooks.ack=()=>gate.wait();const pending=writer.port.afterCommit(event.eventId,context);await gate.reached;const durable=await f.snapshot();context.controller.abort(Error('already sent ack caller cancelled'));await assert.rejects(pending,cancelled);assert.equal(f.acks.size,0);delete f.hooks.ack;gate.release();await writer.port.afterCommit(event.eventId,call());assert.equal(f.acks.size,1);assert.deepEqual(await readFile(f.file),durable.file);assert.deepEqual(await readFile(f.checkpointPath),durable.head);assert.equal(f.released.length,f.acquisitions.length);
});
test('job reconciliation stops before another event after an already-dispatched acknowledgement aborts',async t=>{
 const f=await fixture(t),{writer,event}=await prepared(f);await writer.port.afterCommit(event.eventId);const a=f.event('target_erased',event.payload.jobId),b=f.event('target_erased',event.payload.jobId);f.outbox.set(a.eventId,a);f.outbox.set(b.eventId,b);const gate=f.gate(),context=call();f.hooks.ack=(_sql,args)=>args[0]===a.eventId?gate.wait():undefined;const pending=writer.port.acknowledgeJob(event.payload.jobId,context);await gate.reached;context.controller.abort(Error('job caller cancelled'));await assert.rejects(pending,cancelled);delete f.hooks.ack;gate.release();await writer.port.beforeCommit(f.event(),call());assert.equal(f.acks.has(a.eventId),true);assert.equal(f.acks.has(b.eventId),false);assert.equal(f.queries.some(q=>q.sql.startsWith('SELECT event_id')&&q.args[0]===b.eventId),false);await writer.port.acknowledgeJob(event.payload.jobId,call());assert.equal(f.acks.has(b.eventId),true);
});

test('only an omitted legacy context opts out; malformed explicit contexts cannot bypass admission',async t=>{
 const f=await fixture(t),writer=await f.writer(),event=f.event(),before=await f.snapshot();
 for(const context of [null,false,{}, {...call(),attemptId:''},{...call(),deadlineUnixMs:Infinity},{...call(),signal:{aborted:false}}])await assert.rejects(writer.port.beforeCommit(event,context),/Call-owned journal/);
 await f.unchanged(before);await writer.port.beforeCommit(event);
});
