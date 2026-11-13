import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {randomBytes,randomUUID,createHash} from 'node:crypto';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {BrowserAuthService,SupabaseEmailOTPProvider} from '../dist/browser-auth.js';
import {createHTTPServer} from '../dist/http.js';
const admin=new pg.Pool({connectionString:process.env.TEST_ADMIN_DATABASE_URL}),runtime=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL,max:12});
const issuer='https://email-identity.fixture.invalid',audience='authenticated',webOrigin='https://web.fixture.invalid';
const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='bff-fixture';
const verifier=new JWTIdentityVerifier({issuer,audience,jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
const repo=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(issuer)});
const encryptionKey=randomBytes(32).toString('base64'),accounts=new Map(),refreshes=new Map();
const calls={otp:0,verify:0,refresh:0,logout:0};let providerOrigin;let refreshWrongSubject=false,logoutFailure=false,verifyMissingSession=false;
async function issue(account){
  const access_token=await new SignJWT({session_id:account.sessionId}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(issuer).setAudience(audience).setSubject(account.subject).setIssuedAt().setExpirationTime('1h').sign(privateKey);
  const refresh_token=randomBytes(32).toString('base64url');refreshes.set(refresh_token,account);
  return{access_token,refresh_token,token_type:'bearer',expires_in:3600};
}
const providerServer=createServer(async(req,res)=>{
  const data=[];for await(const part of req)data.push(part);const input=data.length?JSON.parse(Buffer.concat(data).toString('utf8')):{};
  const send=(status,value)=>{res.statusCode=status;res.setHeader('Content-Type','application/json');res.end(value===undefined?undefined:JSON.stringify(value));};
  if(req.headers.apikey!=='sb_publishable_fictional_bff_integration'){send(401,{});return;}
  if(req.url==='/auth/v1/otp'){
    calls.otp++;if(!accounts.has(input.email))accounts.set(input.email,{subject:randomUUID(),sessionId:randomUUID()});send(200,{});return;
  }
  if(req.url==='/auth/v1/verify'){
    calls.verify++;const account=accounts.get(input.email);if(input.token!=='123456'||!account){send(422,{msg:'PRIVATE wrong code'});return;}
    if(!verifyMissingSession)await admin.query('INSERT INTO auth.sessions(id,user_id) VALUES($1,$2) ON CONFLICT(id) DO NOTHING',[account.sessionId,account.subject]);
    send(200,await issue(account));return;
  }
  if(req.url==='/auth/v1/token?grant_type=refresh_token'){
    calls.refresh++;let account=refreshes.get(input.refresh_token);if(!account){send(422,{});return;}
    refreshes.delete(input.refresh_token);
    if(refreshWrongSubject){account={subject:randomUUID(),sessionId:account.sessionId};await admin.query('UPDATE auth.sessions SET user_id=$2 WHERE id=$1',[account.sessionId,account.subject]);}
    send(200,await issue(account));return;
  }
  if(req.url==='/auth/v1/logout?scope=local'){
    calls.logout++;if(logoutFailure){send(503,{});return;}
    try{const identity=await verifier.verify(req.headers.authorization?.slice(7)??'');await admin.query('DELETE FROM auth.sessions WHERE id=$1',[identity.sessionId]);}catch{}
    send(204);return;
  }
  send(404,{});
});
function provider(){return new SupabaseEmailOTPProvider({url:'https://email-provider.fixture.invalid',publicKey:'sb_publishable_fictional_bff_integration'},(url,options)=>fetch(String(url).replace('https://email-provider.fixture.invalid',providerOrigin),options));}
let application,origin,bff;
async function listen(server){await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));return'http://127.0.0.1:'+server.address().port;}
before(async()=>{providerOrigin=await listen(providerServer);bff=new BrowserAuthService(repo,verifier,provider(),{encryptionKey});application=createHTTPServer({repository:repo,verifier,webOrigin,browserAuth:bff,maxRequestsPerMinute:10000});origin=await listen(application);});
after(async()=>{await Promise.all([new Promise(resolve=>application.close(resolve)),new Promise(resolve=>providerServer.close(resolve))]);await Promise.all([admin.end(),runtime.end()]);});
function browser(base=()=>origin){
  const jar=new Map();
  async function call(path,method='GET',body,csrf,extra={}){
    const response=await fetch(base()+path,{method,headers:{...(jar.size?{Cookie:[...jar].map(([k,v])=>k+'='+v).join('; ')}:{}),...(body===undefined?{}:{'Content-Type':'application/json'}),...(method==='GET'?{}:{Origin:webOrigin}),...(csrf?{'X-CSRF-Token':csrf}:{}),...extra},...(body===undefined?{}:{body:JSON.stringify(body)})});
    for(const value of response.headers.getSetCookie()){const[name,...rest]=value.split(';')[0].split('=');if(value.includes('Max-Age=0'))jar.delete(name);else jar.set(name,rest.join('='));}
    return{status:response.status,data:await response.json(),headers:response.headers};
  }
  return{jar,call};
}
async function signIn(client=browser(),email=randomUUID()+'@example.invalid'){
  const challenge=await client.call('/v1/auth/session');assert.equal(challenge.status,200);assert.equal(challenge.data.authenticated,false);
  assert.equal((await client.call('/v1/auth/email/start','POST',{email},challenge.data.csrf)).status,200);
  const verified=await client.call('/v1/auth/email/verify','POST',{code:'123456'},challenge.data.csrf);assert.equal(verified.status,200,JSON.stringify(verified.data));
  return{client,email,csrf:verified.data.csrf,challenge};
}
async function createScope(logged,label='Fictional OTP household'){
  const created=await logged.client.call('/v1/households','POST',{clientKey:randomUUID(),label,alias:'Adult',adultAttestation:true},logged.csrf);assert.equal(created.status,201,JSON.stringify(created.data));
  const activated=await logged.client.call('/v1/session','POST',{householdId:created.data.householdId},logged.csrf);assert.equal(activated.status,200,JSON.stringify(activated.data));
  return{householdId:created.data.householdId,session:activated.data};
}
function cookieHash(client){return createHash('sha256').update(client.jar.get('__Host-ritc_auth')).digest('hex');}

