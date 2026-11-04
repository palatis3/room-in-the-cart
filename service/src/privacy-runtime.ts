import {createPrivateKey,createPublicKey} from 'node:crypto';
import {z} from 'zod';
import type {Database} from './database.js';
import {privacyPhase,withPrivacyClient} from './privacy-call.js';
import {journalHash} from './privacy-journal.js';
import {createDurablePrivacyJournal,durableJournalPinsSchema} from './privacy-journal-durable.js';
import type {JournalCall,JournalCapacity} from './privacy-journal-durable-contract.js';
import {createHTTPSJournalAuthority} from './privacy-journal-https.js';
import {createPostgresCommittedSource} from './privacy-journal-pg-source.js';
import {MAX_JOURNAL_BYTES,MAX_JOURNAL_RECORDS} from './privacy-journal-limits.js';
import {SupabaseAccountDeletionProvider,validateDeletionPolicy,type DeletionPolicy} from './privacy.js';

const name=z.string().min(1).max(63);
const pem=z.string().min(1).max(262144);
const oid=z.string().regex(/^[1-9][0-9]{0,9}$/);
const reference=z.string().trim().min(1).max(200);
const configurationSchema=z.object({
 version:z.literal(1),
 pins:durableJournalPinsSchema,
 writerPrivateKey:pem.startsWith('-----BEGIN PRIVATE KEY-----'),
 authorityPublicKey:pem.startsWith('-----BEGIN PUBLIC KEY-----'),
 authority:z.object({origin:z.string().max(512),writerToken:z.string().max(256),ca:pem.optional()}).strict(),
 observer:z.object({
  connection:z.object({
   host:z.string().min(1).max(300),port:z.number().int().min(1).max(65535),database:name,user:name,
   password:z.string().max(16384).optional(),tls:z.object({ca:pem,servername:name}).strict().optional(),
  }).strict(),databaseOid:oid,observerRoleOid:oid,ownerRole:name,ownerRoleOid:oid,
 }).strict(),
 retentionPolicy:z.unknown(),retentionApprovalReference:reference,restoreApprovalReference:reference,
}).strict();
const bindingSchema=z.object({
 lineage:z.string(),schemaDigest:z.string(),configurationId:z.string(),sourceIdentity:z.string(),
 database:name,databaseOid:oid,observerRoleOid:oid,fenced:z.boolean(),
}).strict();

type PrivacyRole='application'|'operations';
type PrivacyState='disabled'|'configuration_required'|'source_unavailable'|'authority_unavailable'|'blocked'|'ready';
type PrivacyHealth={state:PrivacyState;capacity:(JournalCapacity&{nearLimit:boolean})|null};

export function privacyDeploymentConfigurationId(input:{
 issuer:string;policy:DeletionPolicy;retentionApprovalReference:string;restoreApprovalReference:string;
}):string {
 return journalHash({version:1,issuer:input.issuer,policy:validateDeletionPolicy(input.policy),
  retentionApprovalReference:reference.parse(input.retentionApprovalReference),
  restoreApprovalReference:reference.parse(input.restoreApprovalReference)});
}

function unavailableRuntime(state:'disabled'|'configuration_required'){
 return {options:undefined,health:async():Promise<PrivacyHealth>=>({state,capacity:null}),close:async()=>{}};
}

