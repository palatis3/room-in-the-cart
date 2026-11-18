// Destructive only to databases this process creates on an explicit local test server.
import assert from 'node:assert/strict';
import pg from 'pg';
import {mkdtemp,mkdir,readFile,readdir,copyFile,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {createHash,randomUUID} from 'node:crypto';
import {migrate} from './migrate.mjs';
const connection=process.env.TEST_ADMIN_DATABASE_URL;
const owner=new pg.Client({connectionString:connection,connectionTimeoutMillis:5000});
const params=owner.connectionParameters;
assert(connection&&['127.0.0.1','localhost','::1'].includes(params.host)&&params.database.startsWith('ritc_'),'Explicit loopback disposable ritc_ database required');
await owner.connect();
const directory=fileURLToPath(new URL('../migrations/',import.meta.url));
const files=(await readdir(directory)).filter(n=>/^\d+.*\.sql$/.test(n)).sort();
const checksums=Object.fromEntries(await Promise.all(files.map(async n=>[n,createHash('sha256').update(await readFile(join(directory,n))).digest('hex')])));
async function seed(db,through){
 const h=randomUUID(),m=randomUUID(),shop=randomUUID(),device=randomUUID(),window=randomUUID(),lot=randomUUID();
 await db.query('INSERT INTO ritc.household(household_id,label) VALUES($1,$2)',[h,'Historical fixture']);
 await db.query("INSERT INTO ritc.member(household_id,member_id,issuer,subject,alias,kind,state,organizer,can_contribute) VALUES($1,$2,'fixture',$2::uuid::text,'Adult','adult','active',true,true)",[h,m]);
 await db.query("INSERT INTO ritc.shop(household_id,shop_id,shopper_id,quote) VALUES($1,$2,$3,'{}')",[h,shop,m]);
 await db.query("INSERT INTO ritc.device(household_id,device_id,member_id,token_hash,session_id) VALUES($1,$2,$3,$4,'fixture')",[h,device,m,'a'.repeat(64)]);
 await db.query("INSERT INTO ritc.replay_window(household_id,window_id,member_id,device_id,issued_at,expires_at) VALUES($1,$2,$3,$4,now(),now()+interval '1 hour')",[h,window,m,device]);
 const operation=async(id,revision,standalone=false)=>{
  const columns=through>=51?',authority_scope,pantry_grant_epoch':'';
  const values=through>=51?(standalone?",'household_pantry',0":",'shop',NULL"):'';
  await db.query(`INSERT INTO ritc.operation(household_id,operation_id,actor_id,device_id,client_key,window_id,kind,shop_id,payload_digest,response_scope${columns}) VALUES($1,$2,$3,$4,$2,$5,'pantry.observe',$6,$7,$8${values})`,[h,id,m,device,window,standalone?null:shop,'b'.repeat(64),standalone?'pantry':'shopper']);
  await db.query('INSERT INTO ritc.operation_response VALUES($1,$2,$3)',[h,id,{pantryRevision:revision}]);
 };
 await operation(lot,1);
 await db.query("INSERT INTO ritc.pantry_lot(household_id,lot_id,origin_shop_id,location,food_name,exclusion_tags,actor_id,operation_id) VALUES($1,$2,$3,'pantry','Wraps','{}',$4,$2)",[h,lot,shop,m]);
 for(const [revision,count] of [[2,8],[3,5]]){
  const id=randomUUID();await operation(id,revision);
  await db.query("INSERT INTO ritc.pantry_event(household_id,lot_id,shop_id,operation_id,actor_id,kind,pantry_revision,confirmed_at,quantity) VALUES($1,$2,$3,$4,$5,'observe',$6,'2026-11-01T12:00:00Z',$7)",[h,lot,shop,id,m,revision,{amount:{numerator:count,denominator:1},unit:'count',originalLiteral:String(count)}]);
 }
 if(through>=51){
  const id=randomUUID(),correction=randomUUID();await operation(id,4,true);await operation(correction,5,true);
  await db.query("INSERT INTO ritc.pantry_lot(household_id,lot_id,origin_shop_id,location,food_name,exclusion_tags,actor_id,operation_id) VALUES($1,$2,NULL,'fridge','Limes','{}',$3,$2)",[h,id,m]);
  for(const [event,revision,count,previous] of [[id,4,3,null],[correction,5,0,id]])await db.query("INSERT INTO ritc.pantry_event(household_id,lot_id,shop_id,operation_id,actor_id,kind,pantry_revision,confirmed_at,quantity,predecessor_observation_id) VALUES($1,$2,NULL,$3,$4,'observe',$5,'2026-11-01T13:00:00Z',$6,$7)",[h,id,event,m,revision,{amount:{numerator:count,denominator:1},unit:'count',originalLiteral:String(count)},previous]);
 }
 await db.query('UPDATE ritc.household SET pantry_revision=$2 WHERE household_id=$1',[h,through>=51?5:3]);
 const price={id:randomUUID(),sourceRevision:{sourceId:randomUUID(),revision:1,shopRevision:1,authorityEpoch:1},price:{kind:'exact',minor:550}};
 await db.query("INSERT INTO ritc.price_observation(household_id,observation_id,shop_id,actor_id,record,observed_at) VALUES($1,$2,$3,$4,$5,'2026-11-01T12:00:00Z')",[h,price.id,shop,m,price]);
 return {h,m,shop,price};
}
const results=[];
try{
 for(const history of [{name:'049',through:49},{name:'051',through:51},{name:'051-plus-057',through:51,price:true}]){
  const database='ritc_upgrade_'+randomUUID().replaceAll('-','');const url=new URL(connection);url.pathname='/'+database;
  const scratch=await mkdtemp(join(tmpdir(),'ritc-household-upgrade-'));let db,created=false;
  try{
   await owner.query('CREATE DATABASE "'+database+'"');created=true;
   db=new pg.Client({connectionString:url.toString()});await db.connect();
   await db.query('CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz); CREATE TABLE auth.sessions(id uuid PRIMARY KEY,user_id uuid NOT NULL,not_after timestamptz)');
   await mkdir(join(scratch,'scripts'));await mkdir(join(scratch,'migrations'));
   await copyFile(new URL('./migrate.mjs',import.meta.url),join(scratch,'scripts','migrate.mjs'));
   await symlink(fileURLToPath(new URL('../node_modules/',import.meta.url)),join(scratch,'node_modules'));
   const prior=files.filter(n=>Number(n.slice(0,3))<=history.through||(history.price&&n.startsWith('057')));
   for(const n of prior)await copyFile(join(directory,n),join(scratch,'migrations',n));
   const baseline=await import(pathToFileURL(join(scratch,'scripts','migrate.mjs')).href);await baseline.migrate(url.toString());
   const seeded=await seed(db,history.through);
   const read=()=>db.query('SELECT operation_id,lot_id,pantry_revision,quantity,confirmed_at'+(history.through>=51?',predecessor_observation_id':'')+' FROM ritc.pantry_event ORDER BY pantry_revision');
   const before=(await read()).rows;
   const applied=(await db.query('SELECT version,checksum,applied_at FROM public.ritc_schema_migration ORDER BY version')).rows;
   await migrate(url.toString());await migrate(url.toString());
   const registry=(await db.query('SELECT version,checksum,applied_at FROM public.ritc_schema_migration ORDER BY version')).rows;
   assert.deepEqual(registry.map(r=>[r.version,r.checksum]),files.map(n=>[n,checksums[n]]));
   for(const row of applied)assert.deepEqual(registry.find(r=>r.version===row.version),row);
   assert.deepEqual((await read()).rows,before);
   assert.equal((await db.query('SELECT count(*)::int n FROM ritc.pantry_event WHERE event_id<>operation_id')).rows[0].n,0);
   assert.equal((await db.query('SELECT count(*)::int n FROM ritc.pantry_batch')).rows[0].n,history.through>=51?5:3);
   assert.deepEqual((await db.query('SELECT record FROM ritc.price_observation WHERE household_id=$1',[seeded.h])).rows[0].record,seeded.price);
   await assert.rejects(db.query('INSERT INTO ritc.price_observation(household_id,observation_id,shop_id,actor_id,record,observed_at) VALUES($1,$2,$3,$4,$5,now())',[seeded.h,randomUUID(),seeded.shop,seeded.m,seeded.price]),e=>e.code==='23505');
   for(const table of ['meal_preference_profile','meal_preference_write_key','staple_settings','staple_group','staple_purchase','pantry_batch','shared_cook','household_meal_feedback','receipt_source_key','retired_receipt_line','household_receipt_line','receipt_submission_line','tonight_recipe','tonight_choice']){
    const r=(await db.query('SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid=$1::regclass',['ritc.'+table])).rows[0];assert(r.relrowsecurity&&r.relforcerowsecurity,table);
   }
   const chain=[['privacy_erase_extension','privacy_erase_before_tonight'],['privacy_erase_before_tonight','privacy_erase_before_household_receipts'],['privacy_erase_before_household_receipts','privacy_erase_before_meal_feedback'],['privacy_erase_before_meal_feedback','privacy_erase_before_cook_completion'],['privacy_erase_before_cook_completion','privacy_erase_before_staples'],['privacy_erase_before_staples','privacy_erase_before_meal_preferences']];
   for(const [fn,priorFn] of chain){const r=(await db.query('SELECT pg_get_functiondef($1::regprocedure) body',['ritc.'+fn+'(uuid,uuid)'])).rows[0];assert(r.body.includes(priorFn),fn);}
   results.push({history:history.name,priorMigrations:prior.length,finalMigrations:registry.length,physicalEventsPreserved:before.length,immutablePricePreserved:true,migrationsIdempotent:true,erasureChainPreserved:true});
  }finally{await db?.end();if(created)await owner.query('DROP DATABASE "'+database+'"');await rm(scratch,{recursive:true,force:true});}
 }
 console.log(JSON.stringify({passed:true,results,migrationChecksums:checksums},null,2));
}finally{await owner.end();}