test('email code login stores encrypted provider state and grants no household authority',async()=>{
  const logged=await signIn();const state=await logged.client.call('/v1/auth/session');assert.deepEqual(Object.keys(state.data).sort(),['available','authenticated','csrf'].sort());assert.equal(state.data.authenticated,true);
  assert.deepEqual((await logged.client.call('/v1/me/workspaces')).data,{workspaces:[]});
  assert.equal((await logged.client.call('/v1/households/'+randomUUID()+'/devices','POST',{},logged.csrf)).status,404);
  const row=(await admin.query('SELECT * FROM ritc.browser_auth WHERE token_hash=$1',[cookieHash(logged.client)])).rows[0];
  assert.ok(row.secret_cipher.startsWith('v1.'));assert.equal(row.secret_cipher.includes('access_token'),false);assert.equal(row.email_cipher,null);
  assert.equal(JSON.stringify(state.data).includes('refresh'),false);assert.equal(JSON.stringify(state.data).includes(logged.email),false);
  assert.match(logged.challenge.headers.get('set-cookie'),/^__Host-ritc_auth=/);
  assert.match(logged.challenge.headers.get('set-cookie'),/HttpOnly; Secure; SameSite=Strict/);
  assert.equal(logged.challenge.headers.get('set-cookie').includes('Domain='),false);
  const scoped=await createScope(logged);assert.equal((await logged.client.call('/v1/session')).data.household.id,scoped.householdId);
  const onlyScope=browser();onlyScope.jar.set('ritc_session',logged.client.jar.get('ritc_session'));assert.equal((await onlyScope.call('/v1/session')).status,401);
});

