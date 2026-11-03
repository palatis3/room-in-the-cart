import type {FinancialEntry,Period,SourceVersion} from './history-contracts.js';
import {ServiceError} from './errors.js';
const invalid=()=>new ServiceError(422,'invalid_financial_evidence','Review the linked charge, credit or hold evidence.');
export function sum(values:number[]){let value=0n;for(const n of values){if(!Number.isSafeInteger(n))throw invalid();value+=BigInt(n);}if(value>BigInt(Number.MAX_SAFE_INTEGER)||value<BigInt(Number.MIN_SAFE_INTEGER))throw invalid();return Number(value);}
export function appendFinancial(entries:FinancialEntry[],entry:FinancialEntry){
 const old=entries.find(e=>e.id===entry.id||e.evidenceKey===entry.evidenceKey);if(old)throw new ServiceError(409,'evidence_reused','Use the original operation key or review genuinely new evidence.');
 if(['pendingCredit','postedCredit','includedCredit'].includes(entry.kind)){
  if(entry.holdEvidenceKey||!entry.creditId||!entry.chargeEvidenceKey||!entries.some(e=>e.evidenceKey===entry.chargeEvidenceKey&&['postedCharge','postedTopUp'].includes(e.kind)))throw invalid();
  const siblings=entries.filter(e=>e.creditId===entry.creditId);if(siblings.some(e=>e.chargeEvidenceKey!==entry.chargeEvidenceKey)||siblings.some(e=>['postedCredit','includedCredit'].includes(e.kind))||(entry.kind==='pendingCredit'&&siblings.some(e=>e.kind==='pendingCredit')))throw invalid();
 }else if(entry.kind==='holdRelease'){
  const hold=entries.find(e=>e.evidenceKey===entry.holdEvidenceKey&&e.kind==='paymentHold');if(entry.creditId||entry.chargeEvidenceKey||!hold||hold.amountMinor!==entry.amountMinor||entries.some(e=>e.kind==='holdRelease'&&e.holdEvidenceKey===entry.holdEvidenceKey))throw invalid();
 }else if(entry.creditId||entry.chargeEvidenceKey||entry.holdEvidenceKey)throw invalid();
 const result=[...entries,entry];settlement(result);return result;
}
export function settlement(entries:FinancialEntry[]){
 const settled=new Set(entries.filter(e=>['postedCredit','includedCredit'].includes(e.kind)).map(e=>e.creditId));
 return{postedNetMinor:sum(entries.map(e=>['postedCharge','postedTopUp'].includes(e.kind)?e.amountMinor:e.kind==='postedCredit'?-e.amountMinor:0)),pendingCreditsMinor:sum(entries.filter(e=>e.kind==='pendingCredit'&&!settled.has(e.creditId)).map(e=>e.amountMinor)),includedCreditsMinor:sum(entries.filter(e=>e.kind==='includedCredit').map(e=>e.amountMinor)),paymentHoldsMinor:sum(entries.map(e=>e.kind==='paymentHold'?e.amountMinor:e.kind==='holdRelease'?-e.amountMinor:0))};
}
export interface MoneyRange{lowerMinor:number;upperMinor:number|null}
export interface ShopSummary{shopId:string;sourceVersion:SourceVersion;currency:'USD';postedNetMinor:number;pendingCreditsMinor:number;includedCreditsMinor:number;paymentHoldsMinor:number;expectedUnpaid:MoneyRange;projectedCommitment:MoneyRange;reconciledEntered:boolean}
export function summarizeShop(shopId:string,sourceVersion:SourceVersion,entries:FinancialEntry[],expectation:MoneyRange|null,reviewed:boolean):ShopSummary{
 const value=settlement(entries),reconciledEntered=reviewed&&value.pendingCreditsMinor===0&&value.paymentHoldsMinor===0;
 const projectedCommitment=reconciledEntered?{lowerMinor:value.postedNetMinor,upperMinor:value.postedNetMinor}:expectation?{lowerMinor:Math.max(value.postedNetMinor,expectation.lowerMinor),upperMinor:expectation.upperMinor===null?null:Math.max(value.postedNetMinor,expectation.upperMinor)}:{lowerMinor:Math.max(0,value.postedNetMinor),upperMinor:null};
 return{shopId,sourceVersion,currency:'USD',...value,expectedUnpaid:{lowerMinor:sum([projectedCommitment.lowerMinor,-value.postedNetMinor]),upperMinor:projectedCommitment.upperMinor===null?null:sum([projectedCommitment.upperMinor,-value.postedNetMinor])},projectedCommitment,reconciledEntered};
}
function ranges(values:MoneyRange[]){return{lowerMinor:sum(values.map(v=>v.lowerMinor)),upperMinor:values.some(v=>v.upperMinor===null)?null:sum(values.map(v=>v.upperMinor!))};}
export function subtotal(shops:ShopSummary[]){return{shops,currency:'USD' as const,postedNetMinor:sum(shops.map(s=>s.postedNetMinor)),pendingCreditsMinor:sum(shops.map(s=>s.pendingCreditsMinor)),includedCreditsMinor:sum(shops.map(s=>s.includedCreditsMinor)),paymentHoldsMinor:sum(shops.map(s=>s.paymentHoldsMinor)),expectedUnpaid:ranges(shops.map(s=>s.expectedUnpaid)),projectedCommitment:ranges(shops.map(s=>s.projectedCommitment))};}
export function periodSummary(period:Period,shops:ShopSummary[],now:Date){
 const permitted=subtotal(shops),futureReservedMinor=sum(period.reservations.filter(r=>r.state.kind==='reserved').map(r=>r.amountMinor));
 return{permitted,futureReservedMinor,remaining:{minimumMinor:permitted.projectedCommitment.upperMinor===null?null:sum([period.shopBudgetMinor,-permitted.projectedCommitment.upperMinor,-futureReservedMinor]),maximumMinor:sum([period.shopBudgetMinor,-permitted.projectedCommitment.lowerMinor,-futureReservedMinor])},reconciledEnteredPeriod:Boolean(period.reviewedCompleteAt&&Date.parse(period.reviewedCompleteAt)<=now.getTime()&&futureReservedMinor===0&&shops.every(s=>s.reconciledEntered))};
}
