// Isolated synthetic authority only. Importing this module does not listen or write.
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
export const sha = value => createHash('sha256').update(value).digest('hex');
export const markers = Object.freeze({ownA:'SAFARI_OWN_A_7d91',ownB:'SAFARI_OWN_B_f51e',draftA:'SAFARI_DRAFT_A_bf31',queued:'SAFARI_QUEUE_OATS_4101'});
const grants={A:'4f14be8f-efc9-48c4-af14-cb09a8489f38',B:'6d2c640e-c568-4514-87ac-00ea85f83afb'};
const row=(actor,item,id='initial-'+actor)=>({requestId:id,shopId:'shop-'+actor,revision:1,originalItem:item,ownQuantity:null,authoredAt:'2026-11-08T00:00:00Z',receivedAt:'2026-11-08T00:00:01Z',route:'current',status:'pending',ownActionAllowed:true,clarification:null,followupTo:null});
export function createFixture({profile='history',cache='private, max-age=0'}={}) {
 assert(['history','queue'].includes(profile));assert(['private, max-age=0','no-store'].includes(cache));
 const state={actor:'A',offline:false,hold:false,queueAllowed:true,commandMode:'normal',phase:'initial'};
 const enabled={A:false,B:false},rows={A:[],B:[]},operations=new Map(),attempts=[],events=[],held=[];
 if(profile==='history')for(const actor of ['A','B'])rows[actor].push(row(actor,markers['own'+actor]));
 let sequence=0;
 const record=(kind,details={})=>{assert(events.length<2000,'fixture event limit');events.push({seq:++sequence,phase:state.phase,kind,...details});};
 const response=(status,body)=>({status,body});const fail=(status,code)=>response(status,{error:{code}});
 const session=()=>({authenticated:true,role:'contributor',household:{id:state.actor,label:'Fictional Safari household '+state.actor},memberId:'member-'+state.actor,shopId:'shop-'+state.actor,csrf:'fixture-csrf-'+state.actor,enrolled:true,queueConsent:enabled[state.actor]===true,replayWindow:{id:'window-'+state.actor,expiresAt:'2099-01-01T00:00:00Z'},capabilities:['own_requests',...(state.queueAllowed?['request_queue_permission']:[])],...(state.queueAllowed&&enabled[state.actor]?{requestQueueGrant:grants[state.actor],requestQueueUntil:new Date(Date.now()+86400000).toISOString()}: {})});
 function control(c) {
  assert(c&&typeof c==='object'&&!Array.isArray(c));
  assert(Object.keys(c).every(k=>['actor','offline','hold','queueAllowed','commandMode','phase'].includes(k)),'unknown control');
  if('actor'in c)assert(['A','B','revoked','expired'].includes(c.actor));
  for(const k of ['offline','hold','queueAllowed'])if(k in c)assert.equal(typeof c[k],'boolean');
  if('commandMode'in c)assert(['normal','dropBefore','dropAfter'].includes(c.commandMode));
  if('phase'in c)assert.match(c.phase,/^[a-z0-9-]{1,48}$/);
  Object.assign(state,c);record('control',c);
  if(!state.hold)while(held.length)held.shift()();
 }
 async function handle(path,{method='GET',headers={},body=''}={}) {
  record('request',{method,path});
  if(path==='/v1/session'&&method==='GET') {
   if(state.hold){record('authority-held');await new Promise(resolve=>held.push(resolve));}
   if(state.offline){record('authority-drop');return {drop:true};}
   if(state.actor==='revoked')return fail(403,'access_ended');
   if(state.actor==='expired')return fail(401,'session_needed');
   return response(200,session());
  }
  if(path==='/v1/auth/session'&&method==='GET')return response(200,{available:true,authenticated:false,csrf:'synthetic-auth-only'});
  if(!['A','B'].includes(state.actor))return fail(403,'access_ended');
  if(state.offline)return {drop:true};
  const actor=state.actor;
  if(path===`/v1/households/${actor}/requests/mine`&&method==='GET')return response(200,{requests:rows[actor],nextCursor:null});
  if(method!=='GET'&&headers['x-csrf-token']!=='fixture-csrf-'+actor)return fail(403,'csrf_failed');
  if(path==='/v1/session'&&method==='DELETE') {state.actor='expired';record('logout-effect');return response(200,{signedOut:true,providerRevoked:true});}
  let data;try{data=body?JSON.parse(body):null;}catch{return fail(422,'invalid_entry');}
  if(path===`/v1/households/${actor}/devices/current/request-queue`&&method==='PUT') {
   if(!state.queueAllowed||typeof data?.enabled!=='boolean'||Object.keys(data).length!==1)return fail(403,'access_ended');
   enabled[actor]=data.enabled;record('queue-permission',{enabled:data.enabled});return response(200,session());
  }
  if(path===`/v1/households/${actor}/commands`&&method==='POST') {
   const digest=sha(body);attempts.push({actor,digest,key:data?.clientKey??null,grant:headers['x-request-queue-grant']??null});record('command-attempt',{digest});
   if(!state.queueAllowed||!enabled[actor]||headers['x-request-queue-grant']!==grants[actor])return fail(409,'queue_permission_ended');
   if(data?.v!==1||data.kind!=='request.send'||data.replayWindow!=='window-'+actor||data.shopId!=='shop-'+actor||data.base?.shopRevision!==0||data.base?.authorityEpoch!==0||typeof data.clientKey!=='string'||typeof data.body?.clientRequestId!=='string'||data.body.originalItem!==markers.queued||data.body.ownQuantity!==null||data.body.route!=='current'||!Number.isFinite(Date.parse(data.body.authoredAt)))return fail(422,'invalid_entry');
   const key=actor+'/'+data.clientKey,old=operations.get(key);
   if(old){if(old.body!==body)return fail(409,'key_reused');record('exact-retry',{digest});return response(200,old.receipt);}
   if(state.commandMode==='dropBefore'){record('command-before-effect-drop');return {drop:true};}
   const request={...row(actor,markers.queued,data.body.clientRequestId),authoredAt:data.body.authoredAt,receivedAt:new Date().toISOString()};
   const receipt={operationId:randomUUID(),kind:data.kind,request};rows[actor].push(request);operations.set(key,{body,receipt});record('command-effect',{digest});
   if(state.commandMode==='dropAfter'){state.commandMode='normal';record('command-after-effect-drop');return {drop:true};}
   return response(200,receipt);
  }
  return fail(404,'fixture_route_unavailable');
 }
 return {handle,control,cache,markers,snapshot:()=>({profile,cache,state:{...state},pendingAuthority:held.length,counts:{commandAttempts:attempts.length,commandEffects:operations.size,rowsA:rows.A.length,rowsB:rows.B.length},attempts:[...attempts],events:[...events]})};
}
