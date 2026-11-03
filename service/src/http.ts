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
import {PrivacyService,deletionSchema,exitSchema} from './privacy.js';
import {viewReplacementSchema,proposalResolutionSchema,householdCreateSchema,inviteCreateSchema,inviteRedeemSchema,viewCreateSchema,viewUpdateSchema,proposalSchema,revocationSchema, parseCommand,previewSchema,uuid } from './contracts.js';
export interface HTTPOptions { repository:HouseholdRepository; verifier?:IdentityVerifier; webOrigin?:string; maxRequestsPerMinute?:number; billing?:BillingService; browserAuth?:BrowserAuthService; privacy?:PrivacyService; clientAddress?:(request:IncomingMessage)=>string|undefined }
async function body(req:IncomingMessage,maxBytes=65_536):Promise<unknown> {
  if(!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type']??''))throw new ServiceError(415,'json_required','Send a JSON command.');
  const chunks:Buffer[]=[];let size=0;
  for await(const chunk of req) {size+=chunk.length;if(size>maxBytes)throw new ServiceError(413,'body_too_large','Send one bounded command.');chunks.push(chunk);}
  try{return JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{throw invalid();}
}
function equal(a:string,b:string){const aa=Buffer.from(a),bb=Buffer.from(b);return aa.length===bb.length&&timingSafeEqual(aa,bb);}
function cookie(req:IncomingMessage,name='ritc_session'):string|null {
  return req.headers.cookie?.split(';').map(s=>s.trim()).find(s=>s.startsWith(name+'='))?.slice(name.length+1)??null;
}
export function createHTTPServer(options:HTTPOptions) {
  const repository=options.repository,verifier=options.verifier??new DenyIdentityVerifier();
  const lifecycle=new HouseholdLifecycle(repository),helperReview=new HelperReview(lifecycle),history=new PriceBudgetHistory(repository,options.billing);
  const decisions = new DecisionHistory(options.billing);
  const mealMoves = new MealMoves(repository,options.billing);
  const mealIdeas = new SharedMealIdeas(repository,mealMoves);
  const mealChanges = new SharedMealChanges(repository,mealMoves);
  const storeQuotes = new SharedStoreQuotes(repository);
  const measurement = new HouseholdMeasurement(repository);
  const placementReports = new PlacementReports(repository);
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
      const ip=options.clientAddress?options.clientAddress(req):req.socket.remoteAddress;
      if(!ip||ip.length>128)throw new ServiceError(503,'client_context_unavailable','Try again when the service can verify this connection.');
      const now=Date.now(),old=limits.get(ip);
      if(limits.size>=10_000)for(const[k,v]of limits)if(v.until<now)limits.delete(k);
      if(limits.size>=10_000&&!old){res.setHeader('Retry-After','60');throw new ServiceError(429,'rate_limited','Retry later.');}
      const bucket=old&&old.until>now?old:{count:0,until:now+60_000};bucket.count++;limits.set(ip,bucket);
      if(bucket.count>(options.maxRequestsPerMinute??120)){res.setHeader('Retry-After','60');throw new ServiceError(429,'rate_limited','Keep the operation key and retry later.');}
      if(url.pathname==='/v1/apple/notifications'&&method==='POST'&&options.billing){const input=billingNotificationSchema.parse(await body(req,262_144));send(200,await options.billing.notification(repository.pool,input.signedPayload));return;}
      const privacyStatus=/^\/v1\/privacy\/jobs\/([^/]+)$/.exec(url.pathname);
      if(privacyStatus&&method==='GET'){
        if(!options.privacy)throw new ServiceError(503,'deletion_unavailable','Account deletion is not configured.');
        const token=z.string().regex(/^[A-Za-z0-9_-]{43}$/).parse(req.headers['x-deletion-token']);
        send(200,await options.privacy.status(uuid.parse(privacyStatus[1]),token));return;
      }
      const browserCookie=cookie(req,'__Host-ritc_auth');
      const setAuthCookie=(value:string,maxAge:number)=>`__Host-ritc_auth=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${maxAge}`;
      const clearScope='ritc_session=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0';
      const csrfHeader=()=>{const value=req.headers['x-csrf-token'];if(!options.webOrigin||req.headers.origin!==options.webOrigin||typeof value!=='string')throw new ServiceError(403,'csrf_failed','Reload sign-in and try again.');return value;};
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
        const identity=await verifier.verify(match[1]!);
        auth={identity,...(typeof req.headers['x-device-token']==='string'?{deviceToken:req.headers['x-device-token']}:{}),...(req.headers['x-view-grant-id']!==undefined?{viewGrantId:uuid.parse(req.headers['x-view-grant-id'])}:{}),...(req.headers['x-shop-id']!==undefined?{selectedShopId:uuid.parse(req.headers['x-shop-id'])}:{})};
      }else {
        if(browserCookie&&options.browserAuth){try{browserIdentity=await options.browserAuth.authenticate(browserCookie);auth={identity:browserIdentity.identity};}catch(error){if(!(error instanceof ServiceError)||error.code!=='session_needed')throw error; if(url.pathname!=='/v1/session'||method!=='GET')throw error;}}
        const value=cookie(req);if(value){session=await repository.webIdentity(value,browserIdentity?.identity);auth=session.auth;}
      }
      if(method==='GET'&&url.pathname==='/v1/session'&&!session){send(200,{authenticated:false});return;}
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
        if(url.pathname==='/v1/privacy/deletion-preview'&&method==='GET'){send(200,await options.privacy.preview(auth.identity));return;}
        if(url.pathname==='/v1/privacy/deletions'&&method==='POST'){
          const result=await options.privacy.request(auth.identity,deletionSchema.parse(await body(req)));
          res.setHeader('Set-Cookie',[clearScope,setAuthCookie('',0)]);send(202,result);return;
        }
      }
      if(url.pathname==='/v1/households'&&method==='POST'){send(201,await lifecycle.create(auth.identity,householdCreateSchema.parse(await body(req))));return;}
      if(url.pathname==='/v1/invites/redeem'&&method==='POST'){send(200,await lifecycle.redeem(auth.identity,inviteRedeemSchema.parse(await body(req))));return;}
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
        const result=await options.privacy.leave(auth.identity,householdId,exitSchema.parse(await body(req)));
        if(session)res.setHeader('Set-Cookie',clearScope);send(200,result);return;
      }
      if(path==='/devices'&&method==='POST') {
        z.object({}).strict().parse(await body(req));
        send(201,await repository.enroll(householdId,auth.identity));return;
      }
      const payload=method==='POST'||method==='PUT'||(method==='DELETE'&&/\/measurement-feedback$/.test(path))?await body(req):undefined;
      const ownPlacement=/^\/shops\/([^/]+)\/placement-reports\/mine\/([^/]+)$/.exec(path);
      const placementCommand=path==='/commands'&&method==='POST'&&typeof payload==='object'&&payload!==null&&'kind' in payload&&(payload.kind==='shop.reportPlaced'||payload.kind==='shop.reconcileReport')?parseCommand(payload):undefined;
      const placementRead=method==='GET'?/^\/shops\/([^/]+)\/placement-reports(?:\/[^/]+)?$/.exec(path):null;
      const historicalReportShopId=placementCommand?.shopId??(ownPlacement&&method==='GET'?uuid.parse(ownPlacement[1]):placementRead?uuid.parse(placementRead[1]):undefined);
      const scopedAuth=historicalReportShopId?{...auth,historicalReportShopId}:auth;
      const output=await repository.authorized(householdId,scopedAuth,async ctx=>{
        if(ownPlacement&&method==='GET')return placementReports.own(ctx,uuid.parse(ownPlacement[1]),uuid.parse(ownPlacement[2]),z.string().regex(/^[0-9a-f]{64}$/).parse(url.searchParams.get('commandDigest')));
        if(path==='/devices/current'&&method==='DELETE')return repository.logout(ctx);
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
        if(path==='/guardian/consents'&&method==='GET')return lifecycle.consents(ctx);
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
        if(path==='/commands'&&method==='POST')return repository.execute(ctx,parseCommand(payload));
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
