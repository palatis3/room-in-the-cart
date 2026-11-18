import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {mealChoiceRoute} from '../dist/meal-choice.js';

test('only selected temporary meal references cross the customer wording boundary',async()=>{
  const candidate={id:randomUUID(),title:'Tacos de frijoles'};
  const request={version:1,requestID:randomUUID(),issuedAt:Date.now(),consent:true,locale:'es',
    sourceLines:[{id:randomUUID(), text:'Quiero tacos'}],candidates:[candidate]};
  const work=mealChoiceRoute.parse(request);
  let reply={candidateID:candidate.id};
  const transport={async structuredText(body) {
    assert.deepEqual(JSON.parse(body),{locale:'es',words:'Quiero tacos',candidates:[candidate]});
    return reply;
  }};
  const signal=new AbortController().signal;
  assert.deepEqual(await work.run(transport,signal),{version:1,requestID:request.requestID,candidateID:candidate.id});
  for(const malformed of [{candidateID:randomUUID()},{candidateID:candidate.id,cost:'free'},{candidateID:null,stock:'covered'},{}]) {
    reply=malformed; await assert.rejects(work.run(transport,signal), e=>e.code==='language_suggestion_unavailable');
  }
  reply={candidateID:null}; assert.equal((await work.run(transport,signal)).candidateID,null);
  for(const delta of [{consent:false},{sourceLines:[]},{candidates:[candidate,candidate]},{candidates:[{...candidate,id:request.requestID}]},
    {candidates:[{...candidate,lotID:randomUUID()}]},{sourceLines:[...request.sourceLines,{id:randomUUID(),text:'another note'}]}]) {
    assert.throws(()=>mealChoiceRoute.parse({...request,...delta}));
  }
});
