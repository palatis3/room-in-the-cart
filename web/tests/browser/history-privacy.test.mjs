import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { chromium } from 'playwright-core';

let browser;
test.before(async () => {
  const started = performance.now();
  console.info('[history-privacy] Starting Chrome');
  browser = await chromium.launch({
    channel: 'chrome', executablePath: process.env.CHROME_BIN, timeout: 60_000,
    // Playwright normally disables the behavior this regression needs to observe.
    ignoreDefaultArgs: ['--disable-back-forward-cache']
  });
  console.info(`[history-privacy] Chrome ${browser.version()} ready after ${Math.round(performance.now() - started)}ms`);
});
test.after(() => browser?.close());

const ownA = 'OWN_ACTOR_A_HISTORY_7d91', ownB = 'OWN_ACTOR_B_HISTORY_f51e';
const draftA = 'UNSENT_ACTOR_A_HISTORY_bf31';
const forbidden = ['OTHER_AUTHOR_ONLY_3ab2', 'BUDGET_PRIVATE_814e', 'PRIVATE_NOTE_9c7d'];
const session = actor => ({
  authenticated: true, role: 'contributor', household: { id: actor, label: `Household ${actor}` },
  memberId: `member-${actor}`, shopId: `shop-${actor}`, csrf: `synthetic-${actor}`,
  replayWindow: { id: `window-${actor}`, expiresAt: '2099-01-01T00:00:00Z' }, enrolled: true, queueConsent: false
});
const row = actor => ({
  requestId: `request-${actor}`, shopId: `shop-${actor}`, revision: 1, originalItem: actor === 'A' ? ownA : ownB,
  ownQuantity: null, authoredAt: '2026-11-06T12:00:00Z', receivedAt: '2026-11-06T12:00:01Z',
  route: 'current', status: 'pending', ownActionAllowed: true, clarification: null, followupTo: null
});
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

