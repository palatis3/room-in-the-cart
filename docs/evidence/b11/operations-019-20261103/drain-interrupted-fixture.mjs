import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';
import pg from '../service/node_modules/pg/lib/index.js';
import {PrivacyMaintenance} from '../service/dist/privacy.js';
const common={host:'/tmp',port:55432,database:'ritc_b11_ops019_20261103',max:1};
const admin=new pg.Pool({...common,user:'palatis'}),worker=new pg.Pool({...common,user:'ritc_b11_ops019_worker_20261103'});
try{
 const pending=(await admin.query("SELECT job_id,issuer,state FROM ritc.privacy_job WHERE state<>'complete'")).rows;
 assert.equal(pending.length,1);assert.equal(pending[0].issuer,'https://store-quotes.fixture.invalid');
 let syntheticProviderCalls=0;
 const result=await new PrivacyMaintenance(worker,{provider:{assertAvailable:async()=>{},deleteAccount:async subject=>{syntheticProviderCalls++;await admin.query('DELETE FROM auth.sessions WHERE user_id=$1',[subject]);}}}).run({batchSize:1});
 assert.equal(result.completed,1);assert.equal(syntheticProviderCalls,1);
 await writeFile(new URL('interrupted-fixture-drain.json',import.meta.url),JSON.stringify({pendingBefore:pending,result,syntheticProviderCalls,remaining:(await admin.query("SELECT count(*)::int n FROM ritc.privacy_job WHERE state<>'complete'")).rows[0].n},null,2)+'\n');
 console.log(JSON.stringify({result,syntheticProviderCalls}));
}finally{await Promise.all([admin.end(),worker.end()]);}