test('pre-auth CSRF, exact origin, strict bodies and persistent attempt bounds guard email verification',async()=>{
  const client=browser(),challenge=await client.call('/v1/auth/session'),email=randomUUID()+'@example.invalid';
  assert.equal((await client.call('/v1/auth/email/start','POST',{email})).status,403);
  assert.equal((await client.call('/v1/auth/email/start','POST',{email},challenge.data.csrf,{Origin:'https://evil.fixture.invalid'})).status,403);
  assert.equal((await client.call('/v1/auth/email/start','POST',{email,redirectTo:'https://evil.fixture.invalid'},challenge.data.csrf)).status,422);
  assert.equal((await client.call('/v1/auth/email/start','POST',{email},challenge.data.csrf)).status,200);
  const before=calls.verify;
  for(let i=0;i<5;i++)assert.equal((await client.call('/v1/auth/email/verify','POST',{code:'000000'},challenge.data.csrf)).status,422);
  assert.equal((await client.call('/v1/auth/email/verify','POST',{code:'123456'},challenge.data.csrf)).status,429);
  assert.equal(calls.verify-before,5);
  assert.equal((await client.call('/v1/auth/email/start','POST',{email},challenge.data.csrf)).status,429);
});

test('an in-flight email delivery releases the challenge lock and cannot reopen a signed-out challenge',async()=>{
  const upstream=provider();
  const started=Promise.withResolvers(),delivery=Promise.withResolvers();
  upstream.start=async()=>{started.resolve();await delivery.promise;};
  const auth=new BrowserAuthService(repo,verifier,upstream,{encryptionKey});
  const {cookie,csrf}=await auth.challenge('slow-mail-test');
  const sending=auth.start(cookie,csrf,{email:randomUUID()+'@example.invalid'},'slow-mail-test');
  const rejected=assert.rejects(sending,error=>error.code==='session_needed');
  try{
    await started.promise;
    assert.equal((await auth.state(cookie)).authenticated,false);
    await assert.rejects(auth.verify(cookie,csrf,{code:'123456'}),error=>error.code==='code_not_accepted');
    await assert.rejects(auth.start(cookie,csrf,{email:randomUUID()+'@example.invalid'},'slow-mail-test'),error=>error.code==='login_rate_limited');
    assert.equal((await auth.logout(cookie,csrf)).signedOut,true);
  }finally{
    delivery.resolve();
    await rejected;
  }
});

test('two service instances enforce the same durable account-scoped OTP request limit',async()=>{
  const secondBff=new BrowserAuthService(repo,verifier,provider(),{encryptionKey});
  const second=createHTTPServer({repository:repo,verifier,webOrigin,browserAuth:secondBff,maxRequestsPerMinute:10000});const secondOrigin=await listen(second);
  try{
    const email=randomUUID()+'@example.invalid';const before=calls.otp;
    const clients=await Promise.all(Array.from({length:6},async(_,index)=>{const client=browser(()=>index%2?secondOrigin:origin),challenge=await client.call('/v1/auth/session');return{client,csrf:challenge.data.csrf};}));
    const results=await Promise.all(clients.map(c=>c.client.call('/v1/auth/email/start','POST',{email},c.csrf)));
    assert.deepEqual(results.map(r=>r.status).sort(),[200,200,200,200,200,429]);assert.equal(calls.otp-before,5);
  }finally{await new Promise(resolve=>second.close(resolve));}
});

test('concurrent BFF requests refresh once and preserve household context without exposing tokens',async()=>{
  const logged=await signIn(),scoped=await createScope(logged);const before=calls.refresh;
  await admin.query("UPDATE ritc.browser_auth SET access_expires_at=now()+interval '20 seconds' WHERE token_hash=$1",[cookieHash(logged.client)]);
  await admin.query("UPDATE ritc.web_session SET expires_at=now()-interval '1 minute' WHERE household_id=$1",[scoped.householdId]);
  const responses=await Promise.all([logged.client.call('/v1/session'),logged.client.call('/v1/session')]);
  for(const response of responses){assert.equal(response.status,200,JSON.stringify(response.data));assert.equal(response.data.household.id,scoped.householdId);}
  assert.equal(calls.refresh-before,1);
  assert.equal((await logged.client.call('/v1/auth/refresh','POST',{},logged.csrf)).status,200);
});

