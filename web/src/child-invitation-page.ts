import type { ChildBrowserEnrollmentReceipt, ChildInvitationAuthStart } from '../../shared/contracts/guardian-enrollment-v1.js';
import { consumeInvitation, ApiError, type BrowserAuthState } from './api.js';
import { ChildClaimController, ChildInvitationAPI, type ChildClaimAccess, type ChildInvitationBrowserPort, type ChildInvitationSession } from './child-invitation.js';
import { languageFor, type Language } from './i18n.js';
import {browserSignOutKey,browserSignOutPending,resumeBrowserSignOut,setBrowserSignOutPending} from './browser-sign-out.js';
import {Outbox} from './outbox.js';

export const childInvitationCopy = {
  title:{en:'Child invitation',es:'Invitación para menores'},
  unavailable:{en:'Child setup is not available in this browser yet.',es:'La configuración para menores aún no está disponible en este navegador.'},
  explanation:{en:'A guardian must complete the approved setup. This browser also needs a supported sign-in for the child’s own account before an invitation can be claimed.',es:'Un tutor debe completar la configuración aprobada. Este navegador también necesita un inicio de sesión compatible para la cuenta propia del menor antes de aceptar una invitación.'},
  account:{en:'Use the child’s own account. Do not share an adult’s account or sign in as an adult to accept this invitation.',es:'Usa la cuenta propia del menor. No compartas la cuenta de una persona adulta ni inicies sesión como una persona adulta para aceptar esta invitación.'},
  secret:{en:'Invitation details are not saved here. Keep the original invitation from your guardian.',es:'Los datos de la invitación no se guardan aquí. Conserva la invitación original de tu tutor.'},
  language:{en:'Language',es:'Idioma'},english:{en:'English',es:'Inglés'},spanish:{en:'Spanish',es:'Español'},help:{en:'Help',es:'Ayuda'},
  loading:{en:'Checking child setup…',es:'Consultando la configuración para menores…'},
  signin:{en:'Use the email your guardian approved. Their current permission is checked before requesting a sign-in code.',es:'Usa el correo que aprobó tu tutor. Su permiso actual se comprueba antes de solicitar un código de acceso.'},
  token:{en:'Invitation code',es:'Código de invitación'},email:{en:'Guardian-approved child email',es:'Correo del menor aprobado por el tutor'},
  send:{en:'Request sign-in code',es:'Solicitar código de acceso'},code:{en:'Six-digit code',es:'Código de seis dígitos'},verify:{en:'Verify code',es:'Verificar código'},
  sent:{en:'Check your email for a six-digit code.',es:'Busca en tu correo un código de seis dígitos.'},
  delivery:{en:'Code delivery is unconfirmed. If a code arrives, enter it below. Another code is requested only when you choose to request one.',es:'No se ha confirmado el envío del código. Si llega un código, ingrésalo abajo. Solo se solicita otro código cuando eliges solicitarlo.'},
  signinUncertain:{en:'Sign-in could not be confirmed. Check current status before requesting another code.',es:'No se pudo confirmar el inicio de sesión. Consulta el estado actual antes de solicitar otro código.'},
  resend:{en:'Request another code',es:'Solicitar otro código'},wait:{en:'Wait before requesting another code.',es:'Espera antes de solicitar otro código.'},
  refresh:{en:'Check current status',es:'Consultar estado actual'},claim:{en:'Claim this child invitation',es:'Aceptar esta invitación para menores'},
  claimExplanation:{en:'A pairing code will appear on this device. Your guardian must confirm that code before access can start.',es:'Aparecerá un código de vinculación en este dispositivo. Tu tutor debe confirmar ese código antes de que pueda comenzar el acceso.'},
  pairing:{en:'Your pairing code',es:'Tu código de vinculación'},waiting:{en:'Waiting for your guardian to confirm this code.',es:'Esperando a que tu tutor confirme este código.'},
  approved:{en:'Your guardian confirmed the code. You can finish setup for your own requests.',es:'Tu tutor confirmó el código. Puedes terminar la configuración para tus propias solicitudes.'},
  finish:{en:'Finish child setup',es:'Terminar la configuración del menor'},retryFinish:{en:'Retry original setup',es:'Reintentar la configuración original'},
  finishUncertain:{en:'The setup response is unconfirmed. Check current status or retry the original setup from this page.',es:'La respuesta de la configuración no está confirmada. Consulta el estado actual o reintenta la configuración original desde esta página.'},
  claimUncertain:{en:'The invitation claim is unconfirmed. Retry the original claim from this page.',es:'La aceptación de la invitación no está confirmada. Reintenta la aceptación original desde esta página.'},
  retryClaim:{en:'Retry original claim',es:'Reintentar la aceptación original'},
  recovered:{en:'This invitation already has a pending pairing.',es:'Esta invitación ya tiene una vinculación pendiente.'},
  recoveryExplanation:{en:'The original pairing and retry details were kept only on the original page. Continue there, or ask your guardian to cancel this setup and review a new invitation. This page cannot replace those details.',es:'Los datos originales de vinculación y reintento solo se conservaron en la página original. Continúa allí o pide a tu tutor que cancele esta configuración y revise una nueva invitación. Esta página no puede reemplazar esos datos.'},
  activeMissing:{en:'Setup is active, but access on this browser could not be confirmed. Continue on the original page to retry its original setup, or ask your guardian to review a new setup.',es:'La configuración está activa, pero no se pudo confirmar el acceso en este navegador. Continúa en la página original para reintentar su configuración original o pide a tu tutor que revise una configuración nueva.'},
  ready:{en:'Your own-request access is ready on this browser.',es:'El acceso a tus propias solicitudes está listo en este navegador.'},open:{en:'Open your requests',es:'Abrir tus solicitudes'},
  blocked:{en:'This account has no current child admission for this invitation. Sign out before using the guardian-approved child sign-in.',es:'Esta cuenta no tiene una admisión de menor vigente para esta invitación. Cierra la sesión antes de usar el inicio de sesión del menor aprobado por el tutor.'},
  ended:{en:'This setup ended or the account changed. Ask your guardian to review a new setup.',es:'Esta configuración terminó o cambió la cuenta. Pide a tu tutor que revise una configuración nueva.'},
  failed:{en:'The current status could not be confirmed. Try checking again.',es:'No se pudo confirmar el estado actual. Intenta consultarlo de nuevo.'},
  invalid:{en:'Check the invitation and guardian-approved email, then try again.',es:'Revisa la invitación y el correo aprobado por el tutor y vuelve a intentarlo.'},wrongCode:{en:'That code was not accepted. Check the latest code.',es:'No se aceptó ese código. Revisa el código más reciente.'},
  signout:{en:'Sign out',es:'Cerrar sesión'},signoutRetry:{en:'Retry sign-out',es:'Reintentar el cierre de sesión'},
  signoutFailed:{en:'Sign-out could not be confirmed. Retry before sharing this browser.',es:'No se pudo confirmar el cierre de sesión. Reintenta antes de compartir este navegador.'}
} as const;
type CopyKey=keyof typeof childInvitationCopy;
type Phase='loading'|'unavailable'|'signin'|'code'|'claim'|'pending'|'recovered'|'active_missing'|'active'|'blocked';
interface LiveChild {auth:BrowserAuthState;child:ChildInvitationSession;access:ChildClaimAccess}

