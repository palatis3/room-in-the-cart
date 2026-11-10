/** Shared basket/quote compensation. Extracted unchanged from complete shop Undo;
 * request acceptance uses these same touched-field and price-provenance rules. */
import {z} from 'zod';
import {lineSchema,quoteSchema} from './contracts.js';
import {digest} from './database.js';
import {ServiceError} from './errors.js';
function insist(value:unknown,reason:string):asserts value {if(!value)throw new ServiceError(409,'food_undo_'+reason,'This complete change cannot be undone. Review a supported correction.');}
const eq=(a:unknown,b:unknown)=>digest(a)===digest(b);
type Basket={lines:z.infer<typeof lineSchema>[];quote:z.infer<typeof quoteSchema>};
const lineFields=['originalItem','packs','unitPriceMinor','feeEligible'] as const;
// Caps describe the shopper's budget, not the observation/coverage/charge basis.
function pricingBasis(quote:z.infer<typeof quoteSchema>){const {capMinor,capScope,...basis}=quote;return basis;}
function pricingFacts(lines:readonly z.infer<typeof lineSchema>[]){return lines.map(({lineId,originalItem,unitPriceMinor,feeEligible})=>
 ({lineId,originalItem,unitPriceMinor,feeEligible})).sort((a,b)=>a.lineId.localeCompare(b.lineId));}
export function deriveFoodUndoBasket(before:Basket,after:Basket,current:Basket,now:Date){
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
 return {lines,quote,touched,quoteChanged};
}