test('live session deletion and a refreshed subject mismatch both fail closed',async()=>{
  const first=await signIn();await admin.query('DELETE FROM auth.sessions WHERE id=$1',[accounts.get(first.email).sessionId]);
  assert.equal((await first.client.call('/v1/me/workspaces')).status,401);
  const second=await signIn();refreshWrongSubject=true;
  try{assert.equal((await second.client.call('/v1/auth/refresh','POST',{},second.csrf)).status,401);}finally{refreshWrongSubject=false;}
  assert.equal((await second.client.call('/v1/me/workspaces')).status,401);
  verifyMissingSession=true;
  try{
    const client=browser(),challenge=await client.call('/v1/auth/session');await client.call('/v1/auth/email/start','POST',{email:randomUUID()+'@example.invalid'},challenge.data.csrf);
    assert.equal((await client.call('/v1/auth/email/verify','POST',{code:'123456'},challenge.data.csrf)).status,401);
  }finally{verifyMissingSession=false;}
});

test('logout revokes local authentication and scoped device even when provider logout fails',async()=>{
  const logged=await signIn();await createScope(logged);const retained=browser();for(const pair of logged.client.jar)retained.jar.set(...pair);
  logoutFailure=true;let result;
  try{result=await logged.client.call('/v1/auth/session','DELETE',undefined,logged.csrf);}finally{logoutFailure=false;}
  assert.equal(result.status,200);assert.deepEqual(result.data,{signedOut:true,providerRevoked:false});assert.equal(logged.client.jar.size,0);
  assert.equal((await retained.call('/v1/me/workspaces')).status,401);
  const scopeOnly=browser();scopeOnly.jar.set('ritc_session',retained.jar.get('ritc_session'));assert.ok([401,403].includes((await scopeOnly.call('/v1/session')).status));
  const retry=await retained.call('/v1/auth/session','DELETE',undefined,logged.csrf);assert.equal(retry.data.providerRevoked,true);
  assert.equal((await admin.query('SELECT 1 FROM auth.sessions WHERE id=$1',[accounts.get(logged.email).sessionId])).rowCount,0);
});

test('context switch requires actual membership and a fresh login clears the previous scoped cookie',async()=>{
  const logged=await signIn(),a=await createScope(logged);
  const created=await logged.client.call('/v1/households','POST',{clientKey:randomUUID(),label:'Second home',alias:'Adult',adultAttestation:true},a.session.csrf);assert.equal(created.status,201);
  const b=await logged.client.call('/v1/session','POST',{householdId:created.data.householdId},a.session.csrf);assert.equal(b.status,200);
  assert.equal((await logged.client.call('/v1/session','POST',{householdId:randomUUID()},b.data.csrf)).status,404);
  const current=await logged.client.call('/v1/session');assert.equal(current.data.household.id,created.data.householdId);
  await logged.client.call('/v1/auth/session','DELETE',undefined,logged.csrf);
  const again=await signIn(logged.client);assert.equal(again.client.jar.has('ritc_session'),false);assert.deepEqual((await again.client.call('/v1/me/workspaces')).data.workspaces,[]);
});

