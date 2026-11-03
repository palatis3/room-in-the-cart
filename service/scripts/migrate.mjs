import pg from 'pg';
import { readFile,readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
export async function migrate(connectionString) {
  if(!connectionString)throw new Error('MIGRATION_DATABASE_URL is required; never use the migration role to serve requests');
  const client=new pg.Client({connectionString});await client.connect();
  try {
    await client.query('SELECT pg_advisory_lock(737462120)');
    await client.query('CREATE TABLE IF NOT EXISTS public.ritc_schema_migration(version text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())');
    await client.query('REVOKE ALL ON public.ritc_schema_migration FROM PUBLIC');
    await client.query('ALTER TABLE public.ritc_schema_migration ENABLE ROW LEVEL SECURITY');
    const directory=new URL('../migrations/',import.meta.url);
    for(const name of (await readdir(directory)).filter(n=>/^\d+.*\.sql$/.test(n)).sort()) {
      const sql=await readFile(new URL(name,directory),'utf8'),checksum=createHash('sha256').update(sql).digest('hex');
      const prior=(await client.query('SELECT checksum FROM public.ritc_schema_migration WHERE version=$1',[name])).rows[0];
      if(prior){if(prior.checksum!==checksum)throw new Error('Previously applied migration changed: '+name);continue;}
      await client.query('BEGIN');try{await client.query(sql);await client.query('INSERT INTO public.ritc_schema_migration(version,checksum) VALUES($1,$2)',[name,checksum]);await client.query('COMMIT');}catch(e){await client.query('ROLLBACK');throw e;}
    }
  }finally{await client.query('SELECT pg_advisory_unlock(737462120)');await client.end();}
}
if(process.argv[1]===fileURLToPath(import.meta.url))await migrate(process.env.MIGRATION_DATABASE_URL);
