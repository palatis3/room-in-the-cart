import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { createHTTPServer } from '../dist/http.js';
import { ReceiptAssistance, receiptAssistanceInput } from '../dist/receipt-assistance.js';

const household = randomUUID();
const budget = {dailyAccountRequests: 2, dailyMicros: 45, maxRequestMicros: 15};
const input = () => ({version:1,requestID:randomUUID(),issuedAt:Date.now(),consent:true,page:2,line:3,text:'AVENA 2 kg'});
const suggested = {page:2,line:3,foodName:'Avena',quantity:'2',unit:'kilogram'};
const completed = value => ({status:'completed',output:[{type:'message',role:'assistant',status:'completed',
  content:[{type:'output_text',text:JSON.stringify(value)}]}]});

test('one consented excerpt produces a strict untooled request and an editable source-bound suggestion', async () => {
  const sent = input();
  assert.equal(ReceiptAssistance.configured({}), undefined);
  assert.equal(ReceiptAssistance.configured({RECEIPT_ASSISTANCE_ENABLED:'true'}), undefined);
  const adapter = new ReceiptAssistance(budget, 'fixture', 'unused', async (url, options) => {
    assert.equal(url, 'https://api.openai.com/v1/responses');
    assert.equal(options.redirect, 'error');
    const body = JSON.parse(options.body);
    assert.deepEqual(JSON.parse(body.input), {page:2,line:3,text:'AVENA 2 kg'});
    assert.equal(body.store, false);
    assert.deepEqual(body.tools, []);
    assert.equal(body.text.format.type,'json_schema');
    assert.equal(body.text.format.strict,true);
    assert.equal(body.text.format.schema.additionalProperties,false);
    return Response.json(completed(suggested));
  });
  assert.deepEqual(await adapter.extract(sent, new AbortController().signal), {version:1, requestID:sent.requestID, ...suggested});
  for (const bad of [{...sent,consent:false},{...sent,text:'x'.repeat(513)},{...sent,photo:'unselected'},{...sent,page:21}])
    assert.equal(receiptAssistanceInput.safeParse(bad).success, false);
});

test('refusal, truncation, unknown or contradictory source data, interruption and oversize preserve manual recovery', async () => {
  const sent = input();
  const refused = completed(suggested);
  refused.output[0].content = [{type:'refusal',refusal:'private-text'}];
  for (const response of [
    Response.json(refused), Response.json({...completed(suggested),status:'incomplete'}),
    Response.json(completed({...suggested,line:4})), Response.json(completed({...suggested,quantity:'20'})),
    Response.json(completed({...suggested,unit:'pound'})), Response.json(completed({...suggested,total:'4.00'})),
    new Response('x'.repeat(24577)), new Response(null,{status:429})
  ]) {
    const adapter = new ReceiptAssistance(budget,'fixture','unused',async () => response);
    await assert.rejects(adapter.extract(sent,new AbortController().signal),e=>e.code==='receipt_assistance_unavailable');
  }
  const offline = new ReceiptAssistance(budget,'fixture','unused',async () => {throw new Error('no connection')});
  await assert.rejects(offline.extract(sent,new AbortController().signal),e=>e.code==='receipt_assistance_unavailable');
  const stopped = AbortSignal.abort();
  const never = new ReceiptAssistance(budget,'fixture','unused',() => assert.fail('cancelled before upload'));
  await assert.rejects(never.extract(sent,stopped),e=>e.code==='receipt_assistance_unavailable');
  const unknown = {page:2,line:3,foodName:null,quantity:null,unit:null};
  const empty = new ReceiptAssistance(budget,'fixture','unused',async () => Response.json(completed(unknown)));
  assert.deepEqual(await empty.extract(sent,new AbortController().signal),{version:1,requestID:sent.requestID,...unknown});
});