test('trusted client-address port separates proxy clients and forwarded-header spoofing cannot evade the socket limit',async()=>{
  const direct=createHTTPServer({repository:repo,maxRequestsPerMinute:1});const directOrigin=await listen(direct);
  const proxied=createHTTPServer({repository:repo,maxRequestsPerMinute:1,clientAddress:req=>req.headers['x-fixture-verified-client']});const proxiedOrigin=await listen(proxied);
  try{
    const client=browser(()=>directOrigin);
    assert.equal((await client.call('/v1/session','GET',undefined,undefined,{'X-Forwarded-For':'192.0.2.1'})).status,200);
    assert.equal((await client.call('/v1/session','GET',undefined,undefined,{'X-Forwarded-For':'192.0.2.2'})).status,429);
    for(const ip of ['192.0.2.1','192.0.2.2'])assert.equal((await browser(()=>proxiedOrigin).call('/v1/session','GET',undefined,undefined,{'X-Fixture-Verified-Client':ip,'X-Forwarded-For':'attacker-controlled'})).status,200);
    assert.equal((await browser(()=>proxiedOrigin).call('/v1/session')).status,503);
  }finally{await Promise.all([new Promise(resolve=>direct.close(resolve)),new Promise(resolve=>proxied.close(resolve))]);}
});

test('unconfigured email auth is explicitly unavailable and never reports a sent code',async()=>{
  const disabled=createHTTPServer({repository:repo,webOrigin});const disabledOrigin=await listen(disabled);
  try{const client=browser(()=>disabledOrigin);assert.deepEqual((await client.call('/v1/auth/session')).data,{available:false,authenticated:false,csrf:null});assert.equal((await client.call('/v1/auth/email/start','POST',{email:'fixture@example.invalid'})).status,503);}finally{await new Promise(resolve=>disabled.close(resolve));}
});

test('trusted IP OTP limits persist across service instances and distinct email addresses',async()=>{
  const key=randomBytes(32).toString('base64');
  const servers=[0,1].map(()=>createHTTPServer({repository:repo,verifier,webOrigin,browserAuth:new BrowserAuthService(repo,verifier,provider(),{encryptionKey:key}),maxRequestsPerMinute:10000,clientAddress:()=> '192.0.2.42'}));
  const origins=await Promise.all(servers.map(listen));
  try{
    const before=calls.otp;
    for(let index=0;index<21;index++){
      const client=browser(()=>origins[index%2]),challenge=await client.call('/v1/auth/session');assert.equal(challenge.status,200);
      const response=await client.call('/v1/auth/email/start','POST',{email:randomUUID()+'@example.invalid'},challenge.data.csrf,{'X-Forwarded-For':'198.51.100.'+index});
      assert.equal(response.status,index<20?200:429);
    }
    assert.equal(calls.otp-before,20);
  }finally{await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));}
});
test('encrypted browser credentials are bound to their own cookie and private tables remain RLS-isolated',async()=>{
  const first=await signIn(),second=await signIn();
  const ciphertext=(await admin.query('SELECT secret_cipher FROM ritc.browser_auth WHERE token_hash=$1',[cookieHash(second.client)])).rows[0].secret_cipher;
  await admin.query('UPDATE ritc.browser_auth SET secret_cipher=$2 WHERE token_hash=$1',[cookieHash(first.client),ciphertext]);
  assert.equal((await first.client.call('/v1/me/workspaces')).status,401);
  assert.equal((await second.client.call('/v1/auth/session')).data.authenticated,true);
  assert.equal((await runtime.query('SELECT * FROM ritc.browser_auth')).rowCount,0);
  assert.equal((await runtime.query('SELECT * FROM ritc.auth_rate_bucket')).rowCount,0);
});

 test('explicit refresh never contacts the provider after its exact session is revoked',async()=>{
 const logged=await signIn(),record=(await admin.query('SELECT session_id FROM ritc.browser_auth WHERE token_hash=$1',[cookieHash(logged.client)])).rows[0];
 await admin.query('DELETE FROM auth.sessions WHERE id=$1',[record.session_id]);const before=calls.refresh;
 const result=await logged.client.call('/v1/auth/refresh','POST',{},logged.csrf);assert.equal(result.status,401);assert.equal(calls.refresh,before);
 });
