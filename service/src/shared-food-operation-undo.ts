/** Whole-operation inverse for the explicitly recorded, eligible shop.patch subset.
 * Never accepts client-supplied historical facts. All evidence is loaded under current
 * shopper authority; unsupported effects are unavailable, never silently omitted. */
import {z} from 'zod';
import {lineSchema,quoteSchema} from './contracts.js';
import {digest} from './database.js';
import {ServiceError} from './errors.js';
import {checkout} from './checkout.js';
import {sharedDemandReceiptSchema,type DemandGraph} from './shared-demand-contracts.js';
import {validateDemandGraph,undoDemandChange,demandLineTotals} from './shared-demand-domain.js';
import {deriveMealUndo,validateMealUndoHistory,type MealUndoEvidence} from './shared-food-meal-undo.js';
const id=z.string().uuid();
const snapshotSchema=z.object({shopId:id,revision:z.number().int().positive(),phase:z.literal('draft'),
 demand:z.object({schemaVersion:z.literal(1),revision:z.number().int().positive(),digest:z.string().regex(/^[a-f0-9]{64}$/)}).strict(),
 mealRefs:z.array(z.object({occurrenceId:id,revision:z.number().int().positive()}).strict()).optional(),
 quote:quoteSchema,lines:z.array(lineSchema).max(200),budget:z.unknown()}).strict();
export type FoodEffect={operation_id:string;shop_id:string;household_id:string;base_shop_revision:number;result_shop_revision:number;
 base_graph_revision:number;result_graph_revision:number;classification:string;reverses_operation_id:string|null};
export type FoodUndoEvidence={operation:{operation_id:string;household_id:string;shop_id:string;kind:string;payload_digest:string};
 effect:FoodEffect|null;before:{snapshot:unknown;digest:string}|null;after:{snapshot:unknown;digest:string}|null;
 beforeGraph:{graph:unknown;graph_digest:string|null}|null;afterGraph:{graph:unknown;graph_digest:string|null;receipt:unknown}|null;alreadyReversed:boolean;meal?:MealUndoEvidence|null};
export const foodUndoFailure=(reason:string)=>new ServiceError(409,'food_undo_'+reason,'This complete change cannot be undone. Review a supported correction.');
function insist(value:unknown,reason:string):asserts value{if(!value)throw foodUndoFailure(reason);}
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
function snapshot(row:FoodUndoEvidence['before']){
 insist(row&&row.digest!=='0'.repeat(64)&&row.digest===digest(row.snapshot),'history_unavailable');
 const parsed=snapshotSchema.safeParse(row.snapshot);insist(parsed.success,'history_unavailable');
 insist(new Set(parsed.data.lines.map(l=>l.lineId)).size===parsed.data.lines.length,'history_unavailable');
 insist(eq(parsed.data.budget,checkout(parsed.data.lines,parsed.data.quote)),'history_unavailable');return parsed.data;
}
function persistedGraph(row:FoodUndoEvidence['beforeGraph']){
 insist(row?.graph_digest&&row.graph_digest===digest(row.graph),'history_unavailable');return validateDemandGraph(row.graph);
}
function delta<T extends {id:string}>(before:T[],after:T[]){return [...new Set([...before,...after].map(r=>r.id))].flatMap(id=>{
 const b=before.find(r=>r.id===id)??null,a=after.find(r=>r.id===id)??null;return eq(b,a)?[]:[{id,before:b,after:a}];});}
const lineFields=['originalItem','packs','unitPriceMinor','feeEligible'] as const;
// Caps describe the shopper's budget, not the observation/coverage/charge basis.
function pricingBasis(quote:z.infer<typeof quoteSchema>){const {capMinor,capScope,...basis}=quote;return basis;}
function pricingFacts(lines:readonly z.infer<typeof lineSchema>[]){return lines.map(({lineId,originalItem,unitPriceMinor,feeEligible})=>
 ({lineId,originalItem,unitPriceMinor,feeEligible})).sort((a,b)=>a.lineId.localeCompare(b.lineId));}
