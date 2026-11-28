import {sourceGatewayConfigurationSchema} from '../../service/dist/privacy-source-configuration.js';
import {createGatewayPostgresCommittedSource} from '../../service/dist/privacy-journal-pg-source.js';
import {sourceGatewayHandler} from '../../service/dist/privacy-journal-source-https.js';

function configure(raw){
 if(!raw||Buffer.byteLength(raw)>1024*1024)throw Error('Bounded source configuration required');
 const {pins,authorityPublicKey,applicationToken,operationsToken,observer}=sourceGatewayConfigurationSchema.parse(JSON.parse(raw));
 if(process.env.VERCEL==='1'&&(!observer.connection.tls||!observer.connection.password||!observer.observerRole)){
  throw Error('Pinned PostgreSQL TLS, observer role and separate login required');
 }
 const {source}=createGatewayPostgresCommittedSource({...observer,pins,authorityPublicKey,applicationName:'ritc-source-gateway',maxConnections:1});
 const databaseBinding={database:observer.connection.database,databaseOid:observer.databaseOid,observerRoleOid:observer.observerRoleOid};
 return sourceGatewayHandler({pins,databaseBinding,source,applicationToken,operationsToken});
}
let handler;
try{handler=configure(process.env.JOURNAL_SOURCE_GATEWAY_JSON);}
catch{
 console.error(JSON.stringify({event:'source_gateway_configuration_error'}));
 handler=(_req,res)=>{
  res.writeHead(503,{'Content-Type':'application/json','Cache-Control':'no-store'});
  res.end('{"error":"source_unavailable"}');
 };
}
export default handler;
