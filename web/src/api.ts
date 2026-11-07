import type { OwnRequest, CommandEnvelope } from '../../shared/contracts/service-v1.js';
export type { OwnRequest };
export type Command = CommandEnvelope;
export interface Session {
  authenticated: true; role: string; household: { id: string; label: string }; memberId: string;
  shopId: string | null; replayWindow: { id: string; expiresAt: string }; csrf: string;
  enrolled: boolean; queueConsent: boolean; grantId?: string;
}
export interface BrowserAuthState { available:boolean; authenticated:boolean; csrf:string|null }
export interface InviteRedemption {
  householdId: string; memberId: string; role: 'contributor' | 'helper' | 'editor'; grantId?: string;
}
export interface CookView {
  grantId: string; shopId: string; shopLabel: string; revision: number; asOf: string;
  expiresAt: string; canPropose: boolean;
  instructions: { item: string; amount: string | null; action: string; basis?: string }[];
}
export interface ProposalIntent {
  readonly householdId:string; readonly memberId:string; readonly shopId:string; readonly grantId:string;
  readonly baseRevision:number; readonly correction:string; readonly clientKey:string; readonly expiresAt:string;
  readonly body:string;
}
export interface ProposalReceipt { proposalId:string; grantId:string; baseRevision:number; status:'pending' }
export interface OwnProposal {
  proposalId:string; grantId:string; baseRevision:number; proposalRevision:number; correction:string;
  status:'pending'|'reviewed'|'dismissed'; createdAt:string;
  resolution:{mutationId:string; decision:'replaced'|'dismissed'; revision:number; resolvedAt:string}|null;
}
export interface OwnProposalPage { proposals:OwnProposal[]; nextCursor:string|null }
function ownProposalValue(value:unknown,grantId:string):OwnProposal {
  const d=record(value);
  if(d.grantId!==grantId||!['pending','reviewed','dismissed'].includes(String(d.status)))return invalid();
  let resolution:OwnProposal['resolution']=null;
  if(d.resolution!==null){const r=record(d.resolution);if(!['replaced','dismissed'].includes(String(r.decision)))return invalid();
    resolution={mutationId:identity(r.mutationId),decision:r.decision as 'replaced'|'dismissed',revision:integer(r.revision,1),resolvedAt:timestamp(r.resolvedAt)};}
  if((d.status==='pending')!==(resolution===null)||(d.status==='reviewed'&&resolution?.decision!=='replaced')||(d.status==='dismissed'&&resolution?.decision!=='dismissed'))return invalid();
  return {proposalId:identity(d.proposalId),grantId,baseRevision:integer(d.baseRevision,1),proposalRevision:integer(d.proposalRevision,1),
    correction:text(d.correction,1000),status:d.status as OwnProposal['status'],createdAt:timestamp(d.createdAt),resolution};
}
export function prepareProposal(session:Session,view:CookView,correction:string,clientKey:string):ProposalIntent {
  const intent={householdId:session.household.id,memberId:session.memberId,shopId:view.shopId,grantId:view.grantId,
    baseRevision:view.revision,correction,clientKey,expiresAt:view.expiresAt,
    body:JSON.stringify({clientKey,baseRevision:view.revision,correction})};
  if(!view.canPropose)throw new ApiError('access_ended',403);
  authorizeProposal(session,intent);return Object.freeze(intent);
}
function authorizeProposal(session:Session,intent:ProposalIntent):void {
  if(session.role!=='editor'||!session.enrolled||session.household.id!==intent.householdId||session.memberId!==intent.memberId
      ||session.grantId!==intent.grantId||session.shopId!==intent.shopId||Date.parse(intent.expiresAt)<=Date.now())throw new ApiError('access_ended',403);
  identity(intent.grantId);identity(intent.shopId);identity(intent.clientKey);integer(intent.baseRevision,1);text(intent.correction,1000);timestamp(intent.expiresAt);
  if(intent.body!==JSON.stringify({clientKey:intent.clientKey,baseRevision:intent.baseRevision,correction:intent.correction}))return invalid();
}
export class ApiError extends Error {
  constructor(readonly code: string, readonly status: number) { super(code); }
}
const segment = encodeURIComponent;
const invalid = (): never => { throw new ApiError('invalid_response', 502); };
function record(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return invalid();
  return value as Record<string, unknown>;
}
function text(value: unknown, max = 2048, allowEmpty = false): string {
  if (typeof value !== 'string' || value.length > max || (!allowEmpty && !value.trim())) return invalid();
  return value;
}
function identity(value: unknown): string {
  const id = text(value, 256);
  if (/[/?#\s]/.test(id)) return invalid();
  return id;
}
function timestamp(value: unknown): string {
  const date = text(value, 64);
  if (!Number.isFinite(Date.parse(date))) return invalid();
  return date;
}
function integer(value: unknown, minimum = 0): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < minimum) return invalid();
  return value;
}
function boolean(value: unknown): boolean { if (typeof value !== 'boolean') return invalid(); return value; }
function optionalText(value: unknown, max = 2048): string | null { return value === null ? null : text(value, max); }
const ownKinds = ['request.send', 'request.edit', 'request.withdraw'];
export function isContributorSession(session: Session): boolean { return ['contributor', 'shopper', 'organizer'].includes(session.role); }

