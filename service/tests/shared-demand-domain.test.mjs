import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
const dist=process.env.RITC_SHARED_DEMAND_DIST;
const moduleURL=name=>dist?pathToFileURL(resolve(dist,name)).href:new URL('../dist/'+name,import.meta.url).href;
const {validateDemandGraph:validate,demandLineQuantity:total,applyDemandChange:apply,undoDemandChange:undo,convertDemandQuantity:convert}=await import(moduleURL('shared-demand-domain.js'));
const {sharedDemandJSONSchema}=await import(moduleURL('shared-demand-contracts.js'));
const fixture=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-demand/conservation-v1.json',import.meta.url),'utf8'));
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const at='2026-11-09T13:00:00Z';
const graph=()=>structuredClone(fixture.graph);
const quantity=(n,unit='count',denominator='1')=>({amount:{numerator:String(n),denominator},unit,originalLiteral:`${n} ${unit}`,confirmedConversion:null});
const change=(g,patch={},op=300)=>({schemaVersion:1,operationId:id(op),householdId:g.householdId,shopId:g.shopId,baseRevision:g.revision,at,lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[],...patch});
const fails=(fn,code)=>assert.throws(fn,error=>error.code===code);
function alias(g,n,duplicate=true){
 const c={...structuredClone(g.contributions[0]),id:id(n),source:{kind:'import',batchId:id(400+n),entryId:id(500+n)}};
 g.contributions.push(c);g.usedIds.push(c.id);
 if(duplicate){const e={...structuredClone(fixture.graph.edges[0]),id:id(600+n),kind:'duplicate',demandId:c.id,supplyId:id(11),quantity:quantity(12)};g.edges.push(e);g.usedIds.push(e.id);}
 return c;
}
function single(q){const g=graph();g.contributions=g.contributions.slice(0,1);g.edges=[];g.contributions[0].quantity=q;return g;}

