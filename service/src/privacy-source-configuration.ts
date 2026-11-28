import {z} from 'zod';
import {durableJournalPinsSchema} from './privacy-journal-durable.js';
import {journalBearerTokenSchema} from './privacy-journal-http-common.js';

const name=z.string().min(1).max(63);
const pem=z.string().min(1).max(262144);
const oid=z.string().regex(/^[1-9][0-9]{0,9}$/);
export const sourceObserverConfigurationSchema=z.object({
  connection:z.object({
   host:z.string().min(1).max(300),port:z.number().int().min(1).max(65535),database:name,user:z.string().min(1).max(84),
   password:z.string().max(16384).optional(),tls:z.object({ca:pem,servername:name}).strict().optional(),
  }).strict(),databaseOid:oid,observerRole:name.optional(),observerRoleOid:oid,ownerRole:name,ownerRoleOid:oid,
 }).strict();
export const sourceGatewayConfigurationSchema=z.object({
 pins:durableJournalPinsSchema,authorityPublicKey:pem.startsWith('-----BEGIN PUBLIC KEY-----'),
 applicationToken:journalBearerTokenSchema,operationsToken:journalBearerTokenSchema,observer:sourceObserverConfigurationSchema,
}).strict();
