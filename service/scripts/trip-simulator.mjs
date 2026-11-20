// Start a disposable, two-adult native development fixture. No external database or issuer is accepted.
import {randomBytes,randomUUID} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mkdtemp,rm,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createServer as portProbe} from 'node:net';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import pg from 'pg';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from 'jose';
import {HouseholdRepository} from '../dist/repository.js';
import {createHTTPServer} from '../dist/http.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../dist/auth.js';
import {assertRuntimeRole} from '../dist/database.js';
import {migrate} from './migrate.mjs';

process.umask(0o077);
const host='127.0.0.1',baseURL='http://'+host+':48762',issuer='https://trip-simulator.fixture.invalid';
const directory=await mkdtemp(join(tmpdir(),'ritc-trip-simulator-')),data=join(directory,'postgres');
const password=randomBytes(24).toString('base64url'),pwfile=join(directory,'password');
const servers=[],pools=[];
let pgStarted=false;
async function listen(server,port){
  await new Promise((resolve,reject)=>{
    server.once('error',reject);
    server.listen(port,host,()=>{server.removeListener('error',reject);resolve();});
  });
  servers.push(server);
}
async function stop(){
  for(const server of servers.splice(0))await new Promise(resolve=>server.close(resolve));
  await Promise.all(pools.splice(0).map(pool=>pool.end()));
  if(pgStarted){execFileSync('pg_ctl',['-D',data,'-m','fast','-w','stop'],{stdio:'ignore'});pgStarted=false;}
  await rm(directory,{recursive:true,force:true});
}
let done;
const ended=new Promise(resolve=>{done=resolve;});
process.once('SIGINT',done);process.once('SIGTERM',done);

