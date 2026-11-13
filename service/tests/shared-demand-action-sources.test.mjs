import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {validateDemandGraph,demandLineQuantity,applyDemandChange} from '../dist/shared-demand-domain.js';
import {actionDemandSources} from '../dist/shared-demand-action-sources.js';
import {mealDemandSources} from '../dist/shared-demand-sources.js';
import {digest} from '../dist/database.js';
import {readActionDemandSources,demandActionSourcesInputSchema} from '../dist/shared-demand-repository.js';
import {requireSharedMealChange,consumeSharedMealChange} from '../dist/shared-meal-changes.js';
import {requireMealMove} from '../dist/meal-moves.js';
import {moveSharedMeal} from '../dist/shared-meal-planning.js';
const q=(n=6,d=1)=>({amount:{numerator:n,denominator:d},unit:'count',originalLiteral:`${n}/${d} wraps`});
function fixture(){
 const shopId=randomUUID(),householdId=randomUUID(),occurrenceId=randomUUID(),ingredientId=randomUUID(),lunch=randomUUID(),lineId=randomUUID();
 const meal={title:'Tacos and lunch',day:'2026-11-10',kind:'dinner',portions:3,protected:false,
  planning:{groups:[{id:lunch,name:'Lunch',servings:{numerator:1,denominator:1},protected:true}],
   ingredients:[{id:ingredientId,name:'Wraps',quantity:q(),groupIds:[lunch],exclusions:['Sesame']}],exclusions:['Peanuts']}};
 const occurrences=[{occurrenceId,revision:2,meal}],facts=mealDemandSources(shopId,occurrences);
 const contributions=facts.map(f=>({id:randomUUID(),lineId,source:f.source.kind==='reservation'?{...f.source,reservationId:randomUUID(),purpose:'Original lunch purpose'}:f.source,
  productKey:'wraps',productName:f.productName,originalText:'Original source wording',quantity:f.quantity,sourceExclusions:f.sourceExclusions,
  exclusions:[],contains:[],removedAt:null}));
 const manual={id:randomUUID(),lineId,source:{kind:'manual'},productKey:'wraps',productName:'Wraps',originalText:'Manual staple',quantity:{...facts[0].quantity},exclusions:[],contains:[],removedAt:null};contributions.push(manual);
 const graph={schemaVersion:1,conversionTableVersion:'us-customary-metric-v1',householdId,shopId,revision:1,
  lines:[{id:lineId,name:'Wraps',unit:'count',originalOrder:0,trashedAt:null}],contributions,edges:[],usedIds:[lineId,...contributions.map(c=>c.id)]};
 return {shopId,householdId,occurrenceId,ingredientId,lunch,lineId,meal,occurrences,graph,contributions,manual};
}
test('arbitrary existing IDs, immutable origin text, reservation purpose and unrelated sources survive',()=>{
 const f=fixture(),unrelated=[f.manual];
 for(const source of [{kind:'request',requestId:randomUUID(),appliedRequestRevision:1},{kind:'import',batchId:randomUUID(),entryId:randomUUID()}]){const row={...f.manual,id:randomUUID(),source};f.graph.contributions.push(row);f.graph.usedIds.push(row.id);unrelated.push(row);}
 const before=structuredClone(f.graph),catalog=actionDemandSources(f.shopId,f.occurrences,f.graph);
 assert.deepEqual(f.graph,before);assert.equal(catalog.sources.length,2);
 for(const row of catalog.sources){assert.deepEqual(row.before,before.contributions.find(c=>c.id===row.proposed.id));assert.equal(row.proposed.originalText,'Original source wording');assert.equal(row.proposed.requiredLineId,f.lineId);assert.equal(row.transition,'retain');}
 assert.equal(catalog.sources[1].proposed.source.reservationId,f.contributions[1].source.reservationId);
 assert.equal(catalog.sources[1].proposed.source.purpose,'Original lunch purpose');
 assert.deepEqual(catalog.retainedContributionIds,unrelated.map(c=>c.id));assert.deepEqual(catalog.retirementCandidates,[]);
 for(const c of unrelated)assert.deepEqual(f.graph.contributions.find(row=>row.id===c.id),before.contributions.find(row=>row.id===c.id));
});
test('changed meal quantity is reduced server-side while before facts and mapped restrictions stay exact',()=>{
 const f=fixture();f.graph.contributions[0].sourceExclusions[0].resolution={kind:'mapped',tags:['peanut'],confirmedAt:'2026-11-09T00:00:00Z'};
 f.graph.contributions[0].exclusions=['peanut'];f.meal.planning.ingredients[0].quantity=q(16,2);
 const row=actionDemandSources(f.shopId,f.occurrences,f.graph).sources[0];
 assert.equal(row.transition,'update');assert.deepEqual(row.proposed.quantity.amount,{numerator:'8',denominator:'1'});assert.equal(row.proposed.originalQuantityText,'16/2 wraps');
 assert.deepEqual(row.proposed.sourceExclusions,row.before.sourceExclusions);assert.equal(row.before.quantity.amount.numerator,'6');
});
test('new exclusion scope stays unresolved; identical labels in another scope do not inherit mapping',()=>{
 const f=fixture();f.contributions[0].sourceExclusions[0].resolution={kind:'mapped',tags:['peanut'],confirmedAt:'2026-11-09T00:00:00Z'};
 f.meal.planning.ingredients[0].exclusions.push('Peanuts');
 const row=actionDemandSources(f.shopId,f.occurrences,f.graph).sources[0];
 assert.equal(row.proposed.sourceExclusions.find(e=>e.ingredientId===f.ingredientId&&e.label==='Peanuts').resolution.kind,'unresolved');
});
test('protected unknown quantification preserves reservation and contribution IDs',()=>{
 const f=fixture(),bindingId=randomUUID();f.meal.planning.bindings=[{id:bindingId,ingredientId:f.ingredientId,groupId:f.lunch,quantity:q(6)}];
 const row=actionDemandSources(f.shopId,f.occurrences,f.graph).sources.find(r=>r.proposed.source.kind==='reservation');
 assert.equal(row.transition,'quantifyReservation');assert.equal(row.proposed.id,f.contributions[1].id);
 assert.deepEqual(row.proposed.source,{...f.contributions[1].source,bindingId});assert.equal(row.proposed.quantity.amount.numerator,'6');
});
test('whole protected representation does not acquire fabricated group allocations',()=>{
 const f=fixture();f.meal.protected=true;
 const old=f.contributions[1];old.source={...old.source,groupId:null,bindingId:null};old.quantity=f.contributions[0].quantity;
 f.graph.contributions=[old,f.manual];f.graph.usedIds=[f.lineId,old.id,f.manual.id];
 f.meal.planning.bindings=[{id:randomUUID(),ingredientId:f.ingredientId,groupId:f.lunch,quantity:q(6)}];
 const rows=actionDemandSources(f.shopId,f.occurrences,f.graph).sources;assert.equal(rows.length,1);assert.equal(rows[0].proposed.id,old.id);assert.equal(rows[0].proposed.source.groupId,null);
});
test('nonprotected disappeared sources are candidates; protected disappearance cannot become retirement',()=>{
 const f=fixture();assert.throws(()=>actionDemandSources(f.shopId,[],f.graph),{code:'demand_protected_source_missing'});
 f.graph.contributions=f.graph.contributions.filter(c=>c.source.kind!=='reservation');
 const result=actionDemandSources(f.shopId,[],f.graph);assert.deepEqual(result.retirementCandidates,[f.contributions[0].id]);assert.deepEqual(result.retainedContributionIds,[f.manual.id]);
});
test('retired provenance and used IDs cannot be silently reused',()=>{
 const f=fixture();f.contributions[0].removedAt='2026-11-09T00:00:00Z';
 assert.throws(()=>actionDemandSources(f.shopId,f.occurrences,f.graph),{code:'demand_source_retired'});
 f.graph.contributions=f.graph.contributions.slice(1);const id=mealDemandSources(f.shopId,f.occurrences)[0].id;f.graph.usedIds.push(id);
 assert.throws(()=>actionDemandSources(f.shopId,f.occurrences,f.graph),{code:'demand_source_identity_reused'});
});
test('ambiguous existing source and non-null binding replacement fail closed',()=>{
 const f=fixture();f.graph.contributions.push({...f.contributions[0],id:randomUUID()});
 assert.throws(()=>actionDemandSources(f.shopId,f.occurrences,f.graph),{code:'demand_source_ambiguous'});
 const g=fixture();g.contributions[1].quantity={...g.contributions[0].quantity};g.contributions[1].source.bindingId=randomUUID();
 g.meal.planning.bindings=[{id:randomUUID(),ingredientId:g.ingredientId,groupId:g.lunch,quantity:q(6)}];
 assert.throws(()=>actionDemandSources(g.shopId,g.occurrences,g.graph),{code:'demand_source_rebinding_required'});
});
test('new authoritative sources are deterministic and carry no inferred product match',()=>{
 const f=fixture();f.graph.contributions=[f.manual];f.graph.usedIds=[f.lineId,f.manual.id];
 const one=actionDemandSources(f.shopId,f.occurrences,f.graph);assert.deepEqual(actionDemandSources(f.shopId,f.occurrences,f.graph),one);
 assert.ok(one.sources.every(r=>r.before===null&&r.transition==='new'&&!('productKey' in r.proposed)));
});
function endpointFixture(){
 const f=fixture(),shop={shop_id:f.shopId,revision:3,authority_epoch:1,demand_revision:1,demand_review_required:false,phase:'draft'},calls=[];
 const ctx={householdId:f.householdId,member:{member_id:randomUUID(),kind:'adult'},deviceId:randomUUID(),now:new Date('2026-11-09T00:00:00Z'),db:{query:async(sql,args)=>{calls.push({sql,args});assert.match(sql,/^SELECT /);if(sql.includes('FROM ritc.shared_tracking_revision'))return{rows:[]};return{rows:[{graph:f.graph,graph_digest:digest(f.graph),receipt:{}}]};}}};
 const repo={requireShopper(){},requireDraft(s){assert.equal(s.phase,'draft');},checkBase(s,b){assert.equal(b.shopRevision,s.revision);assert.equal(b.authorityEpoch,s.authority_epoch);},meals:async()=>structuredClone(f.occurrences)};
 const quote={currency:'USD',scope:'wholeCheckout',complete:true,capMinor:10000,capScope:'wholeCheckout',fee:{kind:'fixed',amountMinor:0},taxesMinor:0,depositsMinor:0,discountsMinor:0,observedAt:'2026-11-08T23:00:00Z',expiresAt:'2026-11-10T00:00:00Z'};
 const input={base:{shopRevision:3,authorityEpoch:1,graphRevision:1,graphDigest:digest(f.graph)},action:{kind:'shop.patch',body:{quote,lines:[{lineId:f.lineId,originalItem:'Wraps',packs:2,unitPriceMinor:100,feeEligible:true}],mealEdit:{occurrenceId:f.occurrenceId,baseMealRevision:2,meal:structuredClone(f.meal)}}}};
 return {...f,ctx,shop,repo,input,calls};
}
test('catalog endpoint requires exact nonzero graph revision/digest and rejects legacy/recovery state',async()=>{
 for(const mutation of [f=>f.shop.demand_revision=0,f=>f.shop.demand_review_required=true,f=>f.input.base.graphRevision=2,f=>f.input.base.graphDigest='0'.repeat(64)]){
  const f=endpointFixture();mutation(f);await assert.rejects(readActionDemandSources(f.repo,f.ctx,f.shop,f.input),e=>['demand_enabled_required','stale_demand'].includes(e.code));
 }
 const f=endpointFixture();f.input.base.graphRevision=0;assert.equal(demandActionSourcesInputSchema.safeParse(f.input).success,false);
});
test('catalog returns normalized action and graph binding without writing or reserving a preview',async()=>{
 const f=endpointFixture();f.input.action.body.mealEdit.meal.title='  Reviewed dinner  ';
 const out=await readActionDemandSources(f.repo,f.ctx,f.shop,f.input);
 assert.equal(out.normalizedAction.body.mealEdit.meal.title,'Reviewed dinner');assert.equal(out.actionDigest,digest(out.normalizedAction));assert.equal(out.graphDigest,digest(f.graph));
 assert.ok(f.calls.every(c=>c.sql.startsWith('SELECT ')));assert.ok(!('previewId' in out));assert.deepEqual(out.sources[0].before,f.contributions[0]);
});
test('catalog denies access before reading graph or private sources',async()=>{
 const f=endpointFixture();f.repo.requireShopper=()=>{throw new Error('denied');};
 await assert.rejects(readActionDemandSources(f.repo,f.ctx,f.shop,f.input),/denied/);assert.equal(f.calls.length,0);
});
function proposalFixture(row){
 const calls=[],shop={shop_id:randomUUID(),revision:4,authority_epoch:2},ctx={householdId:randomUUID(),member:{member_id:randomUUID()},now:new Date(),db:{query:async(sql,args)=>{calls.push({sql,args});return{rows:row===null?[]:[row]};}}};
 return {calls,shop,ctx};
}
test('shared change validator checks exact meal and SQL authority predicates without consumption',async()=>{
 const meal=fixture().meal,f=proposalFixture({body:{meal},actor_id:randomUUID(),grant_revision:3});
 await requireSharedMealChange(f.ctx,f.shop,randomUUID(),randomUUID(),2,meal);
 assert.equal(f.calls.length,1);assert.match(f.calls[0].sql,/c.state='pending'/);assert.match(f.calls[0].sql,/a.state='active'/);assert.match(f.calls[0].sql,/p.revision=c.grant_revision/);
 assert.equal(f.calls[0].args[4],4);assert.equal(f.calls[0].args[5],2);assert.equal(f.calls[0].args[6],2);
 await assert.rejects(requireSharedMealChange(f.ctx,f.shop,randomUUID(),randomUUID(),2,{...meal,title:'Changed payload'}),{code:'stale_proposal'});
 assert.ok(f.calls.every(c=>c.sql.startsWith('SELECT ')));
});
test('revoked/dismissed/unavailable proposals fail; consumption only follows a valid read',async()=>{
 const f=proposalFixture(null),meal=fixture().meal;
 await assert.rejects(consumeSharedMealChange(f.ctx,f.shop,randomUUID(),randomUUID(),2,meal),{code:'stale_proposal'});
 assert.equal(f.calls.length,1);assert.ok(!f.calls.some(c=>c.sql.startsWith('UPDATE')));
 const g=proposalFixture({body:{meal},actor_id:randomUUID(),grant_revision:3});
 await consumeSharedMealChange(g.ctx,g.shop,randomUUID(),randomUUID(),2,meal);assert.equal(g.calls.length,2);assert.match(g.calls[1].sql,/^UPDATE ritc.shared_meal_change/);
});
test('new occurrence still requires current approved idea before any consumption',async()=>{
 const meal=fixture().meal,calls=[],ctx={householdId:randomUUID(),member:{member_id:randomUUID()},db:{query:async(sql,args)=>{calls.push(sql);return{rows:sql.includes('FROM ritc.shared_meal_change')?[{body:{meal,approvedIdeaId:randomUUID(),approvedIdeaRevision:1},actor_id:randomUUID(),grant_revision:1}]:[]};}}};
 await assert.rejects(consumeSharedMealChange(ctx,{shop_id:randomUUID(),revision:4,authority_epoch:2},randomUUID(),randomUUID(),null,meal),{code:'stale_idea'});
 assert.equal(calls.length,2);assert.match(calls[1],/state='approved'/);assert.ok(!calls.some(s=>s.startsWith('UPDATE')));
});
test('move validator requires exact projected day and current authority and never consumes',async()=>{
 const meal=fixture().meal,f=proposalFixture({proposed_day:'2026-11-12'});
 await requireMealMove(f.ctx,f.shop,randomUUID(),randomUUID(),meal,moveSharedMeal(meal,'2026-11-12'));
 assert.equal(f.calls.length,1);assert.match(f.calls[0].sql,/m.state='pending'/);assert.match(f.calls[0].sql,/m.grant_revision=p.revision/);
 await assert.rejects(requireMealMove(f.ctx,f.shop,randomUUID(),randomUUID(),meal,{...meal,day:'2026-11-13'}),{code:'stale_proposal'});
 const revoked=proposalFixture(null);await assert.rejects(requireMealMove(revoked.ctx,revoked.shop,randomUUID(),randomUUID(),meal,meal),{code:'stale_proposal'});
 assert.ok(f.calls.every(c=>c.sql.startsWith('SELECT ')));
});
test('catalog structural scope rejects missing edit/digest, request actions and nested review',()=>{
 for(const change of [f=>delete f.input.action.body.mealEdit,f=>delete f.input.base.graphDigest,f=>f.input.action.kind='request.apply',f=>f.input.action.body.demandReview={previewId:randomUUID(),previewDigest:'a'.repeat(64)}]){
  const f=endpointFixture();change(f);assert.equal(demandActionSourcesInputSchema.safeParse(f.input).success,false);
 }
});
test('catalog wiring checks both proposal types before exposing proposed source facts',async()=>{
 for(const field of ['changeProposalId','proposalId']){
  const f=endpointFixture(),read=f.ctx.db.query;f.input.action.body.mealEdit[field]=randomUUID();
  f.ctx.db.query=async(sql,args)=>sql.includes('FROM ritc.shared_demand_revision')?read(sql,args):{rows:[]};
  await assert.rejects(readActionDemandSources(f.repo,f.ctx,f.shop,f.input),{code:'stale_proposal'});
 }
});
test('source catalog rejects over-limit facts rather than truncating',()=>{
 const f=fixture(),meal=structuredClone(f.meal);meal.planning.groups=[];meal.planning.ingredients=Array.from({length:60},()=>({id:randomUUID(),name:'Wraps',quantity:q(),groupIds:[],exclusions:[]}));
 const occurrences=Array.from({length:34},()=>({occurrenceId:randomUUID(),meal}));
 assert.throws(()=>actionDemandSources(f.shopId,occurrences,f.graph),{code:'demand_source_limit'});
});

