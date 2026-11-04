import {createPublicKey} from 'node:crypto';
import {z} from 'zod';
import {MAX_JOURNAL_BYTES} from '../dist/privacy-journal-limits.js';
import {readPrivateFile} from './journal-authority-config.mjs';

export const publicKey=z.string().max(8192).regex(/^-----BEGIN PUBLIC KEY-----\r?\n/);
export const publicPins=z.object({pins:z.unknown(),writerPublicKey:publicKey,authorityPublicKey:publicKey}).strict();
const archiveSettings=publicPins.extend({journalPath:z.string().min(1),sealPath:z.string().min(1),incomingLinkPath:z.string().min(1).optional()});
export const windowSettings=z.object({
 startScopeDigest:z.string(),terminalSealDigest:z.string(),segments:z.array(archiveSettings).min(1),
}).strict();
export const jsonFile=async(path,maxBytes=1048576)=>JSON.parse(await readPrivateFile(path,maxBytes));

export async function readArchive(segment){
 return {
  pins:segment.pins,writerPublicKey:createPublicKey(segment.writerPublicKey),authorityPublicKey:createPublicKey(segment.authorityPublicKey),
  bytes:await readPrivateFile(segment.journalPath,MAX_JOURNAL_BYTES),seal:await jsonFile(segment.sealPath,8192),
  ...(segment.incomingLinkPath?{incomingLink:await jsonFile(segment.incomingLinkPath,8192)}:{}),
 };
}
export async function* readArchives(segments){
 for(const segment of segments)yield await readArchive(segment);
}
