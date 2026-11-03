// Isolated UI protocol fixture. Never imported by production code; no provider,
// SMTP, credentials, external accounts, callbacks or database are used.
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
export const fixtureInput=Object.freeze({token:'11111111-1111-4111-8111-111111111111.22222222-2222-4222-8222-222222222222.'+'A'.repeat(43),email:'child@example.invalid',code:'123456'});
const hh='11111111-1111-4111-8111-111111111111',invite='22222222-2222-4222-8222-222222222222',claim='33333333-3333-4333-8333-333333333333',member='44444444-4444-4444-8444-444444444444',device='55555555-5555-4555-8555-555555555555',shop='66666666-6666-4666-8666-666666666666',expiry='2030-01-01T00:00:00.000Z';
const empty={available:true,authenticated:false,admitted:false,scope:null,householdId:null,inviteId:null,claimId:null,status:'none',expiresAt:null};
const cookieValues=header=>Object.fromEntries((header??'').split(';').map(part=>part.trim().split('=')));
export function createChildFixture({configured=false}={}) {
  const sessions=new Map(),requests=[],jar=new Map();let loss=null,wrongScope=false;
  const counts={starts:0,verifies:0,claimPosts:0,claims:0,finishPosts:0,finishes:0,ownReads:0,forbidden:0,exactClaimRetries:0,exactFinishRetries:0};
  const response=(status,body,headers={})=>({status,body,headers});
  const fail=(status,code)=>response(status,{error:{code}});
  function control(action){
    if(action==='reset'){sessions.clear();jar.clear();loss=null;wrongScope=false;}
    else if(action==='approve'){for(const session of sessions.values())if(session.status==='awaiting_guardian')session.status='approved';}
    else if(action==='withdraw'){for(const session of sessions.values())if(session.authenticated)session.status='ended';}
    else if(action==='generic'){for(const session of sessions.values()){session.authenticated=true;session.admitted=false;}}
    else if(action==='wrong-scope')wrongScope=true;
    else if(['lose-start','lose-verify','lose-claim','lose-finish','lose-finish-cookie','lose-finish-no-cookie-body'].includes(action))loss=action;
    else throw new Error('Unknown fixture control');
    return {fixtureOnly:true,action,counts:{...counts}};
  }
  async function handle(path,{method='GET',headers={},body}={}) {
    const parsed=new URL(path,'http://fixture.invalid'),cookies=cookieValues(headers.cookie),session=sessions.get(cookies.fixture_auth),csrf=headers['x-csrf-token'];
    let data;try{data=body?JSON.parse(body):undefined;}catch{return fail(422,'invalid_entry');}
    requests.push({path:parsed.pathname,method,body:data});
    if(parsed.pathname==='/v1/guardian/availability')return response(200,{available:configured,reason:configured?null:'provider_configuration_required'});
    if(parsed.pathname==='/v1/auth/session'&&method==='GET'){
      if(!configured)return response(200,{available:false,authenticated:false,csrf:null});
      if(session)return response(200,{available:true,authenticated:session.authenticated,csrf:session.csrf});
      const id=randomUUID(),row={csrf:randomUUID(),authenticated:false,admitted:false,status:'none',requested:false};sessions.set(id,row);
      return response(200,{available:true,authenticated:false,csrf:row.csrf},{'set-cookie':[`fixture_auth=${id}; Path=/; HttpOnly; SameSite=Strict`]});
    }
    if(parsed.pathname==='/v1/auth/session'&&method==='DELETE'){
      if(!session||csrf!==session.csrf)return fail(403,'csrf_failed');sessions.delete(cookies.fixture_auth);
      return response(200,{signedOut:true,providerRevoked:true},{'set-cookie':['fixture_auth=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0','fixture_scope=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0']});
    }
    if(parsed.pathname==='/v1/child-invitations/auth/start'&&method==='POST'){
      if(!configured)return fail(503,'consent_unavailable');
      if(!session||session.authenticated||csrf!==session.csrf)return fail(403,'csrf_failed');
      if(data?.token!==fixtureInput.token||data?.email?.trim().toLowerCase()!==fixtureInput.email)return fail(404,'unavailable');
      counts.starts++;session.requested=true;
      if(loss==='lose-start'){loss=null;return {drop:true};}
      return response(200,{status:'check_email'});
    }
    if(parsed.pathname==='/v1/auth/email/verify'&&method==='POST'){
      if(!session||session.authenticated||csrf!==session.csrf)return fail(403,'csrf_failed');
      if(!session.requested||data?.code!==fixtureInput.code)return fail(422,'code_not_accepted');
      counts.verifies++;sessions.delete(cookies.fixture_auth);const id=randomUUID(),next={...session,authenticated:true,admitted:true,status:'admitted',csrf:randomUUID()};sessions.set(id,next);
      const result=response(200,{available:true,authenticated:true,csrf:next.csrf},{'set-cookie':[`fixture_auth=${id}; Path=/; HttpOnly; SameSite=Strict`,'fixture_scope=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0']});
      if(loss==='lose-verify'){loss=null;return {...result,broken:true};}return result;
    }
    if(parsed.pathname==='/v1/child-invitations/session'&&method==='GET'){
      if(!session?.authenticated)return fail(401,'session_needed');
      if(!session.admitted)return response(200,{...empty,authenticated:true});
      return response(200,{available:configured,authenticated:true,admitted:configured&&session.status!=='ended',scope:configured&&session.status!=='ended'?'own_requests':null,householdId:hh,inviteId:invite,claimId:session.claimBody?claim:null,status:session.status,expiresAt:expiry});
    }
    if(parsed.pathname==='/v1/session'&&method==='GET'){
      if(!session?.authenticated||!cookies.fixture_scope||session.status!=='active')return response(200,{authenticated:false});
      return response(200,{authenticated:true,role:'contributor',household:{id:wrongScope?invite:hh,label:'Fixture household'},memberId:member,shopId:shop,replayWindow:{id:'77777777-7777-4777-8777-777777777777',expiresAt:expiry},csrf:'fixture-scoped-csrf',enrolled:true,queueConsent:false});
    }
    if(parsed.pathname==='/v1/child-invitations/claim'&&method==='POST'){
      counts.claimPosts++;if(!session?.authenticated||!session.admitted||csrf!==session.csrf)return fail(403,'child_signin_required');
      if(data?.token!==fixtureInput.token||!/^[A-Z2-7]{8}$/.test(data?.pairingCode??''))return fail(422,'invalid_entry');
      if(session.claimBody){if(session.claimBody!==body)return fail(409,'key_reused');counts.exactClaimRetries++;}
      else {session.claimBody=body;session.status='awaiting_guardian';counts.claims++;}
      if(loss==='lose-claim'){loss=null;return {drop:true};}
      return response(200,{householdId:hh,claimId:claim,status:'awaiting_guardian',expiresAt:expiry});
    }
    if(parsed.pathname.startsWith('/v1/child-invitations/claims/')&&method==='GET'){
      if(!session?.admitted||!session.claimBody||parsed.searchParams.get('householdId')!==hh)return fail(404,'unavailable');
      return response(200,{claimId:claim,status:session.status,expiresAt:expiry});
    }
    if(parsed.pathname==='/v1/child-invitations/finish'&&method==='POST'){
      counts.finishPosts++;if(!session?.admitted||!session.claimBody||csrf!==(cookies.fixture_scope?'fixture-scoped-csrf':session.csrf))return fail(403,'csrf_failed');
      if(!['approved','active'].includes(session.status)||data?.pairingCode!==JSON.parse(session.claimBody).pairingCode)return fail(409,'guardian_confirmation_needed');
      if(session.finishBody){if(session.finishBody!==body)return fail(409,'key_reused');counts.exactFinishRetries++;}
      else {session.finishBody=body;session.status='active';counts.finishes++;}
      if(loss==='lose-finish'){loss=null;return {drop:true};}
      // Accepted operation with a complete HTTP response but unusable JSON and
      // no scoped cookie. This avoids socket-level automatic retry in browsers.
      if(loss==='lose-finish-no-cookie-body'){loss=null;return {...response(200,{}),broken:true};}
      const result=response(200,{householdId:hh,memberId:member,role:'contributor',deviceId:device},{'set-cookie':['fixture_scope=exact-finished-device; Path=/; HttpOnly; SameSite=Strict']});
      if(loss==='lose-finish-cookie'){loss=null;return {...result,broken:true};}return result;
    }
    if(parsed.pathname===`/v1/households/${hh}/requests/mine`&&method==='GET'&&session?.status==='active'&&cookies.fixture_scope){counts.ownReads++;return response(200,{requests:[],nextCursor:null});}
    counts.forbidden++;return fail(404,'unavailable');
  }
  function applyCookies(headers){for(const line of headers['set-cookie']??[]){const [name,value]=line.split(';')[0].split('=');if(value)jar.set(name,value);else jar.delete(name);}}
  const fetcher=async(path,options={})=>{
    const result=await handle(path,{...options,headers:{...Object.fromEntries(new Headers(options.headers)),cookie:[...jar].map(([key,value])=>`${key}=${value}`).join('; ')}});
    if(result.drop)throw new TypeError('Fixture lost response');applyCookies(result.headers??{});
    return result.broken?new Response('{',{status:200,headers:{'Content-Type':'application/json'}}):Response.json(result.body,{status:result.status});
  };
  return {handle,fetcher,control,counts,requests};
}

