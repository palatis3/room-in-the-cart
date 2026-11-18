import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import pg from 'pg';
import {createLocalJWKSet,exportJWK,generateKeyPair,SignJWT} from 'jose';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {HouseholdRepository} from '../dist/repository.js';
import {createHTTPServer} from '../dist/http.js';
import {VoiceAssistance} from '../dist/voice-assistance.js';
import {ReceiptAssistance} from '../dist/receipt-assistance.js';
import {languagePurposes} from '../dist/language-purposes.js';

test('all language purposes honor enrolled adult scope and share once-only admission across text, crop and voice',async t=>{
  const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL});
  const runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
  t.after(async()=>{await Promise.all([admin.end(),runtime.end()]);});
  const issuer='https://language-contract.fixture.invalid',audience='authenticated';
  const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);
  jwk.kid='test';const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
  const repository=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
  let calls=0,revokeSession;
  const receiptAssistance=new ReceiptAssistance({dailyAccountRequests:2,dailyMicros:2_000_000_000,maxRequestMicros:5,maxCropMicros:10,maxLanguageMicros:20},
    'fixture','fixture-only',async(_url,options)=>{
      calls++;
      const payload=JSON.parse(options.body);
      assert.equal(payload.store,false);assert.deepEqual(payload.tools,[]);
      if(revokeSession) await admin.query('DELETE FROM auth.sessions WHERE id=$1',[revokeSession]);
      const fields=payload.text.format.name==='receipt_line_v1'?{page:1,line:1,foodName:'Rice',quantity:null,unit:null}:{suggestions:[]};
      return Response.json({status:'completed',output:[{type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:JSON.stringify(fields)}]}]});
    });
  const voiceAssistance=new VoiceAssistance(10,'fixture','fixture-only',async()=>{throw new Error('Duplicate voice admission reached the provider');});
  const server=createHTTPServer({repository,verifier,receiptAssistance,voiceAssistance,maxRequestsPerMinute:2000});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  async function actor() {
    const subject=randomUUID(),session=randomUUID();
    await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2)',[session,subject]);
    const token=await new SignJWT({session_id:session}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer)
      .setAudience(audience).setSubject(subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);
    return {session,token,device:null};
  }
  async function call(actor,path,body) {
    const r=await fetch('http://127.0.0.1:'+server.address().port+path,{method:body===undefined?'GET':'POST',
      headers:{Authorization:'Bearer '+actor.token,...actor.device?{'X-Device-Token':actor.device}:{},...body?{'Content-Type':'application/json'}:{}},
      ...body?{body:JSON.stringify(body)}:{}});
    return {status:r.status,data:await r.json()};
  }
  async function household(owner) {
    const created=await call(owner,'/v1/households',{clientKey:randomUUID(),label:'Synthetic language fixture',alias:'Adult',adultAttestation:true});
    assert.equal(created.status,201);const base='/v1/households/'+created.data.householdId;
    const enrolled=await call(owner,base+'/devices',{});assert.equal(enrolled.status,201);owner.device=enrolled.data.deviceToken;
    return base;
  }
  const owner=await actor(),base=await household(owner),guest=await actor();
  const invite=await call(owner,base+'/invites',{kind:'adult_contributor'});assert.equal(invite.status,200);
  assert.equal((await call(guest,'/v1/invites/redeem',{token:invite.data.token,intent:'join',adultAttestation:true,alias:'Contributor'})).status,200);
  const enrolled=await call(guest,base+'/devices',{});assert.equal(enrolled.status,201);guest.device=enrolled.data.deviceToken;
  const kinds = languagePurposes.map(route => route.kind).sort();
  assert.deepEqual(kinds, ['foodkeeper-match', 'meal-explanations', 'meal-feedback', 'meal-preference',
    'natural-list', 'receipt-alias', 'request-duplicate']);
  const paths = kinds.map(kind => '/language-assistance/' + kind);
  for(const path of paths) {
    assert.deepEqual(await call(owner,base+path),{status:200,data:{version:1,available:true}});
    assert.equal((await call(guest,base+path)).status,404);
  }
  const common=()=>({version:1,requestID:randomUUID(),issuedAt:Date.now(),consent:true});
  const list={...common(),locale:'es',sourceLines:[{id:randomUUID(),text:'arroz sin sal'}]};
  const natural='/language-assistance/natural-list';
  assert.equal((await call(guest,base+natural,list)).status,404);assert.equal(calls,0);
  assert.equal((await call(owner,base+natural,list)).status,200);
  const receipt={...common(),page:1,line:1,text:'Rice'};
  assert.equal((await call(owner,base+'/receipt-assistance',{...receipt,requestID:list.requestID})).status,429);
  const crop={...receipt,requestID:list.requestID,crop:{width:8,height:8,pixels:Buffer.alloc(64,128).toString('base64')}};
  assert.equal((await call(owner,base+'/capture-assistance/shelf-line',crop)).status,429);
  const voice={...common(),requestID:list.requestID,samples:1600,pcm:Buffer.alloc(3200).toString('base64'),language:'es'};
  assert.equal((await call(owner,base+'/capture-assistance/transcription',voice)).status,429);
  assert.equal((await call(owner,base+'/receipt-assistance',receipt)).status,200);
  assert.equal((await call(owner,base+natural,{...list,requestID:randomUUID()})).status,429);assert.equal(calls,2);
  const next=await actor(),separate=await household(next);
  revokeSession=next.session;
  const cancelled=await call(next,separate+natural,{...list,requestID:randomUUID()});
  assert.equal(cancelled.status,401);assert.equal(cancelled.data.error.code,'session_needed');assert.equal(calls,3);
});
