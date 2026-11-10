import {PartitionError} from './shared-demand-tracking.js';
import {readTracking,createTrackingCandidate,acceptTrackingCandidate,readTrackingRecord,readTrackingHistory} from './shared-demand-tracking-repository.js';
import {readSharedRecordSnapshot} from './shared-records.js';
import {SharedDemandError} from './shared-demand-domain.js';
import {previewDemand,readDemand,readActionDemandSources,readFoodOperationHistory,previewFoodOperationUndo,readFoodOperationUndoCandidate} from './shared-demand-repository.js';
import { readConfirmedOrder } from './order-amendments.js';
import {rankSharedFallbacks,requireAssistance} from './shared-fallback-options.js';
import {previewCurrentPantryObservation,readSharedRecoveryCoverage} from './shared-recovery-basis.js';
import {loadRecoveryPublication,previewSharedRecovery,readRecoveryDesk} from './shared-recovery-publication.js';
import { cookCorrectionFacts, cookCopyBaseline, cookCopyHistory } from './cook-copy.js';
import { readPantry, readJointCoverage } from './pantry-lots.js';
import { readDelivery, readDeliveryCoverage } from './delivery-evidence.js';
import { createServer, type IncomingMessage } from 'node:http';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import { type IdentityVerifier,DenyIdentityVerifier } from './auth.js';
import { HouseholdRepository,type AuthContext } from './repository.js';
import { BillingService,billingVerifySchema,billingSeatsSchema,billingNotificationSchema } from './billing/service.js';
import { ServiceError,accessEnded,invalid } from './errors.js';
import {BrowserAuthService,emailStartSchema,emailVerifySchema,type BrowserIdentity} from './browser-auth.js';
import {DecisionHistory} from './decision-history.js';
import {PriceBudgetHistory} from './history.js';
import {observationWriteSchema,financialAppendSchema,financialReviewSchema,historyRetireSchema,periodWriteSchema,budgetQuerySchema} from './history-contracts.js';
import {SharedMealChanges,sharedMealChangeSchema,sharedMealDismissSchema} from './shared-meal-changes.js';
import {SharedMealIdeas,sharedIdeaWriteSchema} from './shared-meal-ideas.js';
import { SharedStoreQuotes } from './shared-store-quotes.js';
import { HouseholdMeasurement } from './measurement.js';
import {MealMoves,grantChange,moveRequest,dismissMove} from './meal-moves.js';
import {HelperReview} from './helper-review.js';
import {PlacementReports} from './placement-reports.js';
import {HouseholdLifecycle} from './lifecycle.js';
import {HouseholdDeviceManagement,deviceRevocationSchema} from './device-management.js';
import {PrivacyService,deletionSchema,exitSchema} from './privacy.js';
import {privacyHTTPCall,type PrivacyCall} from './privacy-call.js';
import {GuardianEnrollmentService,guardianCreateSchema,guardianActionSchema,guardianConsentSchema,guardianInvitationSchema,guardianConfirmSchema,childClaimSchema,childFinishSchema,childAuthStartSchema,childNativeStartSchema,childNativeAdmitSchema} from './guardian.js';
import {viewReplacementSchema,proposalResolutionSchema,householdCreateSchema,inviteCreateSchema,inviteRedeemSchema,viewCreateSchema,viewUpdateSchema,proposalSchema,revocationSchema, parseCommand,previewSchema,uuid } from './contracts.js';
import { SharedFallbackRegistry } from './shared-fallback-registry.js';
export interface HTTPOptions { repository:HouseholdRepository; verifier?:IdentityVerifier; webOrigin?:string; maxRequestsPerMinute?:number; billing?:BillingService; browserAuth?:BrowserAuthService; privacy?:PrivacyService; guardian?:GuardianEnrollmentService; clientAddress?:(request:IncomingMessage)=>string|undefined }
async function rawBody(req:IncomingMessage,maxBytes=65_536):Promise<Buffer> {
  if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']??''))throw new ServiceError(415,'json_required','Send a JSON command.');
  const chunks:Buffer[]=[];let size=0;
  for await(const chunk of req) {size+=chunk.length;if(size>maxBytes)throw new ServiceError(413,'body_too_large','Send one bounded command.');chunks.push(chunk);}
  return Buffer.concat(chunks);
}
async function body(req:IncomingMessage,maxBytes=65_536):Promise<unknown>{try{return JSON.parse((await rawBody(req,maxBytes)).toString('utf8'));}catch(error){if(error instanceof ServiceError)throw error;throw invalid();}}

// A disclosed recipe may be larger than an ordinary command. Keep the
// command's byte limit for every other kind, including JSON whitespace.
async function householdBody(req:IncomingMessage,path:string) {
  if(path.endsWith('/demand/tracking/candidates')||path.endsWith('/demand/tracking/previews'))return body(req,1_800_000);
  if(path.endsWith('/demand/previews')) return body(req,1_800_000);
  if(path.endsWith('/accepted-fallbacks')) return body(req,540_000);
  if(path.endsWith('/meal-recovery/options') || path.endsWith('/meal-recovery/preview')) return body(req,1_800_000);
  if(path!=='/commands') return body(req);
  const raw=await rawBody(req,1_800_000);
  let payload:unknown;
  try {payload=JSON.parse(raw.toString('utf8'));} catch {throw invalid();}
  if(raw.length>65_536 && !(typeof payload==='object' && payload && 'kind' in payload && payload.kind==='mealRecovery.apply'))
    throw new ServiceError(413,'body_too_large','Send one bounded command.');
  return payload;
}

