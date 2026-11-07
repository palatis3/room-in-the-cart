import assert from 'node:assert/strict';
import test from 'node:test';
import { chromium } from 'playwright-core';
import { preview } from 'vite';

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
  const browser = await chromium.launch({
    channel: 'chrome', executablePath: process.env.CHROME_BIN, timeout: 15_000
  });
  t.after(() => browser.close());
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
  assert.equal((await status.textContent()).trim(), 'Waiting to send from this browser');
  assert.deepEqual(posts, [commandsPath]);

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
