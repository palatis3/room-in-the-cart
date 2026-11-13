import {assertPriceOnly} from '../dist/shared-demand-repository.js';
import {assertTrackingV1} from '../dist/shared-demand-tracking-repository.js';
import test from 'node:test';
import assert from 'node:assert/strict';
import {readTracking,createTrackingCandidate,acceptTrackingCandidate,stageV1Tracking} from '../dist/shared-demand-tracking-repository.js';
import {digest} from '../dist/database.js';
import {mealDemandSources} from '../dist/shared-demand-sources.js';
import {validateState} from '../dist/shared-demand-tracking.js';
import {digest as trackingDigest} from '../dist/shared-demand-tracking.js';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
function fixture(){
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:500,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:'2026-11-10T11:00:00Z',expiresAt:'2026-11-10T13:00:00Z'},shop={shop_id:id(2),revision:1,authority_epoch:1,quote,demand_revision:null,demand_review_required:false};
 let stored=null,projectionRow=null,privacy=0,storeLive=true;const lines=[{lineId:id(4),originalItem:'Wraps',packs:2,unitPriceMinor:100,feeEligible:true}];
 const repo={options:{trackingV2:true},requireShopper(ctx){if(ctx.member.member_id!==id(3))throw Error('not shopper');},requireDraft(){},checkBase(s,b){assert.equal(b.shopRevision,s.revision);assert.equal(b.authorityEpoch,s.authority_epoch);},async meals(){return[];},async lines(){return structuredClone(lines);},async consent(){}};
 const ctx={householdId:id(1),deviceId:id(5),member:{member_id:id(3)},now:new Date('2026-11-10T12:00:00Z'),db:{async query(sql,args){
  if(sql.startsWith('SELECT graph,graph_digest,receipt'))return{rows:projectionRow?.state?[{graph:projectionRow.state.graph,graph_digest:digest(projectionRow.state.graph),receipt:null}]:[]};
  if(sql.startsWith('SELECT a.revision,a.pair_id'))return{rows:storeLive?[{revision:shop.store_basis_revision,pair_id:id(30),choice:'first',selected:{store:'Selected store',checkoutMinor:200}}]:[]};
  if(sql.startsWith('SELECT * FROM ritc.shared_tracking_revision'))return{rows:projectionRow?[projectionRow]:[]};
  if(sql.includes('SELECT tracking_privacy_revision'))return{rows:[{tracking_privacy_revision:privacy}]};
  if(sql.startsWith('SELECT count(*)'))return{rows:[{n:0}]};
  if(sql.startsWith('INSERT INTO ritc.shared_tracking_preview')){stored={preview_id:args[2],operation_id:args[3],actor_id:args[4],device_id:args[5],authority_epoch:args[6],shop_revision:args[7],intent:args[8],candidate_digest:args[9],created_at:args[10],expires_at:args[11],accepted_digest:null};return{rows:[]};}
  if(sql.startsWith('SELECT * FROM ritc.shared_tracking_preview'))return{rows:stored?[stored]:[]};
  if(sql.startsWith('UPDATE ritc.shared_tracking_preview')){stored.accepted_digest=args[2];stored.review=args[3];return{rows:[]};}
  if(sql.startsWith('SELECT ')||sql.startsWith('DELETE FROM ritc.shared_tracking_preview'))return{rows:[]};throw Error('Unexpected fixture query');
 }}};
 return{shop,repo,ctx,lines,stored:()=>stored,setState(value){projectionRow={state:value,state_digest:trackingDigest(value),projection:null,authority_epoch:1,privacy_revision:0,review:null};},revokeStore(){storeLive=false;},setProjection(value){projectionRow=value;privacy=value.projection.state.privacyRevision;}};
}
const base=p=>({shopRevision:p.shopRevision,authorityEpoch:p.authorityEpoch,graphRevision:p.state.graph.revision,stateDigest:p.basisDigest});
async function candidate(f,edit={}){const p=await readTracking(f.repo,f.ctx,f.shop),after={...f.lines[0],...edit.line},quote={...f.shop.quote,...edit.quote};return createTrackingCandidate(f.repo,f.ctx,f.shop,{mode:'adopt',base:base(p),change:{lines:[{id:id(4),name:'Wraps',unit:'count',originalOrder:0,trashedAt:null}],contributions:[{id:id(6),lineId:id(4),source:{kind:'manual'},productKey:null,productName:'Wraps',originalText:'Unknown original amount',quantity:null,exclusions:[],contains:[],removedAt:null}],edges:[],removeSourceIds:[],removeEdgeIds:[]},action:{kind:'shop.patch',body:{quote,lines:[after]}},packs:[{lineId:id(4),usablePerPack:null,acceptUnresolved:true}]});}

