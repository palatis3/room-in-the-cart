// The Foundation vectors supply event inputs and expected outputs. All routing,
// authorization, checkout, concurrency and replay decisions come from the HTTP service.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {Agent,request} from 'node:http';

const source=new URL('../../docs/product/foundation-gen2.1/references/grocery30/inbox-scenarios.json',import.meta.url);
const ownFields=['requestId','shopId','revision','originalItem','ownQuantity','authoredAt','receivedAt','route','status','ownActionAllowed','clarification','followupTo'].sort();

function session(origin,household,actor) {
  const agent=new Agent({keepAlive:true,maxSockets:1});
  function http(path,body,discardReply=false) {
    return new Promise((resolve,reject)=>{
      const req=request(new URL('/v1/households/'+household+path,origin),{agent,method:body?'POST':'GET',
        headers:{Authorization:'Bearer '+actor.token,'X-Device-Token':actor.deviceToken,...(body?{'Content-Type':'application/json'}:{})}},res=>{
        // The server has committed before writing these headers. Close the socket
        // without delivering receipt bytes to this client's replay bookkeeping.
        if(discardReply && res.statusCode===200){res.destroy();resolve({status:200,lost:true});return;}
        let raw='';res.setEncoding('utf8');res.on('data',chunk=>{raw+=chunk;});res.on('error',reject);
        res.on('end',()=>{try{resolve({status:res.statusCode,data:JSON.parse(raw)});}catch(error){reject(error);}});
      });
      req.on('error',reject);req.end(typeof body==='string'?body:JSON.stringify(body));
    });
  }
  return {http,close:()=>agent.destroy()};
}

function ok(response){assert.equal(response.status,200,JSON.stringify(response.data));return response.data;}
function sameFields(value,fields){assert.deepEqual(Object.keys(value).sort(),[...fields].sort());}
function routeState(row){
  if(row.status==='deferred')assert.equal(row.route,'next');
  if(row.status==='added' || row.status==='withdrawn')assert.equal(row.route,'current');
  assert.equal(row.ownActionAllowed,row.status==='pending');
  return row.route==='next'?'next':row.status;
}
const decisionEvent=e=>e.op==='apply'||e.op==='defer';