test('frozen structural JSON Schema matches executable versioned contracts',async()=>{
 const schema=JSON.parse(await readFile(new URL('../../shared/contracts/shared-demand.schema.json',import.meta.url),'utf8'));
 assert.deepEqual(schema,sharedDemandJSONSchema());
});
test('golden twelve wraps preserve three commitments and all original literals/IDs',()=>{
 const g=graph(),before=structuredClone(g);assert.deepEqual(total(g,id(1)),fixture.expected.initial);
 assert.deepEqual(g,before);assert.equal(g.contributions[3].source.kind,'reservation');
});
test('duplicate twelve counts once; explicit additional twelve counts twice',()=>{
 const duplicate=graph();alias(duplicate,15);assert.deepEqual(total(duplicate,id(1)),fixture.expected.duplicateTwelve);
 const additional=graph();alias(additional,15,false);assert.deepEqual(total(additional,id(1)),fixture.expected.additionalTwelve);
});
test('removing tacos changes only that source and edge; original input never mutates',()=>{
 const g=graph(),before=structuredClone(g),result=apply(g,change(g,{removeSourceIds:[id(12)]}));
 assert.deepEqual(g,before);assert.deepEqual(total(result.graph,id(1)),fixture.expected.removeTacos);
 assert.deepEqual(result.graph.contributions.filter(c=>c.id!==id(12)),g.contributions.filter(c=>c.id!==id(12)));
 assert.equal(result.graph.contributions.find(c=>c.id===id(12)).removedAt,at);
 assert.deepEqual(result.graph.edges,g.edges.filter(e=>e.demandId!==id(12)));
 assert.equal(result.graph.revision,2);
});
test('removing manual source leaves all meal and lunch demand additive',()=>{
 const g=graph(),r=apply(g,change(g,{removeSourceIds:[id(11)]}));
 assert.equal(r.graph.edges.length,0);assert.deepEqual(total(r.graph,id(1)),fixture.expected.removeManual);
 assert.deepEqual(r.graph.contributions.slice(1),g.contributions.slice(1));
 const both=apply(g,change(g,{removeSourceIds:[id(11),id(12)]}));
 assert.deepEqual(total(both.graph,id(1)),fixture.expected.removeManualAndTacos);
});
test('duplicate hub removal rehomes exact reservation edges and conserves surviving equivalence',()=>{
 const g=graph();alias(g,15);alias(g,16);const r=apply(g,change(g,{removeSourceIds:[id(11)]}));
 assert.deepEqual(total(r.graph,id(1)),fixture.expected.initial);
 assert.deepEqual(r.graph.edges.filter(e=>e.kind==='withinExisting').map(e=>e.id),g.edges.filter(e=>e.kind==='withinExisting').map(e=>e.id));
 assert.ok(r.graph.edges.filter(e=>e.kind==='withinExisting').every(e=>e.supplyId!==id(11)));
 assert.equal(r.graph.edges.filter(e=>e.kind==='duplicate').length,1);
 assert.deepEqual(apply(g,change(g,{removeSourceIds:[id(11)]})),r,'repair IDs deterministic');
});
test('duplicate aliases share one finite reservation capacity',()=>{
 const g=graph();alias(g,15);g.edges[0].supplyId=id(15);g.edges[1].supplyId=id(15);
 assert.deepEqual(total(g,id(1)),fixture.expected.initial);
 g.contributions[2].quantity=quantity(5);g.edges[1].quantity=quantity(5);
 fails(()=>validate(g),'allocation_exceeds_quantity');
});
test('partial within-existing link leaves only the uncovered amount additive',()=>{
 const g=graph();g.edges[0].quantity=quantity(3);assert.deepEqual(total(g,id(1)),{amount:{numerator:'15',denominator:'1'},unit:'count'});
});
test('one demand cannot be overallocated across multiple supply edges',()=>{
 const g=graph();alias(g,15,false);const e={...structuredClone(g.edges[0]),id:id(888),supplyId:id(15),quantity:quantity(1)};
 g.edges.push(e);g.usedIds.push(e.id);fails(()=>validate(g),'allocation_exceeds_quantity');
});
test('protected reservation cannot be removed directly or through an upsert',()=>{
 const g=graph();fails(()=>apply(g,change(g,{removeSourceIds:[id(14)]})),'protected_share_changed');
 const c={...g.contributions[3],removedAt:at};fails(()=>apply(g,change(g,{contributions:[c],removeEdgeIds:[id(23)]})),'protected_share_changed');
});
test('protected share quantity, identity and exclusion constraints survive edits',()=>{
 const g=graph();const c=structuredClone(g.contributions[3]);c.quantity=quantity(1);
 fails(()=>apply(g,change(g,{contributions:[c],removeEdgeIds:[id(23)]})),'protected_quantity_reduced');
 c.quantity=quantity(2);c.source.purpose='Other purpose';fails(()=>apply(g,change(g,{contributions:[c]})),'source_identity_changed');
 c.source=g.contributions[3].source;c.exclusions=[];fails(()=>apply(g,change(g,{contributions:[c]})),'protected_share_changed');
});
test('unknown remains unknown and cannot supply an allocation',()=>{
 const g=single(null);assert.equal(total(g,id(1)),null);
 const linked=graph();linked.contributions[0].quantity=null;fails(()=>validate(linked),'unknown_edge_quantity');
 const protectedUnknown=graph();protectedUnknown.edges=[];protectedUnknown.contributions[3].quantity=null;
 assert.equal(total(protectedUnknown,id(1)),null);
 fails(()=>apply(protectedUnknown,change(protectedUnknown,{contributions:[{...protectedUnknown.contributions[3],quantity:quantity(2)}]})),'protected_unknown_changed');
});
test('unit factors are exact and count never means a package or guessed weight',()=>{
 assert.deepEqual(convert(quantity(1,'ounce'),'gram'),{n:45359237n,d:1600000n});
 assert.equal(convert(quantity(2,'count'),'ounce'),null);
 assert.deepEqual(convert(quantity(1,'kilogram'),'gram'),{n:1000n,d:1n});
 const g=single(quantity(2,'ounce'));assert.equal(total(g,id(1)),null);assert.deepEqual(validate(g).contributions[0].quantity,quantity(2,'ounce'));
});
test('explicit ingredient-specific basis works in both directions without float arithmetic',()=>{
 const basis={sourceUnit:'cup',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:'120',denominator:'1'},sourceNote:'Reviewed flour label',confirmedAt:at};
 assert.deepEqual(convert({...quantity(1,'cup'),confirmedConversion:basis},'gram'),{n:120n,d:1n});
 assert.deepEqual(convert({...quantity(120,'gram'),confirmedConversion:basis},'cup'),{n:1n,d:1n});
 assert.equal(convert({...quantity(1,'cup'),confirmedConversion:basis},'count'),null);
 assert.throws(()=>convert({...quantity(1,'gram'),confirmedConversion:{...basis,sourceUnit:'kilogram'}},'gram'),e=>e.code==='invalid_conversion_basis');
});
for(const [n,d] of [['0','1'],['-1','1'],['01','1'],['2','4'],['1','0'],['9223372036854775808','1'],['1','9223372036854775808']])
 test(`reject noncanonical/out-of-bound rational ${n}/${d}`,()=>assert.throws(()=>validate(single(quantity(n,'count',d)))));
