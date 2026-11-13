// Execution is root-owned after review. Syntax checks/importing other modules never listen.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {join} from 'node:path';
import {createInterface} from 'node:readline';
import {createFixture} from './fixture.mjs';
import {validateObservation} from './observation.mjs';
import {verifyPin,here} from './verify-pin.mjs';
assert.equal(process.argv[2],'--reviewed-local-safari-editor-foreground');assert.equal(process.argv.length,6);
const [profile,cacheFlag,caseName]=process.argv.slice(3);assert.equal(profile,'editor');assert.equal(cacheFlag,'eligible');assert.match(caseName,/^[a-z0-9-]{1,48}$/);
const manifest=await verifyPin(),fixture=createFixture({profile,cache:cacheFlag==='eligible'?'private, max-age=0':'no-store'});
const directory=join(here,'runs',caseName);await mkdir(directory,{recursive:false,mode:0o700});
const observations=[];let saveChain=Promise.resolve();let origin;
const save=()=>{const bytes=JSON.stringify({caseName,origin,manifestSHA:manifest.identity,fixture:fixture.snapshot(),observations},null,2)+'\n';saveChain=saveChain.then(()=>writeFile(join(directory,'receipt.json'),bytes,{mode:0o600}));return saveChain;};
const server=createServer(async(req,res)=>{
 try {
  if(req.headers.host!==new URL(origin).host||req.headers.origin&&req.headers.origin!==origin){res.writeHead(403).end();return;}
  const url=new URL(req.url,origin),path=url.pathname;
  // Count/reject every non-GET except the diagnostic observation endpoint, before
  // parsing query/body. Request bodies are deliberately not retained by this fixture.
  if(req.method!=='GET'&&path!=='/__fixture/observation'){
   const result=await fixture.handle(path,{method:req.method,body:''});await save();req.resume();
   res.writeHead(result.status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(result.body));return;
  }
  if(url.search){res.writeHead(400).end();return;}
  if(path.startsWith('/v1/')||path==='/__fixture/observation'){
   const chunks=[];let size=0;for await(const c of req){size+=c.length;if(size>131072){res.writeHead(413).end();return;}chunks.push(c);}const body=Buffer.concat(chunks).toString();
   if(path==='/__fixture/observation'){assert.equal(req.method,'POST');assert(observations.length<100);const value=validateObservation(JSON.parse(body));const facts=fixture.snapshot();observations.push({phase:facts.state.phase,serverCounts:facts.counts,serverAttempts:facts.attempts,pendingAuthority:facts.pendingAuthority,...value});await save();res.writeHead(204,{'Cache-Control':'no-store'}).end();return;}
   const resultPromise=fixture.handle(path,{method:req.method,headers:req.headers,body});await save();const result=await resultPromise;await save();if(result.drop){req.socket.destroy();return;}
   res.writeHead(result.status,{'Content-Type':'application/json','Cache-Control':'no-store','Referrer-Policy':'no-referrer'});res.end(JSON.stringify(result.body));return;
  }
  if(req.method!=='GET'){res.writeHead(405).end();return;}
  if(path==='/neutral'){res.writeHead(404).end();return;}
  if(path==='/__fixture/probe.js'){res.writeHead(200,{'Content-Type':'text/javascript','Cache-Control':'no-store'});res.end(await readFile(join(here,'probe.js')));return;}
  const file=path==='/view'?'index.html':path.slice(1);if(!Object.hasOwn(manifest.bundle,file)){res.writeHead(404).end();return;}
  let bytes=await readFile(join(here,'bundle',file));if(file==='index.html'){const original=bytes.toString();assert.equal(original.split('</head>').length,2);bytes=Buffer.from(original.replace('</head>','<script src="/__fixture/probe.js"></script></head>'));}
  res.writeHead(200,{'Content-Type':file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':file.endsWith('.png')?'image/png':'text/html','Cache-Control':file==='index.html'?fixture.cache:'no-store','Referrer-Policy':'no-referrer'});res.end(bytes);
 }catch{if(!res.headersSent)res.writeHead(422);res.end();}
});
// Avoid transparent transport replay of a dropped POST on a reused socket.
server.maxRequestsPerSocket=1;
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;await save();console.log(JSON.stringify({status:'listening',origin,caseName,pid:process.pid}));
const input=createInterface({input:process.stdin});
async function stop(){fixture.control({hold:false});input.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await save();console.log(JSON.stringify({status:'stopped',caseName}));}
input.on('line',line=>{Promise.resolve().then(async()=>{if(line==='inspect'){await save();console.log(JSON.stringify(fixture.snapshot().counts));}else if(line==='stop'){await stop();}else{fixture.control(JSON.parse(line));await save();console.log(JSON.stringify({status:'controlled',state:fixture.snapshot().state}));}}).catch(()=>console.log(JSON.stringify({status:'control-rejected'})));});
process.once('SIGINT',()=>void stop());process.once('SIGTERM',()=>void stop());