export function deriveSharedFoodUndo(e:FoodUndoEvidence,current:{graph:DemandGraph;lines:z.infer<typeof lineSchema>[];quote:z.infer<typeof quoteSchema>;shopRevision?:number},
 command:{operationId:string;householdId:string;shopId:string;baseRevision:number;at:string},now:Date){
 const {operation:o,effect:f}=e;
 insist(o.household_id===command.householdId&&o.shop_id===command.shopId,'history_unavailable');
 insist(o.payload_digest!=='0'.repeat(64)&&/^[a-f0-9]{64}$/.test(o.payload_digest),'history_unavailable');
 insist(o.kind==='shop.patch',o.kind==='request.apply'?'request_acceptance_unsupported':'operation_unsupported');
 insist(f,'history_unavailable');insist(!e.alreadyReversed,'already_reversed');insist(f.reverses_operation_id===null,'inverse_operation_unsupported');
 insist(f.classification==='eligible'||(f.classification==='meal_action'&&e.meal),f.classification+'_unsupported');
 insist(f.household_id===o.household_id&&f.shop_id===o.shop_id&&f.operation_id===o.operation_id,'history_unavailable');
 insist(f.base_graph_revision>0&&f.result_graph_revision===f.base_graph_revision+1&&f.result_shop_revision===f.base_shop_revision+1,'history_unavailable');
 const before=snapshot(e.before),after=snapshot(e.after),bg=persistedGraph(e.beforeGraph),ag=persistedGraph(e.afterGraph);
 insist(before.shopId===o.shop_id&&after.shopId===o.shop_id&&before.revision===f.base_shop_revision&&after.revision===f.result_shop_revision,'history_unavailable');
 insist(bg.householdId===o.household_id&&ag.householdId===o.household_id&&bg.shopId===o.shop_id&&ag.shopId===o.shop_id,'history_unavailable');
 insist(bg.revision===f.base_graph_revision&&ag.revision===f.result_graph_revision&&before.demand.revision===bg.revision&&after.demand.revision===ag.revision
   &&before.demand.digest===e.beforeGraph!.graph_digest&&after.demand.digest===e.afterGraph!.graph_digest,'history_unavailable');
 const mealScope={householdId:o.household_id,shopId:o.shop_id,operationId:o.operation_id,
  baseShopRevision:f.base_shop_revision,resultShopRevision:f.result_shop_revision};
 const mealUndo=f.classification==='meal_action'&&e.meal
  ?deriveMealUndo(e.meal,mealScope,before.mealRefs??[],after.mealRefs??[],current.shopRevision??0):undefined;
 if(!mealUndo)insist(eq(before.mealRefs??[],after.mealRefs??[]),'meal_action_unsupported');
 const receipt=sharedDemandReceiptSchema.parse(e.afterGraph!.receipt);
 insist(receipt.operationId===o.operation_id&&receipt.householdId===o.household_id&&receipt.shopId===o.shop_id
   &&receipt.baseRevision===bg.revision&&receipt.resultRevision===ag.revision,'history_unavailable');
 for(const key of ['lines','contributions','edges'] as const){
  const expected=delta(bg[key] as {id:string}[],ag[key] as {id:string}[]);
  insist(eq([...receipt[key]].sort((a,b)=>a.id.localeCompare(b.id)),expected.sort((a,b)=>a.id.localeCompare(b.id))),'history_unavailable');
 }
 insist(current.graph.householdId===o.household_id&&current.graph.shopId===o.shop_id&&current.graph.revision>=ag.revision
   &&command.baseRevision===current.graph.revision,'history_unavailable');
 const lines=current.lines.map(l=>lineSchema.parse(l));insist(new Set(lines.map(l=>l.lineId)).size===lines.length,'history_unavailable');
 const touched:{lineId:string;fields:string[]}[]=[];let pricesRestored=false;
 for(const lineId of new Set([...before.lines,...after.lines].map(l=>l.lineId))){
  const b=before.lines.find(l=>l.lineId===lineId),a=after.lines.find(l=>l.lineId===lineId),index=lines.findIndex(l=>l.lineId===lineId),c=lines[index];
  if(eq(b??null,a??null))continue;
  if(!b||!a){
   insist(eq(c??null,a??null),'line_conflict');
   if(index>=0)lines.splice(index,1);if(b)lines.push(structuredClone(b));
   touched.push({lineId,fields:['membership']});pricesRestored=pricesRestored||!!b;continue;
  }
  insist(c,'line_conflict');const fields=lineFields.filter(key=>!eq(b[key],a[key]));
  for(const key of fields){insist(eq(c[key],a[key]),'line_conflict');Object.assign(c,{[key]:b[key]});}
  if(fields.includes('unitPriceMinor'))pricesRestored=true;touched.push({lineId,fields});
 }
 const quoteChanged=!eq(before.quote,after.quote);
 if(quoteChanged)insist(eq(current.quote,after.quote),'quote_conflict');
 // Moving back to an older pricing basis must not relabel later prices or new
 // lines as observed under that basis. Budget-only Undo does not do this.
 if(!eq(pricingBasis(before.quote),pricingBasis(after.quote)))
  insist(eq(pricingFacts(current.lines),pricingFacts(after.lines)),'quote_conflict');
 // A historical price cannot borrow a later quote's observation/expiry provenance.
 if(pricesRestored&&!quoteChanged)insist(eq(current.quote,before.quote),'quote_conflict');
 const quote=quoteSchema.parse(quoteChanged?before.quote:current.quote);
 if(quoteChanged||pricesRestored)insist(Date.parse(quote.expiresAt)>now.getTime(),'expired_quote');
 const changes=receipt.lines.length+receipt.contributions.length+receipt.edges.length;
 const c={...command,schemaVersion:1,lines:[],contributions:[],edges:[],removeSourceIds:[],removeEdgeIds:[]};
 const result=changes?undoDemandChange(current.graph,receipt,c):{
  graph:validateDemandGraph({...current.graph,revision:current.graph.revision+1}),
  receipt:sharedDemandReceiptSchema.parse({schemaVersion:1,operationId:command.operationId,householdId:command.householdId,shopId:command.shopId,
   baseRevision:current.graph.revision,resultRevision:current.graph.revision+1,lines:[],contributions:[],edges:[]})};
 const totals=demandLineTotals(result.graph);
 insist(totals.length===lines.length&&lines.every(l=>totals.some(t=>t.lineId===l.lineId)&&result.graph.lines.some(g=>g.id===l.lineId&&g.name===l.originalItem)),'graph_conflict');
 insist(changes>0||touched.length>0||quoteChanged||mealUndo,'no_effect');
 const scope={targetOperationId:o.operation_id,baseShopRevision:before.revision,resultShopRevision:after.revision,
  touchedLines:touched,quoteChanged,graphRows:changes,mealsChanged:mealUndo!==undefined,requestsChanged:false};
 const action={kind:'shop.patch' as const,body:{lines,quote,...(mealUndo?{mealEdit:{occurrenceId:mealUndo.occurrenceId,
  baseMealRevision:mealUndo.current.meal===null?null:mealUndo.current.revision,meal:mealUndo.restoredMeal}}:{})}};
 return {action,result,scope,effectDigest:digest({scope,before:e.before!.digest,after:e.after!.digest,receipt,
  currentGraph:digest(current.graph),action,...(mealUndo?{mealUndo}:{})}),beforeCheckout:checkout(current.lines,current.quote),afterCheckout:checkout(lines,quote),
  ...(mealUndo?{mealUndo}:{})};
}
/** Retry returns its original response, never derives/applies a second inverse.
 * It still cannot outlive erasure of the target's trusted historical basis. */
export function assertSharedFoodUndoReplay(e:FoodUndoEvidence){
 insist(e.effect&&(e.effect.classification==='eligible'||(e.effect.classification==='meal_action'&&e.meal))
  &&e.operation.payload_digest!=='0'.repeat(64),'history_unavailable');
 const before=snapshot(e.before),after=snapshot(e.after);persistedGraph(e.beforeGraph);persistedGraph(e.afterGraph);
 if(e.effect.classification==='meal_action'&&e.meal)validateMealUndoHistory(e.meal,{
  householdId:e.operation.household_id,shopId:e.operation.shop_id,operationId:e.operation.operation_id,
  baseShopRevision:e.effect.base_shop_revision,resultShopRevision:e.effect.result_shop_revision},before.mealRefs??[],after.mealRefs??[]);
 else insist(eq(before.mealRefs??[],after.mealRefs??[]),'meal_action_unsupported');
 insist(e.afterGraph?.receipt,'history_unavailable');
 const r=sharedDemandReceiptSchema.parse(e.afterGraph.receipt);
 insist(r.operationId===e.operation.operation_id&&r.householdId===e.operation.household_id&&r.shopId===e.operation.shop_id,'history_unavailable');
}
