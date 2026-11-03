import {spawn} from 'node:child_process';
import {open,writeFile} from 'node:fs/promises';
const root=new URL('../',import.meta.url),service=new URL('service/',root);
const common={PATH:'/Users/palatis/Room in the Cart/.tools/node-v22.14.0-darwin-arm64/bin:/usr/bin:/bin',HOME:'/Users/palatis',TMPDIR:'/tmp'};
const urls={
 TEST_DATABASE_URL:'postgresql://ritc_b11_ops019_app_20261103@localhost/ritc_b11_ops019_20261103?host=%2Ftmp&port=55432',
 TEST_ADMIN_DATABASE_URL:'postgresql://palatis@localhost/ritc_b11_ops019_20261103?host=%2Ftmp&port=55432',
 TEST_WORKER_DATABASE_URL:'postgresql://ritc_b11_ops019_worker_20261103@localhost/ritc_b11_ops019_20261103?host=%2Ftmp&port=55432'
};
const cases=[
 {name:'auth-operations',args:['scripts/test-operations.mjs'],env:{...common,OPERATIONS_TEST_DATABASE_URL:urls.TEST_DATABASE_URL,OPERATIONS_TEST_ADMIN_DATABASE_URL:urls.TEST_ADMIN_DATABASE_URL,TEST_WORKER_DATABASE_URL:urls.TEST_WORKER_DATABASE_URL}},
 {name:'privacy-integration',args:['--test','tests/privacy.integration.mjs'],env:{...common,...urls}},
 // This committed harness uses shared ritc_test_worker against only the owned DB.
 {name:'store-quotes-integration',args:['--test','tests/shared-store-quotes.integration.mjs'],env:{...common,...urls}},
 {name:'measurement-integration',args:['--test','tests/measurement.integration.mjs'],env:{...common,...urls}},
 {name:'quote-measurement-pure',args:['--test','tests/shared-store-quotes-math.test.mjs','tests/measurement.test.mjs'],env:common}
];
await writeFile(new URL('committed-test-commands.json',import.meta.url),JSON.stringify(cases,null,2)+'\n');
const results=[];
for(const task of cases){
 const log=await open(new URL(task.name+'.log',import.meta.url),'w');
 const startedAt=new Date().toISOString();
 const result=await new Promise((resolve,reject)=>{
  const child=spawn(process.execPath,task.args,{cwd:service,env:task.env,stdio:['ignore',log.fd,log.fd]});
  child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}));
 });
 await log.close();results.push({name:task.name,startedAt,endedAt:new Date().toISOString(),...result});
 await writeFile(new URL('committed-test-results.json',import.meta.url),JSON.stringify(results,null,2)+'\n');
 console.log(task.name,JSON.stringify(result));
 if(result.code!==0)throw Error('Committed test failed: '+task.name);
}
