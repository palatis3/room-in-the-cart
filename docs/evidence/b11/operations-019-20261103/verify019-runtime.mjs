import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {generateKeyPair,exportJWK,createLocalJWKSet,SignJWT} from '../service/node_modules/jose/dist/webapi/index.js';
import {HouseholdRepository} from '../service/dist/repository.js';
import {JWTIdentityVerifier,SupabaseSessionVerifier} from '../service/dist/auth.js';
import {SharedStoreQuotes} from '../service/dist/shared-store-quotes.js';
import {HouseholdMeasurement} from '../service/dist/measurement.js';

const tables=['shop_budget_grant','store_quote_pair','store_quote_proposal','store_quote_adoption','store_quote_mutation','measurement_consent','measurement_feedback'];
export async function verify019Runtime({database,admin,app,worker,ids}){
 const r={nonempty018019:{},retained:{},erased:{},permissions:{},rls:{},protections:{},runtime:{},willing:{}};
 for(const table of tables){
  const n=(await admin.query(`SELECT count(*)::int n FROM ritc.${table}`)).rows[0].n;assert.ok(n>0,table);r.nonempty018019[table]=n;
  const retained=(await admin.query(`SELECT count(*)::int n FROM ritc.${table} WHERE household_id=$1`,[ids.retained.householdId])).rows[0].n;r.retained[table]=retained;
  await assert.rejects(()=>worker.query(`SELECT * FROM ritc.${table}`),e=>e.code==='42501');
  r.permissions['worker_raw_'+table+'_denied']=true;
  assert.equal((await app.query(`SELECT count(*)::int n FROM ritc.${table}`)).rows[0].n,0);r.rls[table+'_without_tenant_empty']=true;
 }
 assert.deepEqual(r.retained,{shop_budget_grant:1,store_quote_pair:1,store_quote_proposal:1,store_quote_adoption:1,store_quote_mutation:4,measurement_consent:2,measurement_feedback:1});
 for(const table of ['shop_budget_grant','store_quote_pair','store_quote_proposal','store_quote_adoption','measurement_consent','measurement_feedback','billing_state']){
  r.erased[table]=(await admin.query(`SELECT count(*)::int n FROM ritc.${table} WHERE household_id=$1`,[ids.erased.householdId])).rows[0].n;assert.equal(r.erased[table],0,table);
 }
 r.erased.actorMutationReceipts=(await admin.query('SELECT count(*)::int n FROM ritc.store_quote_mutation WHERE household_id=$1 AND actor_id=$2',[ids.erased.householdId,ids.erased.memberId])).rows[0].n;assert.equal(r.erased.actorMutationReceipts,0);
 r.erased.identityBlocked=(await app.query('SELECT ritc.identity_blocked($1,$2) blocked',[ids.issuer,ids.erased.subject])).rows[0].blocked;assert.equal(r.erased.identityBlocked,true);
 const job=(await admin.query('SELECT state,issuer,subject,app_erased_at IS NOT NULL app_erased,provider_erased_at IS NOT NULL provider_erased FROM ritc.privacy_job WHERE job_id=$1',[ids.erased.jobId])).rows[0];
 assert.deepEqual(job,{state:'complete',issuer:null,subject:null,app_erased:true,provider_erased:true});r.erased.completedJob=job;
 r.permissions.effectiveColumnAndTableGrants=(await app.query(`SELECT
  has_table_privilege(current_user,'ritc.store_quote_pair','SELECT') quote_select,
  has_table_privilege(current_user,'ritc.store_quote_pair','INSERT') quote_insert,
  has_table_privilege(current_user,'ritc.store_quote_pair','UPDATE') quote_update,
  has_table_privilege(current_user,'ritc.store_quote_pair','DELETE') quote_delete,
  has_table_privilege(current_user,'ritc.shop_budget_grant','UPDATE') budget_grant_update,
  has_column_privilege(current_user,'ritc.measurement_consent','withdrawn_at','UPDATE') consent_withdraw_update,
  has_column_privilege(current_user,'ritc.measurement_consent','notice_version','UPDATE') consent_notice_update,
  has_table_privilege(current_user,'ritc.measurement_feedback','INSERT') feedback_insert,
  has_table_privilege(current_user,'ritc.measurement_feedback','DELETE') feedback_delete,
  has_table_privilege(current_user,'ritc.measurement_feedback','UPDATE') feedback_update,
  has_table_privilege(current_user,'ritc.measurement_willing_household','SELECT') willing_select`)).rows[0];
 assert.deepEqual(r.permissions.effectiveColumnAndTableGrants,{quote_select:true,quote_insert:true,quote_update:false,quote_delete:false,budget_grant_update:true,consent_withdraw_update:true,consent_notice_update:false,feedback_insert:true,feedback_delete:true,feedback_update:false,willing_select:true});
 const repo=new HouseholdRepository(app,{allowChildNetwork:false,noticeVersion:'fixture',sessionStatus:new SupabaseSessionVerifier(ids.issuer)});
 const wrong=ids.billingControls.sandbox.householdId;
 r.rls.foreignTenantRetainedRows=await repo.transaction(wrong,async db=>{
  const counts={};for(const table of tables)counts[table]=(await db.query(`SELECT count(*)::int n FROM ritc.${table} WHERE household_id=$1`,[ids.retained.householdId])).rows[0].n;return counts;
 });
 assert.ok(Object.values(r.rls.foreignTenantRetainedRows).every(n=>n===0));
 const probe=async({pool=app,household=ids.retained.householdId,sql,args=[],code})=>{
  const db=await pool.connect();try{await db.query('BEGIN');await db.query("SELECT set_config('app.household_id',$1,true)",[household]);await assert.rejects(()=>db.query(sql,args),e=>e.code===code);}finally{await db.query('ROLLBACK');db.release();}
 };
 await probe({household:wrong,sql:'INSERT INTO ritc.measurement_consent(household_id,consent_id,member_id,notice_version,granted_at) VALUES($1,$2,$3,$4,now())',args:[ids.retained.householdId,randomUUID(),ids.retained.owner.memberId,'pickup-feedback-2026-11-03.v1'],code:'42501'});r.protections.foreignTenantInsertRejected=true;
 await probe({sql:'UPDATE ritc.store_quote_pair SET options=options WHERE household_id=$1',args:[ids.retained.householdId],code:'42501'});r.protections.quoteProofRewriteDenied=true;
 await probe({sql:'DELETE FROM ritc.store_quote_pair WHERE household_id=$1',args:[ids.retained.householdId],code:'42501'});r.protections.quoteProofDeleteDenied=true;
 await probe({sql:'UPDATE ritc.measurement_consent SET notice_version=notice_version WHERE household_id=$1',args:[ids.retained.householdId],code:'42501'});r.protections.consentIdentityRewriteDenied=true;
 await probe({pool:admin,household:ids.withdrawn.householdId,sql:'UPDATE ritc.measurement_consent SET withdrawn_at=NULL WHERE household_id=$1 AND consent_id=$2',args:[ids.withdrawn.householdId,ids.withdrawn.consentId],code:'23514'});r.protections.withdrawnConsentResurrectionRejected=true;
 const feedbackInsert='INSERT INTO ritc.measurement_feedback(household_id,feedback_id,shop_id,eligible_week,consent_id,member_id,consent_version,outcome,baseline,comparison,recorded_at) VALUES($1,$2,$3,$4,$5,$6,$7,\'already_knew\',\'list\',\'different\',now())';
 const args=[ids.retained.householdId,randomUUID(),ids.retained.measurementShopId,ids.retained.eligibleWeek,ids.retained.consentId,ids.retained.owner.memberId,'pickup-feedback-2026-11-03.v1'];
 await probe({sql:feedbackInsert,args,code:'23505'});r.protections.secondCanonicalResponseRejected=true;
 await probe({sql:feedbackInsert,args:[args[0],randomUUID(),args[2],'2000-W01',...args.slice(4)],code:'23514'});r.protections.clientChosenEligibleWeekRejected=true;
 const aggregate=async household=>(await repo.transaction(household,db=>db.query('SELECT count(*)::int n FROM ritc.measurement_willing_household'))).rows[0].n;
 r.willing.retained=await aggregate(ids.retained.householdId);assert.equal(r.willing.retained,1);
 for(const [kind,control] of Object.entries(ids.billingControls)){r.willing[kind]=await aggregate(control.householdId);assert.equal(r.willing[kind],control.expectedWilling,kind);}
 r.willing.erased=await aggregate(ids.erased.householdId);assert.equal(r.willing.erased,0);
 // Recreate only the fixture signing authority. Real exact-session, active member,
 // existing trusted-device row, household RLS and service read methods remain active.
 // This uses the supported trusted-device repository context, not restored raw tokens.
 const {publicKey,privateKey}=await generateKeyPair('ES256'),jwk=await exportJWK(publicKey);jwk.kid='restored019';
 const verifier=new JWTIdentityVerifier({issuer:ids.issuer,audience:'authenticated',jwksUrl:ids.issuer+'/keys'},createLocalJWKSet({keys:[jwk]}));
 const quotes=new SharedStoreQuotes(repo),measurement=new HouseholdMeasurement(repo);
 const run=async(actor,household,fn)=>{
  const token=await new SignJWT({session_id:actor.session}).setProtectedHeader({alg:'ES256',kid:jwk.kid}).setIssuer(ids.issuer).setSubject(actor.subject).setAudience('authenticated').setIssuedAt().setExpirationTime('1h').sign(privateKey);
  const identity=await verifier.verify(token);
  const device=(await admin.query('SELECT device_id FROM ritc.device WHERE member_id=$1 AND session_id=$2 AND revoked_at IS NULL LIMIT 1',[actor.memberId,actor.session])).rows[0];assert.ok(device);
  return repo.authorized(household,{identity,trustedDeviceId:device.device_id},fn);
 };
 const h=ids.retained.householdId;
 const owner=await run(ids.retained.owner,h,ctx=>quotes.read(ctx,ids.retained.quoteShopId,null));assert.equal(owner.currentBasis.branch,'B1');
 const reader=await run(ids.retained.reader,h,ctx=>quotes.read(ctx,ids.retained.quoteShopId,null));assert.equal(reader.grantRevision,1);
 await assert.rejects(()=>run(ids.retained.denied,h,ctx=>quotes.read(ctx,ids.retained.quoteShopId,null)),e=>e.code==='unavailable');
 await assert.rejects(()=>run(ids.billingControls.sandbox.owner,h,ctx=>quotes.read(ctx,ids.retained.quoteShopId,null)),e=>e.code==='unavailable');
 const feedback=await run(ids.retained.owner,h,ctx=>measurement.read(ctx,ids.retained.measurementShopId));assert.equal(feedback.feedback.feedbackId,ids.retained.feedbackId);assert.equal(feedback.feedback.incrementalBenefit,0);
 const off=ids.billingControls.noConsent;assert.equal((await run(off.owner,off.householdId,ctx=>measurement.status(ctx))).consent,null);
 assert.equal((await run(ids.withdrawn.owner,ids.withdrawn.householdId,ctx=>measurement.status(ctx))).consent,null);
 r.runtime={retainedShopperQuoteRead:true,retainedBudgetAdultRead:true,ungrantedAndForeignDenied:true,canonicalFeedbackRead:true,billingDidNotCreateConsent:true,withdrawnConsentAbsent:true,fixtureSigningAuthority:true,actualExactSessionAndTrustedDeviceAuthorization:true};

 return r;
}
