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

const mexicanZones=['America/Tijuana','America/Hermosillo','America/Mazatlan','America/Bahia_Banderas','America/Mexico_City',
  'America/Merida','America/Monterrey','America/Chihuahua','America/Ciudad_Juarez','America/Ojinaga','America/Matamoros','America/Cancun'];
const zoneDates=mexicanZones.map(timeZone=>new Intl.DateTimeFormat('en-CA',{timeZone,year:'numeric',month:'2-digit',day:'2-digit'}));
export function sufficientCalendarNotice(now:number,renewal:number):boolean {
  if(renewal-now>=6*day)return true;
  if(renewal-now<4*day)return false;
  const localDay=(zone:Intl.DateTimeFormat,instant:number)=>{
    const fields=Object.fromEntries(zone.formatToParts(instant).map(p=>[p.type,p.value]));
    return Date.UTC(Number(fields.year),Number(fields.month)-1,Number(fields.day));
  };
  return zoneDates.every(zone=>localDay(zone,renewal)-localDay(zone,now)>=5*day);
}

export interface PreviousNotice {date:number;amountMilli:number;sentAt:number;purpose:'reminder'|'correction'}
export function nextNotice(state:VerifiedSubscription,now:number,previous?:PreviousNotice) {
  const facts=state.noticeFacts;
  if(state.environment!=='Production'||state.status!=='active'||state.mxAnnual!==true||state.expiresAt<=now||!facts) return 'not_ready';
  if(facts.signedAt>now+5*60_000)return 'not_ready';
  const unchanged=previous?.date===facts.date&&previous.amountMilli===facts.amountMilli;
  // Without the payer's residence, the smallest calendar lead across Mexico governs.
  if(!sufficientCalendarNotice(now,facts.date))return unchanged?'unchanged':'late';
  if(previous&&!unchanged)return 'correction';
  if(unchanged){
    if(previous.purpose!=='correction'||previous.sentAt>=facts.date-7*day)return 'unchanged';
    return now>=facts.date-7*day?'reminder':'early';
  }
  return now<facts.date-7*day?'early':'reminder';
}
