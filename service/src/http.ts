import { createServer, type IncomingMessage } from 'node:http';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import { type IdentityVerifier,DenyIdentityVerifier } from './auth.js';
import { HouseholdRepository,type AuthContext } from './repository.js';
import { BillingService,billingVerifySchema,billingSeatsSchema,billingNotificationSchema } from './billing/service.js';
import { ServiceError,accessEnded,invalid } from './errors.js';
import {HouseholdLifecycle} from './lifecycle.js';
import {householdCreateSchema,inviteCreateSchema,inviteRedeemSchema,viewCreateSchema,viewUpdateSchema,proposalSchema,revocationSchema, parseCommand,previewSchema,uuid } from './contracts.js';
export interface HTTPOptions { repository:HouseholdRepository; verifier?:IdentityVerifier; webOrigin?:string; maxRequestsPerMinute?:number; billing?:BillingService }
async function body(req:IncomingMessage,maxBytes=65_536):Promise<unknown> {
  if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']??''))throw new ServiceError(415,'json_required','Send a JSON command.');
  const chunks:Buffer[]=[];let size=0;
  for await(const chunk of req) {size+=chunk.length;if(size>maxBytes)throw new ServiceError(413,'body_too_large','Send one bounded command.');chunks.push(chunk);}
  try{return JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{throw invalid();}
}
function equal(a:string,b:string){const aa=Buffer.from(a),bb=Buffer.from(b);return aa.length===bb.length&&timingSafeEqual(aa,bb);}
function cookie(req:IncomingMessage):string|null {
  return req.headers.cookie?.split(';').map(s=>s.trim()).find(s=>s.startsWith('ritc_session='))?.slice(13)??null;
}
export function createHTTPServer(options:HTTPOptions) {
  const repository=options.repository,verifier=options.verifier??new DenyIdentityVerifier();
  const lifecycle=new HouseholdLifecycle(repository);
  const limits=new Map<string,{count:number;until:number}>();
  return createServer(async(req,res)=>{
    const correlationId=randomUUID();
    res.setHeader('Content-Type','application/json; charset=utf-8');res.setHeader('Cache-Control','no-store');
    res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
    res.setHeader('Content-Security-Policy',"default-src 'none'; frame-ancestors 'none'");
    res.setHeader('X-Request-ID',correlationId);res.setHeader('Vary','Origin');
    const send=(status:number,value:unknown)=>{res.statusCode=status;res.end(JSON.stringify(value));};
    try {
      const method=req.method??'GET',url=new URL(req.url??'/','https://service.invalid');
      if(req.headers.origin&&req.headers.origin!==options.webOrigin)throw new ServiceError(403,'origin_denied','Use the configured application origin.');
      if(url.pathname==='/health'&&method==='GET'){send(200,{service:'room-in-the-cart',status:'running'});return;}
      const ip=req.socket.remoteAddress??'unknown',now=Date.now(),old=limits.get(ip);
      if(limits.size>=10_000)for(const[k,v]of limits)if(v.until<now)limits.delete(k);
      if(limits.size>=10_000&&!old){res.setHeader('Retry-After','60');throw new ServiceError(429,'rate_limited','Retry later.');}
      const bucket=old&&old.until>now?old:{count:0,until:now+60_000};bucket.count++;limits.set(ip,bucket);
      if(bucket.count>(options.maxRequestsPerMinute??120)){res.setHeader('Retry-After','60');throw new ServiceError(429,'rate_limited','Keep the operation key and retry later.');}
      if(url.pathname==='/v1/apple/notifications'&&method==='POST'&&options.billing){const input=billingNotificationSchema.parse(await body(req,262_144));send(200,await options.billing.notification(repository.pool,input.signedPayload));return;}
      let auth:AuthContext|undefined,session:Awaited<ReturnType<HouseholdRepository['webIdentity']>>|undefined;
      const authorization=req.headers.authorization;
      if(authorization) {
        const match=/^Bearer ([A-Za-z0-9_.-]+)$/.exec(authorization);
        if(!match)throw new ServiceError(401,'session_needed','Authenticate again.');
        const identity=await verifier.verify(match[1]!);
        auth={identity,...(typeof req.headers['x-device-token']==='string'?{deviceToken:req.headers['x-device-token']}:{})};
      }else {
        const value=cookie(req);if(value){session=await repository.webIdentity(value);auth=session.auth;}
      }
      if(method==='GET'&&url.pathname==='/v1/session'&&!auth){send(200,{authenticated:false});return;}
      if(!auth)throw new ServiceError(401,'session_needed','Sign in; preserve private local drafts.');
      if(session&&method!=='GET'&&method!=='HEAD') {
        const csrf=req.headers['x-csrf-token'];
        if(!options.webOrigin||req.headers.origin!==options.webOrigin||typeof csrf!=='string'||!equal(csrf,session.csrf))throw new ServiceError(403,'csrf_failed','Reload the current session and try again.');
      }
      if(url.pathname==='/v1/session'&&method==='POST') {
        const input=z.object({householdId:uuid,grantId:uuid.optional()}).strict().parse(await body(req));
        const result=await repository.startWebSession(input.householdId,auth.identity,input.grantId??(session?.householdId===input.householdId?session.auth.viewGrantId:undefined));
        res.setHeader('Set-Cookie',`ritc_session=${result.cookie}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${Math.max(0,Math.floor((result.expiresAt.getTime()-Date.now())/1000))}`);
        send(200,result.session);return;
      }
      if(url.pathname==='/v1/session'&&session) {
        if(method==='GET'){send(200,await repository.authorized(session.householdId,auth,async ctx=>({authenticated:true,...await repository.bootstrap(ctx),replayWindow:await repository.window(ctx),csrf:session!.csrf})));return;}
        if(method==='DELETE'){const result=await repository.authorized(session.householdId,auth,ctx=>repository.logout(ctx));res.setHeader('Set-Cookie','ritc_session=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0');send(200,result);return;}
      }
      if(url.pathname==='/v1/households'&&method==='POST'){send(201,await lifecycle.create(auth.identity,householdCreateSchema.parse(await body(req))));return;}
      if(url.pathname==='/v1/invites/redeem'&&method==='POST'){send(200,await lifecycle.redeem(auth.identity,inviteRedeemSchema.parse(await body(req))));return;}
      const viewMatch=/^\/v1\/views\/([^/]+)\/(current|proposals)$/.exec(url.pathname);
      if(viewMatch){
        const grantId=uuid.parse(viewMatch[1]);
        const householdId=session?.householdId??uuid.parse(req.headers['x-household-id']);
        const payload=method==='POST'?await body(req):undefined;
        send(200,await repository.authorized<unknown>(householdId,auth,async ctx=>{
          if(viewMatch[2]==='current'&&method==='GET')return lifecycle.currentView(ctx,grantId);
          if(viewMatch[2]==='proposals'&&method==='POST')return lifecycle.propose(ctx,grantId,proposalSchema.parse(payload));
          throw new ServiceError(404,'unavailable','Return to your current workspace.');
        }));return;
      }
      if(url.pathname==='/v1/me/workspaces'&&method==='GET'){send(200,await repository.workspaces(auth.identity));return;}
      if(url.pathname==='/v1/billing/verify'&&method==='POST'&&options.billing){const input=billingVerifySchema.parse(await body(req,262_144));if(session&&session.householdId!==input.householdId)throw accessEnded();send(200,await repository.authorized(input.householdId,auth,ctx=>options.billing!.verify(ctx,input.signedTransactionInfo)));return;}
      const match=/^\/v1\/households\/([^/]+)(.*)$/.exec(url.pathname);
      if(!match)throw new ServiceError(404,'unavailable','Return to your current workspace.');
      const householdId=uuid.parse(match[1]),path=match[2]!;
      if(session&&session.householdId!==householdId)throw accessEnded();
      if(path==='/devices'&&method==='POST') {
        z.object({}).strict().parse(await body(req));
        send(201,await repository.enroll(householdId,auth.identity));return;
      }
      const payload=method==='POST'||method==='PUT'?await body(req):undefined;
      const output=await repository.authorized(householdId,auth,async ctx=>{
        if(path==='/devices/current'&&method==='DELETE')return repository.logout(ctx);
        if(options.billing){
          if(path==='/entitlements'&&method==='GET')return options.billing.snapshot(ctx);
          if(path==='/billing/seat-candidates'&&method==='GET')return options.billing.seatCandidates(ctx);
          if(path==='/billing/purchase-context'&&method==='POST'){z.object({}).strict().parse(payload);return options.billing.prepare(ctx);}
          if(path==='/billing/seats'&&method==='PUT')return options.billing.replaceSeats(ctx,billingSeatsSchema.parse(payload));
        }
        if(path==='/members'&&method==='GET')return lifecycle.members(ctx);
        if(path==='/invites'&&method==='POST')return lifecycle.invite(ctx,inviteCreateSchema.parse(payload));
        if(path==='/views'&&method==='POST')return lifecycle.createView(ctx,viewCreateSchema.parse(payload));
        if(path==='/revocations'&&method==='POST')return lifecycle.revoke(ctx,revocationSchema.parse(payload));
        if(path==='/guardian/consents'&&method==='GET')return lifecycle.consents(ctx);
        if(path==='/guardian/enrollment'&&method==='POST')throw new ServiceError(503,'consent_unavailable','Child enrollment is unavailable until verified guardian consent is configured.');
        const consentMatch=/^\/guardian\/consents\/([^/]+)\/revoke$/.exec(path);
        if(consentMatch&&method==='POST'){z.object({}).strict().parse(payload);return lifecycle.revokeConsent(ctx,uuid.parse(consentMatch[1]));}
        const managedView=/^\/views\/([^/]+)(\/proposals)?$/.exec(path);
        if(managedView){
          const grantId=uuid.parse(managedView[1]);
          if(managedView[2]==='/proposals'&&method==='GET')return lifecycle.proposals(ctx,grantId);
          if(!managedView[2]&&method==='PUT')return lifecycle.updateView(ctx,grantId,viewUpdateSchema.parse(payload));
        }
        if(path==='/bootstrap'&&method==='GET')return repository.bootstrap(ctx);
        if(path==='/replay-windows'&&method==='POST'){z.object({}).strict().parse(payload);return repository.window(ctx);}
        if(path==='/requests/mine'&&method==='GET') {
          const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);
          return repository.requests(ctx,cursor);
        }
        if(path==='/commands'&&method==='POST')return repository.execute(ctx,parseCommand(payload));
        const shopMatch=/^\/shops\/([^/]+)(.*)$/.exec(path);
        if(shopMatch) {
          const shopId=uuid.parse(shopMatch[1]),tail=shopMatch[2];
          if(tail===''&&method==='GET')return repository.adultShop(ctx,shopId);
          if(tail==='/inbox'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return repository.requests(ctx,cursor,shopId);}
          if(tail==='/previews'&&method==='POST')return repository.preview(ctx,shopId,previewSchema.parse(payload));
        }
        throw new ServiceError(404,'unavailable','Return to your current workspace.');
      });
      send(200,output);
    }catch(error) {
      let safe:ServiceError;
      if(error instanceof ServiceError)safe=error;
      else if(error instanceof z.ZodError)safe=invalid();
      else if(error&&typeof error==='object'&&'code'in error&&error.code==='23505')safe=new ServiceError(409,'identity_conflict','Refresh current records before retrying.');
      else if(error&&typeof error==='object'&&'code'in error&&['23503','23514'].includes(String(error.code)))safe=new ServiceError(422,'invalid_candidate','Review linked records and required values.');
      else {safe=new ServiceError(503,'storage_unavailable','Keep your draft and retry the same operation key.');res.setHeader('Retry-After','1');}
      send(safe.status,{error:{code:safe.code,correlationId,recovery:safe.recovery}});
    }
  });
}
