import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {day,mexicoRenewal,nextNotice} from '../../../dist/billing/renewal-facts.js';
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
  assert.equal(nextNotice({...state,noticeFacts:{...state.noticeFacts,signedAt:now-day-1}},now),'not_ready');
  for(const zone of ['America/Tijuana','America/Ciudad_Juarez','America/Cancun','America/Mexico_City']){
    const localDate=ms=>Date.parse(new Intl.DateTimeFormat('en-CA',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit'}).format(ms)+'T00:00:00Z');
    assert.ok((localDate(due)-localDate(now+day))/day>=5);
  }
  assert.equal(nextNotice({...state,noticeFacts:{...state.noticeFacts,signedAt:now+2*day}},now+2*day),'late');
  assert.equal(nextNotice(state,now,prior),'unchanged');
  assert.equal(nextNotice({...state,noticeFacts:{...state.noticeFacts,date:due+day}},now,prior),'correction');
  assert.equal(nextNotice(state,now,{...prior,purpose:'correction',sentAt:now-day}),'reminder');
});
test('Resend requires domain tracking off, one idempotent bilingual text and verified provider receipt',async()=>{
  const domain=randomUUID(),id=randomUUID(),key=randomUUID(),calls=[];
  let event='delivered',tracking=false;
  const fake=async(url,init)=>{
    calls.push({url,init});
    assert.equal(init.redirect,'error');
    const body=url.endsWith('/domains/'+domain)?{id:domain,name:'roominthecart.com',status:'verified',click_tracking:tracking,open_tracking:false}:
      url.endsWith('/emails/'+id)?{id,last_event:event}:{id};
    return Response.json(body);
  };
  const p=new ResendRenewalProvider('fixture','notice@roominthecart.com',domain,fake),signal=AbortSignal.timeout(3000);
  assert.equal(await p.ready(signal),true);tracking=true;assert.equal(await p.ready(signal),false);
  const m={date:due,amountMilli:193400,purpose:'correction'};
  assert.equal(await p.send(key,'adult@example.invalid',m,signal),id);
  const call=calls.at(-1).init,body=JSON.parse(call.body);
  assert.equal(call.headers['Idempotency-Key'],'renewal/'+key);
  assert.deepEqual(body.to,['adult@example.invalid']);assert.equal('html' in body,false);
  assert.match(body.text,/193\.40/);assert.match(body.text,/manage|Manage/);assert.match(body.text,/apps\.apple\.com\/account\/subscriptions/);
  assert.match(body.text,/Ciudad de México/);assert.match(body.text,/UTC:/);assert.match(body.text,/actualizan/);
  for(const [value,expected] of [['delivered','delivered'],['bounced','failed'],['sent','accepted']]){
    event=value;assert.equal(await p.delivery(id,signal),expected);
  }
});
test('live dispatch defaults to off and Sandbox can never add a household outside the verified allowlist',()=>{
  const home=randomUUID();assert.equal(renewalConfig({}).mode,'off');
  assert.throws(()=>renewalConfig({MX_RENEWAL_NOTICES_MODE:'send'}));
  const scoped={APPLE_ENVIRONMENT:'Production',APPLE_REVIEW_HOUSEHOLD_IDS:home,MX_RENEWAL_SANDBOX_PREFLIGHT_HOUSEHOLDS:home};
  assert.deepEqual([...renewalConfig(scoped).sandboxHomes],[home]);assert.equal(renewalConfig(scoped).provider,null);
  assert.throws(()=>renewalConfig({...scoped,MX_RENEWAL_SANDBOX_PREFLIGHT_HOUSEHOLDS:randomUUID()}));
});
