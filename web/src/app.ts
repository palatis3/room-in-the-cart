import { API, ApiError, isContributorSession, type BrowserAuthState,type Session, type OwnRequest, type Command, type CookView, type InviteRedemption, prepareProposal, type ProposalIntent, type ProposalReceipt, type OwnProposal } from './api.js';
import { Outbox, scopeFor, type Pending } from './outbox.js';
import { languageFor, translate, type Language } from './i18n.js';

type Draft = {item:string; amount:string; route:'current'|'next'; editing:OwnRequest|null; followup:string|null};
const blank = ():Draft => ({item:'',amount:'',route:'current',editing:null,followup:null});
const statuses:Record<string,string> = {pending:'Received',clarified:'Needs clarification',added:'Added to the pickup',deferred:'Saved for next shop',handled:'Handled',dismissed:'Dismissed',withdrawn:'Withdrawn'};
// A reviewed draft is valid only for the exact actor, role and destination that displayed it.
function reviewScope(session: Session): string {
  return JSON.stringify([session.household.id, session.memberId, session.role, session.shopId, session.grantId ?? null]);
}
export class WebApp {
  private session:Session|null = null;
  private browserAuth:BrowserAuthState|null=null;
  private loginEmail='';
  private loginCode='';
  private codeRequested=false;
  private identityLogoutPending:string|null=null;
  private reviewedScope:string|null = null;
  private logoutPending:Session|null = null;
  private requests:OwnRequest[] = [];
  private view:CookView|null = null;
  private pending:Pending[] = [];
  private confirmedOperations = new Set<string>();
  private draft = blank();
  private review = false;
  private busy = false;
  private notice = '';
  private failurePurpose:'load'|'mutation'|null=null;
  private language:Language;
  private consent = false;
  private adultAttestation = false;
  private inviteAlias = '';
  private redemption:InviteRedemption|null = null;
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
  private withdrawn:OwnRequest|null = null;
  private withdrawalCommand:Command|null = null;
  constructor(private readonly root:HTMLElement, private readonly api = new API(), private readonly outbox = new Outbox(), private invitation:string|null = null) {
    this.language=languageFor(root.ownerDocument.defaultView?.navigator.language ?? 'en');
  }
  private t(key:string):string { return translate(key,this.language); }
  private el<K extends keyof HTMLElementTagNameMap>(tag:K,text?:string):HTMLElementTagNameMap[K] {
    const e=this.root.ownerDocument.createElement(tag); if(text!==undefined)e.textContent=text; return e;
  }
  private button(key:string,action:()=>void,primary=false):HTMLButtonElement {
    const b=this.el('button',this.t(key)); b.type='button'; b.disabled=this.busy; if(primary)b.className='primary'; b.addEventListener('click',action); return b;
  }
  private async run(action:()=>Promise<void>,purpose:'load'|'mutation'='mutation'):Promise<void> {
    if(this.busy)return; this.busy=true; this.render();
    try { await action(); if(purpose==='load'&&this.failurePurpose==='load'){this.notice='';this.failurePurpose=null;} } catch(error) { await this.fail(error,purpose); }
    finally {this.busy=false;this.render();this.root.querySelector<HTMLElement>('[role="status"]')?.focus();}
  }
  private supportedRoute():boolean {return ['/', '/requests', '/invite', '/view'].includes(this.root.ownerDocument.defaultView?.location.pathname??'/');}
  async start():Promise<void> { if(!this.supportedRoute()){this.render();return;} if(this.logoutPending){this.render();return;} await this.run(async()=>{await this.load();},'load'); }
  private clearPrivate():void {
    this.session=null;this.reviewedScope=null;this.requests=[];this.view=null;this.pending=[];this.draft=blank();
    this.retryCommand=null;this.uncertainSend=false;this.consent=false;this.review=false;this.correction='';
    this.receivedSuggestions=[];this.suggestionsCursor=null;this.suggestionsState='unchecked';
    this.proposalGeneration++;this.proposalIntent=null;this.proposalReceipt=null;this.proposalStatus=null;this.proposalConflict=false;this.withdrawn=null;this.withdrawalCommand=null;this.confirmedOperations.clear();
  }
  checkExpiry():void {
    if(this.view && Date.parse(this.view.expiresAt)<=Date.now()) {
      this.clearPrivate();void this.outbox.clear().catch(()=>{});
      this.notice='Access has ended. Ask your household for a new invitation.';this.render();
    }
  }
  private async load():Promise<void> {
    const start=this.proposalGeneration,fresh=await this.api.session();
    if(start!==this.proposalGeneration)return;
    if(this.reviewedScope && fresh && this.reviewedScope!==reviewScope(fresh)) {
      this.clearPrivate();this.notice='';
      await this.outbox.retainScope(scopeFor(fresh)).catch(()=>{});
    }
    this.session=fresh;
    if(!fresh){this.requests=[];this.view=null;this.pending=[];this.receivedSuggestions=[];this.suggestionsState='unchecked';this.consent=false;this.browserAuth=await this.api.authState();return;}
    this.reviewedScope=reviewScope(fresh);
    if(fresh.role==='helper'||fresh.role==='editor') {
      this.requests=[];this.view=null;this.pending=[];this.draft=blank();this.retryCommand=null;this.uncertainSend=false;this.consent=false;
      this.receivedSuggestions=[];this.suggestionsCursor=null;this.suggestionsState='unchecked';
      const generation=this.proposalGeneration;
      await this.outbox.clear().catch(()=>{});const view=await this.api.view(fresh);
      if(generation!==this.proposalGeneration)return;
      this.view=view;
      if(Date.parse(view.expiresAt)<=Date.now())throw new ApiError('access_ended',403);
      await this.readReceivedSuggestions(fresh,null);
    } else {this.view=null;this.requests=await this.api.requests(fresh);}
    if(isContributorSession(fresh)&&fresh.queueConsent&&fresh.enrolled) {
      try {await this.outbox.retainScope(scopeFor(fresh));this.pending=await this.outbox.list(scopeFor(fresh));}
      catch {this.pending=[];this.notice='Stored pending requests could not be opened.';}
    } else {this.pending=[];await this.outbox.clear().catch(()=>{});}
  }
  private async reauthenticate(command?:Command, grantId?:string):Promise<Session> {
    const fresh=await this.api.session();
    if(!fresh)throw new ApiError('session_needed',401);
    if(!this.reviewedScope||reviewScope(fresh)!==this.reviewedScope)throw new ApiError('access_ended',403);
    if(grantId ? fresh.role!=='editor'||fresh.grantId!==grantId : !isContributorSession(fresh))throw new ApiError('access_ended',403);
    if(command&&(fresh.replayWindow.id!==command.replayWindow||Date.parse(fresh.replayWindow.expiresAt)<=Date.now()))throw new ApiError('stale_replay_window',409);
    this.session=fresh;return fresh;
  }
  private async signOut():Promise<void> {
    const old=this.logoutPending??this.session;
    if(!old)return;
    this.logoutPending=old;this.clearPrivate();this.invitation=null;this.redemption=null;this.adultAttestation=false;this.inviteAlias='';this.render();
    let cleared=true;try{await this.outbox.clear();}catch{cleared=false;}
    try {const result=await this.api.logout(old);this.logoutPending=null;this.browserAuth=null;this.notice=result?.providerRevoked===false?'Signed out of this browser. Provider sign-out could not be confirmed.':cleared?'You are signed out.':'You are signed out, but browser storage could not be cleared. Clear site data before sharing this browser.';}
    catch {this.notice='Sign-out could not be confirmed. Retry before sharing this browser.';}
  }
  private async fail(error:unknown,purpose:'load'|'mutation'='mutation'):Promise<void> {
    this.failurePurpose=purpose;
    const e=error instanceof ApiError ? error:new ApiError('unavailable',500);
    if(e.status===403||e.code==='access_ended'||(e.status===404&&(this.proposalIntent!==null||['editor','helper'].includes(this.session?.role??'')))) {
      this.clearPrivate();
      await this.outbox.clear().catch(()=>{});this.notice='Access has ended. Ask your household for a new invitation.';
    } else if(e.status===401) {this.session=null;this.requests=[];this.view=null;this.pending=[];this.receivedSuggestions=[];this.suggestionsState='unchecked';this.notice='Sign in again to continue. Your text stays on this page.';this.browserAuth=await this.api.authState().catch(()=>null);this.codeRequested=false;this.loginCode='';}
    else if(e.code==='login_unavailable')this.notice='Email sign-in is not available yet. Your invitation stays on this page.';
    else if(e.code==='code_not_accepted')this.notice='That code was not accepted. Check the latest code or request another one.';
    else if(e.code==='login_rate_limited')this.notice='Wait before requesting or checking another code.';
    else if(e.code==='consent_unavailable')this.notice='Child enrollment is not available here yet. Ask a guardian to use the verified setup.';
    else if(e.status===409) this.notice='This information changed. Refresh, review, and try again.';
    else if(e.status===422) this.notice='Check your entry and try again.';
    else if(this.suggestionsState==='unavailable')this.notice='Received suggestions could not be checked. Retry recovery before sending another suggestion.';
    else if(purpose==='load')this.notice='Could not load your account. Refresh to try again.';
    else if(this.proposalReceipt)this.notice='Suggestion status could not be checked. Its earlier receipt is still confirmed. Try again.';
    else if(this.proposalIntent)this.notice='Suggestion receipt is unconfirmed. Retry the original suggestion. It is only kept on this page; closing or reloading loses this local copy.';
    else this.notice=this.uncertainSend?'Not saved in this browser. Receipt is unconfirmed. Your text is still here. Retry to check.':'Not saved. Your text is still here. Reconnect and try again.';
  }
  private date(value:string):string {
    const d=new Date(value);return Number.isFinite(d.getTime())?new Intl.DateTimeFormat(this.language==='es'?'es-US':'en-US',{dateStyle:'full',timeStyle:'short'}).format(d):value;
  }
  render():void {
    this.root.replaceChildren();this.root.ownerDocument.documentElement.lang=this.language;
    const header=this.el('header');header.append(this.el('p','Room in the Cart'));
    const lang=this.el('select');lang.id='language';lang.setAttribute('aria-label',this.t('Language'));
    for(const [v,k] of [['en','English'],['es','Spanish']]) {const o=this.el('option',this.t(k!));o.value=v!;o.selected=v===this.language;lang.append(o);}
    lang.addEventListener('change',()=>{this.language=lang.value as Language;this.render();});header.append(lang);this.root.append(header);
    const main=this.el('main');main.setAttribute('aria-busy',String(this.busy));this.root.append(main);
    const status=this.el('p',this.busy?this.t('Loading…'):this.t(this.notice));status.className='notice';status.setAttribute('role','status');status.setAttribute('tabindex','-1');main.append(status);
    if(!this.supportedRoute()){main.append(this.el('h1',this.t('This page is not available.')));const link=this.el('a',this.t('Open your requests'));link.href='/requests';main.append(link);return;}
    if(this.identityLogoutPending){main.append(this.el('h1',this.t('Finish signing out')),this.button('Retry sign-out',()=>void this.run(()=>this.signOutIdentity()),true));return;}
    if(this.logoutPending){main.append(this.el('h1',this.t('Finish signing out')),this.button('Retry sign-out',()=>void this.run(()=>this.signOut()),true));return;}
    if(this.invitation!==null || !this.session) {this.renderInvite(main);return;}
    const context=this.el('section');context.append(this.el('p',this.session.household.label));
    const actions=this.el('div');actions.className='actions';actions.append(this.button('Refresh',()=>void this.run(()=>this.load(),'load')),this.button('Sign out',()=>void this.run(()=>this.signOut())));context.append(actions);main.append(context);
    if(this.session.role==='helper'||this.session.role==='editor'){
      if(this.view)this.renderCook(main);else main.append(this.el('p',this.t('No instructions are available.')));
    } else this.renderContributor(main);
  }
  private async signOutIdentity():Promise<void>{
    const csrf=this.identityLogoutPending??this.browserAuth?.csrf;if(!csrf)return;
    this.identityLogoutPending=csrf;this.clearPrivate();this.browserAuth=null;this.loginEmail='';this.loginCode='';this.codeRequested=false;this.invitation=null;this.redemption=null;
    await this.outbox.clear().catch(()=>{});
    const result=await this.api.logoutIdentity(csrf);this.identityLogoutPending=null;
    this.notice=result.providerRevoked?'You are signed out.':'Signed out of this browser. Provider sign-out could not be confirmed.';
    this.browserAuth=await this.api.authState();
  }
  private renderLogin(main:HTMLElement):void{
    main.append(this.el('h1',this.t('Sign in to continue')));
    if(!this.browserAuth){main.append(this.el('p',this.t('Connect to load sign-in options.')),this.button('Refresh',()=>void this.run(()=>this.load(),'load')));return;}
    if(!this.browserAuth.available){main.append(this.el('p',this.t(this.invitation?'Email sign-in is not available yet. Your invitation stays on this page.':'Email sign-in is not available yet.')),this.button('Refresh',()=>void this.run(()=>this.load(),'load')));return;}
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
  private renderInvite(main:HTMLElement):void {
    if(!this.session&&!this.browserAuth?.authenticated){this.renderLogin(main);return;}

    main.append(this.el('h1',this.t('Continue with your invitation')),this.el('p',this.t('Open an invitation from your household to join.')));
    const form=this.el('form');const label=this.el('label',this.t('Invitation code'));label.htmlFor='invitation';
    const input=this.el('input');input.id='invitation';input.type='password';input.autocomplete='off';input.required=true;input.value=this.invitation??'';
    input.maxLength=4096;input.disabled=this.redemption!==null;
    input.addEventListener('input',()=>{this.invitation=input.value;});form.append(label,input);
    this.field(form,'Your display name (optional)','invite-alias',this.inviteAlias,value=>{this.inviteAlias=value;});
    const alias=form.querySelector<HTMLInputElement>('#invite-alias');if(alias){alias.maxLength=80;alias.disabled=this.redemption!==null;}
    const adultLabel=this.el('label');adultLabel.className='checkbox';const adult=this.el('input');adult.type='checkbox';adult.id='adult-attestation';adult.checked=this.adultAttestation;adult.required=true;adult.disabled=this.redemption!==null;
    adult.addEventListener('change',()=>{this.adultAttestation=adult.checked;});adultLabel.append(adult,this.el('span',this.t('I am 18 or older.')));form.append(adultLabel);
    form.append(this.el('p',this.t('An adult signs in before joining. Child access requires verified guardian setup.')));
    const submit=this.button('Join this household',()=>{},true);submit.type='submit';form.append(submit);
    form.addEventListener('submit',e=>{e.preventDefault();if(!input.value.trim()||!this.adultAttestation)return;void this.run(async()=>{
      this.redemption??=await this.api.redeem(input.value.trim(),this.session?.csrf??this.browserAuth?.csrf??undefined,{adultAttestation:this.adultAttestation,...(this.inviteAlias.trim()?{alias:this.inviteAlias.trim()}:{})});
      await this.api.activateSession(this.redemption.householdId,this.session?.csrf??this.browserAuth?.csrf??undefined,this.redemption.grantId);
      const accepted=this.redemption;this.session=null;this.requests=[];this.view=null;this.pending=[];this.notice='';await this.load();
      const opened=this.session as Session|null;
      if(!opened||opened.household.id!==accepted.householdId||opened.memberId!==accepted.memberId)throw new ApiError('session_needed',401);
      if(accepted.grantId&&opened.grantId!==accepted.grantId){this.view=null;this.requests=[];throw new ApiError('grant_context_changed',409);}
      this.invitation=null;this.redemption=null;this.adultAttestation=false;this.inviteAlias='';
    });});main.append(form,this.el('p',this.t('An internet connection is needed to open an invitation.')),this.button('Refresh',()=>void this.run(()=>this.load(),'load')));
    if(!this.session&&this.browserAuth?.authenticated)main.append(this.button('Sign out',()=>void this.run(()=>this.signOutIdentity())));
  }
  private field(form:HTMLElement,key:string,id:string,value:string,update:(value:string)=>void,multiline=false):void {
    const label=this.el('label',this.t(key));label.htmlFor=id;const input=multiline?this.el('textarea'):this.el('input');input.id=id;input.value=value;input.maxLength=id==='item'?240:id==='amount'?80:1000;
    if(id==='item')input.required=true;input.addEventListener('input',()=>{update(input.value);if(id==='item'||id==='amount')this.retryCommand=null;});form.append(label,input);
  }
  private renderContributor(main:HTMLElement):void {
    main.append(this.el('h1',this.t('Ask the shopper')));
    const form=this.el('form');form.className='card';
    if(this.review) {
      form.append(this.el('h2',this.t('Review before sending')),this.el('p',this.draft.item),this.el('p',this.draft.amount||this.t('Unknown amount')),this.el('p',this.t(this.draft.route==='next'?'Next shop':'This pickup')));
      const back=this.button('Back to edit',()=>{this.review=false;this.render();});back.disabled=this.busy||this.uncertainSend;form.append(back);
      const submit=this.button(this.draft.editing?'Save changes':'Send request',()=>{},true);submit.type='submit';form.append(submit);
      form.addEventListener('submit',e=>{e.preventDefault();void this.run(()=>this.send());});
    } else {
      this.field(form,'Item','item',this.draft.item,v=>{this.draft.item=v;},true);
      form.append(this.el('p',this.t('Keep the food name and any restrictions as written.')));
      this.field(form,'Amount or pack count (optional)','amount',this.draft.amount,v=>{this.draft.amount=v;});
      const label=this.el('label',this.t('Intended trip'));label.htmlFor='route';const route=this.el('select');route.id='route';route.disabled=this.draft.editing!==null;
      for(const [v,k] of [['current','This pickup'],['next','Next shop']]){const option=this.el('option',this.t(k!));option.value=v!;option.selected=v===this.draft.route;route.append(option);}
      route.addEventListener('change',()=>{this.draft.route=route.value as 'current'|'next';this.retryCommand=null;});form.append(label,route);
      const review=this.button('Review request',()=>{},true);review.type='submit';form.append(review);
      form.addEventListener('submit',e=>{e.preventDefault();if(!this.draft.item.trim())return;this.review=true;this.render();});
    }
    if(this.session!.enrolled&&this.session!.queueConsent) {
      const label=this.el('label');label.className='checkbox';const cb=this.el('input');cb.type='checkbox';cb.checked=this.consent;cb.addEventListener('change',()=>{this.consent=cb.checked;});label.append(cb,this.el('span',this.t('Save pending requests on this browser')));form.append(label,this.el('p',this.t('Only enable this on your own device. Queued requests are not yet received.')));
    }
    if(this.draft.item) form.append(this.button('Copy your text',()=>void this.run(async()=>{await navigator.clipboard.writeText(`${this.draft.item}\n${this.draft.amount}`);this.notice='Copied';})));
    if(this.session!.shopId)main.append(form);
    else main.append(this.el('p',this.t('No pickup is accepting requests. Ask the shopper to start a pickup.')));
    if(this.pending.length) {
      const section=this.el('section');section.append(this.el('h2',this.t('Pending requests')));
      for(const p of this.pending) {const card=this.el('article');card.className='card';card.append(this.el('p',String(p.command.body.originalItem??'')),this.el('p',this.t(this.confirmedOperations.has(p.id)?'Received; local cleanup pending':'Waiting to send from this browser')));
        card.append(this.button('Retry',()=>void this.run(()=>this.retry(p))),this.button('Remove pending request',()=>void this.run(async()=>{await this.outbox.remove(p.id);this.pending=this.pending.filter(x=>x.id!==p.id);})));section.append(card);}
      main.append(section);
    }
    const own=this.el('section');own.append(this.el('h2',this.t('Your requests')));
    if(!this.requests.length)own.append(this.el('p',this.t('No requests yet.')));
    for(const r of this.requests){const card=this.el('article');card.className='card';card.dataset.requestId=r.requestId;
      card.append(this.el('h3',r.originalItem),this.el('p',r.ownQuantity??this.t('Unknown amount')),this.el('p',this.t(statuses[r.status]??'Status unavailable')),this.el('p',this.t(r.route==='next'?'Next shop':'This pickup')),this.el('p',this.date(r.receivedAt)));
      if(r.clarification)card.append(this.el('p',r.clarification));
      if(r.ownActionAllowed){card.append(this.button('Edit',()=>{if(this.uncertainSend)return;this.draft={item:r.originalItem,amount:r.ownQuantity??'',route:r.route,editing:r,followup:null};this.review=false;this.retryCommand=null;this.render();this.root.querySelector<HTMLElement>('#item')?.focus();}),this.button('Withdraw',()=>{this.withdrawn=r;this.withdrawalCommand=null;this.render();}));}
      else if(r.status!=='withdrawn')card.append(this.button('Follow up',()=>{if(this.uncertainSend)return;this.draft={...blank(),item:r.originalItem,amount:r.ownQuantity??'',route:r.route,followup:r.requestId};this.review=false;this.retryCommand=null;this.render();this.root.querySelector<HTMLElement>('#item')?.focus();}));
      if(this.withdrawn?.requestId===r.requestId){card.append(this.el('p',this.t('Withdraw this pending request?')),this.button('Confirm withdrawal',()=>void this.run(async()=>{
        const fresh=await this.reauthenticate(this.withdrawalCommand??undefined);
        this.withdrawalCommand??=this.makeCommand('request.withdraw',{requestId:r.requestId},r.revision,r.shopId);await this.api.command(fresh,this.withdrawalCommand);this.withdrawn=null;this.withdrawalCommand=null;this.notice='Withdrawn';await this.load();
      })),this.button('Cancel',()=>{this.withdrawn=null;this.render();}));}own.append(card);
    }main.append(own);
  }
  private makeCommand(kind:string,body:Record<string,unknown>,requestRevision?:number,shopId=this.session!.shopId??''):Command {
    return {v:1,replayWindow:this.session!.replayWindow.id,clientKey:crypto.randomUUID(),shopId,kind,
      base:{shopRevision:0,authorityEpoch:0,...(requestRevision!==undefined?{requestRevision}:{})},body};
  }
  private async send():Promise<void> {
    const s=await this.reauthenticate(this.retryCommand??undefined);
    if(!this.retryCommand)this.retryCommand=this.draft.editing?
      this.makeCommand('request.edit',{requestId:this.draft.editing.requestId,originalItem:this.draft.item,ownQuantity:this.draft.amount||null},this.draft.editing.revision,this.draft.editing.shopId):
      this.makeCommand('request.send',{clientRequestId:crypto.randomUUID(),originalItem:this.draft.item,ownQuantity:this.draft.amount||null,authoredAt:new Date().toISOString(),route:this.draft.route,...(this.draft.followup?{followupTo:this.draft.followup}:{})},undefined,this.requests.find(r=>r.requestId===this.draft.followup)?.shopId??s.shopId??'');
    const command=this.retryCommand;
    const p:Pending={id:command.clientKey,scope:scopeFor(s),command,createdAt:new Date().toISOString()};
    let persisted=false;
    if(this.consent&&s.queueConsent&&s.enrolled){try{await this.outbox.put(p,s,true);persisted=true;}catch{this.notice='Browser storage is unavailable. Requests will remain editable but will not be saved offline.';}}
    try{await this.api.command(s,command);}catch(error){
      this.uncertainSend=error instanceof ApiError && (error.status===0||error.status>=500);

      if(persisted && error instanceof ApiError && (error.status===0||error.status>=500||error.status===429)) {
        this.pending=await this.outbox.list(scopeFor(s));this.notice='Waiting to send from this browser';this.draft=blank();this.retryCommand=null;this.uncertainSend=false;this.review=false;return;
      }
      if(persisted)await this.outbox.remove(p.id);throw error;
    }
    this.confirmedOperations.add(command.clientKey);
    let cleanupFailed=false;if(persisted){try{await this.outbox.remove(p.id);}catch{cleanupFailed=true;}}
    this.draft=blank();this.retryCommand=null;this.uncertainSend=false;this.review=false;this.notice=cleanupFailed?'Received by the shopper. A local pending copy remains; retry it to confirm and clear it.':'Received by the shopper.';
    // A successful command is received even if the subsequent refresh disconnects.
    try{await this.load();}catch(error){if(error instanceof ApiError&&(error.status===401||error.status===403))throw error;}
  }
  private async retry(p:Pending):Promise<void>{
    const fresh=await this.api.session();
    if(!fresh||reviewScope(fresh)!==this.reviewedScope||scopeFor(fresh)!==p.scope||!isContributorSession(fresh)||!fresh.enrolled||!fresh.queueConsent)throw new ApiError('access_ended',403);
    if(fresh.replayWindow.id!==p.command.replayWindow||Date.parse(fresh.replayWindow.expiresAt)<=Date.now()) {this.notice='This queued request needs a new review. It was not resent.';return;}
    await this.api.command(fresh,p.command);await this.outbox.remove(p.id);this.session=fresh;this.pending=this.pending.filter(x=>x.id!==p.id);this.notice='Received by the shopper.';await this.load();
  }
  private resetProposal():void {
    this.proposalGeneration++;this.proposalIntent=null;this.proposalReceipt=null;this.proposalStatus=null;this.proposalConflict=false;
  }
  private async sendProposal(view:CookView):Promise<void> {
    const generation=this.proposalGeneration;
    const fresh=await this.reauthenticate(undefined,this.proposalIntent?.grantId??view.grantId);
    if(generation!==this.proposalGeneration)return;
    this.proposalIntent??=prepareProposal(fresh,view,this.correction,crypto.randomUUID());
    const intent=this.proposalIntent;
    try {
      const receipt=await this.api.sendProposal(fresh,intent);
      if(generation!==this.proposalGeneration||this.proposalIntent!==intent)return;
      this.proposalReceipt=receipt;this.proposalStatus=this.receivedSuggestions.find(p=>p.proposalId===receipt.proposalId)??null;this.proposalConflict=false;
      this.notice='Proposal received. The shopper must review it before anything changes.';
    }catch(error){
      if(generation!==this.proposalGeneration||this.proposalIntent!==intent)return;
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
    this.proposalStatus=status;this.receivedSuggestions=this.receivedSuggestions.map(p=>p.proposalId===status.proposalId?status:p);this.notice='Suggestion status checked.';
  }
  private async readReceivedSuggestions(fresh:Session,cursor:string|null):Promise<void> {
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
      if(this.proposalReceipt)this.proposalStatus=this.receivedSuggestions.find(p=>p.proposalId===this.proposalReceipt?.proposalId)??this.proposalStatus;
    }catch(error){if(generation!==this.proposalGeneration)return;this.suggestionsState='unavailable';throw error;}
  }
  private async recoverSuggestions(more=false):Promise<void> {
    const generation=this.proposalGeneration,fresh=await this.api.session();
    if(generation!==this.proposalGeneration)return;
    if(!fresh||!this.reviewedScope||reviewScope(fresh)!==this.reviewedScope||!['helper','editor'].includes(fresh.role))throw new ApiError('access_ended',403);
    await this.readReceivedSuggestions(fresh,more?this.suggestionsCursor:null);
    if(generation===this.proposalGeneration&&this.suggestionsState==='ready')this.notice='Received suggestions checked.';
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
  private renderCook(main:HTMLElement):void {
    const view=this.view!;
    if(Date.parse(view.expiresAt)<=Date.now()){main.append(this.el('p',this.t('Access has ended. Ask your household for a new invitation.')));this.clearPrivate();void this.outbox.clear().catch(()=>{});return;}
    main.append(this.el('h1',this.t('Current instructions')),this.el('h2',view.shopLabel));
    main.append(this.el('p',`${this.t('As of')}: ${this.date(view.asOf)}`),this.el('p',`${this.t('Revision')}: ${view.revision}`),this.el('p',`${this.t('Expires')}: ${this.date(view.expiresAt)}`));
    for(const line of view.instructions){const a=this.el('article');a.className='card';a.append(this.el('h3',line.item),this.el('p',line.amount??this.t('Unknown amount')),this.el('p',line.action));if(line.basis)a.append(this.el('p',line.basis));main.append(a);}
    this.renderReceivedSuggestions(main);
    if(!view.canPropose){main.append(this.el('p',this.t('This view is read-only.')));return;}
    if(this.proposalIntent){
      const intent=this.proposalIntent,card=this.el('section');
      card.append(this.el('h2',this.t('Your reviewed suggestion')),this.el('p',intent.correction),this.el('p',`${this.t('Reviewed revision')}: ${intent.baseRevision}`));
      card.append(this.el('p',this.t('This draft is only kept on this page. After reloading, only suggestions already received by the service can be recovered.')));
      if(this.proposalReceipt){
        card.append(this.el('p',this.t(this.proposalStatus?.status==='reviewed'?'Suggestion reviewed':this.proposalStatus?.status==='dismissed'?'Suggestion dismissed':'Suggestion received for shopper review')),
          this.button('Check suggestion status',()=>void this.run(()=>this.checkProposal())),
          this.button('Write another suggestion',()=>{this.resetProposal();this.correction='';this.render();}));
      }else if(this.proposalConflict){
        card.append(this.el('p',this.t('The original suggestion was not accepted because its reviewed instructions changed. Review the current instructions before starting a new suggestion.')),
          this.button('Review current instructions',()=>void this.run(async()=>{await this.load();if(this.proposalIntent===intent){this.resetProposal();this.correction=intent.correction;this.notice='Review the current instructions before sending again.';}})));
      }else card.append(this.el('p',this.t('Receipt unconfirmed; the shopper may already have received this suggestion.')),
        this.button('Retry original suggestion',()=>void this.run(()=>this.sendProposal(view))));
      main.append(card);return;
    }
    if(this.suggestionsState!=='ready')return;
    const form=this.el('form');form.append(this.el('h2',this.t('Propose a correction')));this.field(form,'Correction for the shopper to review','correction',this.correction,v=>{this.correction=v;},true);
    form.append(this.el('p',this.t('This draft is only kept on this page. After reloading, only suggestions already received by the service can be recovered.')));
    const send=this.button('Send proposal',()=>{},true);send.type='submit';form.append(send);form.addEventListener('submit',e=>{e.preventDefault();if(!this.correction.trim())return;void this.run(()=>this.sendProposal(view));});main.append(form);
  }
}
