import {randomUUID} from 'node:crypto';
import type {QueryResult} from 'pg';
import type {Database,Transaction} from '../database.js';
import type {AppleBillingGateway} from './apple.js';
import type {VerifiedSubscription} from './domain.js';
import {day,nextNotice,sufficientCalendarNotice} from './renewal-facts.js';
import {providerRetryWindow,type NoticeProvider,type RenewalConfig} from './renewal-provider.js';

interface Enrollment {id:string;household_id:string;purchaser_id:string;original_id:string}
interface Dispatch {id:string;contact_id:string;edition:number;purpose:'reminder'|'correction';due_at:Date;amount_milli:string;signed_at:Date;
  first_attempt:Date;purge_at:Date;state:'attempted'|'accepted'|'delivered'|'failed';provider_id:string|null}
interface Ready {recipient:string;verifiedSince:number;prior?:Dispatch}
type Planned={kind:'send';id:string}|{kind:'wait';at:number;attention:boolean};

async function transaction<T>(pool:Database,work:(db:Transaction)=>Promise<T>) {
  const db=await pool.connect();
  try {
    await db.query('BEGIN');await db.query("SET LOCAL statement_timeout='4s'; SET LOCAL lock_timeout='1500ms'");
    const result=await work(db);await db.query('COMMIT');return result;
  } catch(error){await db.query('ROLLBACK');throw error;}finally{db.release();}
}

async function authorized(db:Transaction,c:Enrollment,fresh:VerifiedSubscription,issuer:string):Promise<Ready|null> {
  const live=await db.query('SELECT id FROM ritc.renewal_contact WHERE id=$1 AND original_id=$2 FOR UPDATE',[c.id,c.original_id]);
  if(!live.rowCount)return null;
  const record=(await db.query<{destination:string;verified_since:Date;subscription:VerifiedSubscription}>(
    'SELECT * FROM ritc.renewal_worker_contact($1,$2)',[c.id,issuer])).rows[0];
  if(!record||fresh.environment!=='Production'||fresh.originalTransactionID!==c.original_id||
    fresh.appAccountToken!==record.subscription.appAccountToken||fresh.productID!==record.subscription.productID||
    fresh.purchasedAt<record.subscription.purchasedAt||fresh.signedAt<record.subscription.signedAt||
    (fresh.signedAt===record.subscription.signedAt&&fresh.status==='active'&&record.subscription.status!=='active'))return null;
  const previous=(await db.query<Dispatch>(`SELECT * FROM ritc.renewal_dispatch WHERE household_id=$1 AND purchaser_id=$2
    AND original_id=$3 AND term=$4 ORDER BY edition DESC LIMIT 1 FOR UPDATE`,
    [c.household_id,c.purchaser_id,c.original_id,fresh.transactionID])).rows[0];
  return {recipient:record.destination,verifiedSince:record.verified_since.getTime(),...(previous?{prior:previous}:{})};
}