async function partial(){const f=fixture(),c=await candidate(f),meal={title:'Protected lunch',day:null,kind:'lunch',portions:2,protected:true,planning:{groups:[],ingredients:[{id:id(42),name:'Unknown wraps',quantity:null,groupIds:[],exclusions:[]}]}};f.repo.meals=async()=>[{occurrenceId:id(41),revision:1,meal}];const catalog=mealDemandSources(f.shop.shop_id,await f.repo.meals()).map(({productName,...v})=>({...v,revision:1}));const state=validateState({...c.after,catalog,unbound:catalog.map(x=>({factId:x.id,transferred:null})),bindings:[]},catalog);f.shop.demand_revision=1;f.shop.store_basis_revision=2;f.shop.store_review_required=true;f.shop.revision=2;f.setState(state);return{...f,state};}
async function reviewInput(f){const p=await readTracking(f.repo,f.ctx,f.shop);return{mode:'review',base:base(p),action:{kind:'shop.patch',body:{lines:f.lines.map(x=>({...x,unitPriceMinor:300})),quote:f.shop.quote,reviewedStoreBasisRevision:f.shop.store_basis_revision}},packs:f.state.packReviews};}
test('partial selected-store review preserves unknown protected identities and explicitly acknowledges checkout overage',async()=>{const f=await partial(),input=await reviewInput(f),c=await createTrackingCandidate(f.repo,f.ctx,f.shop,input);assert.deepEqual(c.after.unbound,f.state.unbound);assert.deepEqual(c.after.catalog,f.state.catalog);assert.deepEqual(c.after.graph.contributions,f.state.graph.contributions);assert.equal(c.disclosure.pickup.coverage.status,'partial');assert.equal(c.disclosure.money.after.totalMinor,600);await assert.rejects(()=>acceptTrackingCandidate(f.repo,f.ctx,f.shop,{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:c.disclosure}));const accepted=await acceptTrackingCandidate(f.repo,f.ctx,f.shop,{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:c.disclosure,acceptOverage:true,acceptUnknown:false});assert.equal(accepted.action.body.reviewedStoreBasisRevision,2);assert.equal(f.shop.store_review_required,true,'preview is not Apply');});
for(const bad of ['missingRevision','differentRevision','changedLegacyName','wrongMode'])test('selected-store review rejects '+bad,async()=>{const f=await partial(),input=await reviewInput(f);if(bad==='missingRevision')delete input.action.body.reviewedStoreBasisRevision;if(bad==='differentRevision')input.action.body.reviewedStoreBasisRevision++;if(bad==='changedLegacyName')input.action.body.lines[0].originalItem='Renamed food';if(bad==='wrongMode'){input.mode='change';input.change={lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]};input.unboundFactIds=f.state.unbound.map(x=>x.factId);}await assert.rejects(()=>createTrackingCandidate(f.repo,f.ctx,f.shop,input));});
for(const stale of ['storeGrant','selection','shopper','privacy'])test('held partial monetary review rechecks '+stale,async()=>{const f=await partial(),c=await createTrackingCandidate(f.repo,f.ctx,f.shop,await reviewInput(f));if(stale==='storeGrant')f.revokeStore();if(stale==='selection')f.shop.store_basis_revision++;if(stale==='shopper')f.ctx.member.member_id=id(99);if(stale==='privacy')f.shop.demand_review_required=true;await assert.rejects(()=>acceptTrackingCandidate(f.repo,f.ctx,f.shop,{candidateId:c.candidateId,candidateDigest:c.candidateDigest,acknowledgedDisclosure:c.disclosure,acceptOverage:true,acceptUnknown:false}));});

// Store selection may reset prices while preserving a valid partial partition.
// That narrow path must neither admit it to V1 nor conceal stale/private food.
test('internal store price reset accepts valid partial food without granting V1 admission',async()=>{
 const f=await partial(),before=structuredClone(f.state);
 await assertPriceOnly(f.repo,f.ctx,f.shop,{body:{quote:f.shop.quote,lines:f.lines.map(l=>({...l,unitPriceMinor:null}))}});
 assert.deepEqual(f.state,before);
 await assert.rejects(()=>assertTrackingV1(f.repo,f.ctx,f.shop),e=>e.code==='tracking_v2_required');
});
for(const kind of ['packs','name','line','meal','reviewRequired','stalePrice','staleDigest'])test('internal partial store price reset rejects '+kind,async()=>{
 const f=await partial(),body={quote:f.shop.quote,lines:structuredClone(f.lines)};
 if(kind==='packs')body.lines[0].packs++;
 if(kind==='name')body.lines[0].originalItem='Different food';
 if(kind==='line')body.lines[0].lineId=id(99);
 if(kind==='meal')body.mealEdit={occurrenceId:id(41),baseMealRevision:1,meal:null};
 if(kind==='reviewRequired')f.shop.demand_review_required=true;
 if(kind==='stalePrice')f.lines[0].unitPriceMinor++;
 if(kind==='staleDigest'){f.setState(f.state);f.state.unbound=[];}
 // setState retains the provided object and its original digest.
 await assert.rejects(()=>assertPriceOnly(f.repo,f.ctx,f.shop,{body}));
});
