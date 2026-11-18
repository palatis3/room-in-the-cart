import test from 'node:test';
import assert from 'node:assert/strict';
import {mealExplanationsRoute,mealExplanationRequest} from '../dist/meal-explanations.js';
const id='10000000-0000-4000-8000-000000000001';
const other='20000000-0000-4000-8000-000000000002';
function input(locale='en') {return {version:1,requestID:other,issuedAt:1800000000000,consent:true,locale,
  sourceLines:[{id,text:locale==='es'?'Tacos de frijoles':'Bean tacos'}],candidates:[{id,allowedReasons:['pantry_match','needs_more_food']}]};}
async function run(reply,request=input()) {return mealExplanationsRoute.parse(request).run({structuredText:async()=>reply},new AbortController().signal);}
test('English and Spanish selected eligible IDs preserve exact request and controlled reasons',async()=>{
  for(const locale of ['en','es']) {
    const result=await run({suggestions:[{sourceLineID:id,reasons:['needs_more_food','pantry_match']}]},input(locale));
    assert.equal(result.requestID,other); assert.equal(result.suggestions[0].sourceLineID,id);
    assert.equal(JSON.stringify(result).includes('price'),false);
  }
});
test('unknown, repeated and unsupported candidate claims fail closed',async()=>{
  for(const suggestions of [
    [{sourceLineID:other,reasons:['pantry_match']}],
    [{sourceLineID:id,reasons:['ingredients_covered']}],
    [{sourceLineID:id,reasons:['pantry_match'],price:0}],
    [{sourceLineID:id,reasons:['pantry_match'],explanation:'Allergy safe'}],
    [{sourceLineID:id,reasons:['pantry_match','pantry_match']}],
    [{sourceLineID:id,reasons:['pantry_match']},{sourceLineID:id,reasons:['pantry_match']}]
  ]) await assert.rejects(run({suggestions}),e=>e.code==='language_suggestion_unavailable');
  await assert.rejects(run({suggestions:[],extra:'invented'}));
});
test('candidate and shared title sets must match with explicit consent and bounded strict fields',()=>{
  assert.throws(()=>mealExplanationRequest.parse({...input(),consent:false}));
  assert.throws(()=>mealExplanationRequest.parse({...input(),candidates:[{id:other,allowedReasons:['pantry_match']}]}));
  assert.throws(()=>mealExplanationRequest.parse({...input(),stock:100}));
  assert.throws(()=>mealExplanationRequest.parse({...input(),sourceLines:[{id,text:'x'.repeat(513)}]}));
});
test('provider outage propagates without a fabricated fallback proposal',async()=>{
  await assert.rejects(mealExplanationsRoute.parse(input()).run({structuredText:async()=>{throw new Error('offline');}},new AbortController().signal),/offline/);
});

test('actual HTTP meal route excludes helpers and children and rechecks adult access after provider',async t=>{
  const {randomUUID}=await import('node:crypto');
  const {createHTTPServer}=await import('../dist/http.js');
  const {ReceiptAssistance}=await import('../dist/receipt-assistance.js');
  let persona='adult',calls=0,revoke=false;
  const household=randomUUID();
  const repository={options:{},async authorized(_id,auth,work){return work({now:new Date(),householdId:household,
    member:{member_id:'member',kind:persona,organizer:persona==='adult'},viewGrantId:auth.viewGrantId,
    db:{async query(){return {rows:[],rowCount:1};}}});}};
  const verifier={verify:async()=>({issuer:'test',subject:'adult',sessionId:'test',expiresAt:new Date(Date.now()+60000)})};
  const adapter=new ReceiptAssistance({dailyAccountRequests:8,dailyMicros:100,maxRequestMicros:10,maxLanguageMicros:10},'fixture','unused',async(_url,options)=>{
    calls++; const body=JSON.parse(options.body);
    assert.deepEqual(body.tools,[]); assert.equal(body.store,false);
    assert.deepEqual(Object.keys(JSON.parse(body.input)).sort(),['candidates','locale','sourceLines']);
    if(revoke) persona='child';
    return Response.json({status:'completed',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify({suggestions:[{sourceLineID:id,reasons:['pantry_match']}]})}]}]});
  });
  const server=createHTTPServer({repository,verifier,receiptAssistance:adapter});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  const endpoint=`http://127.0.0.1:${server.address().port}/v1/households/${household}/language-assistance/meal-explanations`;
  const post=(headers={})=>fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer fixture','Content-Type':'application/json',...headers},
    body:JSON.stringify({...input(),issuedAt:Date.now(),requestID:randomUUID()})});
  assert.equal((await fetch(endpoint)).status,401);
  assert.equal((await post({'X-View-Grant-ID':randomUUID()})).status,404);
  for(const denied of ['child','contributor']) {persona=denied;assert.equal((await post()).status,404);}
  assert.equal(calls,0); persona='adult';
  assert.equal((await post()).status,200);
  revoke=true; assert.equal((await post()).status,404);
  assert.equal(calls,2);
});