test('Int64 exact boundary succeeds but aggregate overflow fails closed',()=>{
 const g=single(quantity('9223372036854775807'));assert.equal(total(g,id(1)).amount.numerator,'9223372036854775807');
 const c={...structuredClone(g.contributions[0]),id:id(15),quantity:quantity(1)};g.contributions.push(c);g.usedIds.push(c.id);
 fails(()=>validate(g),'rational_overflow');
});
for(const [label,mutate,code] of [
 ['dangling endpoint',g=>g.edges[0].supplyId=id(999),'invalid_edge_reference'],
 ['self edge',g=>g.edges[0].supplyId=g.edges[0].demandId,'invalid_edge_reference'],
 ['nonmatching product',g=>g.contributions[1].productKey='rice','product_match_required'],
 ['excluded product',g=>g.contributions[0].contains=['peanut'],'excluded_product'],
 ['wrong source direction',g=>{g.edges[0].demandId=id(11);g.edges[0].supplyId=id(12);},'invalid_within_source'],
 ['unregistered ID',g=>g.usedIds.pop(),'unregistered_identity'],
 ['duplicate source ID',g=>g.contributions.push(structuredClone(g.contributions[0])),'duplicate_identity'],
 ['duplicate edge pair',g=>{alias(g,15);g.edges.push({...g.edges.at(-1),id:id(999)});g.usedIds.push(id(999));},'duplicate_edge'],
])test('reject '+label,()=>{const g=graph();mutate(g);fails(()=>validate(g),code);});
test('confirmed match cannot be omitted or false',()=>{const g=graph();g.edges[0].confirmation.productMatchConfirmed=false;assert.throws(()=>validate(g));});
test('same line cannot silently aggregate different products without an edge',()=>{const g=graph();g.edges=[];g.contributions[1].productKey='rice';fails(()=>validate(g),'product_match_required');});
test('duplicate cycle and unequal duplicate amount rejected',()=>{
 const g=graph();alias(g,15);g.edges.push({...g.edges.at(-1),id:id(999),demandId:id(11),supplyId:id(15)});g.usedIds.push(id(999));
 fails(()=>validate(g),'allocation_cycle');g.edges.pop();g.contributions.at(-1).quantity=quantity(13);fails(()=>validate(g),'duplicate_amount_mismatch');
});
test('cross-line, removed endpoint and repeated provenance rejected',()=>{
 const g=graph();g.lines.push({...g.lines[0],id:id(2),originalOrder:1});g.usedIds.push(id(2));g.contributions[1].lineId=id(2);
 fails(()=>validate(g),'invalid_edge_reference');g.contributions[1].lineId=id(1);g.contributions[1].removedAt=at;fails(()=>validate(g),'invalid_edge_reference');
 const d=graph();alias(d,15);const c={...structuredClone(d.contributions.at(-1)),id:id(16)};d.contributions.push(c);d.usedIds.push(c.id);fails(()=>validate(d),'duplicate_source');
});
test('scope, stale revision, no-op and identity reuse are rejected',()=>{
 const g=graph();fails(()=>apply(g,change(g,{shopId:id(999)})),'wrong_scope');fails(()=>apply(g,change(g,{baseRevision:0})),'stale_revision');
 fails(()=>apply(g,change(g)),'no_change');
 const r=apply(g,change(g,{removeEdgeIds:[id(21)]}));fails(()=>apply(r.graph,change(r.graph,{edges:[g.edges[0]]},301)),'identity_reused');
});
test('old unrelated tombstones are never retimestamped',()=>{
 const g=graph(),dead={...structuredClone(g.contributions[0]),id:id(19),removedAt:'2026-11-01T00:00:00Z'};g.contributions.push(dead);g.usedIds.push(dead.id);
 const r=apply(g,change(g,{removeSourceIds:[id(12)]}));assert.deepEqual(r.graph.contributions.at(-1),dead);
 fails(()=>apply(g,change(g,{contributions:[{...dead,removedAt:at}]})),'tombstone_changed');
});
test('touched-ID Undo restores removed source/edges while preserving unrelated additions',()=>{
 const g=graph(),removed=apply(g,change(g,{removeSourceIds:[id(12)]}));
 const extra={...structuredClone(g.contributions[0]),id:id(18),quantity:quantity(3)};
 const added=apply(removed.graph,change(removed.graph,{contributions:[extra]},301));
 const undone=undo(added.graph,removed.receipt,change(added.graph,{},302));
 assert.deepEqual(undone.graph.contributions.find(c=>c.id===extra.id),extra);
 for(const original of g.contributions)assert.deepEqual(undone.graph.contributions.find(c=>c.id===original.id),original);
 assert.deepEqual(total(undone.graph,id(1)),{amount:{numerator:'15',denominator:'1'},unit:'count'});
 assert.equal(undone.graph.revision,4);
 assert.equal(undone.receipt.contributions.length,1);assert.equal(undone.receipt.contributions[0].before.removedAt,at);assert.equal(undone.receipt.contributions[0].after.removedAt,null);
 fails(()=>undo(undone.graph,removed.receipt,change(undone.graph,{},303)),'undo_conflict');
});
test('Undo detects same-source conflict and does not overwrite later work',()=>{
 const g=graph(),q=structuredClone(g.contributions[0]);q.quantity=quantity(13);
 const edit=apply(g,change(g,{contributions:[q]}));const newer=apply(edit.graph,change(edit.graph,{contributions:[{...q,quantity:quantity(14)}]},301));
 fails(()=>undo(newer.graph,edit.receipt,change(newer.graph,{},302)),'undo_conflict');assert.equal(total(newer.graph,id(1)).amount.numerator,'14');
});
test('Undo addition tombstones original IDs rather than permitting reuse',()=>{
 const g=graph(),extra={...structuredClone(g.contributions[0]),id:id(18),quantity:quantity(3)};
 const added=apply(g,change(g,{contributions:[extra]})),undone=undo(added.graph,added.receipt,change(added.graph,{},301));
 assert.equal(undone.graph.contributions.find(c=>c.id===extra.id).removedAt,at);assert.ok(undone.graph.usedIds.includes(extra.id));
 assert.deepEqual(total(undone.graph,id(1)),fixture.expected.initial);
 fails(()=>apply(undone.graph,change(undone.graph,{contributions:[extra]},302)),'tombstone_changed');
});

