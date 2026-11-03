import {createHmac, timingSafeEqual} from 'node:crypto';
import {z} from 'zod';
import {ServiceError} from './errors.js';
import {tokenHash} from './database.js';

export type GuardianProviderConfiguration = {organizationId:string;environment:'test'|'production'} & ({scope:'organization';productId:null}|{scope:'product';productId:string});
export interface GuardianVerificationRequest {
  email:string; location:string; language:'en'|'es'; userContext:'parent'; externalPayload:string;
}
/** A start implementation must use the verified, organization-specific PV API
 * specification. There is deliberately no guessed send-email endpoint here. */
export interface GuardianVerificationGateway {
  readonly kind:'kws'|'fixture'; readonly configuration:GuardianProviderConfiguration;
  start(request:GuardianVerificationRequest):Promise<void>;
}
const signedEvent=z.object({name:z.literal('parent-verified'),time:z.string().min(1).max(100),
  orgId:z.uuid(),productId:z.uuid().nullable(),payload:z.object({parentEmail:z.email().max(320),externalPayload:z.string().max(250),
    status:z.object({verified:z.literal(true),transactionId:z.string().min(1).max(256)}).strict()}).strict()}).strict();
const correlation=z.object({v:z.literal(1),h:z.uuid(),a:z.uuid(),n:z.string().regex(/^[A-Za-z0-9_-]{43}$/)}).strict();
export type GuardianVerifiedEvent={householdId:string;attemptId:string;nonce:string;parentEmail:string;transactionId:string;eventDigest:string;eventTime:Date;signatureTime:Date} & GuardianProviderConfiguration;
const denied=()=>new ServiceError(401,'provider_signature_invalid','Use the configured authenticated provider callback.');
/** Official KWS contract: x-kws-signature t=<milliseconds>,v1=<hex HMAC>;
 * HMAC-SHA256 over timestamp + '.' + the original UTF-8 request body. Multiple
 * v1 signatures support secret rotation. No redirect establishes authority.
 * https://dev.epicgames.com/docs/kids-web-services/parent-verification-service/set-up/pv-service-configure-webhook
 */
export class KWSWebhookVerifier {
  constructor(readonly configuration:GuardianProviderConfiguration,private readonly secrets:readonly string[]){
    if(!z.uuid().safeParse(configuration.organizationId).success||!(configuration.scope==='organization'?configuration.productId===null:configuration.scope==='product'&&z.uuid().safeParse(configuration.productId).success)||secrets.length<1||secrets.length>3||secrets.some(s=>s.length<16))throw new Error('Explicit KWS organization/product scope and active webhook secrets required');
  }
  verify(raw:Buffer,header:string|undefined,now=new Date()):GuardianVerifiedEvent {
    if(!header||header.length>1024||raw.length>16_384)throw denied();
    const parts=header.split(',').map(value=>value.trim());
    const times=parts.filter(value=>/^t=\d{1,16}$/.test(value));
    const signatures=parts.filter(value=>/^v1=[0-9a-f]{64}$/i.test(value)).map(value=>Buffer.from(value.slice(3),'hex'));
    if(times.length!==1||signatures.length<1||signatures.length>8||parts.length!==times.length+signatures.length)throw denied();
    const stamp=times[0]!.slice(2),ms=Number(stamp);
    if(!Number.isSafeInteger(ms)||ms<=0||ms>now.getTime()+300_000)throw denied();
    let valid=false;
    for(const secret of this.secrets){const expected=createHmac('sha256',secret).update(stamp+'.').update(raw).digest();for(const signature of signatures)valid=timingSafeEqual(expected,signature)||valid;}
    if(!valid)throw denied();
    let value:unknown;try{value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(raw));}catch{throw denied();}
    const parsed=signedEvent.safeParse(value);if(!parsed.success)throw denied();
    const event=parsed.data;
    if(event.orgId!==this.configuration.organizationId||event.productId!==this.configuration.productId)throw denied();
    const time=Date.parse(event.time);if(!Number.isFinite(time)||time<=0||time>now.getTime()+300_000)throw denied();
    let context:unknown;try{context=JSON.parse(event.payload.externalPayload);}catch{throw denied();}
    const external=correlation.safeParse(context);if(!external.success)throw denied();
    // Lower timestamp bounds come from the persisted attempt, not a short global
    // freshness window that would reject delayed legitimate provider retries.
    return {...this.configuration,householdId:external.data.h,attemptId:external.data.a,nonce:external.data.n,
      parentEmail:event.payload.parentEmail,transactionId:event.payload.status.transactionId,eventDigest:tokenHash(raw.toString('utf8')),
      eventTime:new Date(time),signatureTime:new Date(ms)};
  }
}
/** Documented OAuth client-credentials portion only. Not a complete PV adapter.
 * https://dev.epicgames.com/docs/kids-web-services/parent-verification-service/pv-service-integration
 */
