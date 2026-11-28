import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac,randomBytes,randomUUID} from 'node:crypto';
import {day,mexicoRenewal,nextNotice} from '../../../dist/billing/renewal-facts.js';
import {checkSenderSession} from '../../../dist/billing/renewal-sender-health.js';
import {recordRenewalDelivery,webhookKey} from '../../../dist/billing/renewal-webhook.js';
import {renewalConfig,ResendRenewalProvider} from '../../../dist/billing/renewal-provider.js';

const now=Date.UTC(2027,2,10,15),product='annual',due=now+7*day;
const transaction={environment:'Production',storefront:'MEX',productId:product};
const renewal={environment:'Production',productId:product,autoRenewProductId:product,autoRenewStatus:1,
  currency:'MXN',renewalDate:due,signedDate:now,renewalPrice:193400};
test('future price comes from independently verified MXN renewal facts',()=>{
  assert.deepEqual(mexicoRenewal(transaction,renewal,product),{currency:'MXN',date:due,signedAt:now,amountMilli:193400});
  for(const changed of [{storefront:'USA'},{environment:'Sandbox'},{revocationDate:now},{isUpgraded:true},{productId:'other'}])
    assert.equal(mexicoRenewal({...transaction,...changed},renewal,product),null);
  for(const changed of [{currency:'USD'},{renewalPrice:undefined},{renewalPrice:0},{renewalPrice:1234},{autoRenewStatus:0},
    {priceIncreaseStatus:0},{environment:'Sandbox'},{autoRenewProductId:'other'},{renewalDate:undefined},{isInBillingRetryPeriod:true}])
    assert.equal(mexicoRenewal(transaction,{...renewal,...changed},product),null);
});
test('daily seven-day window, corrections, stale facts and conservative cutoff use instants across time zones',()=>{
  const state={environment:'Production',mxAnnual:true,status:'active',expiresAt:due,noticeFacts:mexicoRenewal(transaction,renewal,product)};
  const prior={date:due,amountMilli:193400,purpose:'reminder',sentAt:now};
  assert.equal(nextNotice(state,now),'reminder');
  assert.equal(nextNotice(state,now-1),'early');
  assert.equal(nextNotice({...state,noticeFacts:{...state.noticeFacts,signedAt:now+2*day}},now),'not_ready');
  assert.equal(nextNotice({...state,noticeFacts:{...state.noticeFacts,signedAt:now-180*day}},now),'reminder');
  for(const zone of ['America/Tijuana','America/Ciudad_Juarez','America/Cancun','America/Mexico_City']){
    const localDate=ms=>Date.parse(new Intl.DateTimeFormat('en-CA',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit'}).format(ms)+'T00:00:00Z');
    assert.ok((localDate(due)-localDate(now+day))/day>=5);
  }
  assert.equal(nextNotice({...state,noticeFacts:{...state.noticeFacts,signedAt:now+4*day}},now+4*day),'late');
  assert.equal(nextNotice(state,now,prior),'unchanged');
  assert.equal(nextNotice({...state,noticeFacts:{...state.noticeFacts,date:due+day}},now,prior),'correction');
  assert.equal(nextNotice(state,now,{...prior,purpose:'correction',sentAt:now-day}),'reminder');
});
test('a domain-scoped send-only key needs no read permission; idempotence and opaque correlation use the same dispatch',async()=>{
  const id=randomUUID(),key=randomUUID(),calls=[];
  const fake=async(url,init)=>{calls.push({url,init});assert.equal(url,'https://api.resend.com/emails');return Response.json({id});};
  const p=new ResendRenewalProvider('fixture','notice@roominthecart.com',fake,async()=>true),signal=AbortSignal.timeout(3000);
  assert.equal(await p.ready(signal),true);assert.equal(calls.length,0);
  assert.equal(await p.send(key,'adult@example.invalid',{date:due,amountMilli:193400,purpose:'correction'},signal),id);
  const call=calls[0].init,body=JSON.parse(call.body);
  assert.equal(call.method,'POST');assert.equal(call.headers['Idempotency-Key'],'renewal/'+key);
  assert.deepEqual(body.tags,[{name:'renewal_dispatch',value:key}]);
  assert.deepEqual(body.to,['adult@example.invalid']);assert.equal('html' in body,false);
  assert.match(body.text,/193\.40/);assert.match(body.text,/apps\.apple\.com\/account\/subscriptions/);
  assert.match(body.text,/Ciudad de México/);assert.match(body.text,/UTC:/);assert.match(body.text,/actualizan/);
});
test('scoped sender readiness authenticates over the TLS session and quits without sending',async()=>{
  const command=[],input=async function*(){
    yield '220 smtp ready';yield '250-server';yield '250 AUTH PLAIN LOGIN';yield '235 authenticated';
  };
  assert.equal(await checkSenderSession(input(),v=>command.push(v.split(' ')[0]),'synthetic'),true);
  assert.deepEqual(command,['EHLO','AUTH','QUIT']);
  const denied=async function*(){yield '220 ready';yield '250 AUTH PLAIN';yield '535 denied';};
  await assert.rejects(()=>checkSenderSession(denied(),()=>{},'synthetic'));
});
test('raw signed delivery events project only opaque identifiers and outcome; replay changes no recipient or content',async()=>{
  const key=webhookKey('whsec_'+randomBytes(32).toString('base64')),time=String(Math.floor(now/1000)),id='msg_test_event';
  const providerID=randomUUID(),dispatch=randomUUID(),effects=[],pool={query:async(_sql,params)=>effects.push(params)};
  const signed=(type,tag=dispatch)=>{
    const raw=Buffer.from(JSON.stringify({type,data:{email_id:providerID,tags:{renewal_dispatch:tag},to:['other@example.invalid']}}));
    const signature=createHmac('sha256',key).update(id+'.'+time+'.').update(raw).digest('base64');
    return {raw,headers:{'svix-id':id,'svix-timestamp':time,'svix-signature':'v1,'+signature}};
  };
  const e=signed('email.delivered');
  await assert.rejects(()=>recordRenewalDelivery(pool,key,Buffer.concat([e.raw,Buffer.from(' ')]),e.headers,now));
  await assert.rejects(()=>recordRenewalDelivery(pool,key,e.raw,e.headers,now+301000));
  for(const event of [signed('email.opened'),signed('email.delivered','unknown')])
    await recordRenewalDelivery(pool,key,event.raw,event.headers,now);
  assert.deepEqual(effects,[]);
  for(const type of ['email.sent','email.delivered','email.bounced']){
    const event=signed(type);await recordRenewalDelivery(pool,key,event.raw,event.headers,now);
  }
  assert.deepEqual(effects,['accepted','delivered','failed'].map(status=>[dispatch,providerID,status]));
});
test('live dispatch defaults to off and Sandbox can never add a household outside the verified allowlist',()=>{
  const home=randomUUID();assert.equal(renewalConfig({}).mode,'off');
  assert.throws(()=>renewalConfig({MX_RENEWAL_NOTICES_MODE:'send'}));
  const scoped={APPLE_ENVIRONMENT:'Production',APPLE_REVIEW_HOUSEHOLD_IDS:home,MX_RENEWAL_SANDBOX_PREFLIGHT_HOUSEHOLDS:home};
  assert.deepEqual([...renewalConfig(scoped).sandboxHomes],[home]);assert.equal(renewalConfig(scoped).provider,null);
  assert.throws(()=>renewalConfig({...scoped,MX_RENEWAL_SANDBOX_PREFLIGHT_HOUSEHOLDS:randomUUID()}));
});