test('partial links retain both stable edge IDs when removal converges duplicate supply endpoints',()=>{
 const g=graph();alias(g,15);g.edges[0].quantity=quantity(3);
 const extra={...structuredClone(g.edges[0]),id:id(999),supplyId:id(15)};g.edges.push(extra);g.usedIds.push(extra.id);
 assert.deepEqual(total(g,id(1)),fixture.expected.initial);
 const r=apply(g,change(g,{removeSourceIds:[id(11)]}));
 assert.deepEqual(total(r.graph,id(1)),fixture.expected.initial);
 assert.deepEqual(r.graph.edges.filter(e=>e.demandId===id(12)).map(e=>[e.id,e.supplyId,e.quantity.amount.numerator]),[[id(21),id(15),'3'],[id(999),id(15),'3']]);
});
test('same native unit cannot conceal conflicting ingredient conversion bases in a duplicate',()=>{
 const g=single(quantity(1,'cup'));g.lines[0].unit='gram';
 const basis={sourceUnit:'cup',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:'120',denominator:'1'},sourceNote:'Reviewed density',confirmedAt:at};
 g.contributions[0].quantity.confirmedConversion=basis;const c=alias(g,15);
 c.quantity={...quantity(1,'cup'),confirmedConversion:{...basis,targetAmountPerSourceUnit:{numerator:'150',denominator:'1'}}};
 g.edges[0].quantity=structuredClone(g.contributions[0].quantity);
 fails(()=>validate(g),'conflicting_conversion_basis');
});
test('within-existing capacity uses one exact line unit across compatible native units',()=>{
 const g=graph();g.lines[0].unit='gram';g.contributions[0].quantity=quantity(1,'kilogram');
 for(const c of g.contributions.slice(1))c.quantity=quantity(c.id===id(12)?600:c.id===id(13)?300:100,'gram');
 for(const e of g.edges)e.quantity=structuredClone(g.contributions.find(c=>c.id===e.demandId).quantity);
 assert.deepEqual(total(g,id(1)),{amount:{numerator:'1000',denominator:'1'},unit:'gram'});
 g.contributions[1].quantity=quantity(601,'gram');g.edges[0].quantity=quantity(601,'gram');fails(()=>validate(g),'allocation_exceeds_quantity');
});
test('editing quantity retains original source wording and rejects rewriting it',()=>{
 const g=graph(),c={...g.contributions[0],quantity:quantity(13)};
 const r=apply(g,change(g,{contributions:[c]}));assert.equal(r.graph.contributions[0].originalText,g.contributions[0].originalText);
 fails(()=>apply(g,change(g,{contributions:[{...c,originalText:'replacement'}]})),'original_source_text_changed');
});