function convertedFixture(){
 const f=fixture(),basis={sourceUnit:'cup',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:'120',denominator:'1'},sourceNote:'Reviewed flour density',confirmedAt:'2026-11-09T00:00:00Z'};
 f.meal.planning.groups=[];f.meal.planning.exclusions=[];
 Object.assign(f.meal.planning.ingredients[0],{name:'Flour',quantity:{amount:{numerator:1,denominator:1},unit:'cup',originalLiteral:'1 cup flour'},groupIds:[],exclusions:[]});
 const fact=mealDemandSources(f.shopId,f.occurrences)[0],meal=f.contributions[0];
 Object.assign(meal,{productKey:'flour',productName:'Flour',source:fact.source,quantity:{...fact.quantity,confirmedConversion:basis},sourceExclusions:[]});
 Object.assign(f.manual,{productKey:'flour',productName:'Flour',quantity:{amount:{numerator:'120',denominator:'1'},unit:'gram',originalLiteral:'120 g flour',confirmedConversion:null}});
 f.graph.lines[0].unit='gram';f.graph.lines[0].name='Flour';f.graph.contributions=[meal,f.manual];
 const edge={id:randomUUID(),confirmation:{productMatchConfirmed:true,confirmedAt:'2026-11-09T00:00:00Z',evidence:'Same reviewed flour'},kind:'withinExisting',demandId:meal.id,supplyId:f.manual.id,quantity:{amount:{numerator:'120',denominator:'1'},unit:'gram',originalLiteral:'120 g of existing flour',confirmedConversion:structuredClone(basis)}};
 f.graph.edges=[edge];f.graph.usedIds=[f.lineId,meal.id,f.manual.id,edge.id];
 return {...f,basis};
}
test('unrelated meal edit preserves confirmed conversion and existing cross-unit overlap exactly',()=>{
 const f=convertedFixture(),before=structuredClone(f.graph);
 validateDemandGraph(f.graph);assert.deepEqual(demandLineQuantity(f.graph,f.lineId),{amount:{numerator:'120',denominator:'1'},unit:'gram'});
 f.meal.title='Flour for revised dinner';
 const row=actionDemandSources(f.shopId,f.occurrences,f.graph).sources[0];
 assert.equal(row.transition,'retain');assert.deepEqual(row.proposed.quantity,before.contributions[0].quantity);
 const proposed=structuredClone(f.graph);proposed.contributions[0].quantity=row.proposed.quantity;
 assert.deepEqual(validateDemandGraph(proposed),before);assert.deepEqual(demandLineQuantity(proposed,f.lineId),{amount:{numerator:'120',denominator:'1'},unit:'gram'});
 const dropped=structuredClone(proposed);dropped.contributions[0].quantity.confirmedConversion=null;
 assert.throws(()=>validateDemandGraph(dropped),{code:'incompatible_units'});
 row.proposed.quantity.confirmedConversion.sourceNote='Changed response copy';assert.deepEqual(f.graph,before);
});
test('changed authoritative quantity, unit, literal or food never inherits a prior conversion',()=>{
 for(const mutate of [
  f=>f.meal.planning.ingredients[0].quantity.amount.numerator=2,
  f=>f.meal.planning.ingredients[0].quantity.unit='milliliter',
  f=>f.meal.planning.ingredients[0].quantity.originalLiteral='one cup, newly reviewed',
  f=>f.meal.planning.ingredients[0].name='Almond flour',
 ]){
  const f=convertedFixture(),before=structuredClone(f.graph);mutate(f);
  const row=actionDemandSources(f.shopId,f.occurrences,f.graph).sources[0];
  assert.equal(row.transition,'update');assert.equal(row.proposed.quantity.confirmedConversion,null);
  assert.deepEqual(row.before.quantity.confirmedConversion,f.basis);assert.deepEqual(f.graph,before);
 }
});
test('unchanged facts do not retain a conversion unrelated to their quantity dimension',()=>{
 const f=convertedFixture();f.contributions[0].quantity.confirmedConversion={...f.basis,sourceUnit:'count',targetUnit:'gram'};
 const row=actionDemandSources(f.shopId,f.occurrences,f.graph).sources[0];
 assert.equal(row.transition,'update');assert.equal(row.proposed.quantity.confirmedConversion,null);
});

