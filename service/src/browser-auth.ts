import {createCipheriv,createDecipheriv,createHmac,randomBytes,timingSafeEqual} from 'node:crypto';
import {decodeJwt} from 'jose';
import {z} from 'zod';
import type {IdentityVerifier,VerifiedIdentity} from './auth.js';
import type {Transaction} from './database.js';
import {tokenHash} from './database.js';
import {HouseholdRepository} from './repository.js';
import {ServiceError} from './errors.js';
export const emailStartSchema=z.object({email:z.string().trim().email().max(254)}).strict();
export const emailVerifySchema=z.object({code:z.string().regex(/^\d{6}$/)}).strict();
const tokensSchema=z.object({accessToken:z.string().min(1).max(16_384),refreshToken:z.string().min(1).max(4096)}).strict();
type ProviderTokens=z.infer<typeof tokensSchema>;
export interface EmailOTPProvider {
  start(email:string):Promise<void>;
  verify(email:string,code:string):Promise<ProviderTokens>;
  refresh(refreshToken:string):Promise<ProviderTokens>;
  logout(accessToken:string):Promise<void>;
}
const unavailable=()=>new ServiceError(503,'login_unavailable','Email sign-in is unavailable. Keep your invitation and try again later.');
const sessionNeeded=()=>new ServiceError(401,'session_needed','Sign in again to continue.');
const codeRejected=()=>new ServiceError(422,'code_not_accepted','Check the latest code or request another one.');
const limited=()=>new ServiceError(429,'login_rate_limited','Wait before requesting or checking another code.');
export class SupabaseEmailOTPProvider implements EmailOTPProvider {
  private readonly base:string;
  constructor(config:{url:string;publicKey:string},private readonly fetcher:typeof fetch=fetch){
    const url=new URL(config.url);
    if(url.protocol!=='https:'||url.username||url.password||url.search||url.hash||!['','/'].includes(url.pathname))throw new Error('Fixed HTTPS Supabase project origin required');
    if(!config.publicKey.startsWith('sb_publishable_')){
      try{if(decodeJwt(config.publicKey).role!=='anon')throw new Error('role');}catch{throw new Error('Use only the Supabase publishable or legacy anon key');}
    }
    if(config.publicKey.length>4096||config.publicKey.length<20)throw new Error('Invalid Supabase public key');
    this.base=url.origin+'/auth/v1';this.publicKey=config.publicKey;
  }
  private readonly publicKey:string;
  private async request(path:string,body:unknown,accessToken?:string):Promise<unknown>{
    let response:Response;
    try{response=await this.fetcher(this.base+path,{method:'POST',redirect:'error',signal:AbortSignal.timeout(5000),headers:{apikey:this.publicKey,'Content-Type':'application/json',...(accessToken?{Authorization:'Bearer '+accessToken}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});}catch{throw unavailable();}
    if(response.status===429)throw limited();
    if(!response.ok){if([400,401,403,422].includes(response.status)&&(path==='/verify'||path.startsWith('/token')))throw codeRejected();throw unavailable();}
    if(response.status===204)return null;
    if(!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type')??''))throw unavailable();
    const reader=response.body?.getReader();if(!reader)throw unavailable();
    const chunks:Uint8Array[]=[];let size=0;
    for(;;){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>65_536){await reader.cancel();throw unavailable();}chunks.push(part.value);}
    try{return JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{throw unavailable();}
  }
  private tokens(value:unknown):ProviderTokens{
    const response=z.object({access_token:z.string().min(1).max(16_384),refresh_token:z.string().min(1).max(4096)}).safeParse(value);
    if(!response.success)throw unavailable();return{accessToken:response.data.access_token,refreshToken:response.data.refresh_token};
  }
  async start(email:string){await this.request('/otp',{email,create_user:true});}
  async verify(email:string,code:string){return this.tokens(await this.request('/verify',{email,token:code,type:'email'}));}
  async refresh(refreshToken:string){return this.tokens(await this.request('/token?grant_type=refresh_token',{refresh_token:refreshToken}));}
  async logout(accessToken:string){await this.request('/logout?scope=local',undefined,accessToken);}
}
interface AuthRow {
 token_hash:string;csrf:string;phase:'challenge'|'authenticated';issuer:string|null;subject:string|null;session_id:string|null;
 access_expires_at:Date|null;secret_cipher:string|null;email_cipher:string|null;code_expires_at:Date|null;send_after:Date|null;
 verify_attempts:number;expires_at:Date;revoked_at:Date|null;
}
export interface BrowserIdentity {identity:VerifiedIdentity;csrf:string;cookie:string}
interface Outcome<T>{value?:T;failure?:ServiceError}
export class BrowserAuthService {
  private readonly key:Buffer;
  constructor(private readonly repo:HouseholdRepository,private readonly verifier:IdentityVerifier,private readonly provider:EmailOTPProvider,options:{encryptionKey:string}){
    this.key=Buffer.from(options.encryptionKey,'base64');
    if(this.key.length!==32||this.key.toString('base64')!==options.encryptionKey)throw new Error('Browser auth encryption key must be canonical base64 for 32 random bytes');
  }
  private seal(value:unknown,binding:string){const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',this.key,iv);cipher.setAAD(Buffer.from(binding));const data=Buffer.concat([cipher.update(JSON.stringify(value),'utf8'),cipher.final()]);return['v1',iv.toString('base64url'),cipher.getAuthTag().toString('base64url'),data.toString('base64url')].join('.');}
  private open(value:string,binding:string):unknown{try{const[v,iv,tag,data]=value.split('.');if(v!=='v1'||!iv||!tag||!data)throw new Error('envelope');const decipher=createDecipheriv('aes-256-gcm',this.key,Buffer.from(iv,'base64url'));decipher.setAAD(Buffer.from(binding));decipher.setAuthTag(Buffer.from(tag,'base64url'));return JSON.parse(Buffer.concat([decipher.update(Buffer.from(data,'base64url')),decipher.final()]).toString('utf8'));}catch{throw sessionNeeded();}}
  private csrf(row:AuthRow,value:string){const a=Buffer.from(row.csrf),b=Buffer.from(value);if(a.length!==b.length||!timingSafeEqual(a,b))throw new ServiceError(403,'csrf_failed','Reload sign-in and try again.');}
  private hash(cookie:string){if(!/^[A-Za-z0-9_-]{43}$/.test(cookie))throw sessionNeeded();return tokenHash(cookie);}
  private async transaction<T>(hash:string,fn:(db:Transaction,now:Date)=>Promise<T>):Promise<T>{
    const db=await this.repo.pool.connect();try{await db.query('BEGIN');await db.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='3s'");await db.query("SELECT set_config('app.browser_token_hash',$1,true)",[hash]);const now=(await db.query<{now:Date}>('SELECT clock_timestamp() AS now')).rows[0]!.now;const result=await fn(db,now);await db.query('COMMIT');return result;}catch(e){await db.query('ROLLBACK');throw e;}finally{db.release();}
  }
  private async record(db:Transaction,hash:string,now:Date){const row=(await db.query<AuthRow>('SELECT * FROM ritc.browser_auth WHERE token_hash=$1 FOR UPDATE',[hash])).rows[0];if(!row||row.revoked_at||row.expires_at<=now)throw sessionNeeded();return row;}
  private unwrap<T>(outcome:Outcome<T>):T{if(outcome.failure)throw outcome.failure;return outcome.value!;}
  private async rate(db:Transaction,now:Date,kind:string,value:string,limit:number){
    const key=createHmac('sha256',this.key).update(kind+':'+value).digest('hex');
    await db.query("SELECT set_config('app.auth_rate_key',$1,true)",[key]);
    const row=(await db.query<{attempts:number}>(`INSERT INTO ritc.auth_rate_bucket(bucket_key,window_started,attempts) VALUES($1,$2,1)
      ON CONFLICT(bucket_key) DO UPDATE SET attempts=CASE WHEN ritc.auth_rate_bucket.window_started<$2::timestamptz-interval '1 hour' THEN 1 ELSE ritc.auth_rate_bucket.attempts+1 END,
      window_started=CASE WHEN ritc.auth_rate_bucket.window_started<$2::timestamptz-interval '1 hour' THEN $2 ELSE ritc.auth_rate_bucket.window_started END RETURNING attempts`,[key,now])).rows[0]!;
    return row.attempts<=limit;
  }
  async challenge(clientAddress:string){
    const cookie=randomBytes(32).toString('base64url'),csrf=randomBytes(32).toString('base64url'),hash=this.hash(cookie);
    const allowed=await this.transaction(hash,async(db,now)=>{if(!await this.rate(db,now,'challenge-ip',clientAddress,120))return false;await db.query('INSERT INTO ritc.browser_auth(token_hash,csrf,expires_at) VALUES($1,$2,$3)',[hash,csrf,new Date(now.getTime()+15*60_000)]);return true;});
    if(!allowed)throw limited();
    return{cookie,csrf,authenticated:false as const,expiresIn:900};
  }
  async state(cookie:string){
    const hash=this.hash(cookie);
    const phase=await this.transaction(hash,async(db,now)=>{const row=await this.record(db,hash,now);return{phase:row.phase,csrf:row.csrf};});
    if(phase.phase==='challenge')return{authenticated:false as const,csrf:phase.csrf};
    const authenticated=await this.authenticate(cookie);return{authenticated:true as const,csrf:authenticated.csrf};
  }
  async start(cookie:string,csrf:string,input:z.infer<typeof emailStartSchema>,clientAddress:string){
    const hash=this.hash(cookie),email=input.email.trim().toLowerCase();
    const result=await this.transaction<Outcome<{status:'check_email'}>>(hash,async(db,now)=>{
      const row=await this.record(db,hash,now);this.csrf(row,csrf);
      if(row.phase!=='challenge')return{failure:new ServiceError(409,'already_signed_in','Sign out before using a different email address.')};
      if(row.send_after&&row.send_after>now)return{failure:limited()};
      await db.query('UPDATE ritc.browser_auth SET send_after=$2 WHERE token_hash=$1',[hash,new Date(now.getTime()+60_000)]);
      if(!await this.rate(db,now,'otp-ip',clientAddress,20))return{failure:limited()};
      if(!await this.rate(db,now,'otp-email',email,5))return{failure:limited()};
      try{await this.provider.start(email);}catch(e){return{failure:e instanceof ServiceError?e:unavailable()};}
      await db.query('UPDATE ritc.browser_auth SET email_cipher=$2,code_expires_at=$3,verify_attempts=0 WHERE token_hash=$1',[hash,this.seal({email},hash),new Date(now.getTime()+10*60_000)]);
      return{value:{status:'check_email'}};
    });return this.unwrap(result);
  }
  async verify(cookie:string,csrf:string,input:z.infer<typeof emailVerifySchema>){
    const hash=this.hash(cookie);
    const result=await this.transaction<Outcome<{cookie:string;csrf:string;authenticated:true;expiresIn:number}>>(hash,async(db,now)=>{
      const row=await this.record(db,hash,now);this.csrf(row,csrf);
      if(row.phase!=='challenge'||!row.email_cipher||!row.code_expires_at||row.code_expires_at<=now)return{failure:codeRejected()};
      if(row.verify_attempts>=5)return{failure:limited()};
      await db.query('UPDATE ritc.browser_auth SET verify_attempts=verify_attempts+1 WHERE token_hash=$1',[hash]);
      let tokens:ProviderTokens,identity:VerifiedIdentity;
      try{
        const email=z.object({email:z.string().email()}).parse(this.open(row.email_cipher,hash)).email;
        tokens=tokensSchema.parse(await this.provider.verify(email,input.code));identity=await this.verifier.verify(tokens.accessToken);
        await this.repo.assertSession(db,identity,now);
      }catch(e){return{failure:e instanceof ServiceError?e:unavailable()};}
      await db.query('UPDATE ritc.browser_auth SET revoked_at=$2,email_cipher=NULL WHERE token_hash=$1',[hash,now]);
      const nextCookie=randomBytes(32).toString('base64url'),nextHash=this.hash(nextCookie),nextCSRF=randomBytes(32).toString('base64url');
      await db.query("SELECT set_config('app.browser_token_hash',$1,true)",[nextHash]);
      await db.query(`INSERT INTO ritc.browser_auth(token_hash,csrf,phase,issuer,subject,session_id,access_expires_at,secret_cipher,expires_at)
        VALUES($1,$2,'authenticated',$3,$4,$5,$6,$7,$8)`,[nextHash,nextCSRF,identity.issuer,identity.subject,identity.sessionId,identity.expiresAt,this.seal(tokens,nextHash),new Date(now.getTime()+7*24*60*60_000)]);
      return{value:{cookie:nextCookie,csrf:nextCSRF,authenticated:true,expiresIn:7*24*60*60}};
    });return this.unwrap(result);
  }
  async authenticate(cookie:string,refresh=false):Promise<BrowserIdentity>{
    const hash=this.hash(cookie);
    const result=await this.transaction<Outcome<BrowserIdentity>>(hash,async(db,now)=>{
      const row=await this.record(db,hash,now);if(row.phase!=='authenticated'||!row.secret_cipher||!row.access_expires_at)return{failure:sessionNeeded()};
      let tokens:ProviderTokens,identity:VerifiedIdentity;
      try{
        await this.repo.assertIdentityAllowed(db,row.issuer!,row.subject!);
        tokens=tokensSchema.parse(this.open(row.secret_cipher,hash));
        if(refresh||row.access_expires_at.getTime()<=now.getTime()+60_000){
          // Check the stored, previously verified binding before contacting the refresh endpoint.
          // Signature validity or a cached refresh token cannot revive a revoked provider session.
          const live=(await db.query('SELECT ritc.provider_session_refreshable($1::uuid,$2::uuid) AND NOT ritc.identity_blocked($3,$2::text) AS live',[row.session_id,row.subject,row.issuer])).rows[0]?.live;
          if(live!==true)throw sessionNeeded();
          tokens=tokensSchema.parse(await this.provider.refresh(tokens.refreshToken));
        }
        identity=await this.verifier.verify(tokens.accessToken);
        if(identity.issuer!==row.issuer||identity.subject!==row.subject||identity.sessionId!==row.session_id)throw sessionNeeded();
        await this.repo.assertSession(db,identity,now);
      }catch(e){
        if(e instanceof ServiceError&&[401,422].includes(e.status)){
          await db.query('UPDATE ritc.browser_auth SET revoked_at=$2 WHERE token_hash=$1',[hash,now]);return{failure:sessionNeeded()};
        }
        return{failure:e instanceof ServiceError?e:unavailable()};
      }
      await db.query('UPDATE ritc.browser_auth SET secret_cipher=$2,access_expires_at=$3 WHERE token_hash=$1',[hash,this.seal(tokens,hash),identity.expiresAt]);
      return{value:{identity,csrf:row.csrf,cookie}};
    });return this.unwrap(result);
  }
  async refresh(cookie:string,csrf:string){
    await this.transaction(this.hash(cookie),async(db,now)=>{this.csrf(await this.record(db,this.hash(cookie),now),csrf);});
    const identity=await this.authenticate(cookie,true);return{authenticated:true as const,csrf:identity.csrf};
  }
  async logout(cookie:string,csrf:string){
    const hash=this.hash(cookie);let tokens:ProviderTokens|null=null;
    await this.transaction(hash,async(db,now)=>{
      const row=(await db.query<AuthRow>('SELECT * FROM ritc.browser_auth WHERE token_hash=$1 FOR UPDATE',[hash])).rows[0];if(!row)return;this.csrf(row,csrf);
      if(row.secret_cipher)tokens=tokensSchema.parse(this.open(row.secret_cipher,hash));
      // Local logout commits even if the provider is temporarily unavailable.
      await db.query("UPDATE ritc.browser_auth SET revoked_at=COALESCE(revoked_at,$2),email_cipher=NULL,logout_state=CASE WHEN secret_cipher IS NULL THEN 'complete' ELSE 'pending' END,logout_next_at=$2 WHERE token_hash=$1",[hash,now]);
    });
    let providerRevoked=tokens===null;
    if(tokens){try{await this.provider.logout((tokens as ProviderTokens).accessToken);providerRevoked=true;}catch{providerRevoked=false;}}
    if(providerRevoked)await this.transaction(hash,async db=>{await db.query("UPDATE ritc.browser_auth SET phase='challenge',secret_cipher=NULL,issuer=NULL,subject=NULL,session_id=NULL,access_expires_at=NULL,logout_state='complete',logout_finished_at=clock_timestamp(),logout_lease_id=NULL,logout_lease_until=NULL WHERE token_hash=$1",[hash]);});
    return{signedOut:true as const,providerRevoked};
  }
}