test('aggregate exclusions cover every live member, including non-first pairs without edges',()=>{
 const g=graph();g.edges=[];g.contributions[0].exclusions=[];g.contributions[1].exclusions=['dairy'];g.contributions[2].contains=['dairy'];
 fails(()=>validate(g),'excluded_product');
 g.contributions[2].removedAt=at;assert.doesNotThrow(()=>validate(g),'removed source facts do not constrain current demand');
});
test('request provenance is distinct and reviewed request quantity may be within existing manual quantity',()=>{
 const g=graph();g.contributions[1].source={kind:'request',requestId:id(900),appliedRequestRevision:4};
 assert.deepEqual(total(g,id(1)),fixture.expected.initial);
 const r=apply(g,change(g,{removeSourceIds:[id(12)]}));assert.deepEqual(total(r.graph,id(1)),fixture.expected.removeTacos);
 assert.deepEqual(r.graph.contributions.find(c=>c.id===id(12)).source,g.contributions[1].source);
 const duplicate=structuredClone(g);duplicate.contributions[2].source={kind:'request',requestId:id(900),appliedRequestRevision:5};fails(()=>validate(duplicate),'duplicate_source');
});
test('edge conversion cannot inflate a mass supply while claiming fewer native volume units',()=>{
 const g=graph();g.lines[0].unit='gram';const basis={sourceUnit:'cup',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:'120',denominator:'1'},sourceNote:'Reviewed density',confirmedAt:at};
 g.contributions[0].quantity={...quantity(1,'cup'),confirmedConversion:basis};
 for(const c of g.contributions.slice(1))c.quantity=quantity(c.id===id(12)?60:c.id===id(13)?40:20,'gram');
 for(const e of g.edges)e.quantity=structuredClone(g.contributions.find(c=>c.id===e.demandId).quantity);
 // Explicit same basis on the edge lets the graph compare mass allocations with cup supply.
 for(const e of g.edges)e.quantity.confirmedConversion=basis;
 assert.deepEqual(total(g,id(1)),{amount:{numerator:'120',denominator:'1'},unit:'gram'});
 g.edges[0].quantity={...quantity(1,'cup','2'),confirmedConversion:{...basis,targetAmountPerSourceUnit:{numerator:'60',denominator:'1'}}};
 fails(()=>validate(g),'conflicting_conversion_basis');
});

test('cross-language golden unit factors remain exact and incompatible dimensions remain unknown',async()=>{
 const golden=JSON.parse(await readFile(new URL('../../shared/fixtures/shared-demand/unit-conversions-v1.json',import.meta.url),'utf8'));
 for(const row of golden.cases){const result=convert(row.quantity,row.targetUnit);assert.deepEqual(result===null?null:{numerator:String(result.n),denominator:String(result.d)},row.expected);}
});

