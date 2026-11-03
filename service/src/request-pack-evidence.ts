import {z} from 'zod';
const integer=z.string().regex(/^(0|[1-9][0-9]{0,18})$/).refine(v=>{try{return BigInt(v)<=9223372036854775807n;}catch{return false;}});
const quantity=z.object({numerator:integer.refine(v=>{try{return BigInt(v)>0n;}catch{return false;}}),denominator:integer.refine(v=>{try{return BigInt(v)>0n;}catch{return false;}}),unit:z.enum(['count','gram','kilogram','ounce','pound','milliliter','liter','fluidOunce','cup']),originalLiteral:z.string().max(2048)}).strict();
export const reviewedPackEvidenceSchema=z.object({
  version:z.literal(1),offerId:z.string().min(1).max(128),label:z.string().min(1).max(240),needed:quantity,usablePerPack:quantity,
  packs:z.number().int().min(1).max(10000),unitPriceMinor:z.number().int().min(0).max(1_000_000_000).nullable(),
  productMatchConfirmed:z.literal(true),availabilityConfirmed:z.literal(true),availablePackLimit:z.number().int().min(0).max(10000).nullable(),
  quoteSource:z.string().min(1).max(2048).refine(v=>v.trim().length>0),quoteObservedAt:z.string().datetime({offset:true}),reviewedAt:z.string().datetime({offset:true})
}).strict();
export type ReviewedPackEvidence=z.infer<typeof reviewedPackEvidenceSchema>;
const units:Record<ReviewedPackEvidence['needed']['unit'],[string,bigint,bigint]>={
 count:['count',1n,1n],gram:['mass',1n,1n],kilogram:['mass',1000n,1n],ounce:['mass',45359237n,1600000n],pound:['mass',45359237n,100000n],
 milliliter:['volume',1n,1n],liter:['volume',1000n,1n],fluidOunce:['volume',473176473n,16000000n],cup:['volume',473176473n,2000000n]
};
/** Validate the chosen whole-pack projection, not global cheapest or retailer truth. */
export function matchesReviewedPack(line:{originalItem:string;packs:number;unitPriceMinor:number|null},e:ReviewedPackEvidence):boolean {
 try {
 if(line.originalItem!==e.label||line.packs!==e.packs||line.unitPriceMinor!==e.unitPriceMinor||e.availablePackLimit!==null&&e.packs>e.availablePackLimit)return false;
 const [dimension,nf,nd]=units[e.needed.unit],[other,uf,ud]=units[e.usablePerPack.unit];
 if(dimension!==other)return false;
 const numerator=BigInt(e.needed.numerator)*nf*BigInt(e.usablePerPack.denominator)*ud;
 const denominator=BigInt(e.needed.denominator)*nd*BigInt(e.usablePerPack.numerator)*uf;
 if(numerator<=0n||denominator<=0n)return false;
 const packs=(numerator+denominator-1n)/denominator;
 return packs===BigInt(e.packs)&&Date.parse(e.quoteObservedAt)<=Date.parse(e.reviewedAt)+300000;
 }catch{return false;}
}