function decide(fresh:VerifiedSubscription,c:Enrollment,context:Ready|null,now:number):Planned|'reminder'|'correction' {
  const incident:Planned={kind:'wait',at:now+day,attention:true};
  if(!context)return incident;
  const p=context.prior,facts=fresh.noticeFacts;
  const newlyConfirmedAfterFailure=p?.state==='failed'&&p.contact_id!==c.id&&context.verifiedSince>p.first_attempt.getTime();
  if(p&&((p.contact_id!==c.id&&p.state==='attempted')||(p.state==='failed'&&!newlyConfirmedAfterFailure)||
    (facts&&facts.signedAt<p.signed_at.getTime())))return incident;
  if(p?.state==='accepted')return {kind:'wait',at:now+day,attention:now-p.first_attempt.getTime()>=day};
  const previous=p&&!newlyConfirmedAfterFailure?{date:p.due_at.getTime(),amountMilli:Number(p.amount_milli),sentAt:p.first_attempt.getTime(),purpose:p.purpose}:undefined;
  const action=nextNotice(fresh,now,previous);
  if(p?.state==='attempted') {
    // Provider acceptance can precede a local timeout. Never reuse the key with new content or after its guarantee expires.
    if(!facts||fresh.status!=='active'||fresh.expiresAt<=now||facts.signedAt>now+5*60_000||previous?.date!==facts.date||previous.amountMilli!==facts.amountMilli||now>=p.first_attempt.getTime()+providerRetryWindow||
       !sufficientCalendarNotice(now,facts.date)||now>=p.purge_at.getTime())return incident;
    return {kind:'send',id:p.id};
  }
  if(action==='reminder'||action==='correction'){
    if(action==='correction'&&p&&facts&&facts.signedAt<=p.signed_at.getTime())return incident;
    return action;
  }
  if(action==='early')return {kind:'wait',at:facts!.date-7*day,attention:false};
  if(action==='late')return {kind:'wait',at:Math.max(now+day,facts!.date),attention:true};
  if(action==='unchanged')return {kind:'wait',at:now+day,attention:false};
  if(action==='not_ready'&&(fresh.status!=='active'||fresh.autoRenewOff===true))return {kind:'wait',at:now+day,attention:false};
  return incident;
}

async function defer(db:Transaction,id:string,at:number,attention:boolean){
  await db.query('UPDATE ritc.renewal_contact SET next_check=$2,attention=$3 WHERE id=$1',[id,new Date(at),attention]);
}

