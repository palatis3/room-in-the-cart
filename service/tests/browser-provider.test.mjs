import test from 'node:test';
import assert from 'node:assert/strict';
import {SupabaseEmailOTPProvider} from '../dist/browser-auth.js';
const config={url:'https://provider.fixture.invalid',publicKey:'sb_publishable_fictional_key_for_tests'};
test('email provider uses fixed documented endpoints and never follows provider redirects',async()=>{
  const calls=[];
  const provider=new SupabaseEmailOTPProvider(config,async(url,options)=>{
    calls.push({url,options});
    return url.includes('/logout')?new Response(null,{status:204}):Response.json(url.endsWith('/otp')?{}:{access_token:'signed.fixture',refresh_token:'fixture-refresh'});
  });
  await provider.start('adult@example.invalid');await provider.verify('adult@example.invalid','123456');await provider.refresh('fixture-refresh');await provider.logout('signed.fixture');
  assert.deepEqual(calls.map(c=>c.url),['/otp','/verify','/token?grant_type=refresh_token','/logout?scope=local'].map(p=>config.url+'/auth/v1'+p));
  for(const call of calls){assert.equal(call.options.redirect,'error');assert.equal(call.options.headers.apikey,config.publicKey);assert.ok(call.options.signal);}
  assert.deepEqual(JSON.parse(calls[0].options.body),{email:'adult@example.invalid',create_user:true});
  assert.deepEqual(JSON.parse(calls[1].options.body),{email:'adult@example.invalid',token:'123456',type:'email'});
  assert.equal(calls[3].options.headers.Authorization,'Bearer signed.fixture');
});
test('email provider rejects secret credentials, arbitrary paths and malformed/oversized upstream responses',async()=>{
  assert.throws(()=>new SupabaseEmailOTPProvider({...config,url:'http://provider.fixture.invalid'}));
  assert.throws(()=>new SupabaseEmailOTPProvider({...config,url:config.url+'/other'}));
  assert.throws(()=>new SupabaseEmailOTPProvider({...config,publicKey:'sb_secret_do_not_use_for_browser_auth'}));
  for(const response of [new Response('<html>bad</html>',{headers:{'Content-Type':'text/html'}}),Response.json({access_token:'x'.repeat(70_000),refresh_token:'r'}),Response.json({access_token:'only-access'})]){
    const provider=new SupabaseEmailOTPProvider(config,async()=>response);
    await assert.rejects(provider.verify('adult@example.invalid','123456'),e=>e.code==='login_unavailable');
  }
});
test('provider errors are fixed public codes and do not expose upstream text or credentials',async()=>{
  for(const [status,code] of [[429,'login_rate_limited'],[422,'code_not_accepted'],[503,'login_unavailable']]){
    const provider=new SupabaseEmailOTPProvider(config,async()=>Response.json({msg:'PRIVATE_PROVIDER_DETAIL'},{status}));
    await assert.rejects(provider.verify('adult@example.invalid','123456'),e=>e.code===code&&!e.message.includes('PRIVATE_PROVIDER_DETAIL'));
  }
});