/** The server-configured, consent-covered child path. Never adult auth/start,
 * adult invitation redemption, generic enrollment, or a browser secret store. */
export class ChildInvitationPage {
  private language:Language; private phase:Phase='loading'; private busy=false; private generation=0; private notice:CopyKey|null=null;
  private email=''; private code=''; private requested=false; private nextSendAt=0; private verificationUncertain=false;
  private intent:Readonly<ChildInvitationAuthStart>|null=null; private auth:BrowserAuthState|null=null;
  private child:ChildInvitationSession|null=null; private scope:string|null=null; private controller:ChildClaimController|null=null;
  private expected:ChildBrowserEnrollmentReceipt|null=null; private logoutPending=false;
  private visibility:'ready'|'hidden'|'checking'='ready';
  private visibilityRevision=0;
  private refreshAfterAction=false;
  constructor(private readonly root:HTMLElement,private readonly api:ChildInvitationBrowserPort=new ChildInvitationAPI(),private token:string|null=null) {this.language=languageFor(root.ownerDocument.defaultView?.navigator.language??'en');}
  private check(generation:number):void {if(generation!==this.generation)throw new ApiError('access_ended',403);}
  clear():void {this.generation++;this.controller?.clear(true);this.controller=null;this.scope=null;this.child=null;this.token=null;this.email='';this.code='';this.intent=null;this.requested=false;this.verificationUncertain=false;this.expected=null;}
  private async run(action:(generation:number)=>Promise<void>,retryingSignOut=false):Promise<void> {
    if(this.busy||(this.logoutPending&&!retryingSignOut))return;this.busy=true;this.render();
    try {
      await action(this.generation);
    } catch(error) {
      this.fail(error);
    } finally {
      this.busy=false;
      const refresh=this.refreshAfterAction&&this.visibility==='checking'&&!this.logoutPending;
      this.refreshAfterAction=false;
      if(refresh)void this.start();
      else this.render();
    }
  }
  async start():Promise<void>{
    if(this.logoutPending||this.visibility==='hidden')return;
    const revision=this.visibilityRevision;
    await this.run(async generation=>{
      try {
        await this.load(generation);
      } catch(error){
        if(!(error instanceof ApiError&&[401,403,410].includes(error.status)))throw error;
        this.fail(error);
      }
      if(revision===this.visibilityRevision)this.visibility='ready';
    });
  }
  conceal():void {
    this.visibility='hidden';
    this.visibilityRevision++;
    this.render();
  }
  leavePage():void {
    this.clear();
    this.auth=null;
    this.phase='loading';
    this.notice=null;
    this.nextSendAt=0;
    this.conceal();
  }
  resume():void {
    if(this.visibility!=='hidden')return;
    if(this.logoutPending){
      this.visibility='ready';
      this.render();
      return;
    }
    this.visibility='checking';
    if(this.busy){
      this.refreshAfterAction=true;
      this.render();
    }else void this.start();
  }
  private async live(generation:number):Promise<LiveChild|null> {
    const auth=await this.api.authState();this.check(generation);
    if(!auth.available||!auth.authenticated||!auth.csrf)return null;
    const child=await this.api.childSession();this.check(generation);
    const again=await this.api.authState();this.check(generation);
    if(!again.available||!again.authenticated||again.csrf!==auth.csrf)throw new ApiError('access_ended',403);
    if(child.status==='ended')throw new ApiError('access_ended',403);
    if(!child.available||!child.authenticated||!child.admitted||child.scope!=='own_requests'||!child.householdId||!child.inviteId||!child.expiresAt||child.status==='none')return null;
    if(child.status!=='active'&&Date.parse(child.expiresAt)<=Date.now())throw new ApiError('access_ended',403);
    return{auth:again,child,access:{kind:'approved_child_session',scope:JSON.stringify([again.csrf,child.householdId,child.inviteId]),csrf:again.csrf!}};
  }
  private adopt(live:LiveChild):void {
    if(this.scope&&this.scope!==live.access.scope)throw new ApiError('access_ended',403);
    this.auth=live.auth;this.child=live.child;this.scope=live.access.scope;
  }
  private async currentAccess():Promise<ChildClaimAccess|null>{const live=await this.live(this.generation);if(!live){if(this.scope)throw new ApiError('access_ended',403);return null;}if(this.scope&&live.access.scope!==this.scope)throw new ApiError('access_ended',403);return live.access;}
  private async scoped(generation:number,live:LiveChild):Promise<boolean> {
    const session=await this.api.scopedSession();this.check(generation);const after=await this.live(generation);
    if(!after||after.access.scope!==live.access.scope)throw new ApiError('access_ended',403);
    if(!session)return false;
    if(session.role!=='contributor'||!session.enrolled||session.household.id!==live.child.householdId||this.expected&&(session.household.id!==this.expected.householdId||session.memberId!==this.expected.memberId))throw new ApiError('access_ended',403);
    this.adopt(after);this.controller?.clear();this.controller=null;this.token=null;this.intent=null;this.email='';this.code='';this.phase='active';this.notice='ready';return true;
  }
  private async load(generation:number):Promise<void> {
    const availability=await this.api.availability(this.language);this.check(generation);
    if(!availability.available){this.clear();this.phase='unavailable';this.notice=null;return;}
    if(browserSignOutPending(this.root.ownerDocument.defaultView)){this.requireSignOut();return;}
    const auth=await this.api.authState();this.check(generation);
    if(!auth.available){this.clear();this.phase='unavailable';this.notice=null;return;}
    if(!auth.authenticated){
      if(this.scope)throw new ApiError('access_ended',403);
      if(this.auth&&this.auth.csrf!==auth.csrf){this.clear();this.phase='signin';this.auth=auth;this.notice='ended';return;}
      this.auth=auth;this.phase=this.requested?'code':'signin';return;
    }
    const live=await this.live(generation);
    if(!live){this.clear();this.auth=auth;this.phase='blocked';this.notice='blocked';return;}
    if(live.auth.csrf!==auth.csrf)throw new ApiError('access_ended',403);
    if(this.token){
      const [householdId,inviteId]=this.token.split('.');
      const matchesAdmission=householdId?.toLowerCase()===live.child.householdId&&inviteId?.toLowerCase()===live.child.inviteId;
      // A lost response to this page's verification can be recovered from the
      // admission. An unrelated tab's sign-in cannot inherit this page's token.
      if(!matchesAdmission||(this.auth&&this.auth.csrf!==auth.csrf&&!this.verificationUncertain))this.token=null;
    }
    this.adopt(live);this.email='';this.code='';this.intent=null;this.requested=false;this.verificationUncertain=false;
    if(live.child.status==='active'){
      if(await this.scoped(generation,live))return;
      this.phase=this.controller?.state.stage==='finish_retry'?'pending':'active_missing';this.notice=this.phase==='pending'?'finishUncertain':'activeMissing';return;
    }
    if(live.child.claimId){
      if(this.controller?.state.pairingCode){this.phase=this.controller.state.stage==='ready'?'claim':'pending';if(this.phase==='pending')await this.controller.refresh();this.check(generation);}
      else {this.phase='recovered';this.notice='recovered';}return;
    }
    this.controller??=new ChildClaimController({current:()=>this.currentAccess()},this.api,this.root.ownerDocument.defaultView?.crypto??globalThis.crypto);
    this.phase='claim';this.notice=null;
  }
  private async sendCode(generation:number):Promise<void> {
    if(Date.now()<this.nextSendAt){this.notice='wait';return;}
    const before=await this.api.authState();this.check(generation);
    if(!before.available||before.authenticated||!before.csrf||before.csrf!==this.auth?.csrf)throw new ApiError('access_ended',403);
    this.intent??=Object.freeze({token:this.token??'',email:this.email});this.requested=true;this.phase='code';this.nextSendAt=Date.now()+60_000;
    await this.api.startSignin(this.intent,before.csrf);this.check(generation);
    const after=await this.api.authState();this.check(generation);if(after.authenticated||after.csrf!==before.csrf)throw new ApiError('access_ended',403);
    this.auth=after;this.notice='sent';
  }
  private async verify(generation:number):Promise<void> {
    const auth=await this.api.authState();this.check(generation);
    if(auth.authenticated){await this.load(generation);return;}
    if(!auth.available||!auth.csrf||auth.csrf!==this.auth?.csrf)throw new ApiError('access_ended',403);
    this.verificationUncertain=true;
    const verified=await this.api.verifySignin(this.code,auth.csrf);
    this.check(generation);
    this.auth=verified;
    this.verificationUncertain=false;
    this.code='';this.email='';this.intent=null;this.requested=false;
    await this.load(generation);
  }
  private async claim(generation:number):Promise<void> {
    if(!this.controller||!this.token)throw new ApiError('invalid_entry',422);
    await this.controller.claim(this.token);this.check(generation);this.token=null;this.phase='pending';this.notice=null;
  }
  private async finish(generation:number):Promise<void> {
    const live=await this.live(generation);if(!live)throw new ApiError('access_ended',403);this.adopt(live);
    if(live.child.status==='active'&&await this.scoped(generation,live))return;
    if(!this.controller)throw new ApiError('original_finish_needed',409);
    this.expected=await this.controller.finish();this.check(generation);
    const after=await this.live(generation);if(!after||after.access.scope!==live.access.scope)throw new ApiError('access_ended',403);
    if(!await this.scoped(generation,after)){this.phase='active_missing';this.notice='activeMissing';}
  }
  requireSignOut():void {
    this.logoutPending=true;this.clear();this.auth=null;this.phase='blocked';this.notice='signoutFailed';this.render();
  }
  private async signout(csrf?:string):Promise<void> {
    const window=this.root.ownerDocument.defaultView;
    setBrowserSignOutPending(window,true);this.requireSignOut();
    try { await new Outbox().clear(); } catch { /* Continue server sign-out when storage is unavailable. */ }
    if(csrf)await this.api.logoutIdentity(csrf);
    else await resumeBrowserSignOut(()=>this.api.scopedSession(),this.api);
    setBrowserSignOutPending(window,false);this.logoutPending=false;this.notice=null;
    await this.load(this.generation);
  }
  checkExpiry():void {
    if(this.controller?.checkExpiry()||this.child&&this.child.status!=='active'&&this.child.expiresAt&&Date.parse(this.child.expiresAt)<=Date.now()) {this.clear();this.phase='blocked';this.notice='ended';this.render();}
    else if(this.phase==='code'&&this.nextSendAt&&Date.now()>=this.nextSendAt){this.nextSendAt=0;this.render();}
  }
  private fail(error:unknown):void {
    if(this.logoutPending){this.notice='signoutFailed';return;}
    const e=error instanceof ApiError?error:new ApiError('unavailable',500);
    if(e.status===401||e.status===403||e.status===410){this.clear();this.phase='blocked';this.notice='ended';}
    else if(e.code==='consent_unavailable'||e.code==='login_unavailable'||e.code==='child_setup_unavailable'){this.clear();this.phase='unavailable';this.notice=null;}
    else if(e.code==='code_not_accepted'){this.notice='wrongCode';this.code='';this.verificationUncertain=false;}
    else if(e.status===429){this.notice='wait';}
    else if(e.status===422||e.status===404){this.notice='invalid';if(this.phase==='code'){this.requested=false;this.intent=null;this.nextSendAt=0;this.phase='signin';}}
    else if(this.controller?.state.stage==='finish_retry'){this.phase='pending';this.notice='finishUncertain';}
    else if(this.controller?.state.pairingCode&&this.controller.state.stage==='ready'){this.phase='claim';this.notice='claimUncertain';}
    else if(this.phase==='code'){this.notice=this.verificationUncertain?'signinUncertain':'delivery';}else {this.notice='failed';}
  }
  render():void {
    const document=this.root.ownerDocument,t=(key:CopyKey)=>childInvitationCopy[key][this.language];
    const el=<K extends keyof HTMLElementTagNameMap>(tag:K,text?:string):HTMLElementTagNameMap[K]=>{const item=document.createElement(tag);if(text!==undefined)item.textContent=text;return item;};
    const button=(key:CopyKey,action:()=>void)=>{const b=el('button',t(key));b.type='button';b.disabled=this.busy;b.addEventListener('click',action);return b;};
    const field=(form:HTMLElement,key:CopyKey,id:string,value:string,type:string,change:(value:string)=>void)=>{const label=el('label',t(key));label.htmlFor=id;const input=el('input');input.id=id;input.type=type;input.value=value;input.required=true;input.disabled=this.busy;input.autocomplete='off';input.addEventListener('input',()=>change(input.value));form.append(label,input);return input;};
    document.documentElement.lang=this.language;this.root.replaceChildren();const header=el('header');header.append(el('p','Room in the Cart'));
    const select=el('select');select.id='language';select.setAttribute('aria-label',t('language'));
    for(const value of ['en','es'] as const){const option=el('option',t(value==='en'?'english':'spanish'));option.value=value;option.selected=value===this.language;select.append(option);}
    select.addEventListener('change',()=>{this.language=select.value==='es'?'es':'en';this.render();this.root.querySelector<HTMLSelectElement>('#language')?.focus();});header.append(select);
    const main=el('main');main.setAttribute('aria-busy',String(this.busy));main.append(el('h1',t('title')));
    // The original page retains an OTP or pairing intent when switching apps.
    // Its DOM stays free of private fields until the current session is verified.
    if(this.visibility==='hidden'||(this.visibility==='checking'&&!this.logoutPending)){
      const status=el('p',t(this.busy||this.visibility==='hidden'?'loading':'failed'));
      status.setAttribute('role','status');main.append(status);
      if(this.visibility==='checking'&&!this.busy)main.append(button('refresh',()=>void this.start()));
      this.root.append(header,main);return;
    }
    const status=el('p',this.busy?t('loading'):this.notice?t(this.notice):'');status.setAttribute('role','status');main.append(status);
    const message=(key:CopyKey)=>{if(status.textContent!==t(key))main.append(el('p',t(key)));};
    if(this.logoutPending)main.append(button('signoutRetry',()=>void this.run(()=>this.signout(),true)));
    else if(this.phase==='unavailable'){status.textContent=t('unavailable');main.append(el('p',t('explanation')),el('p',t('account')),el('p',t('secret')));}
    else if(this.phase==='signin'){
      main.append(el('p',t('signin')),el('p',t('account')));const form=el('form');
      const token=field(form,'token','child-invitation',this.token??'','password',value=>{this.token=value;});token.maxLength=4096;
      const email=field(form,'email','child-email',this.email,'email',value=>{this.email=value;});email.maxLength=254;email.autocomplete='email';
      const send=button('send',()=>{});send.type='submit';form.append(send);form.addEventListener('submit',event=>{event.preventDefault();void this.run(generation=>this.sendCode(generation));});main.append(form,el('p',t('secret')));
    }else if(this.phase==='code'){
      const form=el('form');const input=field(form,'code','child-code',this.code,'text',value=>{this.code=value;});input.inputMode='numeric';input.pattern='[0-9]{6}';input.maxLength=6;input.autocomplete='one-time-code';
      const verify=button('verify',()=>{});verify.type='submit';form.append(verify);form.addEventListener('submit',event=>{event.preventDefault();void this.run(generation=>this.verify(generation));});
      const resend=button('resend',()=>void this.run(generation=>this.sendCode(generation)));resend.disabled=this.busy||Date.now()<this.nextSendAt;main.append(form,resend);
    }else if(this.phase==='claim'){
      main.append(el('p',t('claimExplanation')));const form=el('form');
      if(!this.controller?.state.pairingCode){const input=field(form,'token','child-invitation',this.token??'','password',value=>{this.token=value;});input.maxLength=4096;}
      const claim=button(this.controller?.state.pairingCode?'retryClaim':'claim',()=>{});claim.type='submit';form.append(claim);form.addEventListener('submit',event=>{event.preventDefault();void this.run(generation=>this.claim(generation));});main.append(form);
    }else if(this.phase==='pending'){
      const state=this.controller?.state;if(state?.pairingCode){main.append(el('h2',t('pairing')));const code=el('p',state.pairingCode);code.id='pairing-code';main.append(code);}
      message(state?.stage==='approved'?'approved':state?.stage==='finish_retry'?'finishUncertain':'waiting');
      if(state?.stage==='approved'||state?.stage==='finish_retry')main.append(button(state.stage==='finish_retry'?'retryFinish':'finish',()=>void this.run(generation=>this.finish(generation))));
    }else if(this.phase==='recovered')main.append(el('p',t('recoveryExplanation')));
    else if(this.phase==='active_missing')message('activeMissing');
    else if(this.phase==='active'){const link=el('a',t('open'));link.href='/requests';main.append(link);}
    if(this.phase!=='unavailable'&&this.phase!=='loading'&&!this.logoutPending)main.append(button('refresh',()=>void this.start()));
    if(this.auth?.authenticated&&!this.logoutPending)main.append(button('signout',()=>void this.run(()=>this.signout(this.auth?.csrf??undefined))));
    const help=el('a',t('help'));help.href='/help';main.append(help);this.root.append(header,main);
  }
}

