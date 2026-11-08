// Offline-safe synthetic editor authority. Importing never listens or writes.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
export const sha=value=>createHash('sha256').update(value).digest('hex');
export const markers=Object.freeze({household:'SAFARI_EDITOR_HOUSEHOLD_783a',shop:'SAFARI_EDITOR_SHOP_249d',item:'SAFARI_COOK_WRAP_b038',amount:'6 wraps',action:'SAFARI_SAVE_TWO_LUNCHES_18ac',suggestion:'SAFARI_RECEIVED_SUGGESTION_e134',draft:'SAFARI_UNSENT_CORRECTION_b7e2',budget:'FORBIDDEN_BUDGET_d539',otherShop:'FORBIDDEN_OTHER_SHOP_6e30'});
export const ids=Object.freeze({household:'editor-household',member:'editor-member',shop:'editor-shop',grant:'editor-grant',proposal:'received-proposal'});
export function createFixture({profile='editor',cache='private, max-age=0'}={}){
 assert.equal(profile,'editor');assert.equal(cache,'private, max-age=0');
 const state={actor:'A',hold:false,phase:'initial'},events=[],held=[],attempts=[];let sequence=0,forbiddenResponseCount=0;
 const record=(kind,details={})=>{assert(events.length<2000,'fixture event limit');events.push({seq:++sequence,phase:state.phase,kind,...details});};
 const response=(status,body)=>{const wire=JSON.stringify(body),forbidden=wire.includes(markers.budget)||wire.includes(markers.otherShop);if(forbidden)forbiddenResponseCount++;record('response',{status,forbidden});return {status,body};};
 const fail=(status,code)=>response(status,{error:{code}});
 function control(c){assert(c&&typeof c==='object'&&!Array.isArray(c));assert(Object.keys(c).every(k=>['actor','hold','phase'].includes(k)),'unknown control');if('actor'in c)assert(['A','revoked'].includes(c.actor));if('hold'in c)assert.equal(typeof c.hold,'boolean');if('phase'in c)assert(['initial','held','final'].includes(c.phase));Object.assign(state,c);record('control',c);if(!state.hold)while(held.length)held.shift()();}
 const session=()=>({authenticated:true,role:'editor',household:{id:ids.household,label:markers.household},memberId:ids.member,shopId:ids.shop,grantId:ids.grant,csrf:'synthetic-editor-csrf',enrolled:true,queueConsent:false,replayWindow:{id:'editor-window',expiresAt:'2099-01-01T00:00:00Z'}});
 // Private values exist only in server fixture state; projection constructors never serialize them.
 const privateRecord={budget:markers.budget,otherShop:markers.otherShop};
 async function handle(path,{method='GET',body=''}={}){
  record('request',{method,path});
  if(method!=='GET'){attempts.push({method,path,digest:sha(body)});record('write-rejected',{method,path});return fail(405,'fixture_read_only');}
  if(path==='/v1/session'){
   if(state.hold){record('authority-held');await new Promise(resolve=>held.push(resolve));}
   if(state.actor==='revoked')return fail(403,'access_ended');return response(200,session());
  }
  if(path==='/v1/auth/session')return response(200,{available:false,authenticated:false,csrf:null});
  if(state.actor!=='A')return fail(403,'access_ended');
  if(path===`/v1/views/${ids.grant}/current`)return response(200,{grantId:ids.grant,shopId:ids.shop,shopLabel:markers.shop,revision:7,asOf:'2026-11-08T12:00:00Z',expiresAt:'2099-01-01T00:00:00Z',language:'en',mode:'edit',canPropose:true,items:[{label:markers.item,amount:'6',unit:'wraps',action:markers.action}]});
  if(path===`/v1/views/${ids.grant}/proposals`)return response(200,{proposals:[{proposalId:ids.proposal,grantId:ids.grant,baseRevision:6,proposalRevision:1,correction:markers.suggestion,status:'pending',createdAt:'2026-11-08T11:00:00Z',resolution:null}],nextCursor:null});
  return fail(403,'access_ended');
 }
 return {handle,control,cache,markers,snapshot:()=>({profile,cache,state:{...state},pendingAuthority:held.length,counts:{commandAttempts:attempts.length,commandEffects:0,forbiddenResponseCount},attempts:[...attempts],events:[...events],privateCanariesPresent:privateRecord.budget===markers.budget&&privateRecord.otherShop===markers.otherShop})};
}
