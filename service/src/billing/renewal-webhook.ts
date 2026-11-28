import {createHmac,timingSafeEqual} from 'node:crypto';
import type {IncomingHttpHeaders} from 'node:http';
import {z} from 'zod';
import type {Database} from '../database.js';
import {ServiceError} from '../errors.js';

export function webhookKey(secret:string):Buffer {
  if(!/^whsec_[A-Za-z0-9+/]+={0,2}$/.test(secret))throw Error('Invalid renewal webhook signing secret');
  const key=Buffer.from(secret.slice(6),'base64');
  if(key.length<16||key.toString('base64')!==secret.slice(6))throw Error('Invalid renewal webhook signing secret');
  return key;
}

export async function recordRenewalDelivery(pool:Pick<Database,'query'>,key:Buffer,raw:Buffer,headers:IncomingHttpHeaders,now=Date.now()){
  const id=headers['svix-id'],timestamp=headers['svix-timestamp'],signatures=headers['svix-signature'];
  const unauthorized=()=>new ServiceError(401,'unauthorized','A signed delivery event is required.');
  if(typeof id!=='string'||!/^msg_[A-Za-z0-9_-]{1,150}$/.test(id)||typeof timestamp!=='string'||
     !/^\d{10}$/.test(timestamp)||Math.abs(now/1000-Number(timestamp))>300||typeof signatures!=='string'||signatures.length>2048)
    throw unauthorized();
  const expected=createHmac('sha256',key).update(id+'.'+timestamp+'.').update(raw).digest();
  const valid=signatures.split(' ').some(value=>{
    if(!/^v1,[A-Za-z0-9+/]{43}=$/.test(value))return false;
    const supplied=Buffer.from(value.slice(3),'base64');
    return supplied.length===expected.length&&timingSafeEqual(supplied,expected);
  });
  if(!valid)throw unauthorized();
  let message;
  try{message=JSON.parse(raw.toString('utf8'));}catch{throw new ServiceError(422,'invalid_event','Invalid delivery event.');}
  const record=z.object({type:z.string(),data:z.object({email_id:z.string().uuid(),tags:z.record(z.string(),z.string()).optional()})}).safeParse(message);
  if(!record.success)return;
  const {type,data}=record.data,tag=z.string().uuid().safeParse(data.tags?.renewal_dispatch);
  const outcome=type==='email.sent'?'accepted':type==='email.delivered'?'delivered':
    ['email.bounced','email.complained','email.failed','email.suppressed'].includes(type)?'failed':null;
  if(tag.success&&outcome)await pool.query('SELECT ritc.apply_renewal_delivery($1,$2,$3)',[tag.data,data.email_id,outcome]);
}