async function serve(){
  const configured=process.argv.includes('--configured'),fixture=createChildFixture({configured}),build=resolve(dirname(fileURLToPath(import.meta.url)),'../../public-build');
  const server=createServer(async(req,res)=>{
    try {
      const path=new URL(req.url,'http://127.0.0.1').pathname;
      if(path.startsWith('/v1/')){
        const chunks=[];for await(const chunk of req){chunks.push(chunk);if(Buffer.concat(chunks).length>8192){res.writeHead(413).end();return;}}
        const result=await fixture.handle(req.url,{method:req.method,headers:req.headers,body:Buffer.concat(chunks).toString()});
        if(result.drop){req.socket.destroy();return;}
        res.writeHead(result.status,{'Content-Type':'application/json','Cache-Control':'no-store',...result.headers});res.end(result.broken?'{':JSON.stringify(result.body));return;
      }
      const target=path.startsWith('/assets/')?resolve(build,'.'+path):resolve(build,'index.html');
      if(!target.startsWith(build+'/')){res.writeHead(404).end();return;}
      res.writeHead(200,{'Content-Type':target.endsWith('.js')?'text/javascript':target.endsWith('.css')?'text/css':'text/html','Cache-Control':'no-store','Referrer-Policy':'no-referrer'});res.end(await readFile(target));
    }catch{res.writeHead(500).end('Fixture failure');}
  });
  server.listen(4188,'127.0.0.1',()=>process.stdout.write(JSON.stringify({fixtureOnly:true,configured,origin:'http://127.0.0.1:4188'})+'\n'));
  let input='';process.stdin.setEncoding('utf8');process.stdin.on('data',chunk=>{input+=chunk;let end;while((end=input.indexOf('\n'))>=0){const command=input.slice(0,end).trim();input=input.slice(end+1);if(command)process.stdout.write(JSON.stringify(fixture.control(command))+'\n');}});
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url))await serve();