async function runVector(t,vector,f,admin,origin) {
  const actors=Object.keys(f.actors),sessions=Object.fromEntries(actors.map(name=>[name,session(origin,f.h,f.actors[name])]));
  t.after(()=>Object.values(sessions).forEach(s=>s.close()));
  for(const key of ['subject','session','deviceId','window']){
    assert.equal(new Set(actors.map(a=>f.actors[a][key])).size,actors.length,key);
  }
  const shopPath='/shops/'+f.shopId,ids=new Map(),requests=new Map(),prepared=new Map(),receipts=new Map(),envelopes=new Map();
  const shopState=actor=>sessions[actor].http(shopPath);
  const inbox=actor=>sessions[actor].http(shopPath+'/inbox');
  const when=new Date().toISOString(); // Authored/observed before any delayed delivery in this vector.
  const id=label=>{if(!ids.has(label))ids.set(label,randomUUID());return ids.get(label);};
  const ownerKey=e=>(e.owner??e.actor)+'/'+e.id;
  const requestId=e=>requests.get(ownerKey(e))??id('missing/'+ownerKey(e));
  const commandKey=e=>e.actor+'/'+e.key;
  const signature=e=>JSON.stringify(e);
  const reviewedSends=new Map();
  const base=e=>({shopRevision:e.revision??0,authorityEpoch:e.epoch??0,...(e.request_revision?{requestRevision:e.request_revision}:{})});
  const ask=(e,path,body)=>sessions[e.actor].http(path,body);
  function decision(e,quantity) {
    if(e.op==='defer')return {choice:'defer'};
    return {choice:'add',promote:false,line:{lineId:id('basket/'+ownerKey(e)),originalItem:'Reviewed '+ownerKey(e),
      packs:quantity==='two boxes'?2:1,unitPriceMinor:349,feeEligible:true}};
  }
  function preview(e,row,version=base(e)) {
    return ask(e,shopPath+'/previews',{requestId:requestId(e),base:version,decision:decision(e,row?.ownQuantity)});
  }
  // Hold the real preview open while the other session edits, buys, or
  // transfers authority. A retry resends the original preview id.
  async function prepare(future) {
    for(const e of future.filter(decisionEvent)) {
      if(prepared.has(signature(e)) || !requests.has(ownerKey(e)))continue;
      const res=await shopState(e.actor);
      if(res.status!==200 || res.data.phase!=='draft' || res.data.shopRevision!==e.revision || res.data.authorityEpoch!==e.epoch)continue;
      const row=ok(await inbox(e.actor)).requests.find(r=>r.requestId===requestId(e));
      if(!row || row.status!=='pending' || row.revision!==e.request_revision)continue;
      const p=ok(await preview(e,row));
      assert.equal(p.shopRevision,e.revision);assert.equal(p.requestRevision,row.revision);assert.equal(p.authorityEpoch,e.epoch);
      if(e.op==='apply'){
        assert.equal(p.changeMinor,decision(e,row.ownQuantity).line.packs*349);
        assert.equal(p.requiresOverageAcceptance,true);
      }
      prepared.set(signature(e),p);
    }
  }
  function wireCommand(e,kind,body) {
    return {v:1,clientKey:id('operation/'+e.key),replayWindow:f.actors[e.actor].window,shopId:f.shopId,kind,base:base(e),body};
  }
  // Compose sends before the first event, including those delivered only after
  // the checkout closes or the device loses access.
  const queued=new Map(vector.events.filter(e=>e.op==='send').map(e=>{
    const body={clientRequestId:id('local/'+e.id),originalItem:'Requested '+e.id,ownQuantity:e.text,authoredAt:when};
    return [signature(e),JSON.stringify(wireCommand(e,'request.send',body))];
  }));
  async function submit(e,kind,body,drop) {
    const bytes=kind==='request.send'?queued.get(signature(e)):JSON.stringify(wireCommand(e,kind,body));
    assert.equal(typeof bytes,'string');
    if(envelopes.has(signature(e)))assert.equal(bytes,envelopes.get(signature(e)));
    envelopes.set(signature(e),bytes);
    const result=await sessions[e.actor].http('/commands',bytes,drop);
    const persisted=(await admin.query(`SELECT o.operation_id,r.response FROM ritc.operation o
      JOIN ritc.operation_response r USING(household_id,operation_id)
      WHERE o.household_id=$1 AND o.actor_id=$2 AND o.client_key=$3`,[f.h,f.actors[e.actor].id,id('operation/'+e.key)])).rows;
    if(result.status!==200){
      assert.equal(persisted.length,receipts.has(commandKey(e))?1:0);
      if(persisted.length)assert.deepEqual(persisted[0].response,receipts.get(commandKey(e)));
      return result;
    }
    assert.equal(persisted.length,1);
    const saved=persisted[0].response;
    assert.equal(saved.operationId,persisted[0].operation_id);assert.equal(saved.kind,kind);
    if(!result.lost)assert.deepEqual(result.data,saved);
    if(receipts.has(commandKey(e))){
      assert.deepEqual(receipts.get(commandKey(e)),saved);
    }else if(saved.request){
      sameFields(saved,['kind','operationId','request']);
      const row=saved.request;
      assert.equal(row.shopId,f.shopId);assert.equal(row.originalItem,'Requested '+e.id);assert.equal(row.authoredAt,when);
      assert(Number.isFinite(Date.parse(row.receivedAt)));
      if(e.op==='send' || e.op==='edit')reviewedSends.set(ownerKey(e),e.text);
      assert.equal(row.ownQuantity,reviewedSends.get(ownerKey(e)));
    }else if(kind!=='shop.reportPlaced'){
      const decisionFields=decisionEvent(e)?['requestId','requestRevision']:[];
      sameFields(saved,['kind','operationId','shopId','shopRevision','authorityEpoch','disposition',...decisionFields]);
      const dbShop=(await admin.query('SELECT revision,authority_epoch FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows[0];
      assert.equal(saved.shopId,f.shopId);assert.equal(saved.shopRevision,dbShop.revision);assert.equal(saved.authorityEpoch,dbShop.authority_epoch);
      if(decisionEvent(e)){assert.equal(saved.requestId,requestId(e));assert.equal(saved.requestRevision,e.request_revision+1);}
    }
    receipts.set(commandKey(e),saved);
    // Only the test observer can describe a committed acknowledgement that a
    // transport lost. The client obtains the request id on successful retry.
    if(e.op==='send' && !result.lost)requests.set(ownerKey(e),result.data.request.requestId);
    return result.lost?{status:200,data:saved}:result;
  }
  async function execute(e,drop) {
    switch(e.op){
      case 'send':return submit(e,'request.send',undefined,drop);
      case 'edit':return submit(e,'request.edit',{requestId:requestId(e),originalItem:'Requested '+e.id,ownQuantity:e.text},drop);
      case 'withdraw':return submit(e,'request.withdraw',{requestId:requestId(e)},drop);
      case 'transfer':return submit(e,'shop.transferAuthority',{newShopperId:f.actors[e.target].id},drop);
      case 'freeze':return submit(e,'shop.freeze',{},drop);
      case 'change_basis':{
        const current=ok(await shopState(e.actor));
        return submit(e,'shop.patch',{lines:current.lines,quote:{...current.quote,capMinor:3700}},drop);
      }
      case 'place':{
        // The live placement flow opens the current shopper's exact shop.
        // A former shopper may *separately* report their historical checkout.
        const current=await shopState(e.actor);
        if(current.status!==200)return current;
        assert.equal(current.data.authorityEpoch,e.epoch);assert.equal(current.data.shopRevision,e.revision);
        return submit(e,'shop.reportPlaced',{occurredAt:when},drop);
      }
      case 'report_order':return submit(e,'shop.reportPlaced',{occurredAt:when},drop);
      case 'revoke':{
        const target=f.actors[e.target];
        if(vector.label==='Revocation prevents replaying an already accepted submission'){
          const res=await ask(e,'/revocations',{kind:'member',targetId:target.id});
          assert.deepEqual(ok(res),{revoked:true,kind:'member',targetId:target.id});
          return res;
        }
        const res=await ask(e,'/devices/'+target.deviceId+'/revocation',{memberId:target.id});
        assert.equal(ok(res).revoked,true);assert.equal(res.data.deviceId,target.deviceId);
        return res;
      }
      case 'apply':case 'defer':{
        let p=prepared.get(signature(e));
        if(!p){const fresh=await preview(e);if(fresh.status!==200)return fresh;p=fresh.data;prepared.set(signature(e),p);}
        return submit(e,'request.apply',{requestId:requestId(e),previewId:p.previewId,
          acceptOverage:p.requiresOverageAcceptance,acceptUnknown:p.requiresUnknownAcceptance},drop);
      }
      default:assert.fail('Unmapped Foundation operation '+e.op);
    }
  }
  async function outcome(e,res){
    if(res.status===200){
      const r=res.data;
      if(e.op==='revoke')return 'revoked';
      if(e.op==='report_order' || e.op==='place'){
        sameFields(r,['operationId','kind','reportId','disposition']);
        return r.disposition==='pending_reconciliation'?'separate report':r.disposition;
      }
      if(r.request){
        sameFields(r.request,ownFields);
        if(e.op==='edit'){assert.equal(r.request.ownQuantity,e.text);assert.equal(r.request.revision,e.request_revision+1);return 'updated';}
        return routeState(r.request);
      }
      return {patched:'basis changed',deferred:'next'}[r.disposition]??r.disposition;
    }
    const code=res.data.error.code;
    sameFields(res.data,['error']);sameFields(res.data.error,['code','correlationId','recovery']);
    if(code==='unavailable'){
      assert.equal(res.status,404);
      if(e.op==='edit')return 'request unavailable';
      if(e.op==='transfer')return e.actor==='Mia'?'eligible adult required':'organizer required';
      assert(['apply','place','freeze','report_order'].includes(e.op));return 'shopper required';
    }
    if(code==='stale_base'||code==='stale_preview'){
      assert.equal(res.status,409);assert(decisionEvent(e));
      const current=ok(await shopState(e.actor));
      if(current.phase==='placed'){
        const row=ok(await inbox(e.actor)).requests.find(r=>r.requestId===requestId(e));
        assert(row);
        const fresh=await preview(e,row,{shopRevision:current.shopRevision,authorityEpoch:current.authorityEpoch,requestRevision:row.revision});
        assert.equal(fresh.status,409);assert.equal(fresh.data.error.code,'checkout_locked');
        return 'checkout closed to edits';
      }
      return 'refresh preview';
    }
    const errors={access_ended:[403,'access ended'],authority_changed:[409,'shopper required'],checkout_locked:[409,'checkout closed to edits'],
      key_reused:[409,'operation conflict'],already_handled:[409,'already handled'],followup_required:[409,'follow-up required']};
    assert(errors[code],JSON.stringify(res));assert.equal(res.status,errors[code][0]);return errors[code][1];
  }
  const results=[];
  for(const [i,e] of vector.events.entries()){
    const drop=vector.label==='Lost reply retries the same request and decision' && !receipts.has(commandKey(e));
    const result=await outcome(e,await execute(e,drop));
    assert.equal(result,vector.expected.results[i],JSON.stringify(e));
    if(result==='refresh preview' || (result==='checkout closed to edits' && vector.label==='Pending request crosses cutoff while preview is open')){
      const p=prepared.get(signature(e));
      assert(p,vector.label+' must exercise a previously opened preview');
      assert.equal(JSON.parse(envelopes.get(signature(e))).body.previewId,p.previewId);
    }
    results.push(result);await prepare(vector.events.slice(i+1));
  }
  const expected=vector.expected;
  const shop=(await admin.query('SELECT shopper_id,authority_epoch,revision,phase FROM ritc.shop WHERE household_id=$1 AND shop_id=$2',[f.h,f.shopId])).rows[0];
  const shopper=actors.find(a=>f.actors[a].id===shop.shopper_id);
  const current=ok(await shopState(shopper));
  assert.equal(current.shopRevision,shop.revision);assert.equal(current.authorityEpoch,shop.authority_epoch);assert.equal(current.phase,shop.phase);
  const rows=ok(await inbox(shopper)).requests;
  const states={},lookup=new Map([...requests].map(([key,value])=>[value,key]));
  for(const r of rows){
    const key=lookup.get(r.requestId);assert(key);assert.equal(r.authorAlias,key.split('/')[0]);
    assert.equal(r.linkedLineId,current.phase==='placed' && r.status==='added'?id('basket/'+key):undefined);
    assert.equal(r.ownQuantity,reviewedSends.get(key));assert.equal(r.purchaseOutcome,undefined);states[key]=routeState(r);
  }
  for(const actor of actors){
    const res=await sessions[actor].http('/requests/mine');
    if(vector.events.some(e=>e.op==='revoke' && e.target===actor)){
      assert.equal(res.status,403);assert.equal(res.data.error.code,'access_ended');continue;
    }
    const mine=ok(res).requests;
    mine.forEach(r=>sameFields(r,ownFields));
    assert.deepEqual(mine,rows.filter(r=>r.authorAlias===actor).map(({authorAlias,linkedLineId,...r})=>r));
    if(actor!==shopper)assert.equal((await inbox(actor)).status,404);
  }
  const mutations=(await admin.query("SELECT operation_id FROM ritc.operation WHERE household_id=$1 AND kind<>'shop.create'",[f.h])).rows;
  assert.deepEqual(mutations.map(r=>r.operation_id).sort(),[...receipts.values()].map(r=>r.operationId).sort());
  const linked=(await admin.query(`SELECT l.request_id,l.line_id FROM ritc.request_link l
    JOIN ritc.shop_snapshot s USING(household_id,operation_id,shop_id)
    WHERE l.household_id=$1 AND l.shop_id=$2 AND s.purpose='decision' ORDER BY s.revision`,[f.h,f.shopId])).rows;
  assert.equal(current.lines.length,linked.length+1);
  assert.deepEqual(current.lines.find(l=>l.lineId===f.lineId),f.line);
  const basket=linked.map(l=>{
    const key=lookup.get(l.request_id),row=rows.find(r=>r.requestId===l.request_id);assert(row);
    assert.deepEqual(current.lines.find(x=>x.lineId===l.line_id),decision({op:'apply',owner:key.split('/')[0],id:key.split('/')[1]},row.ownQuantity).line);
    return key;
  });
  const reports=(await admin.query('SELECT actor_id,reported_epoch,reported_revision,state,operation_id FROM ritc.placement_report WHERE household_id=$1 AND shop_id=$2 ORDER BY received_at',[f.h,f.shopId])).rows;
  for(const r of reports)assert([...receipts.values()].some(receipt=>receipt.operationId===r.operation_id && receipt.disposition===(r.state==='applied'?'placed':'pending_reconciliation')));
  assert.equal(reports.filter(r=>r.state==='applied').length,Number(current.phase==='placed'));
  const separate_reports=reports.filter(r=>r.state==='pending_reconciliation').map(r=>[actors.find(a=>f.actors[a].id===r.actor_id),r.reported_epoch,r.reported_revision]);
  assert.deepEqual({results,states,basket,shopper,epoch:shop.authority_epoch,revision:shop.revision,phase:shop.phase==='draft'?'open':shop.phase,separate_reports},expected);
}

export async function grocery30Routing(t,fixture,admin,origin) {
  const {routing}=JSON.parse(await readFile(source,'utf8'));
  assert.equal(routing.length,20);assert.equal(new Set(routing.map(s=>s.label)).size,20);
  for(const scenario of routing)await t.test(scenario.label,async sub=>runVector(sub,scenario,await fixture(),admin,origin));
}
