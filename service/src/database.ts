import pg, { type PoolClient } from 'pg';
import { createHash } from 'node:crypto';
export const { Pool }=pg;
export type Database=pg.Pool;
export type Transaction=PoolClient;
export function digest(value:unknown):string { return createHash('sha256').update(canonical(value)).digest('hex'); }
export function canonical(value:unknown):string {
  if(value instanceof Date)return JSON.stringify(value.toISOString());
  if(value===null||typeof value!=='object')return JSON.stringify(value);
  if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
  return '{'+Object.entries(value).sort(([a],[b])=>a.localeCompare(b,'en')).map(([k,v])=>JSON.stringify(k)+':'+canonical(v)).join(',')+'}';
}
export function tokenHash(token:string):string {return createHash('sha256').update(token).digest('hex');}
export async function assertRuntimeRole(pool:Database):Promise<void> {
  const {rows}=await pool.query(`SELECT r.rolsuper,r.rolbypassrls,
    EXISTS(SELECT FROM pg_tables WHERE schemaname='ritc' AND tableowner=current_user) AS owns_tables
    FROM pg_roles r WHERE r.rolname=current_user`);
  if(rows[0]?.rolsuper||rows[0]?.rolbypassrls||rows[0]?.owns_tables) throw new Error('Runtime database role must not own tables, be superuser, or bypass RLS');
}