/** Shared release composition. Faults here leave the rest of the service available. */
export function createPrivacyRuntime(pool:Database,environment:NodeJS.ProcessEnv,role:PrivacyRole){
 const flag=environment[role==='application'?'PRIVACY_DELETION_ACCEPTANCE':'PRIVACY_DELETION_PROCESSING'];
 if(flag===undefined||flag==='false')return unavailableRuntime('disabled');
 if(flag!=='true')return unavailableRuntime('configuration_required');

 let source:ReturnType<typeof createPostgresCommittedSource>|undefined;
 let authority:ReturnType<typeof createHTTPSJournalAuthority>|undefined;
 try{
  const raw=environment.PRIVACY_DELETION_JSON;
  if(!raw||Buffer.byteLength(raw)>1024*1024)throw Error('Bounded privacy configuration required');
  const config=configurationSchema.parse(JSON.parse(raw));
  const {pins,observer}=config;
  const policy=validateDeletionPolicy(config.retentionPolicy);
  const origin=environment.SUPABASE_URL??'';
  const provider=new SupabaseAccountDeletionProvider({url:origin,secretKey:environment.PRIVACY_SUPABASE_ADMIN_KEY??''});
  const issuer=new URL('/auth/v1',origin).href;
  if(role==='application'&&(!environment.JWT_AUDIENCE||environment.JWT_ISSUER!==issuer||
    environment.JWT_JWKS_URL!==issuer+'/.well-known/jwks.json'))throw Error('Application identity issuer mismatch');
  if(environment.JWT_ISSUER!==undefined&&environment.JWT_ISSUER!==issuer)throw Error('Privacy identity issuer mismatch');
  if(pins.configurationId!==privacyDeploymentConfigurationId({issuer,policy,
    retentionApprovalReference:config.retentionApprovalReference,restoreApprovalReference:config.restoreApprovalReference})){
   throw Error('Privacy release configuration mismatch');
  }
  const writerPrivateKey=createPrivateKey(config.writerPrivateKey);
  const authorityPublicKey=createPublicKey(config.authorityPublicKey);
  const {password,tls,...connection}=observer.connection;
  if(environment.VERCEL==='1'&&!tls)throw Error('A pinned observer TLS endpoint is required');
  authority=createHTTPSJournalAuthority({pins,origin:config.authority.origin,writerToken:config.authority.writerToken,
   ...(config.authority.ca?{ca:config.authority.ca}:{})});
  source=createPostgresCommittedSource({...observer,pins,authorityPublicKey,
   connection:{...connection,...(password!==undefined?{password}:{}),...(tls?{tls}:{})},
   applicationName:'ritc-privacy-'+role,maxConnections:1});
  const observerSource=source.source;
  const journal=createDurablePrivacyJournal({pins,privateKey:writerPrivateKey,authorityPublicKey,source:observerSource,...authority});
  const allowed=role==='application'?'ritc_app':'ritc_worker';
  const excluded=role==='application'?'ritc_worker':'ritc_app';
  async function assertSource(call:JournalCall){
   await privacyPhase(call,async phase=>{
     const [binding]=await Promise.all([
      withPrivacyClient(pool,phase,async db=>{
       const {rows}=await db.query(`SELECT ritc.privacy_runtime_binding() AS binding,
        current_user=session_user AND pg_has_role(session_user,$1,'MEMBER') AND NOT pg_has_role(session_user,$2,'MEMBER') AS permitted`,
        [allowed,excluded]);
       if(!rows[0]?.permitted)throw Error('Privacy connection role mismatch');
       return bindingSchema.parse(rows[0].binding);
      }),
      observerSource.readOrigin(phase),
     ]);
     if(binding.fenced||binding.lineage!==pins.lineage||binding.schemaDigest!==pins.schemaDigest||
       binding.configurationId!==pins.configurationId||binding.sourceIdentity!==pins.sourceIdentity||
       binding.database!==connection.database||binding.databaseOid!==observer.databaseOid||
       binding.observerRoleOid!==observer.observerRoleOid)throw Error('Privacy source binding mismatch');
   },3000);
  }
  async function health(call:JournalCall):Promise<PrivacyHealth>{
   try{await assertSource(call);}
   catch{return {state:'source_unavailable',capacity:null};}

   try{
    const value=await privacyPhase(call,phase=>journal.capacity(phase),3000);
    const capacity={...value,nearLimit:value.usedRecords+value.reservedRecords>=MAX_JOURNAL_RECORDS*0.8||
     value.usedBytes+value.reservedBytes>=MAX_JOURNAL_BYTES*0.8};
    return {state:value.mode==='active'&&!value.uncertain&&!journal.isPoisoned()?'ready':'blocked',capacity};
   }catch{return {state:'authority_unavailable',capacity:null};}
  }
  async function available(call:JournalCall){
   const {state,capacity}=await health(call);
   return state==='ready'&&capacity!==null&&capacity.usedRecords+capacity.reservedRecords+2<=MAX_JOURNAL_RECORDS&&
    capacity.usedBytes+capacity.reservedBytes<MAX_JOURNAL_BYTES;
  }
  return {options:{provider,policy,journal:journal.port,available,assertSource,issuer},health,
   async close(){authority?.close();await source?.close();}};
 }catch{
  authority?.close();
  void source?.close().catch(()=>{});
  return unavailableRuntime('configuration_required');
 }
}
