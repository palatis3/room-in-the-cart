import {z} from 'zod';
import {uuid} from './contracts.js';
const text=(max:number,empty=false)=>z.string().max(max).refine(value=>Buffer.byteLength(value,'utf8')<=max&&(empty||value.trim().length>0));
const cents=z.number().int().min(0).max(1_000_000_000_000),date=z.string().datetime({offset:true});
export const sourceVersionSchema=z.object({shopRevision:z.number().int().positive(),authorityEpoch:z.number().int().positive(),financialRevision:z.number().int().min(0)}).strict();
export const costEvidenceSchema=z.discriminatedUnion('kind',[
 z.object({kind:z.literal('exact'),minor:cents}).strict(),
 z.object({kind:z.literal('bounded'),lowerMinor:cents,upperMinor:cents,reason:text(2048)}).strict().refine(v=>v.lowerMinor<=v.upperMinor),
 z.object({kind:z.literal('unknown'),reason:text(2048)}).strict()
]);
export const observationSchema=z.object({id:uuid,shopId:uuid,itemName:text(512),packLabel:text(512),usablePack:z.object({amount:z.object({numerator:z.number().int().positive().max(1e12),denominator:z.number().int().positive().max(1e12)}).strict(),unit:z.enum(['count','gram','kilogram','ounce','pound','milliliter','liter','fluidOunce','cup']),originalLiteral:text(512)}).strict().nullable(),price:costEvidenceSchema,currency:z.literal('USD'),store:text(512),branch:text(512),channel:z.enum(['storeShelf','warehouse','retailerWebsite','retailerApp','other','unspecified']),mode:z.enum(['pickup','delivery','inStore']),eligibility:text(2048,true),observedAt:date,sourceText:text(8192),sourceLocale:text(512)}).strict();
export const observationWriteSchema=z.object({clientKey:uuid,observation:observationSchema}).strict();
export const financialEntrySchema=z.object({id:uuid,evidenceKey:uuid,kind:z.enum(['postedCharge','postedTopUp','pendingCredit','postedCredit','includedCredit','paymentHold','holdRelease']),amountMinor:cents,currency:z.literal('USD'),occurredAt:date,creditId:uuid.nullable(),chargeEvidenceKey:uuid.nullable(),holdEvidenceKey:uuid.nullable(),sourceText:text(8192)}).strict();
export const financialAppendSchema=z.object({clientKey:uuid,sourceVersion:sourceVersionSchema,entry:financialEntrySchema}).strict();
export const financialReviewSchema=z.object({clientKey:uuid,sourceVersion:sourceVersionSchema,allEvidenceEntered:z.boolean(),closeShop:z.boolean()}).strict();
export const historyRetireSchema=z.object({clientKey:uuid,sourceVersion:sourceVersionSchema,confirm:z.literal(true)}).strict();
const reservationSchema=z.object({id:uuid,originalText:text(2048),amountMinor:cents,plannedAt:date,state:z.discriminatedUnion('kind',[z.object({kind:z.literal('reserved')}).strict(),z.object({kind:z.literal('released')}).strict(),z.object({kind:z.literal('applied'),shopId:uuid}).strict()])}).strict();
export const periodSchema=z.object({id:uuid,title:text(512),startsAt:date,endsAt:date,timeZoneId:text(100),currency:z.literal('USD'),shopBudgetMinor:cents,alreadyExcludedReserveMinor:cents.nullable(),shopIds:z.array(uuid).max(100),reservations:z.array(reservationSchema).max(1000),reviewedCompleteAt:date.nullable()}).strict().superRefine((v,c)=>{
 let validZone=true;try{new Intl.DateTimeFormat('en',{timeZone:v.timeZoneId});}catch{validZone=false;}
 if(!validZone||Date.parse(v.startsAt)>=Date.parse(v.endsAt)||new Set(v.shopIds).size!==v.shopIds.length||new Set(v.reservations.map(r=>r.id)).size!==v.reservations.length||v.reservations.some(r=>r.state.kind==='applied'&&!v.shopIds.includes(r.state.shopId))||(v.reviewedCompleteAt&&(Date.parse(v.reviewedCompleteAt)<Date.parse(v.endsAt)||v.reservations.some(r=>r.state.kind==='reserved'))))c.addIssue({code:'custom',message:'Invalid period scope or review'});
});
export const periodWriteSchema=z.object({clientKey:uuid,baseRevision:z.number().int().min(0),period:periodSchema}).strict();
export const budgetQuerySchema=z.object({shopIds:z.array(uuid).max(100)}).strict().refine(v=>new Set(v.shopIds).size===v.shopIds.length);
export type FinancialEntry=z.infer<typeof financialEntrySchema>;
export type SourceVersion=z.infer<typeof sourceVersionSchema>;
export type Period=z.infer<typeof periodSchema>;
