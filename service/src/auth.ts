import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';
import type { Transaction } from './database.js';
import { ServiceError } from './errors.js';
export interface VerifiedIdentity { readonly issuer:string; readonly subject:string; readonly sessionId:string; readonly expiresAt:Date }
export interface IdentityVerifier { verify(token:string):Promise<VerifiedIdentity> }
export class DenyIdentityVerifier implements IdentityVerifier {
  async verify(_token:string):Promise<never> { throw new ServiceError(401,'session_needed','Sign in with the configured identity provider.'); }
}
export interface JWTConfiguration { issuer:string; audience:string; jwksUrl:string; sessionClaim?:string }
export class JWTIdentityVerifier implements IdentityVerifier {
  private readonly key: JWTVerifyGetKey;
  constructor(private readonly config:JWTConfiguration, trustedKey?:JWTVerifyGetKey) {
    const issuer=new URL(config.issuer), jwks=new URL(config.jwksUrl);
    if(issuer.protocol!=='https:' || jwks.protocol!=='https:' || jwks.username || jwks.password || !config.audience) throw new Error('HTTPS JWT issuer, audience and JWKS required');
    this.key=trustedKey??createRemoteJWKSet(jwks,{ timeoutDuration:5000,cooldownDuration:30_000,cacheMaxAge:600_000 });
  }
  async verify(token:string):Promise<VerifiedIdentity> {
    try {
      const {payload}=await jwtVerify(token,this.key,{issuer:this.config.issuer,audience:this.config.audience,algorithms:['ES256','RS256'],requiredClaims:['iss','aud','sub','exp','iat',this.config.sessionClaim??'session_id'],clockTolerance:5});
      const sessionId=payload[this.config.sessionClaim??'session_id'];
      if(typeof payload.sub!=='string'||!payload.sub.length||payload.sub.length>256||typeof sessionId!=='string'||!sessionId.length||sessionId.length>256||payload.iat!>Date.now()/1000+5) throw new Error('Invalid identity');
      return Object.freeze({issuer:this.config.issuer,subject:payload.sub,sessionId,expiresAt:new Date(payload.exp!*1000)});
    }catch { throw new ServiceError(401,'session_needed','Authenticate again; keep private drafts on this device.'); }
  }
}

export interface SessionStatusVerifier { assertLive(db:Transaction,identity:VerifiedIdentity,now:Date):Promise<void> }
export class SupabaseSessionVerifier implements SessionStatusVerifier {
  constructor(private readonly issuer:string) { if(new URL(issuer).protocol!=='https:')throw new Error('HTTPS session issuer required'); }
  async assertLive(db:Transaction,identity:VerifiedIdentity,now:Date):Promise<void> {
    const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if(identity.issuer!==this.issuer||identity.expiresAt<=now||!uuid.test(identity.subject)||!uuid.test(identity.sessionId))throw new ServiceError(401,'session_needed','Authenticate again; keep private drafts on this device.');
    const result=await db.query<{live:boolean}>('SELECT ritc.provider_session_live($1::uuid,$2::uuid) AS live',[identity.sessionId,identity.subject]);
    if(result.rows[0]?.live!==true)throw new ServiceError(401,'session_needed','Authenticate again; keep private drafts on this device.');
  }
}