test('unlinked incompatible typed quantities stay intact and unresolved; links requiring missing basis reject',()=>{
 const g=graph();g.edges=[];g.contributions[1].quantity=quantity(2,'ounce');
 assert.equal(total(g,id(1)),null);assert.deepEqual(validate(g).contributions[1].quantity,quantity(2,'ounce'));
 g.edges=[structuredClone(fixture.graph.edges[0])];fails(()=>validate(g),'incompatible_units');
});
test('exact Int64 bound applies to conserved total, not a temporary double-counted sum',()=>{
 const g=graph(),maximum='9223372036854775807';g.contributions=g.contributions.slice(0,2);g.edges=g.edges.slice(0,1);
 for(const c of g.contributions)c.quantity=quantity(maximum);g.edges[0].quantity=quantity(maximum);
 assert.deepEqual(total(g,id(1)),{amount:{numerator:maximum,denominator:'1'},unit:'count'});
});
test('confirmed cross-dimension basis requires timestamped explicit evidence',()=>{
 const q={...quantity(1,'cup'),confirmedConversion:{sourceUnit:'cup',targetUnit:'gram',targetAmountPerSourceUnit:{numerator:'120',denominator:'1'},sourceNote:'Reviewed density'}};
 assert.throws(()=>convert(q,'gram'));q.confirmedConversion.confirmedAt=at;assert.deepEqual(convert(q,'gram'),{n:120n,d:1n});
});
test('unresolved exact inherited restriction remains representable but cannot authorize allocations',()=>{
 const g=graph();g.contributions[1].sourceExclusions=[{occurrenceId:g.contributions[1].source.occurrenceId,ingredientId:g.contributions[1].source.ingredientId,label:'No sesame',resolution:{kind:'unresolved'}}];
 fails(()=>validate(g),'unresolved_exclusion');g.edges=g.edges.filter(e=>e.demandId!==g.contributions[1].id);assert.doesNotThrow(()=>validate(g));assert.equal(total(g,id(1)).amount.numerator,'18');
});
test('explicit timestamped mapping must preserve exact label identity and enforce mapped tags',()=>{
 const g=graph(),c=g.contributions[1];c.sourceExclusions=[{occurrenceId:c.source.occurrenceId,ingredientId:c.source.ingredientId,label:'No sesame',resolution:{kind:'mapped',tags:['sesame'],confirmedAt:at}}];
 fails(()=>validate(g),'missing_mapped_exclusion');c.exclusions.push('sesame');assert.doesNotThrow(()=>validate(g));g.contributions[0].contains.push('sesame');fails(()=>validate(g),'excluded_product');
});
test('source restriction identity cannot be forged by another contribution or source kind',()=>{
 const g=graph(),source=g.contributions[1],entry={occurrenceId:source.source.occurrenceId,ingredientId:source.source.ingredientId,label:'No sesame',resolution:{kind:'unresolved'}};
 g.edges=[];source.sourceExclusions=[entry];assert.doesNotThrow(()=>validate(g));entry.ingredientId=null;assert.doesNotThrow(()=>validate(g));
 entry.occurrenceId=id(999);fails(()=>validate(g),'invalid_exclusion_origin');entry.occurrenceId=source.source.occurrenceId;entry.ingredientId=id(998);fails(()=>validate(g),'invalid_exclusion_origin');
 source.sourceExclusions=[];for(const kind of [{kind:'manual'},{kind:'import',batchId:id(700),entryId:id(701)},{kind:'request',requestId:id(702),appliedRequestRevision:1}]){const other=structuredClone(g);other.contributions[0].source=kind;other.contributions[0].sourceExclusions=[{...entry,ingredientId:null}];fails(()=>validate(other),'invalid_exclusion_origin');}
});
test('protected unknown becomes quantified only through explicit same-reservation intent and cannot discard its accepted minimum via Undo',()=>{
 const g=graph();g.edges=g.edges.filter(e=>e.demandId!==id(14));const unknown=g.contributions[3];unknown.quantity=null;unknown.source.bindingId=null;
 const next={...structuredClone(unknown),quantity:quantity(2),source:{...unknown.source,bindingId:id(999)}};
 fails(()=>apply(g,change(g,{contributions:[next]})),'source_identity_changed');
 const result=apply(g,change(g,{contributions:[next],quantifyReservationIds:[unknown.id]}));assert.equal(result.graph.contributions.length,4);assert.equal(result.graph.contributions[3].id,unknown.id);
 fails(()=>undo(result.graph,result.receipt,change(result.graph,{},301)),'protected_quantification_undo');
 fails(()=>apply(g,change(g,{contributions:[{...next,source:{...next.source,groupId:id(998)}}],quantifyReservationIds:[unknown.id]})),'source_identity_changed');
});