test('the HTTP route rejects unauthorized scopes and limits admissions before submitting an excerpt', async t => {
  let calls = 0, persona = 'adult', subject = 'first', revokeBeforeReturn = false;
  let buckets = new Map();
  const repository = {options:{}, async authorized(_id,auth,work) {
    const tentative = new Map(buckets);
    const ctx = { now:new Date(), householdId:household, member:{member_id:'member', kind:persona, organizer:persona==='adult'},
      viewGrantId:auth.viewGrantId, db:{async query(sql,params) {
        if (sql.includes('set_config')) return {rows:[]};
        const [key,,cost,cap] = params;
        const count = (tentative.get(key) ?? 0) + cost;
        if (count > cap) return {rowCount:0};
        tentative.set(key,count); return {rowCount:1};
      }}};
    const result = await work(ctx);
    buckets = tentative; return result;
  }};
  const verifier = {verify:async () => ({issuer:'test',subject,sessionId:'test-session',expiresAt:new Date(Date.now()+60000)})};
  const adapter = new ReceiptAssistance(budget,'fixture','unused',async () => {
    calls++; if (revokeBeforeReturn) persona='child'; return Response.json(completed(suggested));
  });
  const server = createHTTPServer({repository,verifier,receiptAssistance:adapter});
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const endpoint = 'http://127.0.0.1:'+server.address().port+'/v1/households/'+household+'/receipt-assistance';
  const post = (value,headers={})=>fetch(endpoint,{method:'POST',headers:{Authorization:'Bearer fixture','Content-Type':'application/json',...headers},body:JSON.stringify(value)});
  assert.equal((await fetch(endpoint)).status,401);
  assert.deepEqual(await (await fetch(endpoint,{headers:{Authorization:'Bearer fixture'}})).json(),{version:1,available:true,allowsCrop:false});
  assert.equal((await post(input(),{'X-View-Grant-ID':randomUUID()})).status,404);
  persona='child'; assert.equal((await post(input())).status,404);
  persona='contributor'; assert.equal((await post(input())).status,404);
  persona='adult'; assert.equal((await post({...input(),consent:false})).status,422);
  assert.equal(calls,0);
  const selected = input();
  assert.equal((await post(selected)).status,200);
  assert.equal((await post(selected)).status,429);
  assert.equal((await post({...input(),issuedAt:Date.now()-350000})).status,503);
  assert.equal((await post(input())).status,200);
  assert.equal((await post(input())).status,429);
  subject='second'; revokeBeforeReturn=true;
  assert.equal((await post(input())).status,404);
  persona='adult'; revokeBeforeReturn=false;
  assert.equal((await post(input())).status,429);
  assert.equal(calls,3);
});

test('a selected crop contains only the preview pixels and needs its own cost allowance', async () => {
  const {inflateSync} = await import('node:zlib');
  const pixels = Buffer.alloc(16 * 8,65);
  const crop = {width:16,height:8,pixels:pixels.toString('base64')};
  const sample = {...input(),text:'',crop};
  assert.equal(receiptAssistanceInput.safeParse(sample).success,true);
  for (const changed of [{...crop,width:20},{...crop,height:0},{...crop,photo:'EXIF'},{...crop,pixels:'not a photograph'}])
    assert.equal(receiptAssistanceInput.safeParse({...sample,crop:changed}).success,false);
  let calls = 0;
  const mock = async (_url, options) => {
    calls++;
    const body = JSON.parse(options.body);
    const [text,picture] = body.input[0].content;
    assert.deepEqual(JSON.parse(text.text),{page:2,line:3,text:''});
    assert.equal(picture.type,'input_image');
    assert.equal(picture.detail,'high');
    const png = Buffer.from(picture.image_url.split(',')[1],'base64');
    assert.deepEqual([...png.subarray(0,8)],[137,80,78,71,13,10,26,10]);
    let offset=8; const types=[];
    while (offset<png.length) {
      const length=png.readUInt32BE(offset);
      const type=png.toString('ascii',offset+4,offset+8); types.push(type);
      if(type==='IHDR') { assert.equal(png.readUInt32BE(offset+8),16); assert.equal(png.readUInt32BE(offset+12),8); }
      if(type==='IDAT') {
        const rows=inflateSync(png.subarray(offset+8,offset+8+length));
        const expected=Buffer.alloc(17*8,65);
        for(let row=0;row<8;row++) expected[row*17]=0;
        assert.deepEqual(rows,expected);
      }
      offset+=12+length;
    }
    assert.deepEqual(types,['IHDR','IDAT','IEND']);
    return Response.json(completed(suggested));
  };
  const off=new ReceiptAssistance(budget,'fixture','unused',mock);
  await assert.rejects(off.extract(sample,new AbortController().signal));
  assert.equal(calls,0);
  const enabled=new ReceiptAssistance({...budget,maxCropMicros:30},'fixture','unused',mock);
  const value=await enabled.extract(sample,new AbortController().signal);
  assert.equal(value.foodName,'Avena');
  assert.equal(calls,1);
});
