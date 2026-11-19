import assert from 'node:assert/strict';
import test from 'node:test';
import { chromium } from 'playwright-core';
import { preview } from 'vite';

let browser;
test.before(async () => {
  const started = performance.now();
  console.info('[outbox-eviction] Starting Chrome');
  browser = await chromium.launch({
    channel: 'chrome', executablePath: process.env.CHROME_BIN, timeout: 60_000
  });
  console.info(`[outbox-eviction] Chrome ${browser.version()} ready after ${Math.round(performance.now() - started)}ms`);
});
test.after(() => browser?.close());

const session = {
  authenticated: true, role: 'contributor',
  household: { id: 'test', label: 'Example household' }, memberId: 'test-member', shopId: 'test-shop',
  replayWindow: { id: 'test-window', expiresAt: '2099-01-01T00:00:00Z' },
  csrf: 'test-csrf', enrolled: true, queueConsent: false, capabilities: ['own_requests', 'request_queue_permission']
};
const commandsPath = '/v1/households/test/commands';
const requestsPath = '/v1/households/test/requests/mine';

test('Refresh reconciles a queued request after IndexedDB eviction without resending it', async t => {
  const posts = [];
  const commandGrants = [];
  const grant = '4f14be8f-efc9-48c4-af14-cb09a8489f38';
  let currentSession = session;
  const server = await preview({
    configFile: false, // Keep this fixture independent of the local service proxy.
    build: { outDir: 'public-build' },
    preview: { host: '127.0.0.1', port: 0 },
    plugins: [{
      name: 'contributor-fixture',
      configurePreviewServer({ middlewares, httpServer }) {
        // Prevent Chrome from retrying a dropped POST on a reused keep-alive socket.
        httpServer.maxRequestsPerSocket = 1;
        middlewares.use((req, res, next) => {
          if (!req.url.startsWith('/v1/')) return next();
          if (req.method === 'POST') posts.push(req.url);
          if (req.method === 'POST' && req.url === commandsPath) {
            commandGrants.push(req.headers['x-request-queue-grant']);
            // Consume the command, then drop the connection before sending any receipt.
            req.on('end', () => res.destroy());
            req.resume();
            return;
          }
          res.setHeader('Content-Type', 'application/json');
          if (req.method === 'GET' && req.url === '/v1/session') return res.end(JSON.stringify(currentSession));
          if (req.method === 'PUT' && req.url === '/v1/households/test/devices/current/request-queue') {
            let body = '';
            req.on('data', chunk => { body += chunk; });
            req.on('end', () => {
              if (JSON.parse(body).enabled !== true) return res.writeHead(400).end();
              currentSession = { ...session, requestQueueGrant: grant, requestQueueUntil: new Date(Date.now() + 86400000).toISOString() };
              res.end(JSON.stringify(currentSession));
            });
            return;
          }
          if (req.method === 'GET' && req.url === requestsPath) {
            return res.end(JSON.stringify({ requests: [], nextCursor: null }));
          }
          res.writeHead(404).end();
        });
      }
    }]
  });
  t.after(() => server.close());
  t.diagnostic(`Chrome ${browser.version()}`);
  const page = await browser.newPage({ locale: 'en-US' });
  page.setDefaultTimeout(10_000);
  await page.goto(new URL('/requests', server.resolvedUrls.local[0]).href);

  const button = name => page.getByRole('button', { name, exact: true });
  await button('Allow pending requests on this browser for up to 24 hours').click();
  await button('Turn off and clear pending requests').waitFor();
  await page.getByLabel('Item', { exact: true }).fill('Fixture oats');
  await button('Review request').click();
  await button('Send request').click();

  const pending = page.getByRole('article').filter({ hasText: 'Fixture oats' });
  await pending.getByRole('button', { name: 'Retry', exact: true }).waitFor();
  const status = page.getByRole('status');
  assert.equal((await status.textContent()).trim(), 'Saved on this browser. Receipt unconfirmed.');
  assert.deepEqual(posts, [commandsPath]);
  assert.deepEqual(commandGrants, [grant], 'The persisted command must use the grant acknowledged by this device');

  const database = 'room-in-the-cart-own-outbox-v1';
  const { origins } = await page.context().storageState({ indexedDB: true });
  const outbox = origins.find(origin => origin.origin === new URL(page.url()).origin)?.indexedDB?.find(db => db.name === database);
  assert.equal(outbox?.stores.find(store => store.name === 'pending')?.records.length, 1, 'The pending row must be durable before eviction');
  await page.evaluate(name => new Promise((resolve, reject) => {
    const deletion = indexedDB.deleteDatabase(name);
    deletion.onsuccess = () => resolve();
    deletion.onerror = () => reject(deletion.error);
    deletion.onblocked = () => reject(new Error('Outbox still has an open connection'));
  }), database);

  await Promise.all([
    page.waitForResponse(response => new URL(response.url()).pathname === requestsPath && response.ok()),
    button('Refresh').click()
  ]);
  await page.locator('main[aria-busy="false"]').waitFor();
  assert.equal(await pending.count(), 0);
  assert.equal(await button('Retry').count(), 0);
  assert.equal((await status.textContent()).trim(), 'A pending request is no longer stored on this browser. Check Your requests for its status.');
  assert.deepEqual(posts, [commandsPath], 'Refresh must not send another command');
});

