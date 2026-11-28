import type {IncomingMessage} from 'node:http';
import {z} from 'zod';

export const journalBearerTokenSchema=z.string().regex(/^[A-Za-z0-9_-]{43}$/).refine(value=>Buffer.from(value,'base64url').toString('base64url')===value);
const oidcTokenSchema=z.string().max(8192).regex(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);

export async function readBoundedJournalJSON(message:IncomingMessage,maxBody:number):Promise<unknown>{
 const declared=message.headers['content-length'];
 if(!declared||!/^\d+$/.test(declared)||Number(declared)>maxBody)throw Error('Bounded journal message required');
 const chunks:Buffer[]=[];let count=0;
 for await(const value of message){
  const chunk=Buffer.isBuffer(value)?value:Buffer.from(value);count+=chunk.length;
  if(count>maxBody)throw Error('Journal message too large');
  chunks.push(chunk);
 }
 if(count!==Number(declared))throw Error('Incomplete journal message');
 return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks)));
}

export async function trustedSourceHeaders(getToken:(()=>Promise<string>)|undefined):Promise<Record<string,string>>{
 if(!getToken)return {};
 const token=oidcTokenSchema.safeParse(await Promise.resolve().then(getToken).catch(()=>undefined));
 if(!token.success)throw Error('Vercel journal identity is unavailable');
 return {'x-vercel-trusted-oidc-idp-token':token.data};
}