function unidentifiedReservation(){const g=graph();g.edges=[];g.contributions=[g.contributions[3]];g.contributions[0].productKey=null;return g;}
test('explicit protected product clarification changes only the unknown key and preserves exact protected need',()=>{
 for(const quantity of [graph().contributions[3].quantity,null]){
  const g=unidentifiedReservation();g.contributions[0].quantity=quantity;const before=structuredClone(g),old=g.contributions[0];
  const replacement={...structuredClone(old),productKey:'food.confirmed-wrap'};
  const result=apply(g,change(g,{contributions:[replacement],clarifyReservationProductIds:[old.id]}));
  assert.deepEqual(g,before);assert.equal(result.graph.contributions.length,1);
  assert.deepEqual(result.graph.contributions[0],replacement);
  assert.deepEqual({...result.graph.contributions[0],productKey:null},old);
  assert.deepEqual(total(result.graph,id(1)),total(g,id(1)));
  assert.deepEqual(result.receipt.contributions,[{id:old.id,before:old,after:replacement}]);
 }
});
test('unlisted protected null product clarification remains forbidden',()=>{
 const g=unidentifiedReservation(),old=g.contributions[0];
 fails(()=>apply(g,change(g,{contributions:[{...old,productKey:'food.confirmed-wrap'}]})),'protected_share_changed');
});
for(const [label,mutate] of [
 ['source identity',c=>c.source.reservationId=id(992)],['source binding',c=>c.source.bindingId=id(993)],
 ['source kind',c=>c.source={kind:'manual'}],['line identity',c=>c.lineId=id(994)],
 ['original source text',c=>c.originalText+=' changed'],['product name',c=>c.productName+=' changed'],
 ['contains',c=>c.contains.push('sesame')],['added exclusion',c=>c.exclusions.push('sesame')],
 ['removed exclusion',c=>c.exclusions=[]],['source exclusion provenance',c=>c.sourceExclusions=[]],
 ['protected quantity reduction',c=>c.quantity=quantity(1)],['protected quantity increase',c=>c.quantity=quantity(3)],
 ['quantity uncertainty',c=>c.quantity=null],['tombstone',c=>c.removedAt=at],
])test('identity clarification does not authorize '+label,()=>{
 const g=unidentifiedReservation(),old=g.contributions[0],next={...structuredClone(old),productKey:'food.confirmed-wrap'};mutate(next);
 fails(()=>apply(g,change(g,{contributions:[next],clarifyReservationProductIds:[old.id]})),'invalid_reservation_product_clarification');
});
test('clarification rejects non-null reassignment and already-known no-op',()=>{
 const g=unidentifiedReservation(),old=g.contributions[0];old.productKey='food.first';
 for(const productKey of ['food.second','food.first'])fails(()=>apply(g,change(g,{contributions:[{...old,productKey}],clarifyReservationProductIds:[old.id]})),'invalid_reservation_product_clarification');
});
test('clarification rejects unknown, omitted, duplicate, removed and nonreservation IDs',()=>{
 const g=unidentifiedReservation(),old=g.contributions[0],next={...old,productKey:'food.confirmed-wrap'};
 fails(()=>apply(g,change(g,{contributions:[next],clarifyReservationProductIds:[id(999)]})),'invalid_reservation_product_clarification');
 fails(()=>apply(g,change(g,{clarifyReservationProductIds:[old.id]})),'invalid_reservation_product_clarification');
 fails(()=>apply(g,change(g,{contributions:[old],clarifyReservationProductIds:[old.id]})),'invalid_reservation_product_clarification');
 fails(()=>apply(g,change(g,{contributions:[next],clarifyReservationProductIds:[old.id,old.id]})),'duplicate_identity');
 for(const altered of [{...old,removedAt:at},{...old,source:{kind:'manual'}}]){
  const other=structuredClone(g);other.contributions=[altered];
  fails(()=>apply(other,change(other,{contributions:[{...altered,productKey:'food.confirmed-wrap'}],clarifyReservationProductIds:[old.id]})),'invalid_reservation_product_clarification');
 }
});
test('identity clarification cannot quantify or rebind the same reservation',()=>{
 const g=unidentifiedReservation(),old=g.contributions[0];old.quantity=null;old.source.bindingId=null;
 const next={...structuredClone(old),productKey:'food.confirmed-wrap',quantity:quantity(2),source:{...old.source,bindingId:id(999)}};
 fails(()=>apply(g,change(g,{contributions:[next],quantifyReservationIds:[old.id],clarifyReservationProductIds:[old.id]})),'invalid_reservation_product_clarification');
});
test('protected clarification cannot be undone into unknown and Undo cannot carry clarification intent',()=>{
 const g=unidentifiedReservation(),old=g.contributions[0],next={...old,productKey:'food.confirmed-wrap'};
 const result=apply(g,change(g,{contributions:[next],clarifyReservationProductIds:[old.id]}));
 fails(()=>undo(result.graph,result.receipt,change(result.graph,{},301)),'protected_product_clarification_undo');
 fails(()=>undo(result.graph,result.receipt,change(result.graph,{clarifyReservationProductIds:[old.id]},301)),'undo_has_changes');
});
test('ordinary manual product edit and unrelated Undo remain available',()=>{
 const g=unidentifiedReservation(),old=g.contributions[0];old.source={kind:'manual'};
 const result=apply(g,change(g,{contributions:[{...old,productKey:'food.confirmed-wrap'}]}));
 const reversed=undo(result.graph,result.receipt,change(result.graph,{},301));assert.deepEqual(reversed.graph.contributions,g.contributions);
 const protectedGraph=unidentifiedReservation(),protectedSource=protectedGraph.contributions[0];
 const clarified=apply(protectedGraph,change(protectedGraph,{contributions:[{...protectedSource,productKey:'food.confirmed-wrap'}],clarifyReservationProductIds:[protectedSource.id]}));
 const manual={...clarified.graph.contributions[0],id:id(998),source:{kind:'manual'}};
 const added=apply(clarified.graph,change(clarified.graph,{contributions:[manual]},302));
 const undone=undo(added.graph,added.receipt,change(added.graph,{},303));
 assert.deepEqual(undone.graph.contributions.find(c=>c.id===protectedSource.id),clarified.graph.contributions[0]);
 assert.equal(undone.graph.contributions.find(c=>c.id===manual.id).removedAt,at);
});


