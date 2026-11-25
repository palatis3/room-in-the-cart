import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {once} from 'node:events';
import test from 'node:test';
import {ClosedReview} from '../dist/closed-review.js';
import {createHTTPServer} from '../dist/http.js';

const householdId=randomUUID(), other=randomUUID(), subjects=[randomUUID(),randomUUID()];
const startsAt=new Date(Date.now()-60_000).toISOString();
const endsAt=new Date(Date.parse(startsAt)+86_400_000).toISOString();
const window={startsAt,endsAt,householdId,subjects};
const configuration=(value=window)=>({
  CLOSED_REVIEW_WINDOW_JSON:JSON.stringify(value),
  APPLE_ENVIRONMENT:'Production',
  APPLE_REVIEW_HOUSEHOLD_IDS:householdId,
});
test('closed review has a bounded lifetime and exactly one Sandbox review household',()=>{
  assert.equal(ClosedReview.configured({}),undefined);
  for(const env of [
    configuration({...window,subjects:[subjects[0],subjects[0]]}),
    configuration({...window,endsAt:new Date(Date.parse(endsAt)+1).toISOString()}),
    {...configuration(),APPLE_REVIEW_HOUSEHOLD_IDS:other},
    {...configuration(),APPLE_ENVIRONMENT:'Sandbox'},
    {...configuration(),CLOSED_REVIEW_WINDOW_JSON:''},
  ])assert.throws(()=>ClosedReview.configured(env));
  const review=ClosedReview.configured(configuration());
  for(const instant of [Date.parse(startsAt)-1,Date.parse(endsAt)]){
    assert.throws(()=>review.checkRequest('POST','/v1/apple/notifications/sandbox',false,instant));
    assert.throws(()=>review.checkRequest('GET','/v1/me/workspaces',true,instant));
  }
});
test('closed HTTP review checks verified subjects, exact household and Sandbox delivery before downstream access',async()=>{
  const workspaces=[householdId,other].map(id=>({householdId:id,label:id,role:'organizer'}));
  const notifications=[];
  const app=createHTTPServer({
    repository:{workspaces:async()=>({workspaces})},
    closedReview:ClosedReview.configured(configuration()),
    verifier:{verify:async token=>({subject:token})},
    billing:{notification:async(_pool,signature,destination)=>{notifications.push([signature,destination]);return{accepted:true};}},
  });
  app.listen(0,'127.0.0.1');await once(app,'listening');
  const base='http://127.0.0.1:'+app.address().port;
  async function request(path,{method='GET',token,data}={}){
    return fetch(base+path,{method,headers:{...(token?{Authorization:'Bearer '+token}:{}),'Content-Type':'application/json'},...(data?{body:JSON.stringify(data)}:{})});
  }
  try{
    assert.equal((await request('/v1/me/workspaces')).status,404);
    assert.equal((await request('/v1/me/workspaces',{token:other})).status,404);
    for(const token of subjects){
      const response=await request('/v1/me/workspaces',{token});
      assert.equal(response.status,200);assert.deepEqual((await response.json()).workspaces,[workspaces[0]]);
    }
    const token=subjects[0];
    for(const path of ['/v1/households/'+other+'/bootstrap','/v1/households/'+householdId+'/guardian/enrollments','/v1/auth/session','/v1/apple/notifications']){
      assert.equal((await request(path,{token})).status,404);
    }
    for(const [path,data] of [
      ['/v1/billing/verify',{householdId:other,signedTransactionInfo:'x'.repeat(32)}],
      ['/v1/invites/preview',{token:other+'.'+'a'.repeat(43),adultAttestation:true}],
      ['/v1/invites/redeem',{token:other+'.'+'a'.repeat(43),adultAttestation:true,intent:'join'}],
    ])assert.equal((await request(path,{token,method:'POST',data})).status,404);
    const signedPayload='x'.repeat(32);
    assert.equal((await request('/v1/apple/notifications',{method:'POST',data:{signedPayload}})).status,404);
    assert.equal((await request('/v1/apple/notifications/sandbox',{method:'POST',data:{signedPayload}})).status,200);
    assert.deepEqual(notifications,[[signedPayload,'reviewSandbox']]);
  }finally{
    const closed=once(app,'close');app.close();await closed;
  }
});
