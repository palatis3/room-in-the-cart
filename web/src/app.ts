import { brandName } from './brand.js';
import { API, ApiError, isContributorSession, type BrowserAuthState,type RequestPickup,type Session, type OwnRequest, type ReadRequest, type Command, type CookView, type InviteRedemption, prepareProposal, type ProposalIntent, type ProposalReceipt, type OwnProposal, type ReportField, type ReportReason, type SafetyAction } from './api.js';
import { Outbox, scopeFor, type Pending } from './outbox.js';
import { languageFor, translate, type Language } from './i18n.js';
import {browserSignOutPending,resumeBrowserSignOut,setBrowserSignOutPending} from './browser-sign-out.js';

interface CookingReportDraft {
  grantId: string;
  revision: number;
  servings: string;
  ingredients: string;
  leftovers: string;
  review: string | null;
}

type SafetyField = {source:ReportField; text:string; label:string};
interface SafetyReview {
  scope:string;
  fields:SafetyField[];
  selected:number;
  reason:ReportReason|'';
  includeText:boolean;
  action:'report'|'block';
  intent?:SafetyAction;
}
type Draft = {item:string; amount:string; route:'current'|'next'; editing:OwnRequest|null; followup:string|null};
const blank = ():Draft => ({item:'',amount:'',route:'current',editing:null,followup:null});
const unavailableInvitationNotice = 'This invitation is unavailable. Ask your household for a new invitation.';
const statuses:Record<string,string> = {pending:'Received',clarified:'Needs clarification',added:'Added to the pickup',deferred:'Saved for next shop',handled:'Handled',dismissed:'Dismissed',withdrawn:'Withdrawn'};
const proposalNotices:Record<OwnProposal['status'],string> = {
  pending:'Proposal received. The shopper must review it before anything changes.',
  reviewed:'Suggestion reviewed',
  dismissed:'Suggestion dismissed',
};
// A reviewed draft is valid only for the exact actor, role and destination that displayed it.
function reviewScope(session: Session): string {
  return JSON.stringify([session.household.id, session.memberId, session.role, session.shopId, session.grantId ?? null]);
}
function isPostingSuspended(error:unknown):boolean {
  return error instanceof ApiError&&error.status===403&&error.code==='shared_posting_unavailable';
}
function isRequestRevisionConflict(error:unknown):boolean {
  return error instanceof ApiError && error.status===409 && (error.code==='followup_required'||error.code==='stale_base');
}

