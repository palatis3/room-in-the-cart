import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {foodKeeperMatchRoute} from '../dist/foodkeeper-match.js';
import {foodKeeperEdition,foodKeeperLabels} from '../dist/foodkeeper-index.js';
import {languagePurposes} from '../dist/language-purposes.js';

const sid='a675441d-4298-442c-8401-553efeb73ba5';
const rid='a676441d-4298-442c-8401-553efeb73ba5';
function request(locale='en') {
  return {version:1,requestID:rid,issuedAt:Date.now(),consent:true,locale,sourceLines:[{id:sid,text:'selected label'}],
    catalogVersion:128,candidates:[1,2].map(id=>({id,label:foodKeeperLabels.get(id)[locale==='es'?1:0]}))};
}
async function answer(input,output) {
  return foodKeeperMatchRoute.parse(input).run({async structuredText(content,_signal,_instructions,_name,schema) {
    const payload=JSON.parse(content);
    assert.deepEqual(Object.keys(payload).sort(),['candidates','locale','referenceEdition','selectedText']);
    assert.equal(payload.selectedText,'selected label');
    assert.deepEqual(schema.properties.candidateID.enum,[1,2,null]);
    return output;
  }},AbortSignal.timeout(2000));
}
test('the service public allowlist matches every EN/ES ID in the distributed USDA edition',()=>{
  const file=JSON.parse(readFileSync(new URL('../../ios/Packages/CoreDomain/Sources/CoreDomain/Resources/FoodKeeper-v128.json',import.meta.url)));
  assert.equal(foodKeeperEdition,file.version);
  assert.deepEqual([...foodKeeperLabels.entries()],file.products.map(p=>[p.id,p.names]));
  assert.ok(languagePurposes.includes(foodKeeperMatchRoute));
});
test('one selected line yields only its offered bilingual reference ID or no match',async()=>{
  for (const locale of ['en','es']) {
    const input=request(locale);
    assert.deepEqual(await answer(input,{candidateID:2}),{version:1,requestID:rid,catalogVersion:128,suggestions:[{sourceLineID:sid,candidateID:2}]});
    assert.deepEqual((await answer(input,{candidateID:null})).suggestions,[]);
  }
});
test('unknown editions, wrong public labels, duplicate candidates and unoffered or extra generated facts fail closed',async()=>{
  const shape=request();
  for(const patch of [{consent:false},{catalogVersion:129},{candidates:[{id:99999,label:'unknown'}]},
      {candidates:[{id:1,label:'private name'}]},{candidates:[shape.candidates[0],shape.candidates[0]]},
      {sourceLines:[...shape.sourceLines,{id:rid,text:'other'}]},{candidates:[]},{pantry:'private content'}]) {
    assert.throws(()=>foodKeeperMatchRoute.parse({...shape,...patch}));
  }
  for(const output of [{candidateID:3},{candidateID:99999},{candidateID:'1'},{candidateID:1,expiry:'tomorrow'},{date:'today'}]) {
    await assert.rejects(answer(shape,output));
  }
});
