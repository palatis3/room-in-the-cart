import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {ReceiptAssistance} from '../dist/receipt-assistance.js';
import {naturalListRoute} from '../dist/language-assistance.js';
import {createHTTPServer} from '../dist/http.js';

const budget={dailyAccountRequests:2,dailyMicros:40,maxRequestMicros:5,maxLanguageMicros:20};
const input=(text,locale='en')=>({version:1,requestID:randomUUID(),issuedAt:Date.now(),consent:true,locale,sourceLines:[{id:randomUUID(),text}]});
const providerReply=suggestions=>Response.json({status:'completed',output:[{type:'message',role:'assistant',status:'completed',
  content:[{type:'output_text',text:JSON.stringify({suggestions})}]}]});
const adapter=respond=>new ReceiptAssistance(budget,'synthetic','fixture-only',respond);
const suggest=(request,transport,signal=new AbortController().signal)=>naturalListRoute.parse(request).run(transport,signal);

for(const [locale,text,name,purpose,exclusion] of [
  ['en','Please grab rolled oats for breakfast without almonds','rolled oats','breakfast','without almonds'],
  ['es','Trae avena integral para mañana sin almendras','avena integral','mañana','sin almendras']
]) test('selected '+locale+' wording is grounded in its source and carries no account or unrelated text',async()=>{
  const request=input(text,locale),result={sourceLineID:request.sourceLines[0].id,itemName:name,purpose,exclusion};
  const transport=adapter(async(_url,options)=>{
    const body=JSON.parse(options.body);
    assert.deepEqual(JSON.parse(body.input),{locale,sourceLines:request.sourceLines});
    assert.equal(body.store,false);assert.deepEqual(body.tools,[]);assert.equal(body.text.format.strict,true);
    assert.equal(body.max_output_tokens,1536);
    return providerReply([result]);
  });
  assert.deepEqual(await suggest(request,transport),{version:1,requestID:request.requestID,suggestions:[result]});
});
test('invalid consent, unbounded messages and ungrounded or duplicate drafts fail closed',async()=>{
  const request=input('bread without nuts');
  for(const fields of [{consent:false},{locale:'fr'},{sourceLines:[]},{sourceLines:Array(9).fill(request.sourceLines[0])},
      {sourceLines:[request.sourceLines[0],request.sourceLines[0]]},{sourceLines:[{id:randomUUID(),text:'x'.repeat(513)}]},{privateShopId:randomUUID()}])
    assert.throws(()=>naturalListRoute.parse({...request,...fields}));
  const row={sourceLineID:request.sourceLines[0].id,itemName:'bread',purpose:null,exclusion:'without nuts'};
  for(const rows of [[{...row,sourceLineID:randomUUID()}],[{...row,itemName:'bananas'}],[{...row,exclusion:'all dairy'}],
      [{...row,price:5}],[row,row],[{...row,sourceLineID:null}],[{...row,itemName:null}]])
    await assert.rejects(suggest(request,adapter(async()=>providerReply(rows))));
  assert.deepEqual((await suggest(request,adapter(async()=>providerReply([])))).suggestions,[]);
});
test('cancelled and unavailable language interpretation leave deterministic capture available',async()=>{
  const request=input('pan sin nueces','es'),abort=new AbortController();abort.abort();
  let calls=0;
  await assert.rejects(suggest(request,adapter(async()=>{calls++;return providerReply([]);}),abort.signal));
  const disabled=new ReceiptAssistance({...budget,maxLanguageMicros:undefined},'synthetic','unused',async()=>{calls++;return providerReply([]);});
  await assert.rejects(suggest(request,disabled));assert.equal(calls,0);
  await assert.rejects(suggest(request,adapter(async()=>Response.json({status:'incomplete',output:[]}))));
});
test('HTTP checks current adult authority before and after requests and charges the common account and operator quotas',async t=>{
  const id=randomUUID(),headers={Authorization:'Bearer fixture','Content-Type':'application/json'};
  let calls=0,persona='adult',subject='one',limited=false,revoke=false,buckets=new Map();
  const repository={options:{},async authorized(_id,auth,work) {
    const next=new Map(buckets);
    const result=await work({now:new Date(),householdId:id,member:{member_id:'member',kind:persona,organizer:persona==='adult'},
      ownRequestsOnly:limited,viewGrantId:auth.viewGrantId,db:{async query(sql,params) {
        if(sql.includes('set_config')) return {rows:[]};
        const [key,,cost,cap]=params,total=(next.get(key)??0)+cost;
        if(total>cap)return {rowCount:0};
        next.set(key,total);return {rowCount:1};
      }}});
    buckets=next;return result;
  }};
  const verifier={verify:async()=>({issuer:'fixture',subject,sessionId:'fixture',expiresAt:new Date(Date.now()+60_000)})};
  const server=createHTTPServer({repository,verifier,receiptAssistance:adapter(async()=>{
    calls++;if(revoke)persona='child';return providerReply([]);
  })});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  const url='http://127.0.0.1:'+server.address().port+'/v1/households/'+id+'/language-assistance/natural-list';
  const post=(body,extra={})=>fetch(url,{method:'POST',headers:{...headers,...extra},body:JSON.stringify(body)});
  assert.equal((await fetch(url)).status,401);
  assert.deepEqual(await (await fetch(url,{headers})).json(),{version:1,available:true});
  const request=input('oats');
  assert.equal((await post({...request,consent:false})).status,422);
  persona='child';assert.equal((await post(request)).status,404);
  persona='adult';limited=true;assert.equal((await post(request)).status,404);limited=false;
  assert.equal((await post(request,{'X-View-Grant-ID':randomUUID()})).status,404);assert.equal(calls,0);
  assert.equal((await post(request)).status,200);assert.equal((await post(request)).status,429);
  revoke=true;assert.equal((await post(input('leche','es'))).status,404);
  revoke=false;persona='adult';subject='two';
  assert.equal((await post(input('bread'))).status,429);assert.equal(calls,2);
});
