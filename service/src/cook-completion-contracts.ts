import {z} from 'zod';
import {mealQuantity} from './shared-meal-planning.js';

const id=z.string().uuid().toLowerCase();
const revision=z.number().int().min(0).max(2_147_483_647);
const base={grantEpoch:revision,pantryRevision:revision,supplyRevision:revision,recoveryRevision:revision,contextRevision:revision,
  occurrenceId:id,mealRevision:revision.min(1),recipeRevisionId:id};
const row={rowId:id,needId:id};
const use=z.discriminatedUnion('kind',[
  z.object({...row,kind:z.literal('known'),lotId:id,headId:id,quantity:mealQuantity}).strict(),
  z.object({...row,kind:z.literal('unknown'),lotId:id.nullable(),headId:id.nullable()}).strict().refine(v=>(v.lotId===null)===(v.headId===null)),
  z.object({...row,kind:z.literal('notUsed')}).strict(),
]);
const output=z.object({lotId:id,name:z.string().trim().min(1).max(120).regex(/^[^\u0000-\u001F\u007F]+$/u),
  portions:z.number().int().min(1).max(1000),location:z.enum(['fridge','freezer','pantry']),
  useFirstAt:z.iso.datetime({offset:true}).optional(),
  allocations:z.array(z.object({needId:id,portions:z.number().int().min(1).max(1000)}).strict()).max(30).optional()}).strict();
export const cookBodies={
  'cook.complete':z.object({...base,servings:z.number().int().min(1).max(1000),uses:z.array(use).max(200),
    outputs:z.array(output).max(12)}).strict(),
  'cook.undo':z.object({...base,cookId:id}).strict(),
  'cook.resolve':z.object({...base,cookId:id,rowId:id,lotId:id,headId:id,quantity:mealQuantity,includedInCount:z.boolean()}).strict(),
};
export type CookKind=keyof typeof cookBodies;
export function isCookCommand(kind:string):kind is CookKind{return Object.hasOwn(cookBodies,kind);}