test('confirmed receipt, posting suspension and lost access have distinct effects on the outbox', async t => {
  const server = await preview({ configFile: false, build: { outDir: 'public-build' }, preview: { host: '127.0.0.1', port: 0 } });
  t.after(() => server.close());
  const context = await browser.newContext({ locale: 'en-US' });
  t.after(() => context.close());
  const page = await context.newPage();
  page.setDefaultTimeout(5000);
  const active = { ...session, requestQueueGrant: '1519b2f0-e731-4dc1-bfc7-09d099f86077', requestQueueUntil: new Date(Date.now() + 86400000).toISOString() };
  const commands = [];
  let readStatus = 200;
  let writeStatus = 503;
  await page.route('**/v1/**', async route => {
    const path = new URL(route.request().url()).pathname;
    if (path === '/v1/session' && readStatus === 429) return route.fulfill({ status: 429, json: { error: { code: 'rate_limited' } } });
    if (path === '/v1/session') return route.fulfill({ json: active });
    if (path === '/v1/auth/session') return route.fulfill({ json: { available: true, authenticated: true, csrf: 'identity-token' } });
    if (path === requestsPath && readStatus === 403) return route.fulfill({ status: 403, json: { error: { code: 'access_ended' } } });
    if (path === requestsPath) return route.fulfill({ json: { requests: [], nextCursor: null } });
    assert.equal(path, commandsPath);
    const command = route.request().postDataJSON();
    commands.push(command.body.originalItem);
    if (writeStatus !== 200) return route.fulfill({ status: writeStatus, json: { error: { code: writeStatus === 403 ? 'shared_posting_unavailable' : 'unavailable' } } });
    readStatus = 429;
    return route.fulfill({ json: { kind: command.kind, operationId: 'operation-a', request: {
      requestId: command.body.clientRequestId, shopId: command.shopId, revision: 1, originalItem: command.body.originalItem,
      ownQuantity: null, route: command.body.route, authoredAt: command.body.authoredAt, receivedAt: new Date().toISOString(),
      status: 'pending', ownActionAllowed: true
    } } });
  });

  const item = page.getByLabel('Item', { exact: true });
  const button = name => page.getByRole('button', { name, exact: true });
  const status = page.getByRole('status');
  const send = async wording => {
    await item.fill(wording);
    await button('Review request').click();
    await button('Send request').click();
    await page.locator('main[aria-busy="false"]').waitFor();
  };
  const storedItems = async () => {
    const { origins } = await context.storageState({ indexedDB: true });
    const outbox = origins.flatMap(origin => origin.indexedDB ?? []).find(db => db.name === 'room-in-the-cart-own-outbox-v1');
    return outbox.stores.find(store => store.name === 'pending').records.map(row => row.value.command.body.originalItem);
  };
  await page.goto(new URL('/requests', server.resolvedUrls.local[0]).href);
  await send('Queued rice');
  assert.deepEqual(await storedItems(), ['Queued rice']);

  writeStatus = 403;
  await send('Keep these oats');
  assert.match(await status.innerText(), /Shared posting is unavailable/);
  assert.equal(await item.inputValue(), 'Keep these oats');
  assert.deepEqual(await storedItems(), ['Queued rice']);

  writeStatus = 200;
  await send('Keep these oats');
  assert.equal(await status.innerText(), 'Received by the shopper.');
  assert.equal(await item.inputValue(), '');
  await page.getByRole('heading', { name: 'Keep these oats', exact: true }).waitFor();
  assert.deepEqual(await storedItems(), ['Queued rice']);

  readStatus = 403;
  await button('Refresh').click();
  await page.getByText('Access has ended. Ask your household for a new invitation.', { exact: true }).waitFor();
  assert.equal(await item.count(), 0);
  assert.deepEqual(await storedItems(), []);
  assert.deepEqual(commands, ['Queued rice', 'Keep these oats', 'Keep these oats']);
});
