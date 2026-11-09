/** Versioned draft commitments only. These records are not physical stock or packs. */
import {z} from 'zod';
const id=z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
const text=z.string().min(1).max(2048);
const tag=z.string().min(1).max(128).regex(/^[a-z0-9][a-z0-9._-]*$/);
const time=z.iso.datetime({offset:true});
export const demandUnitSchema=z.enum(['count','gram','kilogram','ounce','pound','milliliter','liter','fluidOunce','cup']);
const positive=z.string().regex(/^[1-9][0-9]{0,18}$/).refine(s=>BigInt(s)<=9223372036854775807n,'Int64 bound');
export const demandAmountSchema=z.object({numerator:positive,denominator:positive}).strict().refine(q=>{
 let a=BigInt(q.numerator),b=BigInt(q.denominator);while(b){[a,b]=[b,a%b];}return a===1n;
},'Use a reduced rational');
export const demandQuantitySchema=z.object({amount:demandAmountSchema,unit:demandUnitSchema,originalLiteral:text,
 confirmedConversion:z.object({sourceUnit:demandUnitSchema,targetUnit:demandUnitSchema,targetAmountPerSourceUnit:demandAmountSchema,sourceNote:text,confirmedAt:time}).strict().nullable(),
}).strict();
const source=z.discriminatedUnion('kind',[
 z.object({kind:z.literal('manual')}).strict(),
 z.object({kind:z.literal('request'),requestId:id,appliedRequestRevision:z.number().int().min(0).max(2147483647)}).strict(),
 z.object({kind:z.literal('import'),batchId:id,entryId:id}).strict(),
 z.object({kind:z.literal('meal'),occurrenceId:id,ingredientId:id,groupId:id.nullable(),bindingId:id.nullable()}).strict(),
 z.object({kind:z.literal('reservation'),reservationId:id,purpose:text,originOccurrenceId:id.nullable(),ingredientId:id,groupId:id,bindingId:id}).strict(),
]);
export const demandLineSchema=z.object({id,name:text,unit:demandUnitSchema,originalOrder:z.number().int().min(0).max(10000),trashedAt:time.nullable()}).strict();
export const demandContributionSchema=z.object({id,lineId:id,source,productKey:tag.nullable(),productName:text,
 originalText:text,quantity:demandQuantitySchema.nullable(),exclusions:z.array(tag).max(60),contains:z.array(tag).max(60),removedAt:time.nullable()}).strict();
export const demandEdgeSchema=z.object({id,kind:z.enum(['duplicate','withinExisting']),demandId:id,supplyId:id,quantity:demandQuantitySchema,
 confirmation:z.object({productMatchConfirmed:z.literal(true),confirmedAt:time,evidence:text}).strict()}).strict();
const revision=z.number().int().min(0).max(2147483647);
export const sharedDemandGraphSchema=z.object({schemaVersion:z.literal(1),conversionTableVersion:z.literal('us-customary-metric-v1'),
 householdId:id,shopId:id,revision,lines:z.array(demandLineSchema).max(200),contributions:z.array(demandContributionSchema).max(2000),
 edges:z.array(demandEdgeSchema).max(4000),usedIds:z.array(id).max(10000)}).strict();
/** Upserts have stable IDs; removed sources are tombstones, never hard deletes. */
export const sharedDemandChangeSchema=z.object({schemaVersion:z.literal(1),operationId:id,householdId:id,shopId:id,baseRevision:revision,at:time,
 lines:z.array(demandLineSchema).max(200),contributions:z.array(demandContributionSchema).max(2000),edges:z.array(demandEdgeSchema).max(4000),
 removeSourceIds:z.array(id).max(2000),removeEdgeIds:z.array(id).max(4000)}).strict();
function delta<T extends z.ZodType>(value:T){return z.object({id,before:value.nullable(),after:value.nullable()}).strict();}
export const sharedDemandReceiptSchema=z.object({schemaVersion:z.literal(1),operationId:id,householdId:id,shopId:id,
 baseRevision:revision,resultRevision:revision,lines:z.array(delta(demandLineSchema)).max(200),
 contributions:z.array(delta(demandContributionSchema)).max(2000),edges:z.array(delta(demandEdgeSchema)).max(4000)}).strict();
export type DemandGraph=z.infer<typeof sharedDemandGraphSchema>;
export type DemandChange=z.infer<typeof sharedDemandChangeSchema>;
export type DemandReceipt=z.infer<typeof sharedDemandReceiptSchema>;
export type DemandQuantity=z.infer<typeof demandQuantitySchema>;
export type DemandContribution=z.infer<typeof demandContributionSchema>;
export type DemandEdge=z.infer<typeof demandEdgeSchema>;

/** JSON Schema covers wire structure. Cross-record/conservation checks are mandatory. */
export function sharedDemandJSONSchema(){return {$schema:'https://json-schema.org/draft/2020-12/schema',
 title:'Shared draft demand graph v1', $ref:'#/$defs/graph',
 $defs:{graph:z.toJSONSchema(sharedDemandGraphSchema),change:z.toJSONSchema(sharedDemandChangeSchema),receipt:z.toJSONSchema(sharedDemandReceiptSchema)},
 'x-semantic-validation':'shared-demand-domain.validateDemandGraph/applyDemandChange; reduced Int64 rationals, identity/reference/cycle, product/exclusion, capacity and protected conservation checks remain mandatory.'};}