function wholeProtectedUnknownFixture(){
 const f=fixture();f.meal.protected=true;f.meal.planning.ingredients[0].quantity=null;
 const old=f.contributions[1];old.source={...old.source,groupId:null,bindingId:null};old.quantity=null;
 f.graph.contributions=[old,f.manual];f.graph.usedIds=[f.lineId,old.id,f.manual.id];
 return {...f,old};
}
function catalogChange(f,row){return{schemaVersion:1,operationId:randomUUID(),householdId:f.householdId,shopId:f.shopId,baseRevision:f.graph.revision,at:'2026-11-09T00:00:00Z',lines:[],contributions:[{...row.before,source:row.proposed.source,quantity:row.proposed.quantity}],edges:[],removeSourceIds:[],removeEdgeIds:[]};}
test('same-identity protected unknown emits explicit quantification and satisfies the unchanged reducer gate',()=>{
 const f=wholeProtectedUnknownFixture(),before=structuredClone(f.graph);validateDemandGraph(f.graph);
 assert.equal(actionDemandSources(f.shopId,f.occurrences,f.graph).sources[0].transition,'retain');
 f.meal.planning.ingredients[0].quantity=q(6);
 const row=actionDemandSources(f.shopId,f.occurrences,f.graph).sources[0],change=catalogChange(f,row);
 assert.equal(row.transition,'quantifyReservation');assert.deepEqual(row.proposed.source,f.old.source);assert.equal(row.proposed.id,f.old.id);
 assert.throws(()=>applyDemandChange(f.graph,change),{code:'protected_unknown_changed'});
 change.quantifyReservationIds=[row.proposed.id];const result=applyDemandChange(f.graph,change);
 assert.deepEqual(result.graph.contributions.find(c=>c.id===f.old.id),{...f.old,quantity:row.proposed.quantity});assert.deepEqual(f.graph,before);
 const forged=structuredClone(change);forged.contributions[0].source.groupId=randomUUID();
 assert.throws(()=>applyDemandChange(f.graph,forged),{code:'source_identity_changed'});
});
test('known protected and ordinary meal quantity changes do not claim reservation quantification',()=>{
 const f=wholeProtectedUnknownFixture();f.old.quantity={...f.manual.quantity};f.meal.planning.ingredients[0].quantity=q(5);
 const row=actionDemandSources(f.shopId,f.occurrences,f.graph).sources[0];assert.equal(row.transition,'update');
 assert.throws(()=>applyDemandChange(f.graph,catalogChange(f,row)),{code:'protected_quantity_reduced'});
 const ordinary=fixture();ordinary.contributions[0].quantity=null;
 assert.equal(actionDemandSources(ordinary.shopId,ordinary.occurrences,ordinary.graph).sources.find(r=>r.proposed.source.kind==='meal').transition,'update');
});