// Real history traversal, not dispatched lifecycle events or mocked browser routing.
// BFCache must actually restore the eligible document; an unsupported browser fails.
test('history restoration conceals private content until fresh authority succeeds', async t => {
  const state = { actor: 'A', offline: false, gate: null, htmlCache: 'private, max-age=0', loginActor: 'A' };
  const responses = [], writes = [];
  const database = {
    requests: [{ author: 'A', payload: row('A') }, { author: 'B', payload: row('B') },
      { author: 'other', payload: { ...row('A'), originalItem: forbidden[0] } }],
    budget: forbidden[1], privateNote: forbidden[2]
  };
  const server = createServer(async (req, res) => {
    const path = new URL(req.url, 'http://127.0.0.1').pathname;
    if (req.method !== 'GET') writes.push({ method: req.method, path });
    const json = (status, body) => {
      responses.push(body);
      res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(body));
    };
    if (req.method === 'POST' && ['/v1/auth/email/start', '/v1/auth/email/verify'].includes(path)) {
      const chunks = []; for await (const chunk of req) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks).toString());
      if (path.endsWith('/start')) return json(body.email === 'fixture@example.test' ? 200 : 422, { status: 'check_email' });
      if (body.code !== '123456') return json(401, { error: { code: 'code_not_accepted' } });
      state.actor = state.loginActor;
      return json(200, { available: true, authenticated: true, csrf: 'verified-synthetic-challenge' });
    }
    if (path === '/v1/session') {
      const gate = state.gate;
      if (gate) { gate.started.resolve(); await gate.release.promise; }
      if (state.offline) return res.destroy();
      if (state.actor === 'expired') return json(401, { error: { code: 'session_needed' } });
      return state.actor === 'revoked' ? json(403, { error: { code: 'access_ended' } }) : json(200, session(state.actor));
    }
    if (path === '/v1/auth/session') return json(200, { available: true, authenticated: false, csrf: 'fresh-synthetic-challenge' });
    if (path.startsWith('/v1/')) {
      if (path === `/v1/households/${state.actor}/requests/mine`) {
        return json(200, { requests: database.requests.filter(r => r.author === state.actor).map(r => r.payload), nextCursor: null });
      }
      return json(403, { error: { code: 'access_ended' } });
    }
    if (path === '/neutral') {
      res.writeHead(200, { 'Content-Type': 'text/html', 'Cache-Control': 'max-age=0' });
      return res.end('<!doctype html><title>Neutral fixture</title><main>Neutral navigation control</main>');
    }
    const file = path === '/requests' ? 'index.html' : path.startsWith('/assets/') ? path.slice(1) : null;
    if (!file) return res.writeHead(404).end();
    try {
      const body = await readFile(new URL(`../../public-build/${file}`, import.meta.url));
      res.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'text/javascript' : file.endsWith('.css') ? 'text/css' : 'text/html', 'Cache-Control': state.htmlCache });
      res.end(body);
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { state.gate?.release.resolve(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  t.diagnostic(`Chrome ${browser.version()}; synthetic loopback authority; API Cache-Control:no-store`);
  const origin = `http://127.0.0.1:${server.address().port}`;

  for (const htmlCache of ['private, max-age=0', 'no-store']) {
    for (const scenario of ['unchanged', 'changed-delayed', 'revoked-delayed', 'revoked-offline', 'expired-identity-same', 'expired-identity-changed']) {
      await t.test(`${htmlCache}: ${scenario}`, async st => {
        console.info(`[history-privacy] Starting ${htmlCache}: ${scenario}`);
        Object.assign(state, { actor: 'A', offline: false, gate: null, htmlCache, loginActor: scenario.endsWith('-changed') ? 'B' : 'A' });
        writes.length = 0;
        const context = await browser.newContext({ locale: 'en-US', serviceWorkers: 'block' });
        let gate;
        try {
          await context.addInitScript(() => {
            const probe = window.__historyProbe = { id: crypto.randomUUID(), shows: [], samples: [] };
            const sample = () => ({ text: document.body?.innerText ?? '', item: document.querySelector('#item')?.value ?? null,
              url: location.href, state: history.state, visibility: document.visibilityState });
            addEventListener('pageshow', event => { probe.shows.push({ persisted: event.persisted, ...sample() }); });
            document.addEventListener('DOMContentLoaded', () => new MutationObserver(() => probe.samples.push(sample()))
              .observe(document.body, { childList: true, subtree: true, characterData: true }));
          });
          const page = await context.newPage();
          page.setDefaultTimeout(5000);
          const snapshot = () => page.evaluate(() => ({ ...window.__historyProbe, text: document.body.innerText,
            item: document.querySelector('#item')?.value ?? null, url: location.href, state: history.state,
            navigation: performance.getEntriesByType('navigation').map(entry => entry.toJSON()) }));
          await page.goto(`${origin}/requests`);
          await page.getByText(ownA, { exact: true }).waitFor();
          await page.getByLabel('Item', { exact: true }).fill(draftA);
          const initial = await snapshot();
          await page.goto(`${origin}/neutral`);
          state.actor = scenario.startsWith('expired-identity') ? 'expired' : scenario.startsWith('changed') ? 'B' : scenario.startsWith('revoked') ? 'revoked' : 'A';
          state.offline = scenario.endsWith('offline');
          gate = state.gate = { started: deferred(), release: deferred() };
          await page.goBack({ waitUntil: 'commit' });
          // Wait for the actual request without releasing its response or inventing a lifecycle event.
          await Promise.race([gate.started.promise, new Promise((_, reject) => {
            const timer = setTimeout(() => reject(new Error('History return did not revalidate authority within 5s')), 5000);
            timer.unref(); gate.started.promise.then(() => clearTimeout(timer));
          })]);
          const pending = await snapshot();
          const restored = pending.id === initial.id && pending.shows.some(event => event.persisted);
          if (htmlCache !== 'no-store') assert.ok(restored,
            `BFCache unavailable; this is not a pass. Navigation: ${JSON.stringify(pending.navigation)}`);
          st.diagnostic(`${restored ? 'persisted BFCache restore' : 'cold history navigation; BFCache unavailable'}; HTML Cache-Control:${htmlCache}`);
          assert.doesNotMatch(pending.text, new RegExp(`${ownA}|${ownB}`));
          assert.notEqual(pending.item, draftA);
          if (restored) {
            const shown = pending.shows.filter(event => event.persisted).at(-1);
            assert.equal(shown.visibility, 'visible');
            assert.doesNotMatch(shown.text, new RegExp(`${ownA}|${ownB}`), 'Private DOM must already be gone at persisted pageshow');
            assert.notEqual(shown.item, draftA);
          }
          gate.release.resolve(); state.gate = null;
          await page.locator('main[aria-busy="false"]').waitFor();
          const after = await snapshot();
          if (scenario === 'unchanged') {
            assert.match(after.text, new RegExp(ownA));
            if (restored) assert.equal(after.item, draftA, 'Fresh same-actor authority preserves unsent work');
          } else {
            assert.doesNotMatch(after.text, new RegExp(ownA)); assert.notEqual(after.item, draftA);
            if (scenario === 'changed-delayed') assert.match(after.text, new RegExp(ownB));
            if (scenario.startsWith('expired-identity')) {
              assert.equal(await page.locator('#login-email').count(), 1, '401 must expose sign-in without a Refresh loop');
              assert.equal(await page.getByRole('button', { name: 'Send sign-in code', exact: true }).count(), 1);
              await page.locator('#login-email').fill('fixture@example.test');
              await page.getByRole('button', { name: 'Send sign-in code', exact: true }).click();
              await page.locator('#login-code').fill('123456');
              await page.getByRole('button', { name: 'Verify code', exact: true }).click();
              await page.locator('main[aria-busy="false"]').waitFor();
              const recovered = await snapshot();
              assert.match(recovered.text, new RegExp(state.loginActor === 'A' ? ownA : ownB));
              assert.equal(recovered.item, restored && state.loginActor === 'A' ? draftA : '');
              if (state.loginActor === 'B') assert.doesNotMatch(recovered.text, new RegExp(ownA));
              for (const marker of forbidden) assert.ok(!JSON.stringify(recovered).includes(marker));
            }
          }
          for (const marker of forbidden) assert.ok(!JSON.stringify({ pending, after, responses }).includes(marker));
          await page.goForward({ waitUntil: 'commit' });
          assert.equal(page.url(), `${origin}/neutral`);
          assert.equal(await page.getByText('Neutral navigation control', { exact: true }).count(), 1);
          await page.goBack({ waitUntil: 'commit' });
          await page.locator('main[aria-busy="false"]').waitFor();
          const again = await snapshot();
          if (state.actor !== 'A') assert.doesNotMatch(again.text, new RegExp(ownA));
          else assert.match(again.text, new RegExp(ownA));
          for (const marker of forbidden) assert.ok(!JSON.stringify(again).includes(marker));
          const expectedWrites = scenario.startsWith('expired-identity')
            ? [{ method: 'POST', path: '/v1/auth/email/start' }, { method: 'POST', path: '/v1/auth/email/verify' }] : [];
          assert.deepEqual(writes, expectedWrites, 'Only explicitly submitted email/code may write; history traversal must never send a queued command');
        } finally { gate?.release.resolve(); state.gate = null; await context.close(); }
      });
    }
  }
});
