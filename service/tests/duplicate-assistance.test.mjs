import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {receiptAliasRoute, requestDuplicateRoute} from '../dist/duplicate-assistance.js';

test('alias matcher accepts only consented source and candidate IDs, including abstention', async () => {
  const source = {id:randomUUID(),text:'FRJ NEG'}, candidate = {id:randomUUID(),text:'FRJ NEG · Frijoles negros'};
  const input = {version:1,requestID:randomUUID(),issuedAt:Date.now(),consent:true,locale:'es',sourceLines:[source],candidates:[candidate]};
  for (const invalid of [{consent:false},{candidates:[]},{candidates:[candidate,candidate]},{sourceLines:[source,{...source,id:randomUUID()}]},
    {candidates:[{...candidate,text:'x'.repeat(513)}]},{householdID:randomUUID()}]) {
    assert.throws(() => receiptAliasRoute.parse({...input,...invalid}));
  }
  const parsed = receiptAliasRoute.parse(input);
  const accepted = {sourceLineID:source.id,candidateID:candidate.id};
  let mode = 'accept';
  const transport = {structuredText:async payload => {
    const sent = JSON.parse(payload);
    assert.deepEqual(Object.keys(sent).sort(),['candidates','locale','sourceLines']);
    assert.equal(sent.locale,'es');
    assert.equal(sent.sourceLines[0].text,source.text);
    assert.notEqual(sent.sourceLines[0].id,source.id);
    assert.equal(sent.candidates[0].text,candidate.text);
    assert.notEqual(sent.candidates[0].id,candidate.id);
    const selected = {sourceLineID:sent.sourceLines[0].id,candidateID:sent.candidates[0].id};
    return {suggestions:mode==='accept'?[selected]:mode==='empty'?[]:mode==='extra'?[{...selected,approve:true}]:
      mode==='multiple'?[selected,selected]:[{...selected,[mode]:randomUUID()}]};
  }};
  assert.deepEqual((await parsed.run(transport,new AbortController().signal)).suggestions,[accepted]);
  mode = 'empty';
  assert.deepEqual((await parsed.run(transport,new AbortController().signal)).suggestions,[]);
  for (mode of ['extra','multiple','candidateID','sourceLineID']) {
    await assert.rejects(parsed.run(transport,new AbortController().signal),e=>e.code==='language_suggestion_unavailable');
  }
  mode = 'accept';
  const ambiguous = receiptAliasRoute.parse({...input,candidates:[candidate,{...candidate,id:randomUUID()}]});
  assert.deepEqual((await ambiguous.run(transport,new AbortController().signal)).suggestions,[]);
  assert.throws(() => requestDuplicateRoute.parse(input));
});
