import type { BasketLine, BudgetResult, QuoteBasis } from '../../shared/contracts/service-v1.js';
import { invalid } from './errors.js';
export function checkout(lines: readonly BasketLine[], quote: QuoteBasis): BudgetResult {
  const missing: string[]=[];
  let goods=0n,eligible=0n,eligibleKnown=quote.complete;
  if(!quote.complete)missing.push('remaining_original_items');
  for(const line of lines) {
    if(line.unitPriceMinor===null) {missing.push('line_price');if(line.feeEligible)eligibleKnown=false;}
    else {const amount=BigInt(line.packs)*BigInt(line.unitPriceMinor);goods+=amount;if(line.feeEligible)eligible+=amount;}
  }
  const fee: number|null=quote.fee.kind==='fixed'?quote.fee.amountMinor:
    eligible>=BigInt(quote.fee.thresholdMinor)?quote.fee.aboveMinor:eligibleKnown?quote.fee.belowMinor:null;
  if(fee===null)missing.push('fee');
  if(quote.taxesMinor===null)missing.push('tax');
  if(quote.depositsMinor===null)missing.push('deposit');
  if(quote.discountsMinor===null)missing.push('discount');
  const knownSum=goods+BigInt(fee??0)+BigInt(quote.taxesMinor??0)+BigInt(quote.depositsMinor??0)-BigInt(quote.discountsMinor??0);
  if(knownSum>BigInt(Number.MAX_SAFE_INTEGER)||(!missing.length&&knownSum<0n))throw invalid();
  const lowerBoundMinor=quote.discountsMinor===null?0:Math.max(0,Number(knownSum));
  const totalMinor=missing.length?null:Number(knownSum);
  const sameScope=quote.capScope===quote.scope;
  const comparable=totalMinor!==null&&quote.capMinor!==null&&sameScope;
  if(quote.capMinor===null)missing.push('cap');
  if(!sameScope)missing.push('scope_mismatch');
  const overCapMinor=comparable?Math.max(0,totalMinor!-quote.capMinor!):null;
  const status=!sameScope?'scopeMismatch':comparable?(overCapMinor!>0?'overCap':'withinCap'):'unresolved';
  return{currency:'USD',totalMinor,overCapMinor,headroomMinor:comparable?quote.capMinor!-totalMinor!:null,
    status,scope:quote.scope,missing:[...new Set(missing)],lowerBoundMinor,upperBoundMinor:totalMinor,
    wholeCheckoutWithinCap:quote.scope==='wholeCheckout'&&status==='withinCap'};
}
