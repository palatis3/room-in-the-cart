import test from 'node:test';
import assert from 'node:assert/strict';
import {workerDatabaseConfiguration} from '../dist/operations-runtime.js';

test('worker credentials are explicit and different from application credentials',()=>{
 assert.throws(()=>workerDatabaseConfiguration({DATABASE_URL:'postgresql://app@localhost/fixture'}));
 assert.throws(()=>workerDatabaseConfiguration({WORKER_DATABASE_URL:'postgresql://app@localhost/fixture',DATABASE_URL:'postgresql://app@remote/fixture'}));
 assert.throws(()=>workerDatabaseConfiguration({WORKER_DATABASE_URL:'https://worker@localhost/fixture'}));
 assert.throws(()=>workerDatabaseConfiguration({WORKER_DATABASE_URL:'postgresql://localhost/fixture'}));
});
test('remote worker TLS and limits cannot be overridden by PostgreSQL URL options',()=>{
 const config=workerDatabaseConfiguration({WORKER_DATABASE_URL:'postgresql://worker:fictional@db.example/fixture?sslmode=disable&ssl=false&options=-c%20role%3Dadmin&statement_timeout=0&user=admin',WORKER_DATABASE_CA_PEM:'fixture CA'});
 assert.equal(config.ssl.rejectUnauthorized,true);assert.equal(config.ssl.ca,'fixture CA');
 assert.equal(config.user,'worker');assert.equal(config.statement_timeout,2000);assert.equal(config.lock_timeout,500);assert.equal(config.query_timeout,3000);
 assert.equal(config.options,'-c statement_timeout=2000 -c lock_timeout=500');assert.equal(config.connectionString,undefined);assert.equal(config.max,2);
 assert.throws(()=>workerDatabaseConfiguration({WORKER_DATABASE_URL:'postgresql://worker@localhost/fixture?host=remote.example'}));
 assert.equal(workerDatabaseConfiguration({WORKER_DATABASE_URL:'postgresql://worker@127.0.0.1.evil.example/fixture'}).ssl.rejectUnauthorized,true);
});
test('local disposable sockets are explicit and cannot be used in the deployment',()=>{
 const config=workerDatabaseConfiguration({WORKER_DATABASE_URL:'postgresql://worker@localhost:55432/fixture?host=%2Ftmp'});
 assert.equal(config.host,'/tmp');assert.equal(config.port,55432);assert.equal(config.ssl,false);
 assert.throws(()=>workerDatabaseConfiguration({WORKER_DATABASE_URL:'postgresql://worker@localhost:55432/fixture?host=%2Ftmp',VERCEL:'1'}));
});
