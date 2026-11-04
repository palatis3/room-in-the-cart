import {createPrivateKey,createPublicKey} from 'node:crypto';
import {createServer} from 'node:https';
import {z} from 'zod';
import {createPostgresJournalAuthority} from '../dist/privacy-journal-pg-authority.js';
import {journalAuthorityHandler} from '../dist/privacy-journal-https.js';
import {journalDatabase,journalDatabaseSchema,readPrivateFile} from './journal-authority-config.mjs';

const configurationSchema=z.object({pins:z.unknown(),writerToken:z.string(),writerPublicKey:z.string().min(1).max(8192),
 authorityPrivateKey:z.string().min(1).max(8192),checkpointDatabase:journalDatabaseSchema,recordDatabase:journalDatabaseSchema,
 listen:z.object({host:z.string().min(1).max(255),port:z.number().int().min(0).max(65535)}).strict(),
 tls:z.object({key:z.string().min(1).max(65536),cert:z.string().min(1).max(262144)}).strict()}).strict();

async function run(){
 const config=configurationSchema.parse(JSON.parse(await readPrivateFile(process.argv[2],1048576)));
 if(!/^-----BEGIN PUBLIC KEY-----\r?\n/.test(config.writerPublicKey))throw Error('Writer public key required');
 const checkpointPool=journalDatabase(config.checkpointDatabase,'ritc-journal-authority');
 let recordPool;
 try{
  recordPool=journalDatabase(config.recordDatabase,'ritc-journal-authority');
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