try {
  await writeFile(pwfile,password);
  const probe=portProbe();await listen(probe,0);const port=probe.address().port;
  await new Promise(resolve=>probe.close(resolve));servers.pop();
  execFileSync('initdb',['-D',data,'--username=postgres','--pwfile='+pwfile,'--auth=scram-sha-256','--locale=C','--encoding=UTF8'],{stdio:'ignore'});
  execFileSync('pg_ctl',['-D',data,'-l',join(directory,'postgres.log'),'-w','start','-o',`-h 127.0.0.1 -p ${port} -c unix_socket_directories=''`],{stdio:'ignore'});
  pgStarted=true;
  const target=host+':'+port+'/ritc_trip_simulator',adminURL='postgresql://postgres:'+password+'@'+target;
  execFileSync('createdb',['-h',host,'-p',String(port),'-U','postgres','ritc_trip_simulator'],{env:{...process.env,PGPASSWORD:password},stdio:'ignore'});
  const admin=new pg.Pool({connectionString:adminURL});pools.push(admin);
  await admin.query('CREATE SCHEMA auth; CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz); CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz)');
  await migrate(adminURL);
  const runtimePassword=randomBytes(24).toString('hex');
  await admin.query(`CREATE ROLE trip_runtime LOGIN NOSUPERUSER NOBYPASSRLS IN ROLE ritc_app PASSWORD '${runtimePassword}'`);
  const runtime=new pg.Pool({connectionString:'postgresql://trip_runtime:'+runtimePassword+'@'+target});pools.push(runtime);
  await assertRuntimeRole(runtime);
  const {privateKey,publicKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='simulator';
  const repository=new HouseholdRepository(runtime,{allowChildNetwork:false,noticeVersion:'local',trackingV2:true,tripSubstitutions:true,sharedPicking:true,
    sharedContentSafety:true,moderationRetentionDays:7,sessionStatus:new SupabaseSessionVerifier(issuer)});
  const verifier=new JWTIdentityVerifier({issuer,audience:'authenticated',jwksUrl:issuer+'/jwks'},createLocalJWKSet({keys:[jwk]}));
  await listen(createHTTPServer({repository,verifier,maxRequestsPerMinute:2000}),48762);

  const householdId=randomUUID(),shopId=randomUUID(),lineId=randomUUID(),roles={};
  const expiresAt=new Date(Math.floor(Date.now()/1000)*1000+4*3600_000).toISOString();
  await admin.query("INSERT INTO ritc.household(household_id,label) VALUES($1,'Practice household')",[householdId]);
  for(const [role,alias] of [['shopper','Mia'],['requester','Alex']]){
    const subject=randomUUID(),sessionId=randomUUID(),memberId=randomUUID();
    const accessToken=await new SignJWT({session_id:sessionId}).setProtectedHeader({alg:'ES256',kid:jwk.kid})
      .setIssuer(issuer).setSubject(subject).setAudience('authenticated').setIssuedAt().setExpirationTime(Date.parse(expiresAt)/1000).sign(privateKey);
    await admin.query(`INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute)
      VALUES($1,$2,$3,$4,$5,'adult','active',$6,true)`,[householdId,memberId,issuer,subject,alias,role==='shopper']);
    await admin.query('INSERT INTO auth.sessions(id,user_id,not_after) VALUES($1,$2,$3)',[sessionId,subject,expiresAt]);
    const device=await repository.enroll(householdId,await verifier.verify(accessToken));
    roles[role]={baseURL,householdId,shopId,memberId,deviceId:device.deviceId,deviceToken:device.deviceToken,accessToken,issuer,subject,sessionId,expiresAt,lineId};
  }
  async function requestJSON(role,path,body){
    const actor=roles[role];
    const response=await fetch(baseURL+'/v1/households/'+householdId+path,{method:body===undefined?'GET':'POST',
      headers:{Authorization:'Bearer '+actor.accessToken,'X-Device-Token':actor.deviceToken,'Content-Type':'application/json'},body:JSON.stringify(body)});
    if(!response.ok){const detail=await response.json();throw Error('Could not seed '+path+' ('+response.status+', '+detail.error?.code+')');}
    return response.json();
  }
  async function command(role,kind,body,base={shopRevision:0,authorityEpoch:0}){
    const window=await requestJSON(role,'/replay-windows',{});
    return requestJSON(role,'/commands',{v:1,replayWindow:window.id,clientKey:randomUUID(),shopId,kind,base,body});
  }
  const basket={quote:{currency:'USD',scope:'wholeCheckout',complete:true,capMinor:4000,capScope:'wholeCheckout',
    fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:new Date().toISOString(),expiresAt},
    lines:[{lineId,originalItem:'Brown rice 1 lb',packs:1,feeEligible:true,unitPriceMinor:225},
      {lineId:randomUUID(),originalItem:'Canned black beans',packs:3,feeEligible:true,unitPriceMinor:125}]};
  await command('shopper','shop.create',basket);
  // Save a normal candidate, disclosure and shopper acknowledgment for the native freeze review.
  const path='/shops/'+shopId+'/demand/tracking',page=await requestJSON('shopper',path);
  const base={shopRevision:page.shopRevision,authorityEpoch:page.authorityEpoch};
  const quantity=n=>({amount:{numerator:String(n),denominator:'1'},unit:'count',originalLiteral:n+' packs',confirmedConversion:null});
  const candidate=await requestJSON('shopper',path+'/candidates',{
    mode:'adopt',base:{...base,graphRevision:page.state.graph.revision,stateDigest:page.basisDigest},
    change:{lines:basket.lines.map((row,index)=>({id:row.lineId,name:row.originalItem,unit:'count',originalOrder:index,trashedAt:null})),
      contributions:basket.lines.map(row=>({id:randomUUID(),lineId:row.lineId,source:{kind:'manual'},productKey:null,
        productName:row.originalItem,originalText:row.originalItem,quantity:quantity(row.packs),exclusions:[],contains:[],removedAt:null})),
      edges:[],removeSourceIds:[],removeEdgeIds:[]},
    action:{kind:'shop.patch',body:basket},packs:basket.lines.map(row=>({lineId:row.lineId,usablePerPack:quantity(1),acceptUnresolved:false}))
  });
  const review=await requestJSON('shopper',path+'/previews',{candidateId:candidate.candidateId,candidateDigest:candidate.candidateDigest,
    acknowledgedDisclosure:candidate.disclosure,acceptOverage:false,acceptUnknown:false});
  await command('shopper',review.action.kind,{...review.action.body,demandReview:{
    trackingVersion:2,previewId:review.previewId,previewDigest:review.previewDigest}},base);
  if(!(await requestJSON('shopper',path)).freezeReview)throw Error('Fixture lacks a reviewed checkout');
  const {request}=await command('requester','request.send',{clientRequestId:randomUUID(),originalItem:'Oat milk 1 L',ownQuantity:'one carton',authoredAt:new Date().toISOString()});
  for(const actor of Object.values(roles))actor.requestId=request.requestId;

  await listen(createServer((req,res)=>{
    const role=/^\/fixture\/(shopper|requester)$/.exec(req.url??'')?.[1];
    // A native simulator talks directly to loopback. Reject browser origins and DNS-rebound hosts.
    if(!role||req.method!=='GET'||req.headers.host!=='127.0.0.1:48761'||req.headers.origin||req.headers['sec-fetch-site']){
      res.writeHead(404);res.end();return;
    }
    res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
    res.end(JSON.stringify(roles[role]));
  }),48761);
  console.log('Trip simulator ready on 127.0.0.1. Shopper and requester sessions expire at '+expiresAt+'. Stop with Ctrl-C.');
  await ended;
}finally{await stop();}