test('retired request acceptance permits a new reviewed generation without changing old source or protected rows',()=>{
 const g=graph();g.contributions[1].source={kind:'request',requestId:id(900),appliedRequestRevision:4};
 const retired=apply(g,change(g,{removeSourceIds:[id(12)]})).graph,before=structuredClone(retired);
 const next={...structuredClone(g.contributions[1]),id:id(901),source:{kind:'request',requestId:id(900),appliedRequestRevision:7},originalText:'Later author wording'};
 const accepted=apply(retired,change(retired,{contributions:[next]},301));
 assert.deepEqual(retired,before);assert.deepEqual(accepted.graph.contributions.filter(c=>c.id!==next.id),retired.contributions);
 assert.deepEqual(accepted.graph.usedIds,[...retired.usedIds,next.id]);assert.deepEqual(accepted.receipt.contributions,[{id:next.id,before:null,after:next}]);
 const tombstone=accepted.graph.contributions.find(c=>c.id===id(12));assert.deepEqual(tombstone,retired.contributions.find(c=>c.id===id(12)));
 const again=apply(accepted.graph,change(accepted.graph,{removeSourceIds:[next.id]},302)).graph;
 const third={...next,id:id(902),source:{...next.source,appliedRequestRevision:9}};
 assert.doesNotThrow(()=>apply(again,change(again,{contributions:[third]},303)));
});
test('request generations cannot duplicate a retained revision or leave two active generations',()=>{
 const g=graph();g.edges=[];g.contributions[1].source={kind:'request',requestId:id(900),appliedRequestRevision:4};
 for(const [oldRemoved,newRemoved,revision] of [[null,null,5],[at,null,4],[at,at,4],[null,at,4]]){
  const x=structuredClone(g);x.contributions[1].removedAt=oldRemoved;
  const extra={...structuredClone(x.contributions[1]),id:id(901),removedAt:newRemoved,source:{kind:'request',requestId:id(900),appliedRequestRevision:revision}};
  x.contributions.push(extra);x.usedIds.push(extra.id);fails(()=>validate(x),'duplicate_source');
 }
});
test('request generation change never permits ID reuse or rewriting a retained source identity',()=>{
 const g=graph();g.contributions[1].source={kind:'request',requestId:id(900),appliedRequestRevision:4};
 const retired=apply(g,change(g,{removeSourceIds:[id(12)]})).graph;
 const next={...g.contributions[1],source:{kind:'request',requestId:id(900),appliedRequestRevision:7}};
 fails(()=>apply(retired,change(retired,{contributions:[next]},301)),'source_identity_changed');
 retired.usedIds.push(id(901));fails(()=>apply(retired,change(retired,{contributions:[{...next,id:id(901)}]},301)),'identity_reused');
});
test('request generation exception does not permit repeated historical import meal or reservation identities',()=>{
 const sources=[{kind:'import',batchId:id(910),entryId:id(911)},graph().contributions[1].source,graph().contributions[3].source];
 for(const source of sources){
  const g=single(quantity(2));g.contributions[0].source=source;g.contributions[0].removedAt=at;
  const copy={...structuredClone(g.contributions[0]),id:id(901)};g.contributions.push(copy);g.usedIds.push(copy.id);
  fails(()=>validate(g),'duplicate_source');
 }
});