/** Validate persisted commands too: an outbox can carry only this person's request operations. */
export function validateOwnCommand(command: Command): void {
  const c = record(command), base = record(c.base), body = record(c.body);
  if (c.v !== 1 || !ownKinds.includes(String(c.kind)) || base.shopRevision !== 0 || base.authorityEpoch !== 0) return invalid();
  identity(c.replayWindow); identity(c.clientKey); identity(c.shopId);
  const keys = c.kind === 'request.send' ? ['clientRequestId', 'originalItem', 'ownQuantity', 'authoredAt', 'route', 'followupTo']
    : c.kind === 'request.edit' ? ['requestId', 'originalItem', 'ownQuantity'] : ['requestId'];
  if (Object.keys(body).some(key => !keys.includes(key))) return invalid();
  if (c.kind === 'request.send') {
    identity(body.clientRequestId); timestamp(body.authoredAt);
    if (body.route !== 'current' && body.route !== 'next') return invalid();
    if (body.followupTo !== undefined) identity(body.followupTo);
  } else { identity(body.requestId); integer(base.requestRevision, 1); }
  if (c.kind !== 'request.withdraw') { text(body.originalItem, 240); optionalText(body.ownQuantity, 80); }
}

function ownRequest(value: unknown): OwnRequest {
  const r = record(value);
  const route = r.route, status = r.status;
  if (route !== 'current' && route !== 'next') return invalid();
  if (!['pending', 'clarified', 'added', 'deferred', 'handled', 'dismissed', 'withdrawn'].includes(String(status))) return invalid();
  const purchaseOutcome = r.purchaseOutcome;
  if (purchaseOutcome !== undefined &&
      (status !== 'added' || (purchaseOutcome !== 'bought' && purchaseOutcome !== 'notBought'))) return invalid();
  const ownActionAllowed = boolean(r.ownActionAllowed);
  if (ownActionAllowed && status !== 'pending' && status !== 'clarified') return invalid();
  if (r.carriedForward !== undefined && (r.carriedForward !== true || ownActionAllowed || route !== 'next')) return invalid();
  if (r.fromPreviousShop !== undefined && r.fromPreviousShop !== true) return invalid();
  return {requestId:identity(r.requestId), shopId:identity(r.shopId), revision:integer(r.revision, 1),
    originalItem:text(r.originalItem, 240), ownQuantity:optionalText(r.ownQuantity, 80),
    authoredAt:timestamp(r.authoredAt), receivedAt:timestamp(r.receivedAt), route, status:status as OwnRequest['status'], ownActionAllowed,
    ...(r.carriedForward === true ? {carriedForward:true} : {}),
    ...(r.fromPreviousShop === true ? {fromPreviousShop:true} : {}),
    ...(purchaseOutcome === undefined ? {} : {purchaseOutcome}),
    clarification:optionalText(r.clarification ?? null, 300), followupTo:r.followupTo == null ? null : identity(r.followupTo)};
}

function parseSession(value: unknown): Session | null {
  const d = record(value);
  if (d.authenticated === false) return null;
  if (d.authenticated !== true || !['contributor', 'shopper', 'organizer', 'helper', 'editor'].includes(String(d.role))) return invalid();
  const household = record(d.household), replay = record(d.replayWindow);
  const grantId = d.grantId == null ? undefined : identity(d.grantId);
  if ((d.role === 'helper' || d.role === 'editor') && !grantId) return invalid();
  return { authenticated: true, role: String(d.role), household: { id: identity(household.id), label: text(household.label, 512) }, memberId: identity(d.memberId),
    shopId: d.shopId === null ? null : identity(d.shopId), replayWindow: { id: identity(replay.id), expiresAt: timestamp(replay.expiresAt) }, csrf: text(d.csrf, 1024),
    enrolled: boolean(d.enrolled), queueConsent: boolean(d.queueConsent), ...(grantId ? { grantId } : {}) };
}

