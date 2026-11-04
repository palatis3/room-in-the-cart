import {createPrivateKey,createPublicKey} from 'node:crypto';
import {constants} from 'node:fs';
import {open} from 'node:fs/promises';
import {createServer} from 'node:https';
import pg from 'pg';
import {z} from 'zod';
import {createPostgresJournalAuthority} from '../dist/privacy-journal-pg-authority.js';
import {journalAuthorityHandler} from '../dist/privacy-journal-https.js';

const database=z.object({host:z.string().min(1).max(300),port:z.number().int().min(1).max(65535),
 database:z.string().min(1).max(63),user:z.string().min(1).max(63),password:z.string().max(4096).optional(),
 ca:z.string().min(1).max(262144).optional()}).strict();
const configurationSchema=z.object({pins:z.unknown(),writerToken:z.string(),writerPublicKey:z.string().min(1).max(8192),
 authorityPrivateKey:z.string().min(1).max(8192),checkpointDatabase:database,recordDatabase:database,
 listen:z.object({host:z.string().min(1).max(255),port:z.number().int().min(0).max(65535)}).strict(),
 tls:z.object({key:z.string().min(1).max(65536),cert:z.string().min(1).max(262144)}).strict()}).strict();

async function readConfiguration(path){
 if(!path)throw Error('Configuration path required');
 const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{
  const stat=await file.stat();
  if(!stat.isFile()||stat.size>1048576||stat.uid!==process.getuid?.()||(stat.mode&0o077)!==0)throw Error('Owner-only authority configuration required');
  return configurationSchema.parse(JSON.parse(await file.readFile('utf8')));
 }finally{await file.close();}
}

function postgres(database){
 const {host,port,user,password,ca}=database;
 const local=host.startsWith('/')||['127.0.0.1','localhost','::1'].includes(host);
 if(!ca&&!local)throw Error('Pinned CA required for remote journal database');
 const pool=new pg.Pool({host,port,user,password:()=>password??'',database:database.database,
  ssl:ca?{ca,rejectUnauthorized:true}:false,options:'-c search_path=pg_catalog',application_name:'ritc-journal-authority',
  max:4,connectionTimeoutMillis:2000,idleTimeoutMillis:5000,allowExitOnIdle:true});
 pool.on('error',()=>console.error(JSON.stringify({event:'journal_authority_database_connection_error'})));
 return pool;
}

async function run(){
 const config=await readConfiguration(process.argv[2]);
 if(!/^-----BEGIN PUBLIC KEY-----\r?\n/.test(config.writerPublicKey))throw Error('Writer public key required');
 const checkpointPool=postgres(config.checkpointDatabase);
 let recordPool;
 try{
  recordPool=postgres(config.recordDatabase);
  const ports=await createPostgresJournalAuthority({pins:config.pins,writerPublicKey:createPublicKey(config.writerPublicKey),
   authorityPrivateKey:createPrivateKey(config.authorityPrivateKey),checkpointPool,recordPool});
  const server=createServer({...config.tls,minVersion:'TLSv1.2',headersTimeout:5000,requestTimeout:15000,keepAliveTimeout:3000},
   journalAuthorityHandler({pins:config.pins,writerToken:config.writerToken,...ports}));
  server.maxConnections=32;
  await new Promise((resolve,reject)=>{
   server.once('error',reject);server.listen(config.listen,()=>{server.removeListener('error',reject);resolve();});
  });
  console.log(JSON.stringify({event:'journal_authority_listening',port:server.address().port}));
  await new Promise(resolve=>{
   const stop=()=>{process.removeListener('SIGINT',stop);process.removeListener('SIGTERM',stop);server.close(resolve);};
   process.once('SIGINT',stop);process.once('SIGTERM',stop);
  });
 }finally{await Promise.all([checkpointPool.end(),recordPool?.end()]);}
}

try{await run();}
catch{console.error(JSON.stringify({event:'journal_authority_start_failed'}));process.exitCode=1;}
