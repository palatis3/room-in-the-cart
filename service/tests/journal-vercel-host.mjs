import {createServer} from 'node:https';
import {readPrivateFile} from '../scripts/journal-authority-config.mjs';

const {listen,tls,...configuration}=JSON.parse(await readPrivateFile(process.argv[2],1048576));
process.env.JOURNAL_AUTHORITY_JSON=JSON.stringify(configuration);
const url=process.env.JOURNAL_AUTHORITY_TEST_ENTRY??new URL('../../journal-vercel/api/journal.js',import.meta.url);
const {default:vercelHandler}=await import(url);
const server=createServer(tls,vercelHandler);
server.listen(listen,()=>console.log(JSON.stringify({event:'journal_authority_listening',port:server.address().port})));
process.once('SIGTERM',()=>server.close());