function equal(a:string,b:string){const aa=Buffer.from(a),bb=Buffer.from(b);return aa.length===bb.length&&timingSafeEqual(aa,bb);}
function cookie(req:IncomingMessage,name='ritc_session'):string|null {
  return req.headers.cookie?.split(';').map(s=>s.trim()).find(s=>s.startsWith(name+'='))?.slice(name.length+1)??null;
}
export function createHTTPServer(options:HTTPOptions) {
  const repository=options.repository,verifier=options.verifier??new DenyIdentityVerifier();
  const lifecycle=new HouseholdLifecycle(repository),helperReview=new HelperReview(lifecycle),history=new PriceBudgetHistory(repository,options.billing);
  const decisions = new DecisionHistory(options.billing);
  const fallbacks = new SharedFallbackRegistry(repository,options.billing);
  const mealMoves = new MealMoves(repository,options.billing);
  const mealIdeas = new SharedMealIdeas(repository,mealMoves);
  const mealChanges = new SharedMealChanges(repository,mealMoves);
  const storeQuotes = new SharedStoreQuotes(repository);
  const measurement = new HouseholdMeasurement(repository);
  const placementReports = new PlacementReports(repository);
  const devices = new HouseholdDeviceManagement();
  const guardian = options.guardian??new GuardianEnrollmentService(repository);
  const limits=new Map<string,{count:number;until:number}>();
  return createServer(async(req,res)=>{
    const correlationId=randomUUID();
    res.setHeader('Content-Type','application/json; charset=utf-8');res.setHeader('Cache-Control','no-store');
    res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');
    res.setHeader('Content-Security-Policy',"default-src 'none'; frame-ancestors 'none'");
    res.setHeader('X-Request-ID',correlationId);res.setHeader('Vary','Origin');
    const send=(status:number,value:unknown)=>{if(res.destroyed||res.writableEnded)return;res.statusCode=status;res.end(JSON.stringify(value));};
    let privacyCall:PrivacyCall|undefined;
    const withinCall=<T>(work:()=>Promise<T>):Promise<T>=>privacyCall?privacyCall.run(work):work();
    try {
      const method=req.method??'GET',url=new URL(req.url??'/','https://service.invalid');
      if(url.pathname.startsWith('/v1/privacy/')||method==='POST'&&/^\/v1\/households\/[^/]+\/exit$/.test(url.pathname))privacyCall=privacyHTTPCall(req,res,correlationId);
      if(req.headers.origin&&req.headers.origin!==options.webOrigin)throw new ServiceError(403,'origin_denied','Use the configured application origin.');
      if(url.pathname==='/health'&&method==='GET'){send(200,{service:'room-in-the-cart',status:'running'});return;}
      const ip=options.clientAddress?options.clientAddress(req):req.socket.remoteAddress;
      if(!ip||ip.length>128)throw new ServiceError(503,'client_context_unavailable','Try again when the service can verify this connection.');
      const now=Date.now(),old=limits.get(ip);
      if(limits.size>=10_000)for(const[k,v]of limits)if(v.until<now)limits.delete(k);
      if(limits.size>=10_000&&!old){res.setHeader('Retry-After','60');throw new ServiceError(429,'rate_limited','Retry later.');}
      const bucket=old&&old.until>now?old:{count:0,until:now+60_000};bucket.count++;limits.set(ip,bucket);
      if(bucket.count>(options.maxRequestsPerMinute??120)){res.setHeader('Retry-After','60');throw new ServiceError(429,'rate_limited','Keep the operation key and retry later.');}
      if(url.pathname==='/v1/apple/notifications'&&method==='POST'&&options.billing){const input=billingNotificationSchema.parse(await body(req,262_144));send(200,await options.billing.notification(repository.pool,input.signedPayload));return;}
      if(url.pathname==='/v1/guardian/availability'&&method==='GET'){const {notice:_,...availability}=guardian.notice(z.enum(['en','es']).parse(url.searchParams.get('language')??'en'));send(200,availability);return;}
      if(url.pathname==='/v1/guardian/providers/kws/webhook'&&method==='POST'){const header=req.headers['x-kws-signature'];send(200,await guardian.webhook(await rawBody(req,16_384),typeof header==='string'?header:undefined));return;}
      const privacyStatus=/^\/v1\/privacy\/jobs\/([^/]+)$/.exec(url.pathname);
      if(privacyStatus&&method==='GET'){
        if(!options.privacy)throw new ServiceError(503,'deletion_unavailable','Account deletion is not configured.');
        const token=z.string().regex(/^[A-Za-z0-9_-]{43}$/).parse(req.headers['x-deletion-token']);
        send(200,await options.privacy.status(uuid.parse(privacyStatus[1]),token,privacyCall!.call));return;
      }
      const browserCookie=cookie(req,'__Host-ritc_auth');
      const setAuthCookie=(value:string,maxAge:number)=>`__Host-ritc_auth=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${maxAge}`;
      const clearScope='ritc_session=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0';
      const csrfHeader=()=>{const value=req.headers['x-csrf-token'];if(!options.webOrigin||req.headers.origin!==options.webOrigin||typeof value!=='string')throw new ServiceError(403,'csrf_failed','Reload sign-in and try again.');return value;};
      if(url.pathname==='/v1/child-invitations/native-auth/start'&&method==='POST'){send(200,await guardian.nativeSigninStart(childNativeStartSchema.parse(await body(req,4096)),ip));return;}
      if(url.pathname==='/v1/child-invitations/auth/start'&&method==='POST'){const csrf=csrfHeader();if(!browserCookie)throw new ServiceError(401,'session_needed','Open the current sign-in challenge.');send(200,await guardian.startChildSignin(browserCookie,csrf,childAuthStartSchema.parse(await body(req,4096)),ip));return;}
      if(url.pathname.startsWith('/v1/auth/')){
        const bff=options.browserAuth;
        if(!bff||!options.webOrigin){if(url.pathname==='/v1/auth/session'&&method==='GET'){send(200,{available:false,authenticated:false,csrf:null});return;}throw new ServiceError(503,'login_unavailable','Email sign-in is unavailable. Keep your invitation and try again later.');}
        if(url.pathname==='/v1/auth/session'&&method==='GET'){
          if(browserCookie){try{send(200,{available:true,...await bff.state(browserCookie)});return;}catch(error){if(!(error instanceof ServiceError)||error.status!==401)throw error;}}
          const challenge=await bff.challenge(ip);res.setHeader('Set-Cookie',setAuthCookie(challenge.cookie,challenge.expiresIn));send(200,{available:true,authenticated:false,csrf:challenge.csrf});return;
        }
        const csrf=csrfHeader();if(!browserCookie)throw new ServiceError(401,'session_needed','Open sign-in before requesting a code.');
        if(url.pathname==='/v1/auth/email/start'&&method==='POST'){send(200,await bff.start(browserCookie,csrf,emailStartSchema.parse(await body(req,4096)),ip));return;}
        if(url.pathname==='/v1/auth/email/verify'&&method==='POST'){
          const result=await bff.verify(browserCookie,csrf,emailVerifySchema.parse(await body(req,1024)));
          res.setHeader('Set-Cookie',[setAuthCookie(result.cookie,result.expiresIn),clearScope]);send(200,{available:true,authenticated:true,csrf:result.csrf});return;
        }
        if(url.pathname==='/v1/auth/refresh'&&method==='POST'){z.object({}).strict().parse(await body(req,1024));send(200,{available:true,...await bff.refresh(browserCookie,csrf)});return;}
        if(url.pathname==='/v1/auth/session'&&method==='DELETE'){
          const result=await bff.logout(browserCookie,csrf);const scoped=cookie(req);if(scoped)await repository.revokeWebCookie(scoped);
          res.setHeader('Set-Cookie',[setAuthCookie('',0),clearScope]);send(200,result);return;
        }
        throw new ServiceError(404,'unavailable','Return to sign-in.');
      }
      let auth:AuthContext|undefined,session:Awaited<ReturnType<HouseholdRepository['webIdentity']>>|undefined,browserIdentity:BrowserIdentity|undefined;
      const authorization=req.headers.authorization;
      if(authorization) {
        const match=/^Bearer ([A-Za-z0-9_.-]+)$/.exec(authorization);
        if(!match)throw new ServiceError(401,'session_needed','Authenticate again.');
        const identity=await withinCall(()=>verifier.verify(match[1]!));
        auth={identity,...(typeof req.headers['x-device-token']==='string'?{deviceToken:req.headers['x-device-token']}:{}),...(req.headers['x-view-grant-id']!==undefined?{viewGrantId:uuid.parse(req.headers['x-view-grant-id'])}:{}),...(req.headers['x-shop-id']!==undefined?{selectedShopId:uuid.parse(req.headers['x-shop-id'])}:{})};
      }else {
        if(browserCookie&&options.browserAuth){try{browserIdentity=await withinCall(()=>options.browserAuth!.authenticate(browserCookie));auth={identity:browserIdentity.identity};}catch(error){if(!(error instanceof ServiceError)||error.code!=='session_needed')throw error; if(url.pathname!=='/v1/session'||method!=='GET')throw error;}}
        const value=cookie(req);if(value){session=await withinCall(()=>repository.webIdentity(value,browserIdentity?.identity));auth=session.auth;}
      }
      if(method==='GET'&&url.pathname==='/v1/session'&&!session){send(200,{authenticated:false});return;}
      if(url.pathname==='/v1/child-invitations/session'&&method==='GET'){send(200,await guardian.childSession(browserIdentity?.identity,browserIdentity&&options.browserAuth?await options.browserAuth.childBinding(browserIdentity.cookie):undefined));return;}
      if(!auth)throw new ServiceError(401,'session_needed','Sign in; preserve private local drafts.');
      if((session||browserIdentity)&&method!=='GET'&&method!=='HEAD') {
        const csrf=req.headers['x-csrf-token'];
        if(!options.webOrigin||req.headers.origin!==options.webOrigin||typeof csrf!=='string'||!equal(csrf,session?.csrf??browserIdentity!.csrf))throw new ServiceError(403,'csrf_failed','Reload the current session and try again.');
      }
      if(auth.viewGrantId){
        const helperView=url.pathname===`/v1/views/${auth.viewGrantId}/current`&&method==='GET';
        const helperProposal=(url.pathname===`/v1/views/${auth.viewGrantId}/proposals`&&(method==='POST'||method==='GET'))||(new RegExp('^/v1/views/'+auth.viewGrantId+'/proposals/[^/]+$').test(url.pathname)&&method==='GET');
        const helperSession=url.pathname==='/v1/session'||(url.pathname==='/v1/invites/redeem'&&method==='POST');
        const helperHousehold=/^\/v1\/households\/[^/]+\/(bootstrap|replay-windows|devices(?:\/current)?)$/.test(url.pathname);
        if(!helperView&&!helperProposal&&!helperSession&&!helperHousehold)throw new ServiceError(404,'unavailable','Use the selected helper view.');
      }
      if(url.pathname==='/v1/session'&&method==='POST') {
        const input=z.object({householdId:uuid,grantId:uuid.optional(),shopId:uuid.optional()}).strict().refine(value=>!(value.grantId&&value.shopId)).parse(await body(req));
        const result=await repository.startWebSession(input.householdId,auth.identity,input.shopId?undefined:input.grantId??(session?.householdId===input.householdId?session.auth.viewGrantId:undefined),Boolean(browserIdentity),input.grantId?undefined:input.shopId??(session?.householdId===input.householdId?session.auth.selectedShopId:undefined));
        res.setHeader('Set-Cookie',`ritc_session=${result.cookie}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${browserIdentity?604800:Math.max(0,Math.floor((result.expiresAt.getTime()-Date.now())/1000))}`);
        send(200,result.session);return;
      }
      if(url.pathname==='/v1/session'&&session) {
        if(method==='GET'){send(200,await repository.authorized(session.householdId,auth,async ctx=>({authenticated:true,...await repository.bootstrap(ctx),replayWindow:await repository.window(ctx),csrf:session!.csrf})));return;}
        if(method==='DELETE'){let result:unknown=await repository.authorized(session.householdId,auth,ctx=>repository.logout(ctx));if(browserCookie&&browserIdentity&&options.browserAuth)result=await options.browserAuth.logout(browserCookie,browserIdentity.csrf);res.setHeader('Set-Cookie',[clearScope,...(browserCookie?[setAuthCookie('',0)]:[])]);send(200,result);return;}
      }
      if(url.pathname.startsWith('/v1/privacy/')){
        if(!options.privacy)throw new ServiceError(503,'deletion_unavailable','Account deletion is not configured.');
        if(url.pathname==='/v1/privacy/deletion-preview'&&method==='GET'){send(200,await options.privacy.preview(auth.identity,privacyCall!.call));return;}
        if(url.pathname==='/v1/privacy/deletions'&&method==='POST'){
          const input=deletionSchema.parse(await privacyCall!.run(()=>body(req)));
          const result=await options.privacy.request(auth.identity,input,privacyCall!.call);
          res.setHeader('Set-Cookie',[clearScope,setAuthCookie('',0)]);send(202,result);return;
        }
      }
      if(url.pathname==='/v1/households'&&method==='POST'){send(201,await lifecycle.create(auth.identity,householdCreateSchema.parse(await body(req))));return;}
      if(url.pathname==='/v1/invites/redeem'&&method==='POST'){send(200,await lifecycle.redeem(auth.identity,inviteRedeemSchema.parse(await body(req))));return;}
      if(url.pathname==='/v1/child-invitations/native-auth/admit'&&method==='POST'){send(200,await guardian.nativeSigninAdmit(auth.identity,childNativeAdmitSchema.parse(await body(req,4096))));return;}
      if(url.pathname==='/v1/child-invitations/claim'&&method==='POST'){send(200,await guardian.claim(auth.identity,childClaimSchema.parse(await body(req,4096))));return;}
      if(url.pathname==='/v1/child-invitations/finish'&&method==='POST'){const result=await guardian.finish(auth.identity,childFinishSchema.parse(await body(req,4096)));if(browserIdentity){const scoped=await repository.startWebSession(result.householdId,auth.identity,undefined,true,undefined,result.deviceToken);res.setHeader('Set-Cookie',`ritc_session=${scoped.cookie}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=604800`);const {deviceToken:_,...receipt}=result;send(200,receipt);return;}send(200,result);return;}
      const childClaim=/^\/v1\/child-invitations\/claims\/([^/]+)$/.exec(url.pathname);
      if(childClaim&&method==='GET'){send(200,await guardian.claimStatus(auth.identity,uuid.parse(url.searchParams.get('householdId')),uuid.parse(childClaim[1])));return;}
      const ownProposal=/^\/v1\/views\/([^/]+)\/proposals\/([^/]+)$/.exec(url.pathname);
      if(ownProposal&&method==='GET'){const householdId=session?.householdId??uuid.parse(req.headers['x-household-id']);send(200,await repository.authorized(householdId,auth,ctx=>helperReview.ownProposal(ctx,uuid.parse(ownProposal[1]),uuid.parse(ownProposal[2]))));return;}
      const viewMatch=/^\/v1\/views\/([^/]+)\/(current|proposals)$/.exec(url.pathname);
      if(viewMatch){
        const grantId=uuid.parse(viewMatch[1]);
        const householdId=session?.householdId??uuid.parse(req.headers['x-household-id']);
        const payload=method==='POST'?await body(req):undefined;
        send(200,await repository.authorized<unknown>(householdId,auth,async ctx=>{
          if(viewMatch[2]==='current'&&method==='GET')return lifecycle.currentView(ctx,grantId);
          if(viewMatch[2]==='proposals'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return helperReview.ownProposals(ctx,grantId,cursor);}
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
      if(path==='/exit'&&method==='POST'){
        if(!options.privacy)throw new ServiceError(503,'deletion_unavailable','Account lifecycle is not configured.');
        const input=exitSchema.parse(await privacyCall!.run(()=>body(req)));
        const result=await options.privacy.leave(auth.identity,householdId,input,privacyCall!.call);
        if(session)res.setHeader('Set-Cookie',clearScope);send(200,result);return;
      }
      if(path==='/devices'&&method==='POST') {
        z.object({}).strict().parse(await body(req));
        send(201,await repository.enroll(householdId,auth.identity));return;
      }
      const verificationRoute=/^\/guardian\/enrollments\/([^/]+)\/verification$/.exec(path);
      if(verificationRoute&&method==='POST'){send(200,await guardian.verification(householdId,auth,uuid.parse(verificationRoute[1]),guardianActionSchema.parse(await body(req,4096))));return;}
      const payload=method==='POST'||method==='PUT'||(method==='DELETE'&&/\/measurement-feedback$/.test(path))?await householdBody(req,path):undefined;
      const ownPlacement=/^\/shops\/([^/]+)\/placement-reports\/mine\/([^/]+)$/.exec(path);
      const placementCommand=path==='/commands'&&method==='POST'&&typeof payload==='object'&&payload!==null&&'kind' in payload&&(payload.kind==='shop.reportPlaced'||payload.kind==='shop.reconcileReport')?parseCommand(payload):undefined;
      const placementRead=method==='GET'?/^\/shops\/([^/]+)\/placement-reports(?:\/[^/]+)?$/.exec(path):null;
      const historicalReportShopId=placementCommand?.shopId??(ownPlacement&&method==='GET'?uuid.parse(ownPlacement[1]):placementRead?uuid.parse(placementRead[1]):undefined);
      const scopedAuth=historicalReportShopId?{...auth,historicalReportShopId}:auth;
      const output=await repository.authorized(householdId,scopedAuth,async ctx=>{
        if(path==='/devices/current/request-queue' && method==='PUT'){
          const {enabled}=z.object({enabled:z.boolean()}).strict().parse(payload);
          return repository.setRequestQueuePermission(ctx,enabled);
        }
        if(ownPlacement&&method==='GET')return placementReports.own(ctx,uuid.parse(ownPlacement[1]),uuid.parse(ownPlacement[2]),z.string().regex(/^[0-9a-f]{64}$/).parse(url.searchParams.get('commandDigest')));
        if(path==='/devices/current'&&method==='DELETE')return repository.logout(ctx);
        if(path==='/devices'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return devices.list(ctx,cursor);}
        const deviceRevocation=/^\/devices\/([^/]+)\/revocation$/.exec(path);
        if(deviceRevocation&&method==='POST')return devices.revoke(ctx,auth.identity,uuid.parse(deviceRevocation[1]),deviceRevocationSchema.parse(payload));
        if(options.billing){
          if(path==='/entitlements'&&method==='GET')return options.billing.snapshot(ctx);
          if(path==='/billing/seat-candidates'&&method==='GET')return options.billing.seatCandidates(ctx);
          if(path==='/billing/purchase-context'&&method==='POST'){z.object({}).strict().parse(payload);return options.billing.prepare(ctx);}
          if(path==='/billing/seats'&&method==='PUT')return options.billing.replaceSeats(ctx,billingSeatsSchema.parse(payload));
        }
        if(path==='/members'&&method==='GET')return lifecycle.members(ctx);
        if(path==='/invites'&&method==='GET')return lifecycle.invites(ctx);
        if(path==='/views'&&method==='GET')return lifecycle.views(ctx);
        if(path==='/invites'&&method==='POST')return lifecycle.invite(ctx,inviteCreateSchema.parse(payload));
        if(path==='/views'&&method==='POST')return lifecycle.createView(ctx,viewCreateSchema.parse(payload));
        if(path==='/revocations'&&method==='POST')return lifecycle.revoke(ctx,revocationSchema.parse(payload));
        if(path==='/guardian/notice'&&method==='GET'){if(ctx.member.kind!=='adult'||ctx.viewGrantId)throw accessEnded();return guardian.notice(z.enum(['en','es']).parse(url.searchParams.get('language')??'en'));}
        if(path==='/guardian/enrollments'&&method==='GET')return guardian.list(ctx,auth.identity);
        if(path==='/guardian/enrollments'&&method==='POST')return guardian.create(ctx,auth.identity,guardianCreateSchema.parse(payload));
        const guardianRoute=/^\/guardian\/enrollments\/([^/]+)(?:\/(consent|child-invitations|confirm-child|cancel))?$/.exec(path);
        if(guardianRoute){const id=uuid.parse(guardianRoute[1]);if(!guardianRoute[2]&&method==='GET')return guardian.read(ctx,auth.identity,id);if(method==='POST'){
          if(guardianRoute[2]==='consent')return guardian.consent(ctx,auth.identity,id,guardianConsentSchema.parse(payload));
          if(guardianRoute[2]==='child-invitations')return guardian.invite(ctx,auth.identity,id,guardianInvitationSchema.parse(payload));
          if(guardianRoute[2]==='confirm-child')return guardian.confirm(ctx,auth.identity,id,guardianConfirmSchema.parse(payload));
          if(guardianRoute[2]==='cancel')return guardian.cancel(ctx,auth.identity,id,guardianActionSchema.parse(payload));
        }}
        if(path==='/guardian/consents'&&method==='GET')return {...await lifecycle.consents(ctx),enrollmentEnabled:guardian.notice('en').available||guardian.notice('es').available};
        if(path==='/guardian/enrollment'&&method==='POST')throw new ServiceError(503,'consent_unavailable','Child enrollment is unavailable until verified guardian consent is configured.');
        const consentMatch=/^\/guardian\/consents\/([^/]+)\/revoke$/.exec(path);
        if(consentMatch&&method==='POST'){z.object({}).strict().parse(payload);return lifecycle.revokeConsent(ctx,uuid.parse(consentMatch[1]));}
        if(path==='/decisions'&&method==='GET')return decisions.list(ctx,url.searchParams);
        if(path==='/price-observations'&&method==='POST')return history.observe(ctx,observationWriteSchema.parse(payload));
        if(path==='/price-observations'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return history.observations(ctx,cursor);}
        const observation=/^\/price-observations\/([^/]+)$/.exec(path);
        if(observation&&method==='GET')return history.observation(ctx,uuid.parse(observation[1]));
        if(path==='/budget-history'&&method==='POST')return history.budgets(ctx,budgetQuerySchema.parse(payload).shopIds);
        if(path==='/budget-periods'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return history.periods(ctx,cursor);}
        if(path==='/budget-periods'&&method==='POST')return history.writePeriod(ctx,periodWriteSchema.parse(payload));
        const period=/^\/budget-periods\/([^/]+)(\/record)?$/.exec(path);
        if(period&&method==='GET')return history.period(ctx,uuid.parse(period[1]),Boolean(period[2]));
        const financial=/^\/shops\/([^/]+)\/(financial-evidence|financial-reviews|history-retire)$/.exec(path);
        if(financial){const shopId=uuid.parse(financial[1]);if(financial[2]==='financial-evidence'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return history.financialRecord(ctx,shopId,cursor);}
         if(financial[2]==='financial-evidence'&&method==='POST')return history.append(ctx,shopId,financialAppendSchema.parse(payload));
         if(financial[2]==='financial-reviews'&&method==='POST')return history.review(ctx,shopId,financialReviewSchema.parse(payload));
         if(financial[2]==='history-retire'&&method==='POST')return history.retire(ctx,shopId,historyRetireSchema.parse(payload));
        }
        if(path==='/shops'&&method==='GET'){const scope=z.enum(['active','owned']).parse(url.searchParams.get('scope')??'active'),cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return repository.shops(ctx,scope,cursor);}
        const replacement=/^\/views\/([^/]+)\/replacements$/.exec(path);
        if(replacement&&method==='POST')return helperReview.replace(ctx,uuid.parse(replacement[1]),viewReplacementSchema.parse(payload));
        const proposalStatus=/^\/views\/([^/]+)\/proposals\/([^/]+)$/.exec(path);
        if(proposalStatus&&method==='GET')return helperReview.managementProposal(ctx,uuid.parse(proposalStatus[1]),uuid.parse(proposalStatus[2]));
        const resolution=/^\/views\/([^/]+)\/proposals\/([^/]+)\/resolve$/.exec(path);
        if(resolution&&method==='POST')return helperReview.resolve(ctx,uuid.parse(resolution[1]),uuid.parse(resolution[2]),proposalResolutionSchema.parse(payload));
        const managedView=/^\/views\/([^/]+)(\/proposals)?$/.exec(path);
        if(managedView){
          const grantId=uuid.parse(managedView[1]);
          if(managedView[2]==='/proposals'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return lifecycle.proposals(ctx,grantId,cursor);}
          if(!managedView[2]&&method==='GET')return helperReview.current(ctx,grantId);
          if(!managedView[2]&&method==='PUT')return lifecycle.updateView(ctx,grantId,viewUpdateSchema.parse(payload));
        }
        if (path === '/measurement/status' && method === 'GET') return measurement.status(ctx);
        if (path === '/measurement/consent' && method === 'POST') return measurement.consent(ctx, payload);
        if (path === '/measurement/withdraw' && method === 'POST') return measurement.withdraw(ctx, payload);
        if (path === '/history-readable-shops' && method === 'GET') {
          const cursor = url.searchParams.get('cursor');
          if (cursor) uuid.parse(cursor);
          return history.readableShops(ctx, cursor);
        }
        if(path==='/bootstrap'&&method==='GET')return repository.bootstrap(ctx);
        if(path==='/replay-windows'&&method==='POST'){z.object({}).strict().parse(payload);return repository.window(ctx);}
        if(path==='/requests/mine'&&method==='GET') {
          const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);
          return repository.requests(ctx,cursor);
        }
        if(path==='/commands'&&method==='POST') {
          const command=parseCommand(payload), header=req.headers['x-request-queue-grant'];
          const queueGrant=header===undefined?undefined:uuid.parse(header).toLowerCase();
          if(queueGrant && !['request.send','request.edit','request.withdraw'].includes(command.kind))throw invalid();
          return repository.execute(ctx,command,options.billing,queueGrant);
        }
        const shopMatch=/^\/shops\/([^/]+)(.*)$/.exec(path);
        if(shopMatch) {
          const shopId=uuid.parse(shopMatch[1]),tail=shopMatch[2];
          if (tail === '/measurement-feedback') {
            if (method === 'GET') return measurement.read(ctx, shopId);
            if (method === 'POST') return measurement.feedback(ctx, shopId, payload);
            if (method === 'DELETE') return measurement.removeFeedback(ctx, shopId, payload);
          }
          if (tail === '/store-quotes' && method === 'GET') {
            const cursor = url.searchParams.get('cursor');
            if (cursor) uuid.parse(cursor);
            return storeQuotes.read(ctx, shopId, cursor);
          }
          const storeQuoteAction = /^\/store-quotes\/(grants|pairs|proposals|adoptions)$/.exec(tail ?? '');
          if (storeQuoteAction && method === 'POST') {
            const actions = { grants: 'grant', pairs: 'pairs', proposals: 'proposals', adoptions: 'adoptions' } as const;
            return storeQuotes.change(ctx, shopId, actions[storeQuoteAction[1] as keyof typeof actions], payload);
          }
          if(tail==='/decisions'&&method==='POST')return decisions.create(ctx,shopId.toLowerCase(),payload);
          const decisionRoute=/^\/decisions\/([^/]+)(?:\/(outcome|promote))?$/.exec(tail??'');
          if(decisionRoute){
            const id=uuid.parse(decisionRoute[1]).toLowerCase(),action=decisionRoute[2];
            if(!action&&method==='GET')return decisions.read(ctx,shopId.toLowerCase(),id);
            if((action==='outcome'||action==='promote')&&method==='POST')return decisions.update(ctx,shopId.toLowerCase(),id,action,payload);
          }
          if(tail==='/placement-reports'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor)uuid.parse(cursor);return placementReports.pending(ctx,shopId,cursor);}
          if(tail==='/placement-reports/current-shop'&&method==='GET')return placementReports.currentShop(ctx,shopId);
          const placementDetail=/^\/placement-reports\/([^/]+)$/.exec(tail??'');
          if(placementDetail&&method==='GET')return placementReports.detail(ctx,shopId,uuid.parse(placementDetail[1]));
          if(tail==='/accepted-fallbacks' && method==='GET')return fallbacks.read(ctx,shopId.toLowerCase(),url.searchParams.get('cursor'));
          if(tail==='/accepted-fallbacks' && method==='POST')return fallbacks.change(ctx,shopId.toLowerCase(),payload);
          if(tail==='/accepted-fallbacks/source' && method==='POST')return fallbacks.source(ctx,shopId.toLowerCase(),payload);
          if(tail==='/meal-recovery/options' && method==='POST') {
            const shop=await repository.shop(ctx,shopId.toLowerCase());
            repository.requireShopper(ctx,shop);
            await requireAssistance(ctx,options.billing);
            return rankSharedFallbacks(ctx,shop,payload,loadRecoveryPublication);
          }
          if((tail==='/meal-recovery' || tail==='/meal-recovery/coverage') && method==='GET' || tail==='/meal-recovery/preview' && method==='POST') {
            const shop=await repository.shop(ctx,shopId.toLowerCase());
            repository.requireShopper(ctx,shop);
            if(tail==='/meal-recovery/coverage') return readSharedRecoveryCoverage(ctx,shop,loadRecoveryPublication);
            return method==='GET' ? readRecoveryDesk(ctx,shop) : previewSharedRecovery(ctx,shop,payload,options.billing);
          }
          if((tail==='/pantry-lots' || tail==='/pantry-lots/coverage') && method==='GET' ||
             tail==='/pantry-lots/observation-preview' && method==='POST'){
            const shop=await repository.shop(ctx,shopId.toLowerCase());repository.requireShopper(ctx,shop);
            if(tail==='/pantry-lots/coverage') return readJointCoverage(ctx,shop);
            if(tail==='/pantry-lots/observation-preview') return previewCurrentPantryObservation(ctx,shop,payload,loadRecoveryPublication);
            const cursor=url.searchParams.get('cursor');
            return readPantry(ctx,shop,cursor===null?null:uuid.parse(cursor));
          }
          if(tail==='/cook-copies' && method==='GET') {
            const shop=await repository.shop(ctx,shopId.toLowerCase());repository.requireShopper(ctx,shop);
            const cursor=url.searchParams.get('cursor');
            return cookCopyHistory(ctx,shop,uuid.parse(url.searchParams.get('occurrenceId')),cursor===null?null:uuid.parse(cursor));
          }
          if(tail==='/cook-copies/correction' && method==='POST') {
            const shop=await repository.shop(ctx,shopId.toLowerCase());repository.requireShopper(ctx,shop);
            if(!options.billing) throw new ServiceError(503,'billing_unavailable','Try again when membership can be verified.');
            await options.billing.requirePaidSeat(ctx);
            return cookCorrectionFacts(ctx,shop,payload);
          }
          if(tail==='/cook-copies/baseline' && method==='POST') {
            const shop=await repository.shop(ctx,shopId.toLowerCase());repository.requireShopper(ctx,shop);
            return cookCopyBaseline(ctx,shop,payload);
          }
          if(tail==='/confirmed-order' && method==='GET') {
            const shop=await repository.shop(ctx,shopId.toLowerCase());repository.requireShopper(ctx,shop);
            return readConfirmedOrder(ctx,shop);
          }
          if((tail==='/delivery-evidence' || tail==='/delivery-evidence/coverage') && method==='GET'){
            const shop=await repository.shop(ctx,shopId.toLowerCase());repository.requireShopper(ctx,shop);
            if(tail==='/delivery-evidence/coverage') return readDeliveryCoverage(ctx,shop);
            const cursor=url.searchParams.get('cursor');
            return readDelivery(ctx,shop,cursor===null?null:uuid.parse(cursor));
          }
          if(tail==='/shopper-assignment'&&method==='GET')return repository.shopperAssignment(ctx,shopId);
          if(tail==='/meal-plan/ideas'&&method==='GET')return mealIdeas.read(ctx,shopId);
          if(tail==='/meal-plan/ideas'&&method==='POST')return mealIdeas.write(ctx,shopId,sharedIdeaWriteSchema.parse(payload));
          if(tail==='/meal-plan/changes'&&method==='GET')return mealChanges.read(ctx,shopId);
          if(tail==='/meal-plan/changes'&&method==='POST')return mealChanges.propose(ctx,shopId,sharedMealChangeSchema.parse(payload));
          if(tail==='/meal-plan/changes/dismissals'&&method==='POST')return mealChanges.dismiss(ctx,shopId,sharedMealDismissSchema.parse(payload));
          if(tail==='/meal-plan'&&method==='GET')return mealMoves.read(ctx,shopId);
          if(tail==='/meal-plan/planner'&&method==='PUT')return mealMoves.grant(ctx,shopId,grantChange.parse(payload));
          if(tail==='/meal-plan/dismissals'&&method==='POST')return mealMoves.dismiss(ctx,shopId,dismissMove.parse(payload));
          if(tail==='/meal-plan/proposals'&&method==='POST')return mealMoves.propose(ctx,shopId,moveRequest.parse(payload));
          if(tail==='/records/snapshot'&&method==='GET')return readSharedRecordSnapshot(repository,ctx,await repository.shop(ctx,shopId));
          if(tail==='/demand/tracking/operations'&&method==='GET')return readTrackingHistory(repository,ctx,await repository.shop(ctx,shopId));
          if(tail==='/demand/tracking'&&method==='GET')return readTracking(repository,ctx,await repository.shop(ctx,shopId));
          if(tail==='/demand/tracking/candidates'&&method==='POST')return createTrackingCandidate(repository,ctx,await repository.shop(ctx,shopId),payload);
          if(tail==='/demand/tracking/previews'&&method==='POST')return acceptTrackingCandidate(repository,ctx,await repository.shop(ctx,shopId),payload);
          if(tail==='/records/tracking-snapshot'&&method==='GET')return readTrackingRecord(repository,ctx,await repository.shop(ctx,shopId));
          if(tail==='/demand'&&method==='GET')return readDemand(repository,ctx,await repository.shop(ctx,shopId));
          if(tail==='/demand/action-sources'&&method==='POST')return readActionDemandSources(repository,ctx,await repository.shop(ctx,shopId),payload);
          if(tail==='/demand/operations'&&method==='GET')return readFoodOperationHistory(repository,ctx,await repository.shop(ctx,shopId),url.searchParams.get('beforeRevision'));
          if(tail==='/demand/operation-undo-candidates'&&method==='POST')return readFoodOperationUndoCandidate(repository,ctx,await repository.shop(ctx,shopId),payload);
          if(tail==='/demand/operation-undo-previews'&&method==='POST')return previewFoodOperationUndo(repository,ctx,await repository.shop(ctx,shopId),payload);
          if(tail==='/demand/previews'&&method==='POST')return previewDemand(repository,ctx,await repository.shop(ctx,shopId),payload);
          if(tail===''&&method==='GET')return repository.adultShop(ctx,shopId);
          if(tail==='/deferred-requests'&&method==='GET'){const cursor=url.searchParams.get('cursor');if(cursor!==null)uuid.parse(cursor);return repository.deferredRequests(ctx,shopId,cursor);}
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
      else if(error instanceof PartitionError)safe=new ServiceError(409,error.code,'Review the current tracking facts and sources.');
      else if(error instanceof SharedDemandError)safe=new ServiceError(422,error.code,'Review the shared source quantities and allocation choices.');
      else if(error&&typeof error==='object'&&'code'in error&&error.code==='23505')safe=new ServiceError(409,'identity_conflict','Refresh current records before retrying.');
      else if(error&&typeof error==='object'&&'code'in error&&['23503','23514'].includes(String(error.code)))safe=new ServiceError(422,'invalid_candidate','Review linked records and required values.');
      else {safe=new ServiceError(503,'storage_unavailable','Keep your draft and retry the same operation key.');if(!res.destroyed&&!res.headersSent)res.setHeader('Retry-After','1');}
      send(safe.status,{error:{code:safe.code,correlationId,recovery:safe.recovery}});
    } finally {privacyCall?.dispose();}
  });
}
