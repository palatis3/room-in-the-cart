import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { reserveReceiptAssistance } from '../dist/receipt-assistance.js';

// Exercise the existing restricted runtime role and row-level policy on independent connections.
test('concurrent receipt admissions reserve money once and roll back incomplete reservations', async t => {
  const pool = new pg.Pool({connectionString:process.env.TEST_DATABASE_URL,max:6});
  t.after(() => pool.end());
  const day = new Date('2088-07-18T11:45:00.000Z');
  // Isolate a qualification run from any other fixed date, without changing server clocks.
  day.setUTCDate(1 + Math.floor(Math.random() * 26));
  day.setUTCFullYear(2200 + Math.floor(Math.random() * 5000));
  const input = () => ({requestID:randomUUID(),issuedAt:day.getTime()});
  const account = {issuer:'fixture',subject:randomUUID()};
  const budget = {dailyAccountRequests:5,maxRequestMicros:18,dailyMicros:50};
  async function reserve(selected, limits=budget) {
    const db = await pool.connect();
    try {
      await db.query('BEGIN');
      await reserveReceiptAssistance({db,now:day},account,selected,limits);
      await db.query('COMMIT');
    } catch (e) { await db.query('ROLLBACK'); throw e; }
    finally { db.release(); }
  }
  const same = input();
  const first = await Promise.allSettled([reserve(same),reserve(same),reserve(same)]);
  assert.equal(first.filter(r=>r.status==='fulfilled').length,1);
  assert.equal(first.filter(r=>r.status==='rejected'&&r.reason.code==='receipt_assistance_limit').length,2);
  const additional = await Promise.allSettled([reserve(input()),reserve(input()),reserve(input())]);
  assert.equal(additional.filter(r=>r.status==='fulfilled').length,1);
  const smaller = input();
  await assert.rejects(reserve(smaller), e=>e.code==='receipt_assistance_limit');
  await reserve(smaller,{...budget,maxRequestMicros:14});
  await assert.rejects(reserve(input(),{...budget,maxRequestMicros:1}), e=>e.code==='receipt_assistance_limit');
});
