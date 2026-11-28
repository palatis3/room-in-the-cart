import {z} from 'zod';
import {day} from './renewal-facts.js';

const uuid=z.string().uuid();
const manageURL='https://apps.apple.com/account/subscriptions';
export interface NoticeMessage {date:number; amountMilli:number; purpose:'reminder'|'correction'}
export interface NoticeProvider {
  ready(signal:AbortSignal):Promise<boolean>;
  send(key:string,to:string,message:NoticeMessage,signal:AbortSignal):Promise<string>;
  delivery(id:string,signal:AbortSignal):Promise<'accepted'|'delivered'|'failed'>;
}

export function noticeText(m:NoticeMessage) {
  const date=new Date(m.date);
  const when=(locale:string)=>new Intl.DateTimeFormat(locale,{timeZone:'America/Mexico_City',dateStyle:'long',timeStyle:'short'}).format(date);
  const cost=new Intl.NumberFormat('es-MX',{style:'currency',currency:'MXN',currencyDisplay:'code'}).format(m.amountMilli/1000);
  const correction=m.purpose==='correction';
  return {
    subject:correction?'Actualización de tu renovación anual / Annual renewal update':'Tu renovación anual / Your annual renewal',
    text:[
      correction?'Estos datos actualizan el aviso anterior.':'Recordatorio de renovación de Venture House Group.',
      'Apple indica que la suscripción anual de Room in the Cart se renovará por '+cost+' el '+when('es-MX')+' (hora de la Ciudad de México).',
      'Puedes administrarla o cancelarla con Apple antes de la renovación: '+manageURL,
      '',
      correction?'These details update your earlier notice.':'A renewal reminder from Venture House Group.',
      'Apple shows your Room in the Cart annual subscription renewing for '+cost+' on '+when('en-US')+' (Mexico City time).',
      'Manage or cancel with Apple before renewal: '+manageURL,
      'UTC: '+date.toISOString()
    ].join('\n')
  };
}

export class ResendRenewalProvider implements NoticeProvider {
  constructor(private readonly apiKey:string,private readonly address:string,private readonly domainID:string,
    private readonly fetcher:typeof fetch=fetch){}
  private async call(path:string,options:RequestInit,signal:AbortSignal) {
    const response=await this.fetcher('https://api.resend.com/'+path,{...options,redirect:'error',
      headers:{Authorization:'Bearer '+this.apiKey,'Content-Type':'application/json',...options.headers},
      signal:AbortSignal.any([signal,AbortSignal.timeout(2200)])});
    if(!response.ok){await response.body?.cancel();throw new Error('Renewal provider request unconfirmed');}
    return response.json();
  }
  async ready(signal:AbortSignal) {
    const domain=await this.call('domains/'+this.domainID,{},signal);
    return domain.id===this.domainID&&domain.name===this.address.split('@')[1]&&domain.status==='verified'
      && domain.click_tracking===false&&domain.open_tracking===false;
  }
  async send(key:string,to:string,message:NoticeMessage,signal:AbortSignal) {
    const id=uuid.parse(key);
    const result=await this.call('emails',{method:'POST',headers:{'Idempotency-Key':'renewal/'+id},
      body:JSON.stringify({from:'Venture House Group <'+this.address+'>',to:[z.email().parse(to)],...noticeText(message)})},signal);
    return uuid.parse(result.id);
  }
  async delivery(id:string,signal:AbortSignal) {
    const result=await this.call('emails/'+uuid.parse(id),{},signal);
    if(result.id!==id)throw new Error('Unexpected renewal delivery record');
    if(result.last_event==='delivered')return 'delivered';
    if(['bounced','complained','failed','canceled','suppressed'].includes(result.last_event))return 'failed';
    return 'accepted';
  }
}

export function renewalConfig(env:NodeJS.ProcessEnv) {
  const mode=env.MX_RENEWAL_NOTICES_MODE??'off';
  const testIDs=(env.MX_RENEWAL_SANDBOX_PREFLIGHT_HOUSEHOLDS??'').split(',').map(v=>v.trim().toLowerCase()).filter(Boolean);
  const verifiedReview=new Set((env.APPLE_REVIEW_HOUSEHOLD_IDS??'').split(',').map(v=>v.trim().toLowerCase()));
  if(testIDs.some(id=>!uuid.safeParse(id).success||!verifiedReview.has(id))||(testIDs.length&&env.APPLE_ENVIRONMENT!=='Production'))
    throw Error('Sandbox preflight requires explicitly scoped review households');
  const sandboxHomes=new Set(testIDs);
  if(mode!=='off'&&mode!=='observe'&&mode!=='send')throw Error('Invalid renewal notice mode');
  if(mode!=='send')return {mode,provider:null,sandboxHomes} as const;
  // Provider-side log retention is a separate account/contract setting. Fail closed
  // until the operator verifies it, in addition to the live domain tracking checks.
  if(!/^(?:[1-9]|[12][0-9]|30)$/.test(env.MX_RENEWAL_VERIFIED_PROVIDER_RETENTION_DAYS??''))
    throw Error('Verified provider retention of at most 30 days is required');
  const address=z.email().parse(env.MX_RENEWAL_FROM);
  if(!/^(?:[a-z0-9-]+\.)*roominthecart\.com$/.test(address.split('@')[1]??'')||!env.MX_RENEWAL_RESEND_KEY||
     !env.JWT_ISSUER||env.APPLE_ENVIRONMENT!=='Production')throw Error('Incomplete Production renewal configuration');
  return {mode,sandboxHomes,provider:new ResendRenewalProvider(env.MX_RENEWAL_RESEND_KEY,address,uuid.parse(env.MX_RENEWAL_RESEND_DOMAIN_ID))} as const;
}
export type RenewalConfig=ReturnType<typeof renewalConfig>;
export const providerRetryWindow=day-5*60_000;
