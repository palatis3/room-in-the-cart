import {createHash} from 'node:crypto';

// UUIDv5 within the occurrence namespace. Scoped recipe copies can legitimately
// reuse every ingredient, binding and named-group UUID of another dinner.
export function reviewedID(occurrence:string,...parts:(string|number)[]){
  const hash=createHash('sha1').update(Buffer.from(occurrence.replaceAll('-',''),'hex')).update(JSON.stringify(parts)).digest();
  hash[6]=((hash[6]??0)&0x0f)|0x50;hash[8]=((hash[8]??0)&0x3f)|0x80;
  const hex=hash.toString('hex',0,16);
  return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
}
