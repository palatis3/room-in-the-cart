import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {appendFinancial,settlement,summarizeShop,subtotal,periodSummary,sum} from '../dist/history-math.js';
const entry=(kind,amountMinor,extra={})=>({id:randomUUID(),evidenceKey:randomUUID(),kind,amountMinor,currency:'USD',occurredAt:new Date().toISOString(),creditId:null,chargeEvidenceKey:null,holdEvidenceKey:null,sourceText:'Fictional source',...extra});
const version={shopRevision:1,authorityEpoch:1,financialRevision:0};
test('entered credits and holds do not double-subtract or become spending',()=>{
 const charge=entry('postedCharge',10000),credit=randomUUID();let ledger=appendFinancial([],charge);ledger=appendFinancial(ledger,entry('pendingCredit',2000,{creditId:credit,chargeEvidenceKey:charge.evidenceKey}));const hold=entry('paymentHold',15000);ledger=appendFinancial(ledger,hold);
 assert.deepEqual(settlement(ledger),{postedNetMinor:10000,pendingCreditsMinor:2000,includedCreditsMinor:0,paymentHoldsMinor:15000});
 ledger=appendFinancial(ledger,entry('includedCredit',2000,{creditId:credit,chargeEvidenceKey:charge.evidenceKey}));ledger=appendFinancial(ledger,entry('holdRelease',15000,{holdEvidenceKey:hold.evidenceKey}));assert.deepEqual(settlement(ledger),{postedNetMinor:10000,pendingCreditsMinor:0,includedCreditsMinor:2000,paymentHoldsMinor:0});
 assert.throws(()=>appendFinancial(ledger,entry('postedCredit',2000,{creditId:credit,chargeEvidenceKey:charge.evidenceKey})),e=>e.code==='invalid_financial_evidence');assert.throws(()=>appendFinancial(ledger,entry('holdRelease',15000,{holdEvidenceKey:hold.evidenceKey})));
});
test('posted cash is inside an inclusive expectation and unresolved review stays conditional',()=>{
 const charge=entry('postedCharge',4000),pending=entry('pendingCredit',500,{creditId:randomUUID(),chargeEvidenceKey:charge.evidenceKey});const value=summarizeShop(randomUUID(),version,[charge,pending],{lowerMinor:10000,upperMinor:10000},true);
 assert.equal(value.reconciledEntered,false);assert.deepEqual(value.projectedCommitment,{lowerMinor:10000,upperMinor:10000});assert.deepEqual(value.expectedUnpaid,{lowerMinor:6000,upperMinor:6000});
 const exact=summarizeShop(randomUUID(),version,[charge],{lowerMinor:10000,upperMinor:10000},true);assert.equal(exact.reconciledEntered,true);assert.deepEqual(exact.projectedCommitment,{lowerMinor:4000,upperMinor:4000});
 const unknown=summarizeShop(randomUUID(),version,[charge],null,false);assert.deepEqual(unknown.projectedCommitment,{lowerMinor:4000,upperMinor:null});
});
test('period reservation transfers count once and already-excluded reserve is explanatory only',()=>{
 const shop=summarizeShop(randomUUID(),version,[],{lowerMinor:3000,upperMinor:5000},false),period={shopBudgetMinor:10000,alreadyExcludedReserveMinor:20000,reservations:[{amountMinor:1000,state:{kind:'reserved'}},{amountMinor:3000,state:{kind:'applied',shopId:shop.shopId}},{amountMinor:2000,state:{kind:'released'}}],reviewedCompleteAt:null};
 const result=periodSummary(period,[shop],new Date());assert.equal(result.futureReservedMinor,1000);assert.deepEqual(result.remaining,{minimumMinor:4000,maximumMinor:6000});assert.equal('savings'in result,false);
 const partial=subtotal([shop]);assert.equal('remaining'in partial,false);assert.equal('futureReservedMinor'in partial,false);assert.equal('hiddenCount'in partial,false);
 assert.equal(periodSummary(period,[{...shop,projectedCommitment:{lowerMinor:3000,upperMinor:null}}],new Date()).remaining.minimumMinor,null);
 assert.throws(()=>sum([Number.MAX_SAFE_INTEGER,1]));
});