/** Consume secret links before the first API request. Unavailable configuration
 * never exposes a sign-in form or touches any account API or browser store. */
export function mountChildInvitationPage(root:HTMLElement,api:ChildInvitationBrowserPort=new ChildInvitationAPI()):boolean {
  const document=root.ownerDocument,window=document.defaultView;
  if(!window||!/^\/child-invite\/?$/.test(window.location.pathname))return false;
  const token=consumeInvitation(window.location,window.history);window.history.replaceState(null,'',window.location.pathname);
  const page=new ChildInvitationPage(root,api,token);
  if(document.visibilityState==='hidden')page.conceal();else void page.start();
  const timer=window.setInterval(()=>page.checkExpiry(),1000);
  window.addEventListener('online',()=>void page.start());
  window.addEventListener('storage',event=>{if(event.key===browserSignOutKey&&event.newValue==='1')page.requireSignOut();});
  document.addEventListener('visibilitychange',()=>{
    if(document.visibilityState==='hidden')page.conceal();
    else if(document.visibilityState==='visible')page.resume();
  });
  window.addEventListener('pagehide',event=>{
    page.leavePage();
    if(!event.persisted)window.clearInterval(timer);
  });
  window.addEventListener('pageshow',event=>{if(event.persisted&&document.visibilityState==='visible')page.resume();});
  return true;
}
