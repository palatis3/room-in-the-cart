import {z} from 'zod';
import {probeRenewalSender} from './renewal-sender-health.js';
import {webhookKey} from './renewal-webhook.js';
import {day} from './renewal-facts.js';

const uuid=z.string().uuid();
const manageURL='https://apps.apple.com/account/subscriptions';
export interface NoticeMessage {date:number; amountMilli:number; purpose:'reminder'|'correction'}
export interface NoticeProvider {
  ready(signal:AbortSignal):Promise<boolean>;
  send(key:string,to:string,message:NoticeMessage,signal:AbortSignal):Promise<string>;
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
  constructor(private readonly apiKey:string,private readonly address:string,
    private readonly fetcher:typeof fetch=fetch,private readonly probe=probeRenewalSender){}
  private async call(path:string,options:RequestInit,signal:AbortSignal) {
    const response=await this.fetcher('https://api.resend.com/'+path,{...options,redirect:'error',
      headers:{Authorization:'Bearer '+this.apiKey,'Content-Type':'application/json',...options.headers},
      signal:AbortSignal.any([signal,AbortSignal.timeout(2200)])});
    if(!response.ok){await response.body?.cancel();throw new Error('Renewal provider request unconfirmed');}
    return response.json();
  }
  async ready(signal:AbortSignal) {
    // The sender uses a domain-scoped sending_access key. Operator verification
    // of DNS and disabled tracking precedes enablement. The worker records health.
    return this.probe(this.apiKey,signal);
  }
  async send(key:string,to:string,message:NoticeMessage,signal:AbortSignal) {
    const id=uuid.parse(key);
    const result=await this.call('emails',{method:'POST',headers:{'Idempotency-Key':'renewal/'+id},
      body:JSON.stringify({from:'Venture House Group <'+this.address+'>',to:[z.email().parse(to)],tags:[{name:'renewal_dispatch',value:id}],...noticeText(message)})},signal);
    return uuid.parse(result.id);
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
  const webhook=env.MX_RENEWAL_WEBHOOK_SECRET?webhookKey(env.MX_RENEWAL_WEBHOOK_SECRET):undefined;
  if(mode!=='send')return {mode,provider:null,sandboxHomes,webhook} as const;
  const address=z.email().parse(env.MX_RENEWAL_FROM);
  if(!/^(?:[a-z0-9-]+\.)*roominthecart\.com$/.test(address.split('@')[1]??'')||!env.MX_RENEWAL_RESEND_KEY||
     !webhook||env.MX_RENEWAL_TRACKING_DISABLED!=='true'||!env.JWT_ISSUER||env.APPLE_ENVIRONMENT!=='Production')throw Error('Incomplete Production renewal configuration');
  return {mode,sandboxHomes,webhook,provider:new ResendRenewalProvider(env.MX_RENEWAL_RESEND_KEY,address)} as const;
}
export interface RenewalConfig {
  mode:'off'|'observe'|'send';
  provider:NoticeProvider|null;
  sandboxHomes:ReadonlySet<string>;
  webhook?:Buffer|undefined;
}
export const providerRetryWindow=day-5*60_000;
