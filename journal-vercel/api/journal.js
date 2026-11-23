import {createPrivateKey,createPublicKey} from 'node:crypto';
import {attachDatabasePool} from '@vercel/functions';
import {journalAuthorityConfigSchema,journalDatabase} from '../../service/scripts/journal-authority-config.mjs';
import {journalAuthorityHandler} from '../../service/dist/privacy-journal-https.js';
import {createPostgresJournalAuthority} from '../../service/dist/privacy-journal-pg-authority.js';

function createHandler(rawConfiguration) {
  const config=journalAuthorityConfigSchema.parse(JSON.parse(rawConfiguration));
  const {pins,writerToken}=config;
  const writerPublicKey=createPublicKey(config.writerPublicKey);
  const authorityPrivateKey=createPrivateKey(config.authorityPrivateKey);
  const databases=[config.checkpointDatabase,config.recordDatabase];
  if(process.env.VERCEL==='1'&&databases.some(database=>!database.ca||!database.password)) {
    throw Error('Verified PostgreSQL TLS and separate login credentials are required');
  }

  let initialization;
  function loadPorts() {
    if(!initialization) {
      initialization=(async()=>{
        const pools=[];
        try {
          for(const database of databases) {
            const pool=journalDatabase(database,'ritc-journal-vercel',{max:1});
            pools.push(pool);
            attachDatabasePool(pool);
          }
          const [checkpointPool,recordPool]=pools;
          return await createPostgresJournalAuthority({pins,writerPublicKey,authorityPrivateKey,checkpointPool,recordPool});
        } catch(error) {
          await Promise.allSettled(pools.map(pool=>pool.end()));
          throw error;
        }
      })().catch(error=>{
        initialization=undefined;
        console.error(JSON.stringify({event:'journal_authority_initialization_error'}));
        throw error;
      });
    }
    return initialization;
  }

  return journalAuthorityHandler({pins,writerToken,loadPorts});
}

let handler;
try {
  handler=createHandler(process.env.JOURNAL_AUTHORITY_JSON);
} catch {
  console.error(JSON.stringify({event:'journal_authority_configuration_error'}));
  handler=(_req,res)=>{
    res.writeHead(503,{'Content-Type':'application/json','Cache-Control':'no-store'});
    res.end('{"error":"journal_unavailable"}');
  };
}

export default async function journal(req,res) {
  return handler(req,res);
}
