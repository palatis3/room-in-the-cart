import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { runNativeWireTest } from './run-native-wire-test.mjs';

const run = promisify(execFile);

// A fixture identity provider returns one real signed test JWT. Household requests
// keep their original headers and body and go through the normal API and database.
export async function exerciseSharedMealClient({service, owner, householdId, shopId, shopper, beforeFallbackReplay, undated, removal}) {
  const dir = await mkdtemp(join(tmpdir(), 'ritc-native-wire-'));
  const key = join(dir, 'tls.key'), cert = join(dir, 'tls.pem'), code = randomUUID();
  let tls;
  let fallbackCommands = 0;
  let commandAttempts = 0;
  const fallback = !!beforeFallbackReplay;
  const unsuccessful = [];
  try {
    const config = join(dir, 'openssl.cnf');
    await writeFile(config, '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n');
    await run('openssl', ['req','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','1','-config',config,'-keyout',key,'-out',cert]);
    const der = join(dir, 'tls.der');
    await run('openssl',['x509','-in',cert,'-outform','DER','-out',der]);
    const user = { id:owner.subject, email:'wire@example.invalid', email_confirmed_at:new Date().toISOString() };
    tls = createServer({key:await readFile(key),cert:await readFile(cert)}, async (req,res) => {
      if (!req.url.startsWith('/auth/v1/')) {
        if (req.method === 'POST' && req.url.endsWith('/commands')) commandAttempts++;
        res.once('finish',()=>{
          if(res.statusCode>=400) unsuccessful.push([req.method,req.url.split('?')[0].replace(/[a-f\d-]{36}/gi,'{id}'),res.statusCode].join(' '));
        });
        if (fallback && req.method === 'POST' && req.url.endsWith('/commands') && ++fallbackCommands === 2) {
          try { await beforeFallbackReplay(); }
          catch { res.writeHead(500); res.end(); return; }
        }
        service.emit('request',req,res); return;
      }
      res.setHeader('Content-Type','application/json');
      if (req.method==='POST' && req.url==='/auth/v1/verify') {
        let raw=''; for await(const chunk of req) raw+=chunk;
        if(JSON.parse(raw).token===code) {
          res.end(JSON.stringify({access_token:owner.token,refresh_token:randomUUID(),expires_in:3600,user})); return;
        }
      }
      if(req.method==='GET' && req.url==='/auth/v1/user' && req.headers.authorization==='Bearer '+owner.token) {
        res.end(JSON.stringify(user)); return;
      }
      res.writeHead(401); res.end('{}');
    });
    await new Promise((resolve,reject)=>tls.once('error',reject).listen(0,'127.0.0.1',resolve));
    await runNativeWireTest({
      suite: 'SharedMealNativeWireTests', method: 'testSharedMealClientAgainstPostgres',
      scenario: removal ? 'meal-removal-' + removal.phase : undated ? 'meal-undated-' + undated.phase : fallback ? 'meal-fallback' : shopper ? 'meal-shopper' : 'meal-planner', unsuccessful,
      env:{...(removal ? {RITC_WIRE_REMOVAL_PHASE:removal.phase,RITC_WIRE_REMOVAL_EXPECTED:JSON.stringify(removal.expected)} : {}),
        ...(undated ? {RITC_WIRE_UNDATED_PHASE:undated.phase,RITC_WIRE_UNDATED_IDS:JSON.stringify(undated.ids)} : {}),
        RITC_WIRE_PORT:String(tls.address().port),RITC_WIRE_CERT:der,RITC_WIRE_CODE:code,
        RITC_WIRE_FALLBACK:fallback?"1":"0",RITC_WIRE_SHOPPER:shopper?"1":"0",RITC_WIRE_HOUSEHOLD:householdId,RITC_WIRE_SHOP:shopId},
    });
    return {commandAttempts};
  } finally {
    if(tls?.listening) await new Promise(resolve=>tls.close(resolve));
    await rm(dir,{recursive:true,force:true});
  }
}