async function plan(pool:Database,c:Enrollment,fresh:VerifiedSubscription,issuer:string):Promise<Planned>{
  return transaction(pool,async db=>{
    const now=Date.now(),ctx=await authorized(db,c,fresh,issuer);
    const decision=decide(fresh,c,ctx,now);
    if(typeof decision!=='string'){
      if(decision.kind==='wait')await defer(db,c.id,decision.at,decision.attention);
      return decision;
    }
    const facts=fresh.noticeFacts!,prior=ctx!.prior,id=randomUUID();
    await db.query(`INSERT INTO ritc.renewal_dispatch(id,household_id,purchaser_id,contact_id,original_id,term,
      edition,due_at,amount_milli,signed_at,purge_at,purpose) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
      [id,c.household_id,c.purchaser_id,c.id,c.original_id,fresh.transactionID,(prior?.edition??0)+1,
       new Date(facts.date),facts.amountMilli,new Date(facts.signedAt),prior?.purge_at??new Date(facts.date+30*day),decision]);
    return {kind:'send',id};
  });
}

async function handle(pool:Database,c:Enrollment,gateway:AppleBillingGateway,provider:NoticeProvider,issuer:string,signal:AbortSignal) {
  const lookup=AbortSignal.any([signal,AbortSignal.timeout(15_000)]);
  const limit=AbortSignal.any([lookup,AbortSignal.timeout(3500)]);
  let interrupted:()=>void=()=>{};
  const deadline=new Promise<never>((_,reject)=>{
    interrupted=()=>reject(new Error('Renewal verification timed out'));
    if(limit.aborted)interrupted();else limit.addEventListener('abort',interrupted,{once:true});
  });
  const fresh=await Promise.race([gateway.current(c.original_id),deadline]).finally(()=>limit.removeEventListener('abort',interrupted));
  signal.throwIfAborted();
  lookup.throwIfAborted();
  const p=await plan(pool,c,fresh,issuer);
  if(p.kind==='wait')return;
  try{
    await dispatch(pool,c,fresh,issuer,p.id,provider,lookup);
  }catch(error){
    // The daily schedule can be outside the provider's 24-hour guarantee by its
    // next invocation. Make one bounded same-key recovery while consent, amount,
    // authorization and the provider window can still be rechecked under lock.
    if(lookup.aborted)throw error;
    await dispatch(pool,c,fresh,issuer,p.id,provider,lookup);
  }
}

async function dispatch(pool:Database,c:Enrollment,fresh:VerifiedSubscription,issuer:string,id:string,provider:NoticeProvider,signal:AbortSignal) {
  await transaction(pool,async db=>{
    const now=Date.now(),ctx=await authorized(db,c,fresh,issuer);
    const decision=decide(fresh,c,ctx,now);
    if(!ctx||typeof decision==='string'||decision.kind!=='send'||decision.id!==id)return;
    signal.throwIfAborted();
    // Authoritative identity and enrollment row locks survive until this bounded provider call completes.
    const p=ctx.prior!;
    const providerID=await provider.send(id,ctx.recipient,{date:p.due_at.getTime(),amountMilli:Number(p.amount_milli),purpose:p.purpose},signal);
    await db.query("UPDATE ritc.renewal_dispatch SET state='accepted',provider_id=$2 WHERE id=$1 AND state='attempted'",[id,providerID]);
    await defer(db,c.id,now+60*60_000,false);
  });
}

export async function maintainRenewalNotices(pool:Database,config:RenewalConfig,gateway:AppleBillingGateway|null,issuer:string|undefined,mode:'run'|'status',signal:AbortSignal){
  const tally={mode:config.mode,checked:0,due:0,attention:0};
  let transportFailed=false;
  // Cleanup continues after disabling delivery. Older deployed schemas have no notice data.
  let lostRoutes=0;
  try{
    const {rows}=await pool.query('SELECT ritc.renewal_housekeeping($1) AS lost',[mode==='run']);
    lostRoutes=Number(rows[0]?.lost??0);
  }catch(error){
    if(config.mode==='off'&&error instanceof Error&&'code' in error&&error.code==='42883')return tally;
    throw error;
  }
  if(config.mode!=='send'&&mode==='run')await pool.query('SELECT ritc.renewal_worker_result(false)');
  if(config.mode==='off')return {...tally,attention:lostRoutes};
  if(mode==='run'&&config.provider){
    if(!gateway||!issuer||!await config.provider.ready(signal)){
      await pool.query('SELECT ritc.renewal_worker_result(false)');return {...tally,attention:1};
    }
    // Keyset pages bound each read. Advance even when a stale row changes concurrently.
    // The earliest known renewal takes priority over recently enrolled distant terms.
    const deadline=Date.now()+18_000;
    let cursorAt:Date|null=null,cursorID:string|null=null;
    while(!signal.aborted&&Date.now()<deadline){
      const rows:QueryResult<Enrollment & {priority_at:Date}>=await pool.query(`SELECT id,household_id,purchaser_id,original_id,priority_at
        FROM ritc.renewal_contact WHERE original_id IS NOT NULL AND next_check<=now()
        AND ($1::timestamptz IS NULL OR (priority_at,id)>($1,$2::uuid))
        ORDER BY priority_at,id LIMIT 25`,[cursorAt,cursorID]);
      if(!rows.rowCount)break;
      for(const c of rows.rows){
        if(signal.aborted||Date.now()>=deadline)break;
        cursorAt=c.priority_at;cursorID=c.id;
        try{await handle(pool,c,gateway,config.provider,issuer,signal);tally.checked++;}
        catch{transportFailed=true;await pool.query("UPDATE ritc.renewal_contact SET attention=true,next_check=now()+interval '1 hour' WHERE id=$1",[c.id]);}
      }
      if(rows.rows.length<25)break;
    }
  }
  const totals=(await pool.query('SELECT count(*) FILTER(WHERE original_id IS NOT NULL AND next_check<=now()) AS due,count(*) FILTER(WHERE attention) AS attention FROM ritc.renewal_contact')).rows[0]!;
  if(mode==='run'&&config.mode==='send')await pool.query('SELECT ritc.renewal_worker_result($1)',[!signal.aborted&&!transportFailed&&Number(totals.due)===0]);
  return {...tally,due:Number(totals.due),attention:Number(totals.attention)+lostRoutes};
}
