// Proposal only: one real shared fixture journal, serialized test-file processes.
import{randomUUID,generateKeyPairSync,createHash}from'node:crypto';import{mkdtemp,mkdir,chmod,writeFile,readFile,lstat}from'node:fs/promises';import{createLocalPrivacyJournal}from'../dist/privacy-journal.js';
export async function preparePrivacyJournalFixture(source,root,privateRoot='/tmp'){
 await mkdir(root,{recursive:true,mode:0o700});await chmod(root,0o700);
 if((await source.query('SELECT 1 FROM ritc.privacy_journal_origin')).rowCount)throw Error('Fixture origin already provisioned; refuse replacement');
 const lineage=randomUUID(),schemaDigest=createHash('sha256').update(JSON.stringify((await source.query('SELECT version,checksum FROM public.ritc_schema_migration ORDER BY version')).rows)).digest('hex'),configurationId='synthetic-integration-approved-fixture-set-v1';await source.query('INSERT INTO ritc.privacy_journal_origin(lineage,schema_digest,configuration_id) VALUES($1,$2,$3)',[lineage,schemaDigest,configurationId]);
 const keys=await mkdtemp(privateRoot+'/ritc-integration-journal-private-');await chmod(keys,0o700);const{privateKey}=generateKeyPairSync('ed25519'),privateKeyPath=keys+'/writer.pem';await writeFile(privateKeyPath,privateKey.export({format:'pem',type:'pkcs8'}),{mode:0o600});
 const configuration={directory:root+'/journal',checkpointPath:root+'/head.json',privateKeyPath,keyId:'synthetic-fixture-key',lineage,schemaDigest,configurationId},path=root+'/configuration.json';await writeFile(path,JSON.stringify(configuration),{mode:0o600});const initial=await createLocalPrivacyJournal({source,...configuration});await initial.close();return path;
}
export async function openPrivacyJournalFixture(source,path=process.env.PRIVACY_JOURNAL_TEST_CONFIGURATION){if(!path)throw Error('Real synthetic journal fixture configuration required; no no-op port');const s=await lstat(path);if(!s.isFile()||s.isSymbolicLink()||(s.mode&0o077)!==0||s.uid!==process.getuid())throw Error('Owner-only journal fixture configuration required');return createLocalPrivacyJournal({source,...JSON.parse(await readFile(path,'utf8'))});}
export async function fencePrivacyJournalFixture(source,path){const writer=await openPrivacyJournalFixture(source,path);try{return await writer.fence();}finally{await writer.close();}}

// These tests stop at acceptance or profile erasure. Leave their journal and
// erasure evidence intact, but do not let an expired lease offer that identity
// to a later test's unrelated provider. Other jobs keep their queue positions.
export function deferProfileOnlyDeletion(admin,jobId){
 return admin.query("UPDATE ritc.privacy_job SET next_at='infinity' WHERE job_id=$1 AND state<>'complete'",[jobId]);
}