export class WebApp {
  private session:Session|null = null;
  private joinedSession: Session | null = null;
  private browserAuth:BrowserAuthState|null=null;
  private loginEmail='';
  private loginCode='';
  private codeRequested=false;
  private reviewedScope:string|null = null;
  private logoutPending = false;
  private requests:ReadRequest[] = [];
  private firstRequestPageAsOf:string|undefined;
  private pickups:RequestPickup[]=[];
  private chosenPickupId:string|null=null;
  private view:CookView|null = null;
  private pending:Pending[] = [];
  private queueState:'ready'|'unavailable'|'missing' = 'ready';
  private confirmedOperations = new Set<string>();
  private draft = blank();
  private review = false;
  private busy = false;
  private historySuspended = false;
  private historyAway = false;
  private historyGeneration = 0;
  private historyResumePending = false;
  private notice = '';
  private failurePurpose:'load'|'mutation'|null=null;
  private language:Language;
  private consent = false;
  private adultAttestation = false;
  private inviteAlias = '';
  private redemption:InviteRedemption|null = null;
  // A live draft keeps its online receipt identity across changes to offline storage permission.
  private retryCommand:Command|null = null;
  private uncertainSend = false;
  private proposalIntent:ProposalIntent|null = null;
  private proposalReceipt:ProposalReceipt|null = null;
  private proposalStatus:OwnProposal|null = null;
  private proposalConflict=false;
  private proposalGeneration=0;
  private receivedSuggestions:OwnProposal[]=[];
  private suggestionsCursor:string|null=null;
  private suggestionsState:'unchecked'|'ready'|'unavailable'='unchecked';
  private correction = '';
  private cookingReport: CookingReportDraft | null = null;
  private safety:SafetyReview|null=null;
  private withdrawn:OwnRequest|null = null;
  private withdrawalCommand:Command|null = null;
  constructor(private readonly root:HTMLElement, private readonly api = new API(), private readonly outbox = new Outbox(), private invitation:string|null = null) {
    const browser = root.ownerDocument.defaultView;
    const selected = new URLSearchParams(browser?.location.search).get('lang');
    this.language = selected === 'en' || selected === 'es' ? selected : languageFor(browser?.navigator.language ?? 'en');
  }
  private t(key:string):string { return translate(key,this.language); }
  private el<K extends keyof HTMLElementTagNameMap>(tag:K,text?:string):HTMLElementTagNameMap[K] {
    const e=this.root.ownerDocument.createElement(tag); if(text!==undefined)e.textContent=text; return e;
  }
  private button(key:string,action:()=>void,primary=false):HTMLButtonElement {
    const b=this.el('button',this.t(key)); b.type='button'; b.disabled=this.busy; if(primary)b.className='primary'; b.addEventListener('click',action); return b;
  }
  private async run(action:()=>Promise<void>,purpose:'load'|'mutation'='mutation',retryingSignOut=false):Promise<void> {
    if(this.busy||(this.signOutPending&&!retryingSignOut))return;
    this.joinedSession=null;
    this.busy=true; this.render();
    const historyGeneration=this.historyGeneration;
    try { await action(); if(purpose==='load'&&!this.historyAway&&historyGeneration===this.historyGeneration)this.historySuspended=false; if(purpose==='load'&&this.failurePurpose==='load'){this.notice='';this.failurePurpose=null;} } catch(error) { await this.fail(error,purpose); }
    finally {this.busy=false;this.render();this.root.querySelector<HTMLElement>('[role="status"]')?.focus();
      if(this.historyResumePending){this.historyResumePending=false;void this.start();}
    }
  }
  private supportedRoute():boolean {
    const path=this.root.ownerDocument.defaultView?.location.pathname??'/';
    if(path==='/')return true;
    return ['/requests','/invite','/view'].includes(path.endsWith('/')?path.slice(0,-1):path);
  }
  private get signOutPending():boolean {return this.logoutPending||browserSignOutPending(this.root.ownerDocument.defaultView);}
  suspendForHistory():void {
    // Remove private DOM before the browser can retain a history snapshot. Keep
    // unsent work in memory until a fresh session confirms the same scope.
    this.historyAway=true;this.historySuspended=true;this.historyGeneration++;this.render();
  }
  resumeFromHistory():void {
    this.historyAway=false;
    if(this.busy){this.historyResumePending=true;return;}
    void this.start();
  }
  resumeWithFreshAuthority():void {
    // Visibility/pageshow can describe the same return. Keep an existing
    // concealed read (or its deferred refresh) instead of starting another.
    if(this.historySuspended&&!this.historyAway&&this.busy)return;
    this.historySuspended=true;this.historyGeneration++;this.render();
    this.resumeFromHistory();
  }
  async start():Promise<void> {
    if(this.historyAway)return;
    if(!this.supportedRoute()){this.render();return;}
    if(this.signOutPending){this.hideWhileSigningOut();this.render();return;}
    await this.run(()=>this.load(),'load');
  }
  private clearPrivate():void {
    this.safety=null;this.clearInvitationDraft();this.browserAuth=null;
    this.joinedSession=null;
    this.session=null;this.reviewedScope=null;this.pickups=[];this.chosenPickupId=null;this.requests=[];this.firstRequestPageAsOf=undefined;this.view=null;this.pending=[];this.queueState='ready';this.draft=blank();
    this.retryCommand=null;this.uncertainSend=false;this.consent=false;this.review=false;this.correction='';this.cookingReport=null;
    this.receivedSuggestions=[];this.suggestionsCursor=null;this.suggestionsState='unchecked';
    this.proposalGeneration++;this.proposalIntent=null;this.proposalReceipt=null;this.proposalStatus=null;this.proposalConflict=false;this.withdrawn=null;this.withdrawalCommand=null;this.confirmedOperations.clear();
  }
  private clearInvitationDraft():void {
    this.loginEmail='';
    this.loginCode='';
    this.codeRequested=false;
    this.invitation=null;
    this.redemption=null;
    this.adultAttestation=false;
    this.inviteAlias='';
  }
  private adoptBrowserAuth(fresh:BrowserAuthState|null):void {
    const previous=this.browserAuth;
    if(previous&&(previous.csrf!==fresh?.csrf||previous.authenticated!==fresh?.authenticated)){
      const hadInvitation=this.invitation!==null;
      this.clearInvitationDraft();
      this.notice=hadInvitation?'Your sign-in changed. Reopen the invitation you want to use.':'';
    }
    this.browserAuth=fresh;
  }
  checkExpiry():void {
    if (this.session?.requestQueueUntil && Date.parse(this.session.requestQueueUntil) <= Date.now()) {
      const expiredScope=scopeFor(this.session);
      const {requestQueueGrant, requestQueueUntil, ...current} = this.session;
      this.session = {...current, queueConsent:false};
      this.pending=[];this.confirmedOperations.clear();
      this.notice='Offline permission expired. Check Your requests before sending again.';
      void this.outbox.clearScope(expiredScope).catch(()=>{this.queueState='unavailable';this.render();});
      this.render();
    }
    if(this.view && Date.parse(this.view.expiresAt)<=Date.now()) {
      this.clearPrivate();void this.outbox.clear().catch(()=>{});
      this.notice='Access has ended. Ask your household for a new invitation.';this.render();
    }
  }
  private pickupSelectionChanged(fresh:Session):boolean {
    const prior = this.session;
    if (!prior || !isContributorSession(fresh) || !fresh.enrolled) return false;
    const choicesChanged = Boolean(prior.selectionRequired) !== Boolean(fresh.selectionRequired);
    return choicesChanged && this.reviewedScope === reviewScope(prior) &&
      reviewScope({...fresh, shopId: prior.shopId}) === this.reviewedScope;
  }
  private async load(verifiedSession?:Session):Promise<void> {
    if(this.signOutPending)return;
    const start=this.proposalGeneration,fresh=verifiedSession ?? await this.api.session();
    if(start!==this.proposalGeneration)return;
    if (this.redemption && fresh) {
      if (fresh.household.id !== this.redemption.householdId || fresh.memberId !== this.redemption.memberId) {
        throw new ApiError('session_needed', 401);
      }
      if (fresh.grantId !== this.redemption.grantId || fresh.role !== this.redemption.role) {
        // Activation rotates CSRF. Keep the same member's current token for an
        // explicit retry, without reading the other grant or displaying its data.
        this.session = fresh;
        throw new ApiError('grant_context_changed', 409);
      }
    }
    if(fresh && this.pickupSelectionChanged(fresh)) {
      this.chosenPickupId=null;
      if (!this.retryCommand && !this.draft.editing && !this.draft.followup) {
        this.review=false;
        if(this.draft.item || this.draft.amount)this.notice='Available pickups changed. Review the destination before sending.';
      }
    } else if(this.reviewedScope && fresh && this.reviewedScope!==reviewScope(fresh)) {
      this.clearPrivate();this.notice='';this.render();
      await this.outbox.retainScope(scopeFor(fresh)).catch(()=>{});
    }
    const previous=this.session;
    if(!previous&&fresh&&this.browserAuth&&this.invitation!==null){
      // A different tab can activate a household while this invitation is open.
      try {
        this.adoptBrowserAuth(await this.api.authState());
      } catch(error) {
        this.clearInvitationDraft();
        this.browserAuth=null;
        throw error;
      }
    }
    this.session=fresh;
    if(!fresh?.canModerate||!fresh.enrolled||(this.safety&&reviewScope(fresh)!==this.safety.scope))this.safety=null;
    if(!fresh){
      this.cookingReport=null;
      this.requests=[];this.firstRequestPageAsOf=undefined;
      this.view=null;
      this.pending=[];
      this.receivedSuggestions=[];
      this.suggestionsState='unchecked';
      this.consent=false;
      if(previous){
        this.clearInvitationDraft();
        this.browserAuth=null;
      }
      this.render();
    }
    if (previous?.requestQueueGrant && previous.requestQueueGrant !== fresh?.requestQueueGrant) {
      this.pending=[];this.confirmedOperations.clear();
      await this.outbox.clearScope(scopeFor(previous)).catch(()=>{this.queueState='unavailable';});
    }
    if(!fresh){
      this.adoptBrowserAuth(await this.api.authState());
      return;
    }
    if (fresh.role !== 'helper' && fresh.role !== 'editor' && !isContributorSession(fresh)) throw new ApiError('access_ended',403);
    this.reviewedScope=reviewScope(fresh);
    if(fresh.role==='helper'||fresh.role==='editor') {
      this.requests=[];this.firstRequestPageAsOf=undefined;this.view=null;this.pending=[];this.draft=blank();this.retryCommand=null;this.uncertainSend=false;this.consent=false;
      this.receivedSuggestions=[];this.suggestionsCursor=null;this.suggestionsState='unchecked';
      const generation=this.proposalGeneration;
      await this.outbox.clear().catch(()=>{});const view=await this.api.view(fresh);
      if(generation!==this.proposalGeneration)return;
      if(this.cookingReport){
        if(!view.canPropose || view.grantId!==this.cookingReport.grantId)this.cookingReport=null;
        else if(view.revision!==this.cookingReport.revision){
          this.cookingReport.revision=view.revision;
          this.cookingReport.review=null;
        }
      }
      this.view=view;
      if(Date.parse(view.expiresAt)<=Date.now())throw new ApiError('access_ended',403);
      const proposal=await this.readReceivedSuggestions(fresh,null);
      if(generation!==this.proposalGeneration)return;
      if(this.proposalReceipt){
        this.notice=proposal?proposalNotices[proposal.status]:'Received suggestions checked.';
        this.failurePurpose=null;
      }
    } else {
      this.view=null;
      const generation=this.proposalGeneration;
      let firstPageAsOf:string|undefined;
      const rows=await this.api.requests(fresh, asOf=>{firstPageAsOf=asOf;});
      if(generation!==this.proposalGeneration || this.session!==fresh)return;
      this.requests=rows;
      this.firstRequestPageAsOf=firstPageAsOf;
      this.reconcileRequestActions();
      const pickups=fresh.selectionRequired ? await this.api.requestPickups(fresh) : this.pickups.filter(p=>p.shopId===fresh.shopId);
      if(generation!==this.proposalGeneration || this.session!==fresh)return;
      this.pickups=pickups;
      if(this.chosenPickupId && !this.pickups.some(p=>p.shopId===this.chosenPickupId) && !this.retryCommand){
        this.chosenPickupId=null;
        this.review=false;
        this.notice='Choose an open pickup to continue.';
      }
    }
    this.queueState='ready';
    if(isContributorSession(fresh)&&fresh.queueConsent&&fresh.enrolled) {
      try {
        await this.outbox.retainScope(scopeFor(fresh));
        const stored=await this.outbox.list(scopeFor(fresh));
        if(this.session!==fresh)return;
        const storedIDs=new Set(stored.map(row=>row.id));
        if(this.pending.some(row=>!this.confirmedOperations.has(row.id)&&!storedIDs.has(row.id))) {
          this.queueState='missing';
        }
        this.pending=stored;
      } catch {
        this.pending=[];this.queueState='unavailable';
      }
    } else {this.pending=[];await this.outbox.clear().catch(()=>{});}
    if(!this.pending.length&&this.notice==='Saved on this browser. Receipt unconfirmed.')this.notice='';
    // Fresh authorized content supersedes a prior access denial, not receipt or storage warnings.
    if(this.session===fresh&&this.notice==='Access has ended. Ask your household for a new invitation.') {
      this.notice='';this.failurePurpose=null;
    }
  }
  private async reloadChangedRequest():Promise<void> {
    this.notice='This request changed. Review its current status.';
    try {await this.load();} catch(error) {await this.fail(error,'load');}
  }
  private reconcileRequestActions():void {
    if(this.withdrawn) {
      const current=this.requests.find(row=>row.requestId===this.withdrawn?.requestId);
      if(!current?.ownActionAllowed || current.revision!==this.withdrawn.revision) {
        this.withdrawn=null;
        this.withdrawalCommand=null;
        this.notice='This request changed. Review its current status.';
      }
    }
    const editing=this.draft.editing;
    if(!editing || this.retryCommand || this.uncertainSend)return;
    const current=this.requests.find(row=>row.requestId===editing.requestId);
    if(!current || (current.revision===editing.revision && current.ownActionAllowed))return;
    this.review=false;
    if(current.ownActionAllowed) {
      this.draft.editing=current;
      this.notice='This request changed. Compare your draft with the current request before saving.';
    } else if(current.status==='withdrawn') {
      this.draft=blank();
      this.notice='This request has been withdrawn.';
    } else {
      this.draft.editing=null;
      this.draft.followup=current.requestId;
      this.draft.route=current.route;
      this.notice='The shopper has already acted. Review your text as a follow-up.';
    }
  }
  private async reauthenticate(command?:Command, grantId?:string, reviewPickupChanges=false):Promise<Session> {
    const fresh=await this.api.session();
    if(this.signOutPending)throw new ApiError('access_ended',403);
    if(!fresh)throw new ApiError('session_needed',401);
    const choicesChanged = this.pickupSelectionChanged(fresh);
    if (reviewPickupChanges && choicesChanged && !command) return fresh;
    if (reviewScope(fresh)!==this.reviewedScope && !(choicesChanged && command)) throw new ApiError('access_ended',403);
    if(grantId ? fresh.role!=='editor'||fresh.grantId!==grantId : !isContributorSession(fresh))throw new ApiError('access_ended',403);
    if(command&&(fresh.replayWindow.id!==command.replayWindow||Date.parse(fresh.replayWindow.expiresAt)<=Date.now()))throw new ApiError('stale_replay_window',409);
    // A retry owns its original destination. Let load reconcile any other draft
    // against the new selection after the server has checked that exact command.
    if (!choicesChanged) this.session=fresh;
    return fresh;
  }
  private hideWhileSigningOut():void {
    this.logoutPending=true;this.clearPrivate();
    this.notice='Sign-out could not be confirmed. Retry before sharing this browser.';
  }
  private async signOut(scope?:Session,identityCSRF?:string):Promise<void> {
    const window=this.root.ownerDocument.defaultView;
    setBrowserSignOutPending(window,true);this.hideWhileSigningOut();this.render();
    let cleared=true;try{await this.outbox.clear();}catch{cleared=false;}
    try {
      const revoked=scope?(await this.api.logout(scope))?.providerRevoked:identityCSRF?
        (await this.api.logoutIdentity(identityCSRF)).providerRevoked:await resumeBrowserSignOut(()=>this.api.session(),this.api);
      setBrowserSignOutPending(window,false);this.logoutPending=false;
      this.notice=revoked===false?'Signed out of this browser. Provider sign-out could not be confirmed.':cleared?'You are signed out.':
        'You are signed out, but browser storage could not be cleared. Clear site data before sharing this browser.';
      if(identityCSRF)this.browserAuth=await this.api.authState().catch(()=>null);
    } catch { /* Keep the private view closed until a confirmed retry. */ }
  }
  private async recoverBrowserIdentity(historyGeneration:number):Promise<void> {
    this.adoptBrowserAuth(await this.api.authState().catch(()=>null));
    if(!this.historyAway&&historyGeneration===this.historyGeneration)this.historySuspended=false;
  }
  private async fail(error:unknown,purpose:'load'|'mutation'='mutation',rejectedPending?:Pending):Promise<void> {
    const historyGeneration=this.historyGeneration;
    this.failurePurpose=purpose;
    let e=error instanceof ApiError ? error:new ApiError('unavailable',500);
    if (e.code==='queue_permission_ended' && this.session) {
      const prior=this.session;
      this.clearPrivate();
      this.render();
      try {
        await this.outbox.clearScope(scopeFor(prior));
      } catch {
        this.notice='Pending requests could not be cleared. Clear site data before sharing this browser.';
        return;
      }
      try {
        const fresh=await this.api.session();
        if (!fresh) throw new ApiError('session_needed',401);
        if (this.signOutPending || reviewScope(fresh)!==reviewScope(prior) || !fresh.enrolled || !isContributorSession(fresh)) {
          throw new ApiError('access_ended',403);
        }
        await this.load(fresh);
        this.notice='Offline permission changed. Check Your requests before sending again.';
        return;
      } catch (failure) {
        this.clearPrivate();
        e=failure instanceof ApiError ? failure:new ApiError('unavailable',500);
        if (e.status!==401 && e.status!==403) {
          this.historySuspended=true;
          this.failurePurpose='load';
          this.notice='Could not verify household access. Reconnect and refresh.';
          return;
        }
      }
    }
    if((e.status===403&&!isPostingSuspended(e))||e.code==='access_ended'||(e.status===404&&(this.proposalIntent!==null||['editor','helper'].includes(this.session?.role??'')))) {
      const ended=this.session;
      this.clearPrivate();
      this.render();
      try {
        if(ended)await this.outbox.clearScope(scopeFor(ended));
        this.notice='Access has ended. Ask your household for a new invitation.';
      } catch {
        this.notice='Access has ended. Clear site data before sharing this browser.';
      }
      await this.recoverBrowserIdentity(historyGeneration);
      return;
    }
    if(e.status===401) {
      if(this.session){this.clearInvitationDraft();this.browserAuth=null;}
      this.safety=null;this.session=null;this.requests=[];this.firstRequestPageAsOf=undefined;this.view=null;this.pending=[];
      this.receivedSuggestions=[];this.suggestionsState='unchecked';
      this.notice=this.draft.item || this.draft.amount || this.correction
        ? 'Sign in again to continue. Your text stays on this page.'
        : 'Sign in again to continue.';
      this.codeRequested=false;this.loginCode='';
      this.render();
      await this.recoverBrowserIdentity(historyGeneration);
    }
    else if(e.code==='pickup_closed'){
      this.retryCommand=null;this.uncertainSend=false;this.review=false;this.chosenPickupId=null;
      this.notice='Choose an open pickup to continue.';
      if(rejectedPending)await this.outbox.remove(rejectedPending.id,rejectedPending.scope).catch(()=>{});
      try {await this.load();} catch(failure) {await this.fail(failure,'load');}
      return;
    }
    else if(e.code==='login_unavailable')this.notice='Email sign-in is not available yet. Your invitation stays on this page.';
    else if(e.code==='code_not_accepted')this.notice='That code was not accepted. Check the latest code or request another one.';
    else if(e.code==='login_rate_limited')this.notice='Wait before requesting or checking another code.';
    else if(e.code==='consent_unavailable')this.notice='Child enrollment is not available here yet. Ask a guardian to use the verified setup.';
    else if(e.status===409) this.notice='This information changed. Refresh, review, and try again.';
    else if(isPostingSuspended(e))this.notice='Shared posting is unavailable for this account. You can still view your household information.';
    else if(e.code==='content_review_required'){
      this.notice='Edit the wording before sharing it with the household.';
    }
    else if(e.status===422) this.notice='Check your entry and try again.';
    else if(this.suggestionsState==='unavailable')this.notice='Received suggestions could not be checked. Retry recovery before sending another suggestion.';
    else if(purpose==='load')this.notice='Could not load your account. Refresh to try again.';
    else if(this.proposalReceipt)this.notice='Suggestion status could not be checked. Its earlier receipt is still confirmed. Try again.';
    else if(this.proposalIntent)this.notice='Suggestion receipt is unconfirmed. Retry the original suggestion. It is only kept on this page; closing or reloading loses this local copy.';
    else this.notice=this.uncertainSend?'Not saved in this browser. Receipt is unconfirmed. Your text is still here. Retry to check.':'Not saved. Your text is still here. Reconnect and try again.';
    // The server's decision remains authoritative if deleting a rejected copy fails.
    if(rejectedPending)await this.outbox.remove(rejectedPending.id,rejectedPending.scope).catch(()=>{});
  }
  private date(value:string, timeStyle: Intl.DateTimeFormatOptions['timeStyle'] = 'short'):string {
    const d=new Date(value);return Number.isFinite(d.getTime())?new Intl.DateTimeFormat(this.language==='es'?'es-US':'en-US',{dateStyle:'full',timeStyle}).format(d):value;
  }
  render():void {
    this.root.replaceChildren();this.root.ownerDocument.documentElement.lang=this.language;
    const header=this.el('header');header.append(brandName(this.root.ownerDocument));
    const lang=this.el('select');lang.id='language';lang.setAttribute('aria-label',this.t('Language'));
    for(const [v,k] of [['en','English'],['es','Spanish']]) {const o=this.el('option',this.t(k!));o.value=v!;o.selected=v===this.language;lang.append(o);}
    lang.addEventListener('change', () => {
      this.language = lang.value === 'es' ? 'es' : 'en';
      const browser = this.root.ownerDocument.defaultView;
      if (browser) {
        const url = new URL(browser.location.href);
        url.searchParams.set('lang', this.language);
        browser.history.replaceState(null, '', url.pathname + url.search + url.hash);
      }
      this.render();
      this.root.querySelector<HTMLSelectElement>('#language')?.focus();
    });
    header.append(lang);this.root.append(header);
    const main=this.el('main');main.className='household-companion';main.setAttribute('aria-busy',String(this.busy));this.root.append(main);
    // A mobile browser can retain this hidden page as its cold-start preview.
    if(this.historyAway)return;
    const status=this.el('p',this.busy?this.t('Loading…'):this.t(this.notice));status.className='notice';status.setAttribute('role','status');status.setAttribute('tabindex','-1');main.append(status);
    if(!this.supportedRoute()){main.append(this.el('h1',this.t('This page is not available.')));const link=this.el('a',this.t('Open your requests'));link.href='/requests';main.append(link);return;}
    if(this.signOutPending){main.append(this.el('h1',this.t('Finish signing out')),this.button('Retry sign-out',()=>void this.run(()=>this.signOut(),'mutation',true),true));return;}
    if(this.historySuspended){main.append(this.button('Refresh',()=>void this.start()));return;}
    if(this.invitation!==null || !this.session) {this.renderInvite(main,status);return;}
    const context=this.el('section');
    const session=this.session;
    if (this.joinedSession===session && session.enrolled && !this.busy && !this.notice) {
      const joined=this.t('You joined {household}.').replace('{household}',()=>session.household.label);
      const access=isContributorSession(session) ? this.t('You can track your own grocery requests here.')
        : this.view?.canPropose ? this.t('You can read the instructions shared with you for this pickup and suggest changes for the shopper to review.')
        : this.t('You can read the instructions shared with you for this pickup.');
      status.textContent=joined+' '+access;
    } else {
      context.append(this.el('p',session.household.label));
    }
    const actions=this.el('div');actions.className='actions';actions.append(this.button('Refresh',()=>void this.run(()=>this.load(),'load')),this.button('Sign out',()=>void this.run(()=>this.signOut(this.session??undefined))));context.append(actions);main.append(context);
    if(this.safety&&this.session.canModerate&&this.session.enrolled){this.renderSafety(main,this.safety);return;}
    if(this.session.role==='helper'||this.session.role==='editor'){
      if(this.view)this.renderCook(main);else main.append(this.el('p',this.t('No instructions are available.')));
    } else {
      if(!this.busy&&this.queueState==='unavailable')status.append(' ',this.t('Stored pending requests could not be opened.'));
      if(!this.busy&&this.queueState==='missing')status.append(' ',this.t('A pending request is no longer stored on this browser. Check Your requests for its status.'));
      this.renderContributor(main);
    }
  }
  private publicLink(page: 'help' | 'support', label: string): HTMLAnchorElement {
    const link = this.el('a', this.t(label));
    link.href = '/' + page + '?lang=' + this.language;
    link.referrerPolicy = 'no-referrer';
    link.rel = 'noreferrer';
    return link;
  }
  private renderLogin(main:HTMLElement):void{
    main.append(this.el('h1',this.t('Sign in to continue')));
    if (!this.browserAuth?.available) {
      const reason = !this.browserAuth ? 'Connect to load sign-in options.'
        : this.invitation ? 'Email sign-in is not available yet. Your invitation stays on this page.'
        : 'Email sign-in is not available yet.';
      main.append(this.el('p', this.t(reason)), this.button('Refresh', () => void this.run(() => this.load(), 'load')));
      const links = this.el('div');
      links.className = 'actions';
      links.append(this.publicLink('help', 'Public help'), this.publicLink('support', 'Support options'));
      main.append(links);
      return;
    }
    main.append(this.el('p',this.t('Use your email code. Signing in does not join a household.')));
    if(this.invitation)main.append(this.el('p',this.t('Your invitation stays on this page while you sign in.')));
    const form=this.el('form');
    if(!this.codeRequested){
      const label=this.el('label',this.t('Email address'));label.htmlFor='login-email';const email=this.el('input');email.id='login-email';email.type='email';email.autocomplete='email';email.required=true;email.maxLength=254;email.value=this.loginEmail;email.addEventListener('input',()=>{this.loginEmail=email.value;});form.append(label,email);
      const submit=this.button('Send sign-in code',()=>{},true);submit.type='submit';form.append(submit);
      form.addEventListener('submit',event=>{event.preventDefault();void this.run(async()=>{await this.api.sendEmailCode(this.loginEmail,this.browserAuth!.csrf!);this.codeRequested=true;this.loginCode='';this.notice='Check your email for a six-digit code.';});});
    }else{
      const label=this.el('label',this.t('Six-digit code'));label.htmlFor='login-code';const code=this.el('input');code.id='login-code';code.type='text';code.inputMode='numeric';code.autocomplete='one-time-code';code.pattern='[0-9]{6}';code.maxLength=6;code.required=true;code.value=this.loginCode;code.addEventListener('input',()=>{this.loginCode=code.value;});form.append(label,code);
      const submit=this.button('Verify code',()=>{},true);submit.type='submit';form.append(submit,this.button('Use a different email',()=>{this.codeRequested=false;this.loginCode='';this.render();}));
      form.addEventListener('submit',event=>{event.preventDefault();void this.run(async()=>{this.browserAuth=await this.api.verifyEmailCode(this.loginCode,this.browserAuth!.csrf!);this.loginCode='';this.loginEmail='';this.codeRequested=false;this.notice='Signed in. Review your invitation before joining.';await this.load();});});
    }
    main.append(form);
  }
  private renderInvite(main:HTMLElement,status:HTMLElement):void {
    if(!this.session&&!this.browserAuth?.authenticated){this.renderLogin(main);return;}

    const hasCode = Boolean(this.invitation?.trim());
    main.append(this.el('h1', this.t(hasCode ? 'Continue with your invitation' : 'Enter an invitation code')));
    if (!this.redemption) {
      main.append(this.el('p', this.t(hasCode
        ? 'Confirm the household and your role with the person who invited you. An invitation can let you send your own requests or view selected shopping instructions.'
        : 'Open the link from your household, or enter its invitation code below.')));
    }
    const form=this.el('form');
    if(hasCode){
      form.append(this.el('p',this.t('Invitation code received.')));
      if(!this.redemption)form.append(this.button('Enter a different invitation code',()=>{
        this.invitation='';
        this.adultAttestation=false;
        this.render();
        this.root.querySelector<HTMLInputElement>('#invitation')?.focus();
      }));
    }else{
      const label=this.el('label',this.t('Invitation code'));
      label.htmlFor='invitation';
      const input=this.el('input');
      input.id='invitation';
      input.type='password';
      input.autocomplete='off';
      input.required=true;
      input.maxLength=4096;
      input.addEventListener('input',()=>{
        const code=input.value.trim();
        if (this.notice===unavailableInvitationNotice && code && code!==this.invitation?.trim()) {
          this.notice='';
          status.textContent='';
        }
        this.invitation=input.value;
      });
      form.append(label,input);
    }
    this.field(form,'Your display name (optional)','invite-alias',this.inviteAlias,value=>{this.inviteAlias=value;});
    const alias=form.querySelector<HTMLInputElement>('#invite-alias');if(alias){alias.maxLength=80;alias.disabled=this.redemption!==null;}
    const aliasHint=this.el('p',this.t('Leave your display name blank to keep your existing name in this household. If you are joining for the first time, we request “Household member” as your name.'));aliasHint.id='invite-alias-hint';form.append(aliasHint);alias?.setAttribute('aria-describedby',aliasHint.id);
    const adultLabel=this.el('label');adultLabel.className='checkbox';const adult=this.el('input');adult.type='checkbox';adult.id='adult-attestation';adult.checked=this.adultAttestation;adult.required=true;adult.disabled=this.redemption!==null;
    adult.addEventListener('change',()=>{this.adultAttestation=adult.checked;});adultLabel.append(adult,this.el('span',this.t('I am 18 or older.')));form.append(adultLabel);
    form.append(this.el('p',this.t('An adult signs in before joining. Child access requires verified guardian setup.')));
    const submit=this.button('Join this household',()=>{},true);submit.type='submit';form.append(submit);
    form.addEventListener('submit',e=>{
      e.preventDefault();
      const manualCode=form.querySelector<HTMLInputElement>('#invitation');
      const token=(manualCode?.value??this.invitation)?.trim();
      if(!token||!this.adultAttestation)return;
      this.invitation=token;
      void this.run(async()=>{
        try {
          this.redemption??=await this.api.redeem(token,this.session?.csrf??this.browserAuth?.csrf??undefined,{adultAttestation:this.adultAttestation,alias:this.inviteAlias,defaultAliasLanguage:this.language});
        } catch (error) {
          if (!(error instanceof ApiError && error.status === 404 && error.code === 'unavailable')) throw error;
          this.clearInvitationDraft();
          this.invitation=''; // Keep manual entry open even when another household is active.
          this.notice=unavailableInvitationNotice;
          return;
        }
        await this.api.activateSession(this.redemption.householdId,this.session?.csrf??this.browserAuth?.csrf??undefined,this.redemption.grantId);
        const accepted = this.redemption;
        const opened = await this.api.session();
        if (!opened) throw new ApiError('session_needed', 401);
        this.notice = '';
        await this.load(opened);
        if (this.session?.household.id !== accepted.householdId || this.session.memberId !== accepted.memberId) {
          throw new ApiError('session_needed', 401);
        }
        if (this.session.role!==accepted.role || this.session.grantId!==accepted.grantId) {
          throw new ApiError('grant_context_changed',409);
        }
        this.joinedSession=this.session;
        this.invitation=null;this.redemption=null;this.adultAttestation=false;this.inviteAlias='';
      });
    });
    if (!this.redemption && !this.busy) {
      const leave = this.publicLink('help', 'Leave without joining');
      leave.addEventListener('click', () => this.clearInvitationDraft());
      form.append(leave);
    }
    main.append(form,this.el('p',this.t('An internet connection is needed to open an invitation.')),this.button('Refresh',()=>void this.run(()=>this.load(),'load')));
    if(!this.session&&this.browserAuth?.authenticated)main.append(this.button('Sign out',()=>void this.run(()=>this.signOut(undefined,this.browserAuth?.csrf??undefined))));
  }
  private field(form:HTMLElement,key:string,id:string,value:string,update:(value:string)=>void,multiline=false):void {
    const label=this.el('label',this.t(key));label.htmlFor=id;const input=multiline?this.el('textarea'):this.el('input');input.id=id;input.value=value;input.maxLength=id==='item'?240:id==='amount'?80:1000;
    if(id==='item')input.required=true;input.addEventListener('input',()=>{update(input.value);if(id==='item'||id==='amount')this.retryCommand=null;});form.append(label,input);
  }
  private requestTarget(session:Session):string|null {
    if(this.retryCommand)return this.retryCommand.shopId;
    if(this.draft.editing)return this.draft.editing.shopId;
    if(this.draft.followup)return this.requests.find(row=>row.requestId===this.draft.followup)?.shopId??null;
    return session.shopId??this.chosenPickupId;
  }
  private usesProtectedPickup(session:Session):boolean {
    if(this.draft.editing)return false;
    const target=this.requestTarget(session);
    return target===session.shopId ? session.nextShopOnly===true : this.pickups.find(p=>p.shopId===target)?.nextShopOnly===true;
  }
  private pickupLabel(pickup: RequestPickup, index: number): string {
    return this.t('Pickup') + ' ' + (index + 1) + ' · ' + this.t('Created') + ' ' + this.date(pickup.createdAt);
  }
  private renderContributor(main:HTMLElement):void {
    const protectedPickup=this.usesProtectedPickup(this.session!);
    const routeForReview=this.retryCommand?.kind==='request.send'?this.retryCommand.body.route:
      protectedPickup?'next':this.draft.route;
    main.append(this.el('h1',this.t('Ask the shopper')));
    const form=this.el('form');form.className='card';
    const session=this.session!;
    const target=this.requestTarget(session);
    if(session.selectionRequired && !this.draft.editing && !this.draft.followup && !this.review){
      const label=this.el('label',this.t('Pickup for this request'));label.htmlFor='request-pickup';
      const picker=this.el('select');picker.id='request-pickup';picker.disabled=this.busy||this.uncertainSend;
      const placeholder=this.el('option',this.t('Choose a pickup'));placeholder.value='';picker.append(placeholder);
      for (const [index, pickup] of this.pickups.entries()) {
        const option = this.el('option', this.pickupLabel(pickup, index));
        option.value = pickup.shopId;
        picker.append(option);
      }
      picker.value=this.chosenPickupId??'';
      picker.addEventListener('change',()=>{this.chosenPickupId=picker.value||null;this.draft.route='current';this.retryCommand=null;this.render();this.root.querySelector<HTMLElement>('#request-pickup')?.focus();});
      main.append(label,picker);
    }
    if(this.draft.followup)form.append(this.el('h2',this.t('Follow up')));
    if(this.review) {
      if (target) {
        const index = this.pickups.findIndex(pickup => pickup.shopId === target);
        const pickup = this.pickups[index];
        const destination = pickup ? this.pickupLabel(pickup, index)
          : this.draft.editing || this.draft.followup || this.retryCommand ? this.t('The pickup from the original request')
          : this.t('The pickup shared with you');
        form.append(this.el('p', this.t('Pickup for this request') + ' · ' + destination));
      }
      const heading = this.el('h2', this.t('Review before sending'));
      heading.id = 'request-review-heading';
      heading.tabIndex = -1;
      form.append(heading,this.el('p',this.draft.item),this.el('p',this.draft.amount||this.t('Unknown amount')),this.el('p',this.t(routeForReview==='next'?'Next shop':'This pickup')));
      const back = this.button('Back to edit', () => this.showRequestReview(false));
      back.disabled = this.busy || this.uncertainSend;
      form.append(back);
      const submit=this.button(this.draft.editing?'Save changes':this.draft.followup?'Send follow-up':'Send request',()=>{},true);submit.type='submit';form.append(submit);
      form.addEventListener('submit',e=>{e.preventDefault();void this.run(()=>this.send());});
    } else {
      this.field(form,'Item','item',this.draft.item,v=>{this.draft.item=v;},true);
      form.append(this.el('p',this.t('Keep the food name and any restrictions as written.')));
      this.field(form,'Amount or pack count (optional)','amount',this.draft.amount,v=>{this.draft.amount=v;});
      const label=this.el('label',this.t('Intended trip'));label.htmlFor='route';const route=this.el('select');route.id='route';route.disabled=this.draft.editing!==null||protectedPickup;
      for(const [v,k] of [['current','This pickup'],['next','Next shop']]){const option=this.el('option',this.t(k!));option.value=v!;option.selected=v===routeForReview;route.append(option);}
      route.addEventListener('change',()=>{this.draft.route=route.value as 'current'|'next';this.retryCommand=null;});form.append(label,route);
      const review=this.button('Review request',()=>{},true);review.type='submit';form.append(review);
      form.addEventListener('submit', event => {
        event.preventDefault();
        if (!this.draft.item.trim()) return;
        if (protectedPickup) this.draft.route = 'next';
        this.showRequestReview(true);
      });
    }
    if(this.session!.enrolled&&this.session!.canSetRequestQueue) {
      const enabled=this.session!.queueConsent;
      form.append(this.button(enabled?'Turn off and clear pending requests':'Allow pending requests on this browser for up to 24 hours',()=>void this.run(async()=>{
        const fresh=await this.reauthenticate();
        await this.api.setRequestQueue(fresh,!enabled);
        if(enabled){
          this.pending=[];this.confirmedOperations.clear();this.consent=false;
          const {requestQueueGrant,requestQueueUntil,...current}=fresh;
          this.session={...current,queueConsent:false};
          try { await this.outbox.clearScope(scopeFor(fresh)); }
          catch { this.notice='Access has ended. Clear site data before sharing this browser.'; }
        }
        await this.load();
      })),this.el('p',this.t('Only enable this on your own device. Check pending requests for a receipt.')));
    } else if(this.session!.enrolled&&this.session!.queueConsent) {
      const label=this.el('label');label.className='checkbox';const cb=this.el('input');cb.type='checkbox';cb.checked=this.consent;cb.addEventListener('change',()=>{this.consent=cb.checked;});label.append(cb,this.el('span',this.t('Save pending requests on this browser')));form.append(label,this.el('p',this.t('Only enable this on your own device. Check pending requests for a receipt.')));
    }
    if(this.draft.item) form.append(this.button('Copy your text',()=>void this.run(async()=>{await navigator.clipboard.writeText(`${this.draft.item}\n${this.draft.amount}`);this.notice='Copied';})));
    if(this.pending.some(p=>p.needsReview) && this.hasRequestDraft() && !this.uncertainSend) {
      form.append(this.button('Discard current draft',()=>{this.draft=blank();this.review=false;this.retryCommand=null;this.render();}));
    }
    if(target || this.retryCommand)main.append(form);
    else if(!session.selectionRequired)main.append(this.el('p',this.t('No pickup is accepting requests. Ask the shopper to start a pickup.')));
    if(this.pending.length) {
      const section=this.el('section');section.append(this.el('h2',this.t('Pending requests')));
      for(const p of this.pending) {
        const card=this.el('article');card.className='card';
        card.append(this.el('p',String(p.command.body.originalItem??'')),this.el('p',this.t('Saved on this browser')+' · '+this.date(p.createdAt)));
        if(p.needsReview) {
          if(p.command.body.ownQuantity)card.append(this.el('p',String(p.command.body.ownQuantity)));
          card.append(this.el('p',this.t(p.needsReview==='wording'?'Edit the wording before sharing it with the household.':'The original request changed. Review your correction before sending it again.')));
          const move=this.button(p.needsReview==='wording'?'Edit this request':'Move correction to draft',()=>void this.run(()=>this.reviewQueuedRequest(p)));
          card.append(move);
          if(this.hasRequestDraft())card.append(this.el('p',this.t('Finish or discard your current draft first.')));
        } else {
          card.append(this.el('p',this.t(this.confirmedOperations.has(p.id)?'Received; local cleanup pending':'Receipt unconfirmed')),
            this.button('Retry',()=>void this.run(()=>this.retry(p))));
        }
        card.append(this.button('Remove pending request',()=>void this.run(async()=>{
          await this.outbox.remove(p.id,p.scope);this.pending=this.pending.filter(x=>x.id!==p.id);
        })));section.append(card);
      }
      main.append(section);
    }
    const own=this.el('section');own.append(this.el('h2',this.t('Your requests')));
    if(!this.requests.length) {
      own.append(this.el('p',this.t('No requests yet.')));
      if(this.firstRequestPageAsOf)own.append(this.el('p',this.t('Checked on server')+' · '+this.date(this.firstRequestPageAsOf,'medium')));
    }
    const visibleRequestNames = new Map(this.requests.map(row => [row.requestId, row.originalItem]));
    for(const r of this.requests){const card=this.el('article');card.className='card';card.dataset.requestId=r.requestId;
      card.append(this.el('h3',r.originalItem));
      if (r.followupTo) {
        const parentName = visibleRequestNames.get(r.followupTo);
        const relationship = parentName ? this.t('Follow-up to') + ' · ' + parentName
          : this.t('Follow-up to an earlier request');
        card.append(this.el('p', relationship));
      }
      card.append(this.el('p',r.ownQuantity??this.t('Unknown amount')),this.el('p',this.t(r.carriedForward?'Moved to a later pickup for review':statuses[r.status]??'Status unavailable')),this.el('p',this.t(r.route==='next'?'Next shop':'This pickup')),this.el('p',this.date(r.receivedAt)));
      if(r.serverReadAt)card.append(this.el('p',this.t('Checked on server')+' · '+this.date(r.serverReadAt,'medium')));
      const localEdit=this.pending.find(p=>p.command.kind==='request.edit'&&p.command.shopId===r.shopId&&p.command.body.requestId===r.requestId);
      const correction=localEdit?.command ?? (this.uncertainSend && this.retryCommand?.kind==='request.edit' &&
        this.retryCommand.shopId===r.shopId && this.retryCommand.body.requestId===r.requestId ? this.retryCommand : null);
      if(correction) {
        const label=localEdit && this.confirmedOperations.has(localEdit.id) ? 'Received; local cleanup pending' :
          localEdit?.needsReview ? 'Correction needs review' : localEdit ? 'Saved correction on this browser' : 'Correction receipt unconfirmed';
        const wording=[correction.body.originalItem,correction.body.ownQuantity].filter(Boolean).join(' · ');
        card.append(this.el('p',this.t(label)+' · '+wording));
      }
      if(r.fromPreviousShop)card.append(this.el('p',this.t('From an earlier pickup')));
      if(r.status==='added'){
        const purchaseLabel=r.purchaseOutcome==='bought'?'Shopper confirmed purchase':
          r.purchaseOutcome==='notBought'?'Shopper confirmed the item was not bought':'Purchase not confirmed';
        card.append(this.el('p',this.t(purchaseLabel)));
      }
      if(r.clarification){
        card.append(this.el('p',r.clarification));
        if(r.canReportClarification)this.offerSafety(card,[{source:{kind:'clarification',id:r.requestId,revision:r.revision,field:'question'},
          text:r.clarification,label:'Shopper’s question'}]);
      }
      if(r.ownActionAllowed){
        card.append(this.button('Edit',()=>this.openRequestDraft(r)),this.button('Withdraw',()=>{this.withdrawn=r;this.withdrawalCommand=null;this.render();}));
      } else if(r.status!=='withdrawn'){
        card.append(this.button('Follow up',()=>this.openRequestDraft(r)));
      }
      if(this.withdrawn?.requestId===r.requestId){card.append(this.el('p',this.t('Withdraw this pending request?')),this.button('Confirm withdrawal',()=>void this.run(async()=>{
        const fresh=await this.reauthenticate(this.withdrawalCommand??undefined);
        this.withdrawalCommand??=this.makeCommand('request.withdraw',{requestId:r.requestId},r.revision,r.shopId);
        let received:OwnRequest;
        try {received=await this.api.command(fresh,this.withdrawalCommand);} catch(error) {
          if(!isRequestRevisionConflict(error))throw error;
          this.withdrawn=null;this.withdrawalCommand=null;
          await this.reloadChangedRequest();return;
        }
        this.withdrawn=null;this.withdrawalCommand=null;this.notice='Withdrawn';
        await this.refreshAfterReceipt(received);
      })),this.button('Cancel',()=>{this.withdrawn=null;this.render();}));}own.append(card);
    }main.append(own);
  }
  private showRequestReview(review: boolean): void {
    this.review = review;
    this.render();
    this.root.querySelector<HTMLElement>(review ? '#request-review-heading' : '#item')?.focus();
  }
  private openRequestDraft(row:OwnRequest):void {
    if(this.uncertainSend)return;
    if(this.hasRequestDraft() && !this.root.ownerDocument.defaultView?.confirm(this.t('Replace your current draft with this request?')))return;
    this.draft={
      item:row.originalItem,amount:row.ownQuantity??'',route:row.route,
      editing:row.ownActionAllowed?row:null,followup:row.ownActionAllowed?null:row.requestId,
    };
    this.review=false;
    this.retryCommand=null;
    this.render();
    this.root.querySelector<HTMLElement>('#item')?.focus();
  }
  private makeCommand(kind:string,body:Record<string,unknown>,requestRevision?:number,shopId=this.session!.shopId??''):Command {
    return {v:1,replayWindow:this.session!.replayWindow.id,clientKey:crypto.randomUUID(),shopId,kind,
      base:{shopRevision:0,authorityEpoch:0,...(requestRevision!==undefined?{requestRevision}:{})},body};
  }
  private async send():Promise<void> {
    let s:Session;
    let offlineError:ApiError|null=null;
    try {
      s=await this.reauthenticate(this.retryCommand??undefined,undefined,true);
    } catch(error) {
      const cached=this.session;
      if(!(error instanceof ApiError)||error.status!==0||!cached||!isContributorSession(cached)||
         reviewScope(cached)!==this.reviewedScope||!cached.enrolled||!cached.queueConsent||(cached.requestQueueUntil && Date.parse(cached.requestQueueUntil)<=Date.now())||!(cached.canSetRequestQueue||this.consent))throw error;
      if(Date.parse(cached.replayWindow.expiresAt)<=Date.now()||
         (this.retryCommand&&this.retryCommand.replayWindow!==cached.replayWindow.id))throw new ApiError('stale_replay_window',409);
      // The last checked session can scope a local draft. Only a fresh session can send it.
      s=cached;
      offlineError=error;
    }
    if(!offlineError && !this.retryCommand && this.pickupSelectionChanged(s)){
      await this.load(s);
      return;
    }
    if(!offlineError && !this.retryCommand && !this.draft.editing && !this.draft.followup && s.selectionRequired){
      this.pickups=await this.api.requestPickups(s);
      if(!this.pickups.some(p=>p.shopId===this.chosenPickupId)){
        this.chosenPickupId=null;this.review=false;
        this.notice='Choose an open pickup to continue.';return;
      }
    }
    if(!this.retryCommand && this.draft.route==='current' && this.usesProtectedPickup(s)){
      this.draft.route='next';
      this.notice='This pickup closed to new requests. Review the next-shop destination before sending.';
      return;
    }
    if(!this.retryCommand)this.retryCommand=this.draft.editing?
      this.makeCommand('request.edit',{requestId:this.draft.editing.requestId,originalItem:this.draft.item,ownQuantity:this.draft.amount||null},this.draft.editing.revision,this.draft.editing.shopId):
      this.makeCommand('request.send',{clientRequestId:crypto.randomUUID(),originalItem:this.draft.item,ownQuantity:this.draft.amount||null,authoredAt:new Date().toISOString(),route:this.draft.route,...(this.draft.followup?{followupTo:this.draft.followup}:{})},undefined,this.requestTarget(s)??'');
    const command=this.retryCommand;
    const p:Pending={id:command.clientKey,scope:scopeFor(s),command,createdAt:new Date().toISOString()};
    let persisted=false;
    if((s.canSetRequestQueue||this.consent)&&s.queueConsent&&s.enrolled){try{await this.outbox.put(p,s,true);persisted=true;}catch{this.notice='Browser storage is unavailable. Requests will remain editable but will not be saved offline.';}}
    if(this.signOutPending)throw new ApiError('access_ended',403);
    if(offlineError){
      if(!persisted)throw offlineError;
      this.showQueued(p);
      return;
    }
    let received:OwnRequest;
    try{received=await this.api.command(s,command,persisted?s.requestQueueGrant:undefined);}catch(error){
      this.uncertainSend=error instanceof ApiError && (error.status===0||error.status>=500);

      if(isPostingSuspended(error)||(error instanceof ApiError&&error.code==='content_review_required')){
        this.review=false;this.retryCommand=null;
        await this.fail(error,'mutation',persisted?p:undefined);return;
      }
      if(command.kind==='request.edit' && isRequestRevisionConflict(error)) {
        if(persisted)await this.outbox.remove(p.id,p.scope);
        this.retryCommand=null;this.review=false;
        await this.reloadChangedRequest();return;
      }
      if(persisted && error instanceof ApiError && (error.status===0||error.status>=500||error.status===429)) {
        this.showQueued(p);return;
      }
      if(persisted) {
        await this.fail(error,'mutation',p);
        return;
      }
      throw error;
    }
    this.draft=blank();this.retryCommand=null;this.uncertainSend=false;this.review=false;
    await this.finishReceived(p,persisted,received);
  }
  private async finishReceived(p:Pending,persisted:boolean,received?:OwnRequest):Promise<void> {
    this.notice=p.command.kind==='request.send' && received?.route==='next'?'Received for the next shop.':'Received by the shopper.';
    if(persisted) {
      try {
        await this.outbox.remove(p.id,p.scope);
        this.pending=this.pending.filter(row=>row.id!==p.id);
        this.confirmedOperations.delete(p.id);
      } catch {
        this.confirmedOperations.add(p.id);
        this.notice='Received by the shopper. Retry to clear the copy on this browser.';
      }
    }
    await this.refreshAfterReceipt(received);
  }
  private async refreshAfterReceipt(received?:OwnRequest):Promise<void> {
    if(received) {
      const previous=this.requests.find(row=>row.requestId===received.requestId);
      if(!previous)this.requests.unshift(received);
      else if(previous.revision<=received.revision)this.requests=this.requests.map(row=>row===previous?received:row);
      this.reconcileRequestActions();
    }
    // A transient failure on the following read cannot undo the command receipt.
    try { await this.load(); }
    catch(error) {
      if(error instanceof ApiError && (error.status===0 || error.status===429 || error.status>=500))return;
      throw error;
    }
  }
  private showQueued(pending:Pending):void {
    this.pending=[...this.pending.filter(item=>item.id!==pending.id),pending];
    this.notice='Saved on this browser. Receipt unconfirmed.';
    this.draft=blank();this.retryCommand=null;this.uncertainSend=false;this.review=false;
  }
  private hasRequestDraft():boolean {
    return Boolean(this.draft.item || this.draft.amount || this.draft.route==='next' || this.draft.editing || this.draft.followup || this.retryCommand || this.review);
  }
  private async reviewQueuedRequest(p:Pending):Promise<void> {
    if(this.hasRequestDraft()) {
      this.notice='Finish or discard your current draft first.';return;
    }
    await this.load();
    const s=this.session;
    if(!s || !isContributorSession(s) || !s.enrolled || !s.queueConsent || scopeFor(s)!==p.scope)return;
    if(p.command.kind==='request.send'){
      const followup=p.command.body.followupTo;
      const canReturn=followup
        ? this.requests.some(r=>r.requestId===followup&&r.shopId===p.command.shopId)
        : s.shopId===p.command.shopId||this.pickups.some(r=>r.shopId===p.command.shopId);
      if(!canReturn){this.notice='Choose an open pickup to continue.';return;}
      const row=await this.outbox.reviewPending(p.id,p.scope,'take');
      this.pending=this.pending.filter(entry=>entry.id!==p.id);
      if(!row||this.signOutPending||!this.session?.queueConsent||scopeFor(this.session)!==p.scope)return;
      if(s.selectionRequired)this.chosenPickupId=p.command.shopId;
      this.draft={item:String(row.command.body.originalItem),amount:String(row.command.body.ownQuantity??''),
        route:row.command.body.route==='next'?'next':'current',editing:null,followup:typeof followup==='string'?followup:null};
      this.review=false;this.notice='Edit the wording before sharing it with the household.';return;
    }
    const current=this.requests.find(row=>row.requestId===p.command.body.requestId && row.shopId===p.command.shopId);
    if(!current || current.status==='withdrawn') {
      this.notice='This request is no longer available for correction.';return;
    }
    const row=await this.outbox.reviewPending(p.id,p.scope,'take');
    this.pending=this.pending.filter(entry=>entry.id!==p.id);
    if(!row || this.signOutPending || !this.session?.queueConsent || scopeFor(this.session)!==p.scope)return;
    this.draft={item:String(row.command.body.originalItem),amount:String(row.command.body.ownQuantity??''),route:current.route,
      editing:current.ownActionAllowed?current:null,followup:current.ownActionAllowed?null:current.requestId};
    this.review=false;
    this.notice=current.ownActionAllowed?'This request changed. Compare your draft with the current request before saving.':
      'The shopper has already acted. Review your text as a follow-up.';
  }
  private async retry(p:Pending):Promise<void>{
    const fresh=await this.api.session();
    if(this.signOutPending||!fresh||!isContributorSession(fresh)||!fresh.enrolled)throw new ApiError('access_ended',403);
    const choicesChanged = this.pickupSelectionChanged(fresh);
    if(reviewScope(fresh)!==this.reviewedScope && !choicesChanged)throw new ApiError('access_ended',403);
    if(scopeFor(fresh)!==p.scope||!fresh.queueConsent)throw new ApiError('queue_permission_ended',409);
    let received:OwnRequest|undefined;
    if(!this.confirmedOperations.has(p.id)) {
      if(fresh.replayWindow.id!==p.command.replayWindow||Date.parse(fresh.replayWindow.expiresAt)<=Date.now()) {this.notice='This queued request needs a new review. It was not resent.';return;}
      try {received=await this.api.command(fresh,p.command,fresh.requestQueueGrant);} catch(error) {
        if(error instanceof ApiError&&error.code==='content_review_required'){
          const marked=await this.outbox.reviewPending(p.id,p.scope,'wording');
          if(marked)this.pending=this.pending.map(entry=>entry.id===p.id?marked:entry);
          this.notice='Edit the wording before sharing it with the household.';return;
        }
        if(p.command.kind!=='request.edit' || !isRequestRevisionConflict(error))throw error;
        await this.outbox.reviewPending(p.id,p.scope,'mark');
        await this.reloadChangedRequest();return;
      }
    }
    if(!choicesChanged)this.session=fresh;
    await this.finishReceived(p,true,received);
  }
  private resetProposal():void {
    this.proposalGeneration++;this.proposalIntent=null;this.proposalReceipt=null;this.proposalStatus=null;this.proposalConflict=false;
  }
  private async sendProposal(view:CookView, wording=this.correction):Promise<void> {
    const generation=this.proposalGeneration;
    const fresh=await this.reauthenticate(undefined,this.proposalIntent?.grantId??view.grantId);
    if(generation!==this.proposalGeneration)return;
    this.proposalIntent??=prepareProposal(fresh,view,wording,crypto.randomUUID());
    const intent=this.proposalIntent;
    try {
      const receipt=await this.api.sendProposal(fresh,intent);
      if(generation!==this.proposalGeneration||this.proposalIntent!==intent)return;
      this.proposalReceipt=receipt;this.proposalStatus=this.receivedSuggestions.find(p=>p.proposalId===receipt.proposalId)??null;this.proposalConflict=false;
      this.notice=proposalNotices[this.proposalStatus?.status??receipt.status];
    }catch(error){
      if(generation!==this.proposalGeneration||this.proposalIntent!==intent)return;
      if(isPostingSuspended(error)||(error instanceof ApiError&&error.code==='content_review_required')){
        this.resetProposal();
        if(this.cookingReport)this.cookingReport.review=null;else this.correction=wording;
      }
      this.proposalConflict=error instanceof ApiError&&error.status===409&&error.code==='stale_base';
      throw error;
    }
  }
  private async checkProposal():Promise<void> {
    const intent=this.proposalIntent,receipt=this.proposalReceipt,generation=this.proposalGeneration;
    if(!intent||!receipt)return;
    const fresh=await this.reauthenticate(undefined,intent.grantId);
    if(generation!==this.proposalGeneration)return;
    const status=await this.api.ownProposal(fresh,intent,receipt);
    if(generation!==this.proposalGeneration||this.proposalIntent!==intent)return;
    this.proposalStatus=status;this.receivedSuggestions=this.receivedSuggestions.map(p=>p.proposalId===status.proposalId?status:p);this.notice=proposalNotices[status.status];
  }
  private async readReceivedSuggestions(fresh:Session,cursor:string|null):Promise<OwnProposal|undefined> {
    const view=this.view,generation=this.proposalGeneration;
    if(!view)return;
    try {
      const page=await this.api.receivedProposals(fresh,view,cursor);
      if(generation!==this.proposalGeneration)return;
      const current=await this.api.session();
      if(generation!==this.proposalGeneration)return;
      if(!current||reviewScope(current)!==reviewScope(fresh)||Date.parse(view.expiresAt)<=Date.now())throw new ApiError('access_ended',403);
      if(cursor&&page.proposals.some(p=>this.receivedSuggestions.some(old=>old.proposalId===p.proposalId)))throw new ApiError('invalid_response',502);
      this.receivedSuggestions=cursor?[...this.receivedSuggestions,...page.proposals]:page.proposals;
      this.suggestionsCursor=page.nextCursor;this.suggestionsState='ready';
      const proposal=page.proposals.find(p=>p.proposalId===this.proposalReceipt?.proposalId);
      if(proposal)this.proposalStatus=proposal;
      return proposal;
    }catch(error){if(generation!==this.proposalGeneration)return;this.suggestionsState='unavailable';throw error;}
  }
  private async recoverSuggestions(more=false):Promise<void> {
    const generation=this.proposalGeneration,fresh=await this.api.session();
    if(generation!==this.proposalGeneration)return;
    if(!fresh||!this.reviewedScope||reviewScope(fresh)!==this.reviewedScope||!['helper','editor'].includes(fresh.role))throw new ApiError('access_ended',403);
    const proposal=await this.readReceivedSuggestions(fresh,more?this.suggestionsCursor:null);
    if(generation===this.proposalGeneration&&this.suggestionsState==='ready')this.notice=proposal?proposalNotices[proposal.status]:'Received suggestions checked.';
  }
  private renderReceivedSuggestions(main:HTMLElement):void {
    const section=this.el('section');section.append(this.el('h2',this.t('Suggestions received by the service')),
      this.el('p',this.t('These suggestions are recovered from your current account and invitation. They do not need to be sent again.')));
    for(const proposal of this.receivedSuggestions){
      if(proposal.proposalId===this.proposalReceipt?.proposalId)continue;
      const card=this.el('article');card.className='card';card.dataset.proposalId=proposal.proposalId;
      card.append(this.el('p',proposal.correction),this.el('p',`${this.t('Reviewed revision')}: ${proposal.baseRevision}`),
        this.el('p',`${this.t('Received')}: ${this.date(proposal.createdAt)}`),
        this.el('p',this.t(proposal.status==='reviewed'?'Suggestion reviewed':proposal.status==='dismissed'?'Suggestion dismissed':'Suggestion received for shopper review')));
      if(proposal.resolution)card.append(this.el('p',this.date(proposal.resolution.resolvedAt)));
      section.append(card);
    }
    if(this.suggestionsState!=='ready')section.append(this.el('p',this.t('Received suggestions could not be checked. Retry recovery before sending another suggestion.')));
    else if(this.receivedSuggestions.length===0)section.append(this.el('p',this.t('No received suggestions for this invitation. An unsent draft cannot be recovered after reloading.')));
    section.append(this.button('Check received suggestions',()=>void this.run(()=>this.recoverSuggestions())));
    if(this.suggestionsCursor&&this.suggestionsState==='ready')section.append(this.button('Show older suggestions',()=>void this.run(()=>this.recoverSuggestions(true))));
    main.append(section);
  }
  private offerSafety(parent:HTMLElement,fields:SafetyField[]):void {
    if(!this.session?.canModerate||!this.session.enrolled)return;
    parent.append(this.button('Report or block',()=>{
      if(!this.session)return;
      this.safety={scope:reviewScope(this.session),fields,selected:0,reason:'',includeText:false,action:'report'};
      this.notice='';this.render();this.root.querySelector<HTMLElement>('#safety-title')?.focus();
    }));
  }
  private renderSafety(main:HTMLElement,review:SafetyReview):void {
    const heading=this.el('h1',this.t('Report or block'));heading.id='safety-title';heading.tabIndex=-1;main.append(heading);
    const field=review.fields[review.selected]!;
    const current=field.source.kind==='clarification'
      ? this.requests.some(r=>r.requestId===field.source.id&&r.revision===field.source.revision&&r.clarification===field.text&&r.canReportClarification)
      : this.view?.canReportContent&&this.view.grantId===field.source.id&&this.view.revision===field.source.revision&&Date.parse(this.view.expiresAt)>Date.now();
    if(!current&&!review.intent){
      main.append(this.el('p',this.t('This message changed. Open the current message to review it.')),
        this.button('Back',()=>{this.safety=null;this.render();}));return;
    }
    if(review.intent){
      main.append(this.el('p',this.t('Confirmation is pending. Retry the same action to check it.')),
        this.button('Retry same action',()=>void this.run(()=>this.submitSafety(review)),true));
    }else{
      const select=(title:string,choices:readonly (readonly [string,string])[],value:string,change:(value:string)=>void)=>{
        const label=this.el('label',this.t(title)),menu=this.el('select');
        for(const [key,name] of choices){const option=this.el('option',this.t(name));option.value=key;menu.append(option);}
        menu.value=value;menu.addEventListener('change',()=>change(menu.value));label.append(menu);main.append(label);
      };
      if(review.fields.length>1)select('Choose a message field',review.fields.map((f,i)=>[String(i),f.label]),String(review.selected),
        index=>{review.selected=Number(index);review.includeText=false;this.render();});
      const quote=this.el('blockquote',field.text);quote.style.whiteSpace='pre-wrap';main.append(quote);
      if(review.action==='report'){
        select('Why are you reporting this?',[['','Choose a reason'],['unsafe','Unsafe content'],['harassment','Harassment'],['other','Other concern']],
          review.reason,reason=>{review.reason=reason as ReportReason|'';submit.disabled=!review.reason||this.busy;});
        const submit=this.button('Send private report',()=>void this.run(()=>this.submitSafety(review)),true);
        submit.disabled=!review.reason||this.busy;
        const label=this.el('label');label.className='checkbox';
        const check=this.el('input');check.type='checkbox';check.checked=review.includeText;
        check.addEventListener('change',()=>{review.includeText=check.checked;this.render();});
        label.append(check,this.el('span',this.t('Include the selected wording in my report')));main.append(label);
        main.append(this.el('p',this.t(review.includeText?'The review team will receive your reason, the message reference, and the wording shown above.':
          'The review team will receive your reason and the message reference. The wording stays out of the report.')),
          submit,
          this.button('Review blocking this sender',()=>{review.action='block';review.includeText=false;this.render();}));
      }else{
        main.append(this.el('p',this.t('Block messages from this sender in this household? The block uses the message reference only.')),
          this.button('Confirm block',()=>void this.run(()=>this.submitSafety(review)),true),
          this.button('Review a report instead',()=>{review.action='report';this.render();}));
      }
    }
    main.append(this.button('Back',()=>{this.safety=null;this.render();}));
  }
  private async submitSafety(review:SafetyReview):Promise<void>{
    const history=this.historyGeneration;
    const fresh=await this.api.session();
    if(history!==this.historyGeneration||this.safety!==review||this.signOutPending)return;
    if(!fresh?.enrolled||!fresh.canModerate||reviewScope(fresh)!==review.scope)throw new ApiError('access_ended',403);
    const field=review.fields[review.selected]!;
    if(field.source.kind==='instruction'&&this.view&&Date.parse(this.view.expiresAt)<=Date.now())throw new ApiError('access_ended',403);
    if(!review.intent){
      if(review.action==='report'&&!review.reason)return;
      const base={clientKey:crypto.randomUUID(),source:field.source};
      review.intent=review.action==='block'?{...base,action:'block'}:
        {...base,action:'report',reason:review.reason as ReportReason,...(review.includeText?{text:field.text}:{})};
    }
    try{await this.api.moderate(fresh,review.intent);}
    catch(error){
      if(review!==this.safety)return;
      if(!(error instanceof ApiError)||error.status===0||error.status>=500&&error.code!=='moderation_unavailable'){
        this.notice='Confirmation is pending. Retry the same action to check it.';return;
      }
      if(error.status===401||error.status===403)throw error;
      this.safety=null;
      if(error.code==='sender_unavailable'){this.notice='The sender could not be verified for a block. You can still report the message.';return;}
      if(error.code==='moderation_unavailable'){this.notice='Reporting and blocking are unavailable right now.';return;}
      this.notice='This message changed. Open the current message to review it.';return;
    }
    if(this.safety!==review)return;
    this.safety=null;
    if(review.action==='report'){this.notice='Private report received.';return;}
    // Discard previously readable content before fetching the post-block projection.
    this.view=null;this.requests=[];this.receivedSuggestions=[];this.resetProposal();this.correction='';this.cookingReport=null;
    this.withdrawn=null;this.withdrawalCommand=null;
    try{await this.load();}
    catch(error){if(error instanceof ApiError&&(error.status===401||error.status===403))throw error;}
    this.notice='Sender blocked.';
  }
  private renderCook(main:HTMLElement):void {
    const view=this.view!;
    if(Date.parse(view.expiresAt)<=Date.now()){main.append(this.el('p',this.t('Access has ended. Ask your household for a new invitation.')));this.clearPrivate();void this.outbox.clear().catch(()=>{});return;}
    main.append(this.el('h1',this.t('Current instructions')),this.el('h2',view.shopLabel));
    main.append(this.el('p',`${this.t('As of')}: ${this.date(view.asOf)}`),this.el('p',`${this.t('Revision')}: ${view.revision}`),this.el('p',`${this.t('Expires')}: ${this.date(view.expiresAt)}`));
    const base={kind:'instruction' as const,id:view.grantId,revision:view.revision};
    if(view.canReportContent)this.offerSafety(main,[{source:{...base,field:'shopLabel'},text:view.shopLabel,label:'Pickup name'}]);
    for(const [index,line] of view.instructions.entries()){
      const a=this.el('article');a.className='card';
      a.append(this.el('h3',line.item),this.el('p',line.amount??this.t('Unknown amount')),this.el('p',line.action));
      if(line.basis)a.append(this.el('p',line.basis));
      const fields:SafetyField[]=[
        {source:{...base,index,field:'action'},text:line.action,label:'Cooking instruction'},
        {source:{...base,index,field:'label'},text:line.item,label:'Item name'}
      ];
      if(line.rawAmount)fields.push({source:{...base,index,field:'amount'},text:line.rawAmount,label:'Amount'});
      if(line.rawAmount&&line.unit)fields.push({source:{...base,index,field:'unit'},text:line.unit,label:'Unit'});
      if(view.canReportContent)this.offerSafety(a,fields);
      main.append(a);
    }
    this.renderReceivedSuggestions(main);
    if(!view.canPropose){main.append(this.el('p',this.t('This view is read-only.')));return;}
    if(this.proposalIntent){
      const intent=this.proposalIntent,card=this.el('section');
      card.append(this.el('h2',this.t('Your reviewed suggestion')),this.el('p',intent.correction),this.el('p',`${this.t('Reviewed revision')}: ${intent.baseRevision}`));
      card.append(this.el('p',this.t('This draft is only kept on this page. After reloading, only suggestions already received by the service can be recovered.')));
      if(this.proposalReceipt){
        card.append(this.el('p',this.t(this.proposalStatus?.status==='reviewed'?'Suggestion reviewed':this.proposalStatus?.status==='dismissed'?'Suggestion dismissed':'Suggestion received for shopper review')),
          this.button('Check suggestion status',()=>void this.run(()=>this.checkProposal())),
          this.button('Write another suggestion', () => {
            this.resetProposal();
            if (!this.cookingReport) this.correction = '';
            this.cookingReport = null;
            this.render();
          }));
      }else if(this.proposalConflict){
        card.append(this.el('p',this.t('The original suggestion was not accepted because its reviewed instructions changed. Review the current instructions before starting a new suggestion.')),
          this.button('Review current instructions', () => void this.run(async () => {
            await this.load();
            if (this.proposalIntent !== intent) return;
            this.resetProposal();
            if (this.cookingReport) this.cookingReport.review = null;
            else this.correction = intent.correction;
            this.notice = 'Review the current instructions before sending again.';
          })));
      }else card.append(this.el('p',this.t('Receipt unconfirmed; the shopper may already have received this suggestion.')),
        this.button('Retry original suggestion',()=>void this.run(()=>this.sendProposal(view))));
      main.append(card);return;
    }
    if(this.suggestionsState!=='ready')return;
    if(this.cookingReport){
      this.renderCookingReport(main,view);
      return;
    }
    main.append(this.button('Report what you cooked',()=>{
      this.cookingReport={grantId:view.grantId,revision:view.revision,servings:'',ingredients:'',leftovers:'',review:null};
      this.render();
    }));
    const form=this.el('form');form.append(this.el('h2',this.t('Propose a correction')));this.field(form,'Correction for the shopper to review','correction',this.correction,v=>{this.correction=v;},true);
    form.append(this.el('p',this.t('This draft is only kept on this page. After reloading, only suggestions already received by the service can be recovered.')));
    const send=this.button('Send proposal',()=>{},true);send.type='submit';form.append(send);form.addEventListener('submit',e=>{e.preventDefault();if(!this.correction.trim())return;void this.run(()=>this.sendProposal(view));});main.append(form);
  }
  private renderCookingReport(main:HTMLElement,view:CookView):void {
    const draft=this.cookingReport;
    if(!draft || draft.grantId!==view.grantId || draft.revision!==view.revision || !view.canPropose)return;
    const form=this.el('form');
    form.append(this.el('h2',this.t('Report what you cooked')),
      this.el('p',this.t('The shopper reviews this report before deciding whether to update the pantry.')));
    if(draft.review!==null){
      const reviewed=draft.review;
      const summary=this.el('p',reviewed);summary.style.whiteSpace='pre-wrap';
      form.append(summary,this.button('Edit report',()=>{draft.review=null;this.render();}),
        this.button('Send report to shopper',()=>void this.run(()=>this.sendProposal(view,reviewed)),true));
    }else{
      this.field(form,'Servings made (optional)','cook-servings',draft.servings,value=>{draft.servings=value;});
      this.field(form,'Ingredients used and substitutions','cook-ingredients',draft.ingredients,value=>{draft.ingredients=value;},true);
      this.field(form,'Leftovers and storage location','cook-leftovers',draft.leftovers,value=>{draft.leftovers=value;},true);
      form.append(this.el('p',this.t('Include quantities you know. Enter none or unknown where appropriate.')));
      const error = this.el('p');
      error.setAttribute('role', 'status');
      const preview = this.button('Review cooking report', () => {}, true);
      preview.type = 'submit';
      form.append(error, preview);
      form.addEventListener('submit',event=>{
        event.preventDefault();
        if(!draft.ingredients.trim() || !draft.leftovers.trim()){
          error.textContent = this.t('Describe ingredient use and leftovers before reviewing.');
          return;
        }
        const sections=[this.t('Cooking report')];
        if(draft.servings.trim())sections.push(this.t('Servings made')+'\n'+draft.servings.trim());
        sections.push(this.t('Ingredients used and substitutions')+'\n'+draft.ingredients.trim(),
          this.t('Leftovers and storage location')+'\n'+draft.leftovers.trim());
        const report=sections.join('\n\n');
        if (report.length > 1000) {
          error.textContent = this.t('Shorten the report to 1,000 characters including its headings.');
          return;
        }
        draft.review=report;
        this.render();
      });
    }
    form.append(this.button('Cancel report',()=>{this.cookingReport=null;this.render();}));
    main.append(form);
  }
}