function parseBrowserAuth(value:unknown):BrowserAuthState {
  const d=record(value),available=boolean(d.available),authenticated=boolean(d.authenticated);
  if(!available&&authenticated)return invalid();
  const csrf=available?text(d.csrf,1024):d.csrf===null?null:invalid();
  return{available,authenticated,csrf};
}
export class API {
  constructor(private readonly fetcher: typeof fetch = (input, init) => globalThis.fetch(input, init)) {}
  private async call(path: string, method = 'GET', body?: unknown, csrf?: string, encodedBody?:string): Promise<unknown> {
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (csrf) headers['X-CSRF-Token'] = csrf;
    let response: Response;
    try { response = await this.fetcher(path, { method, credentials: 'same-origin', cache: 'no-store', referrerPolicy: 'no-referrer', headers, ...(body !== undefined ? { body: encodedBody ?? JSON.stringify(body) } : {}) }); }
    catch { throw new ApiError('network', 0); }
    const data: unknown = await response.json().catch(() => null);
    if (!response.ok) {
      const error = data && typeof data === 'object' && 'error' in data ? data.error : null;
      const code = error && typeof error === 'object' && 'code' in error && typeof error.code === 'string' ? error.code : 'unavailable';
      throw new ApiError(code, response.status);
    }
    if (!data && response.status !== 204) return invalid();
    return data;
  }
  async authState():Promise<BrowserAuthState>{return parseBrowserAuth(await this.call('/v1/auth/session'));}
  async sendEmailCode(email:string,csrf:string):Promise<void>{
    const clean=email.trim();if(clean.length>254||!/^\S+@\S+\.\S+$/.test(clean))throw new ApiError('invalid_entry',422);
    const result=record(await this.call('/v1/auth/email/start','POST',{email:clean},csrf));if(result.status!=='check_email')return invalid();
  }
  async verifyEmailCode(code:string,csrf:string):Promise<BrowserAuthState>{
    if(!/^\d{6}$/.test(code))throw new ApiError('invalid_entry',422);
    const state=parseBrowserAuth(await this.call('/v1/auth/email/verify','POST',{code},csrf));if(!state.authenticated)return invalid();return state;
  }
  async refreshIdentity(csrf:string):Promise<BrowserAuthState>{
    const state=parseBrowserAuth(await this.call('/v1/auth/refresh','POST',{},csrf));if(!state.authenticated)return invalid();return state;
  }
  async logoutIdentity(csrf:string):Promise<{providerRevoked:boolean}>{
    const result=record(await this.call('/v1/auth/session','DELETE',undefined,csrf));if(result.signedOut!==true)return invalid();return{providerRevoked:boolean(result.providerRevoked)};
  }
  async session(): Promise<Session | null> { return parseSession(await this.call('/v1/session')); }
  async redeem(token: string, csrf: string | undefined, review: {adultAttestation: boolean; alias?: string}): Promise<InviteRedemption> {
    if (!token.trim() || token.length > 4096 || !review.adultAttestation) throw new ApiError('invalid_entry', 422);
    const d = record(await this.call('/v1/invites/redeem', 'POST', {token, intent:'join', adultAttestation:true,
      ...(review.alias?.trim() ? {alias:text(review.alias.trim(), 80)} : {})}, csrf));
    if (d.role !== 'contributor' && d.role !== 'helper' && d.role !== 'editor') return invalid();
    const grantId = d.grantId == null ? undefined : identity(d.grantId);
    if ((d.role === 'helper' || d.role === 'editor') && !grantId) return invalid();
    return {householdId:identity(d.householdId), memberId:identity(d.memberId), role:d.role, ...(grantId ? {grantId} : {})};
  }
  async activateSession(householdId: string, csrf?: string, grantId?: string): Promise<void> {
    const active = parseSession(await this.call('/v1/session', 'POST', {householdId:identity(householdId), ...(grantId ? {grantId:identity(grantId)} : {})}, csrf));
    if (!active || active.household.id !== householdId || (grantId && active.grantId !== grantId)) return invalid();
  }
  async requests(session: Session): Promise<OwnRequest[]> {
    if (!isContributorSession(session)) throw new ApiError('access_ended', 403);
    const rows: OwnRequest[] = [], ids = new Set<string>(), cursors = new Set<string>();
    let cursor: string | null = null;
    do {
      const d = record(await this.call(`/v1/households/${segment(session.household.id)}/requests/mine${cursor ? `?cursor=${segment(cursor)}` : ''}`));
      if (!Array.isArray(d.requests) || d.requests.length > 50) return invalid();
      for (const value of d.requests) {
        const row = ownRequest(value);
        if (ids.has(row.requestId)) return invalid();
        ids.add(row.requestId); rows.push(row);
      }
      cursor = d.nextCursor === null ? null : identity(d.nextCursor);
      if (cursor) { if (cursors.has(cursor) || cursors.size >= 20) return invalid(); cursors.add(cursor); }
      if (rows.length > 1000) throw new ApiError('too_many_results', 422);
    } while (cursor);
    return rows;
  }
  async command(session: Session, command: Command): Promise<void> {
    if (!isContributorSession(session)) throw new ApiError('access_ended', 403);
    validateOwnCommand(command);
    const receipt = record(await this.call(`/v1/households/${segment(session.household.id)}/commands`, 'POST', command, session.csrf));
    identity(receipt.operationId);
    const request = ownRequest(receipt.request);
    if (receipt.kind !== command.kind || request.shopId !== command.shopId
        || (command.kind !== 'request.send' && request.requestId !== command.body.requestId)) return invalid();
  }
  async view(session: Session): Promise<CookView> {
    if (!['helper', 'editor'].includes(session.role) || !session.grantId) throw new ApiError('access_ended', 403);
    const d = record(await this.call(`/v1/views/${segment(session.grantId)}/current`));
    if (!Array.isArray(d.items) || d.items.length > 500 || !['en', 'es'].includes(String(d.language)) || !['read', 'edit'].includes(String(d.mode)) || d.grantId !== session.grantId
        || (session.shopId !== null && d.shopId !== session.shopId)) return invalid();
    return {grantId:identity(d.grantId), shopId:identity(d.shopId), shopLabel:text(d.shopLabel, 512), revision:integer(d.revision, 1),
      asOf:timestamp(d.asOf), expiresAt:timestamp(d.expiresAt), canPropose:boolean(d.canPropose) && session.role === 'editor' && d.mode === 'edit',
      instructions:d.items.map(value => { const i = record(value), amount = optionalText(i.amount, 80), unit = optionalText(i.unit, 80);
        return {item:text(i.label, 240), amount:amount === null ? null : [amount, unit].filter(Boolean).join(' '), action:text(i.action, 500)}; })};
  }
  async propose(session: Session, view: CookView, correction: string, clientKey: string): Promise<ProposalReceipt> {
    return this.sendProposal(session,prepareProposal(session,view,correction,clientKey));
  }
  async sendProposal(session:Session,intent:ProposalIntent):Promise<ProposalReceipt> {
    authorizeProposal(session,intent);
    const receipt=record(await this.call(`/v1/views/${segment(intent.grantId)}/proposals`,'POST',JSON.parse(intent.body),session.csrf,intent.body));
    if(receipt.grantId!==intent.grantId||receipt.baseRevision!==intent.baseRevision||receipt.status!=='pending')return invalid();
    return {proposalId:identity(receipt.proposalId),grantId:intent.grantId,baseRevision:intent.baseRevision,status:'pending'};
  }
  async ownProposal(session:Session,intent:ProposalIntent,receipt:ProposalReceipt):Promise<OwnProposal> {
    authorizeProposal(session,intent);
    if(receipt.grantId!==intent.grantId||receipt.baseRevision!==intent.baseRevision)return invalid();
    const proposal=ownProposalValue(await this.call(`/v1/views/${segment(intent.grantId)}/proposals/${segment(identity(receipt.proposalId))}`),intent.grantId);
    if(proposal.proposalId!==receipt.proposalId||proposal.baseRevision!==intent.baseRevision||proposal.correction!==intent.correction.trim())return invalid();
    return proposal;
  }
  async receivedProposals(session:Session,view:CookView,cursor:string|null=null):Promise<OwnProposalPage> {
    if(!['editor','helper'].includes(session.role)||!session.enrolled||session.grantId!==view.grantId||session.shopId!==view.shopId
      ||Date.parse(timestamp(view.expiresAt))<=Date.now())throw new ApiError('access_ended',403);
    const d=record(await this.call(`/v1/views/${segment(identity(view.grantId))}/proposals${cursor?'?cursor='+segment(identity(cursor)):''}`));
    if(!Array.isArray(d.proposals)||d.proposals.length>20)return invalid();
    const proposals=d.proposals.map(p=>ownProposalValue(p,view.grantId)),nextCursor=d.nextCursor===null?null:identity(d.nextCursor);
    if(new Set(proposals.map(p=>p.proposalId)).size!==proposals.length||proposals.some(p=>p.proposalId===cursor)
      ||(nextCursor!==null&&nextCursor!==proposals.at(-1)?.proposalId))return invalid();
    return {proposals,nextCursor};
  }
  async logout(session: Session): Promise<{providerRevoked:boolean|null}> { const result=record(await this.call('/v1/session', 'DELETE', undefined, session.csrf));if(result.signedOut!==true)return invalid();return{providerRevoked:result.providerRevoked===undefined?null:boolean(result.providerRevoked)}; }
}

/** Consume secret links before the first API request or application rendering. */
export function consumeInvitation(location: Location, history: History): string | null {
  const url = new URL(location.href);
  const hash = new URLSearchParams(url.hash.slice(1));
  const token = hash.get('token') ?? url.searchParams.get('token');
  if (token !== null) {
    url.hash = '';
    url.searchParams.delete('token');
    history.replaceState(null, '', url.pathname + url.search);
  }
  return token;
}
