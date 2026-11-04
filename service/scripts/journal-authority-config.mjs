import {constants} from 'node:fs';
import {open} from 'node:fs/promises';
import pg from 'pg';
import {z} from 'zod';

export const journalDatabaseSchema=z.object({host:z.string().min(1).max(300),port:z.number().int().min(1).max(65535),
 database:z.string().min(1).max(63),user:z.string().min(1).max(63),password:z.string().max(4096).optional(),
 ca:z.string().min(1).max(262144).optional()}).strict();

export async function readPrivateFile(path,maxBytes){
 if(!path)throw Error('Private file path required');
 const file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW);
 try{
  const stat=await file.stat();
  if(!stat.isFile()||stat.size>maxBytes||stat.uid!==process.getuid?.()||(stat.mode&0o077)!==0)throw Error('Owner-only regular file required');
  return await file.readFile();
 }finally{await file.close();}
}

export function journalDatabase(database,applicationName){
 const {host,port,user,password,ca}=database;
 const local=host.startsWith('/')||['127.0.0.1','localhost','::1'].includes(host);
 if(!ca&&!local)throw Error('Pinned CA required for remote journal database');
 const pool=new pg.Pool({host,port,user,password:()=>password??'',database:database.database,
  ssl:ca?{ca,rejectUnauthorized:true}:false,options:'-c search_path=pg_catalog',application_name:applicationName,
  max:4,connectionTimeoutMillis:2000,idleTimeoutMillis:5000,allowExitOnIdle:true});
 pool.on('error',()=>console.error(JSON.stringify({event:'journal_database_connection_error'})));
 return pool;
}
