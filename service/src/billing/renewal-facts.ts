import type {JWSTransactionDecodedPayload,JWSRenewalInfoDecodedPayload} from '@apple/app-store-server-library';
import type {VerifiedSubscription} from './domain.js';

export const day = 86_400_000;
const instant=(n:unknown):n is number=>typeof n==='number' && Number.isSafeInteger(n) && n>0 && n<8.64e15;

export interface RenewalFacts { signedAt:number; date:number; amountMilli:number; currency:'MXN' }

/** Call only after separately verifying both Apple signatures and the series, product and account-token binding. */
export function mexicoRenewal(transaction:JWSTransactionDecodedPayload,renewal:JWSRenewalInfoDecodedPayload,product:string):RenewalFacts|null {
  if(transaction.environment!=='Production'||transaction.storefront!=='MEX'||renewal.environment!=='Production'||
    transaction.productId!==product||renewal.productId!==product||renewal.autoRenewProductId!==product||
    renewal.autoRenewStatus!==1||renewal.isInBillingRetryPeriod===true||renewal.priceIncreaseStatus===0||
    transaction.revocationDate!==undefined||transaction.isUpgraded===true||renewal.currency!=='MXN'||
    !instant(renewal.renewalDate)||!instant(renewal.signedDate)||!Number.isSafeInteger(renewal.renewalPrice)||
    !renewal.renewalPrice||renewal.renewalPrice<0||renewal.renewalPrice%10!==0) return null;
  return {signedAt:renewal.signedDate,date:renewal.renewalDate,amountMilli:renewal.renewalPrice,currency:'MXN'};
}

export interface PreviousNotice {date:number;amountMilli:number;sentAt:number;purpose:'reminder'|'correction'}
export function nextNotice(state:VerifiedSubscription,now:number,previous?:PreviousNotice) {
  const facts=state.noticeFacts;
  if(state.environment!=='Production'||state.status!=='active'||state.mxAnnual!==true||state.expiresAt<=now||!facts) return 'not_ready';
  if(facts.signedAt>now+5*60_000||facts.signedAt<now-day)return 'not_ready';
  const unchanged=previous?.date===facts.date&&previous.amountMilli===facts.amountMilli;
  // The job runs daily. Six elapsed days leaves a margin above five local calendar
  // days even across Mexican border-zone DST transitions. Do not infer the payer's zone.
  if(now>facts.date-6*day)return unchanged?'unchanged':'late';
  if(previous&&!unchanged)return 'correction';
  if(unchanged){
    if(previous.purpose!=='correction'||previous.sentAt>=facts.date-7*day)return 'unchanged';
    return now>=facts.date-7*day?'reminder':'early';
  }
  return now<facts.date-7*day?'early':'reminder';
}
