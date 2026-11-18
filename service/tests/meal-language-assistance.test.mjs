import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {createHTTPServer} from '../dist/http.js';
import {ReceiptAssistance} from '../dist/receipt-assistance.js';
import {mealPreferenceRoute, mealFeedbackRoute} from '../dist/meal-language-assistance.js';

const note = (text, locale = 'en') => ({version: 1, requestID: randomUUID(), issuedAt: Date.now(),
  consent: true, locale, sourceLines: [{id: randomUUID(), text}]});
const signal = new AbortController().signal;

test('meal routes validate the exact selected quote and the purpose-specific additive proposal', async () => {
  for (const [purpose, input, kind, quote] of [
    [mealPreferenceRoute, note('No me gustan los guisantes', 'es'), 'dislike', 'guisantes'],
    [mealPreferenceRoute, note('I prefer Oatly'), 'preferredBrand', 'Oatly'],
    [mealFeedbackRoute, note('Nos sobró demasiado', 'es'), 'tooManyLeftovers', 'sobró demasiado'],
    [mealFeedbackRoute, note('Make this again'), 'makeAgain', 'again']
  ]) {
    const suggestion = {sourceLineID: input.sourceLines[0].id, kind, quote};
    let result = {suggestions: [suggestion]};
    const transport = {async structuredText(body, receivedSignal) {
      assert.deepEqual(JSON.parse(body), {locale: input.locale, sourceLines: input.sourceLines});
      assert.equal(receivedSignal, signal);
      return result;
    }};
    const prepared = purpose.parse(input);
    assert.deepEqual(await prepared.run(transport, signal), {version: 1, requestID: input.requestID, ...result});
    for (const bad of [{kind: 'medicalExclusion'}, {kind: 'remove'}, {sourceLineID: randomUUID()}, {quote: 'invented'}, {strict: true}]) {
      result = {suggestions: [{...suggestion, ...bad}]};
      await assert.rejects(prepared.run(transport, signal), err => err.code === 'language_suggestion_unavailable');
    }
    result = {suggestions: []};
    assert.deepEqual((await prepared.run(transport, signal)).suggestions, []);
    for (const extra of [{consent: false}, {savedPreferences: ['secret']}, {sourceLines: [...input.sourceLines, {id: randomUUID(), text: 'another'}]}]) {
      assert.throws(() => purpose.parse({...input, ...extra}));
    }
  }
});

test('actual meal HTTP endpoints authorize before admission and after the mock provider returns', async t => {
  const household = randomUUID();
  let role = 'adult', revoke = false, calls = 0;
  const repository = {options: {}, async authorized(id, auth, work) {
    assert.equal(id, household);
    return work({now: new Date(), householdId: id, member: {member_id: 'adult', kind: role, organizer: role === 'adult'},
      viewGrantId: auth.viewGrantId, db: {async query() {return {rowCount: 1, rows: []};}}});
  }};
  const verifier = {verify: async () => ({issuer:'test', subject:'person', sessionId:'test', expiresAt:new Date(Date.now()+60000)})};
  assert.equal(ReceiptAssistance.configured({}), undefined);
  const transport = new ReceiptAssistance({dailyAccountRequests: 5, dailyMicros: 100, maxRequestMicros: 10, maxLanguageMicros: 5},
    'fixture', 'unused', async (_url, options) => {
      calls++;
      const body = JSON.parse(options.body);
      const selected = JSON.parse(body.input);
      assert.deepEqual(Object.keys(selected).sort(), ['locale','sourceLines']);
      assert.equal(body.store, false);
      assert.deepEqual(body.tools, []);
      if (revoke) role = 'child';
      const value = {suggestions: [{sourceLineID:selected.sourceLines[0].id, kind:'makeAgain', quote:'again'}]};
      return Response.json({status:'completed', output:[{type:'message',role:'assistant',status:'completed',
        content:[{type:'output_text',text:JSON.stringify(value)}]}]});
    });
  const server = createHTTPServer({repository, verifier, receiptAssistance:transport});
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const url = 'http://127.0.0.1:'+server.address().port+'/v1/households/'+household+'/language-assistance/';
  const headers = {Authorization:'Bearer fixture', 'Content-Type':'application/json'};
  const send = (body, more={}) => fetch(url+'meal-feedback',{method:'POST',headers:{...headers,...more},body:JSON.stringify(body)});
  for (const purpose of ['meal-preference','meal-feedback']) {
    assert.deepEqual(await (await fetch(url+purpose,{headers})).json(), {version:1,available:true});
  }
  const request = note('Make again');
  assert.equal((await send({...request,consent:false})).status,422);
  assert.equal((await send(request,{'X-View-Grant-ID':randomUUID()})).status,404);
  role='child'; assert.equal((await send(request)).status,404);
  role='contributor'; assert.equal((await send(request)).status,404);
  assert.equal(calls,0);
  role='adult';
  const saved = await send(request);
  assert.equal(saved.status,200);
  assert.equal((await saved.json()).suggestions[0].kind,'makeAgain');
  revoke=true;
  assert.equal((await send(note('again'))).status,404);
  assert.equal(calls,2);
});