export class KWSClientCredentials {
  private cached:{token:string;until:number}|undefined;
  constructor(private readonly clientId:string,private readonly apiKey:string,private readonly agent:string,private readonly request:typeof fetch=fetch){
    if(!clientId||clientId.includes(':')||!apiKey||!agent.trim())throw new Error('KWS client, key and User-Agent required');
  }
  invalidate(){this.cached=undefined;}
  async token():Promise<string>{
    if(this.cached&&this.cached.until>Date.now())return this.cached.token;
    try{
      const response=await this.request('https://auth.kidswebservices.com/auth/realms/kws/protocol/openid-connect/token',{
        method:'POST',headers:{Authorization:'Basic '+Buffer.from(this.clientId+':'+this.apiKey).toString('base64'),'Content-Type':'application/x-www-form-urlencoded','User-Agent':this.agent},
        body:new URLSearchParams({grant_type:'client_credentials',scope:'verification'}),redirect:'error',signal:AbortSignal.timeout(5_000)});
      if(!response.ok)throw new Error('provider');
      const value=z.object({access_token:z.string().min(1).max(12_000),expires_in:z.number().int().min(1).max(86_400)}).passthrough().parse(await boundedJSON(response));
      this.cached={token:value.access_token,until:Date.now()+Math.max(0,value.expires_in*1000-30_000)};return value.access_token;
    }catch{throw new ServiceError(503,'verification_provider_unavailable','Keep this setup and retry when verification is available.');}
  }
}

async function boundedJSON(response:Response,limit=16_384):Promise<unknown>{
  if(!response.body)throw new Error('empty provider response');const reader=response.body.getReader();const chunks:Uint8Array[]=[];let size=0;
  try{for(;;){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>limit)throw new Error('provider response too large');chunks.push(part.value);}}finally{await reader.cancel().catch(()=>{});}
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
/** The authenticated official Managed Verification API 1.0 specification documents
 * POST /v1/verifications/send-email and a 202 trustEmailRequestAccepted response.
 * https://dev.epicgames.com/portal/en-US/room-in-the-cart/kws/api-docs/kws-managed-verification
 * The public integration guide identifies this origin. Additional regional hosts
 * require an explicit official-documentation review before this allowlist grows.
 */
export class KWSParentVerificationGateway implements GuardianVerificationGateway {
  readonly kind='kws' as const;
  private readonly tokens:KWSClientCredentials;
  constructor(readonly configuration:GuardianProviderConfiguration,private readonly credentials:{clientId:string;apiKey:string;userAgent:string;serviceOrigin:string},private readonly request:typeof fetch=fetch){
    if(credentials.serviceOrigin!=='https://api.kidswebservices.com')throw new Error('Reviewed exact KWS Service API origin required');
    if(!z.uuid().safeParse(configuration.organizationId).success||!(configuration.scope==='organization'?configuration.productId===null:configuration.scope==='product'&&z.uuid().safeParse(configuration.productId).success))throw new Error('Explicit KWS organization/product scope required');
    this.tokens=new KWSClientCredentials(credentials.clientId,credentials.apiKey,credentials.userAgent,request);
  }
  async start(input:GuardianVerificationRequest):Promise<void>{
    if(!z.email().max(320).safeParse(input.email).success||!/^US(-[A-Z]{2})?$/.test(input.location)||!['en','es'].includes(input.language)||input.userContext!=='parent'||Buffer.byteLength(input.externalPayload,'utf8')>250)throw new Error('Bounded KWS parent verification request required');
    // No automatic resend: KWS exposes no idempotency/status contract for this
    // operation. A lost response leaves a durable uncertain attempt for callback.
    try{
      const send=async()=>this.request(this.credentials.serviceOrigin+'/v1/verifications/send-email',{
        method:'POST',headers:{Authorization:'Bearer '+await this.tokens.token(),'Content-Type':'application/json','User-Agent':this.credentials.userAgent},body:JSON.stringify(input),redirect:'error',signal:AbortSignal.timeout(5_000)});
      let response=await send();
      // A definitive authentication rejection has not accepted the request.
      // Renew once as documented; timeouts, 5xx and lost replies never resend.
      if(response.status===401){await response.body?.cancel();this.tokens.invalidate();response=await send();}
      if(response.status!==202)throw new Error('provider did not accept request');
      const value=z.object({response:z.object({trustEmailRequestAccepted:z.literal(true)}).strict(),meta:z.object({timestamp:z.string(),requestId:z.string()}).strict()}).strict().parse(await boundedJSON(response));
      if(!value.response.trustEmailRequestAccepted)throw new Error('provider');
    }catch{throw new ServiceError(503,'verification_uncertain','The verification request outcome is uncertain; await its authenticated callback.');}
  }
}
