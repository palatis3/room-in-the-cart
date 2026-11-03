import type { PoolConfig } from 'pg';
import { BillingService } from './billing/service.js';
import { appleGatewayFromEnvironment } from './billing/apple.js';
import { Pool, assertRuntimeRole } from './database.js';
import { JWTIdentityVerifier, DenyIdentityVerifier, SupabaseSessionVerifier } from './auth.js';
import { HouseholdRepository } from './repository.js';
import { createHTTPServer } from './http.js';

/** One runtime for the local process and deployed function; never a migration role. */
export function databaseConfiguration(environment: NodeJS.ProcessEnv): PoolConfig {
  if (!environment.DATABASE_URL) throw new Error('DATABASE_URL is required');
  const url = new URL(environment.DATABASE_URL);
  if (!['postgres:', 'postgresql:'].includes(url.protocol)) throw new Error('PostgreSQL URL required');
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  // pg connection-string SSL options replace explicit SSL settings. Remove them
  // so a deployment URL cannot silently disable certificate/hostname verification.
  for (const key of ['ssl', 'sslmode', 'sslcert', 'sslkey', 'sslrootcert']) url.searchParams.delete(key);
  return {
    connectionString: url.toString(), max: 3, connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 5000, allowExitOnIdle: true,
    ...(local ? {} : { ssl: {
      rejectUnauthorized: true,
      ...(environment.DATABASE_CA_PEM ? { ca: environment.DATABASE_CA_PEM } : {}),
    } }),
  };
}

export async function createRuntime(environment: NodeJS.ProcessEnv = process.env) {
  const pool = new Pool(databaseConfiguration(environment));
  pool.on('error', () => { console.error(JSON.stringify({ event: 'database_idle_connection_error' })); });
  try {
    await assertRuntimeRole(pool);
    const { JWT_ISSUER: issuer, JWT_AUDIENCE: audience, JWT_JWKS_URL: jwksUrl, WEB_ORIGIN: webOrigin } = environment;
    const configured = Boolean(issuer && audience && jwksUrl);
    const verifier = configured ? new JWTIdentityVerifier({ issuer: issuer!, audience: audience!, jwksUrl: jwksUrl! }) : new DenyIdentityVerifier();
    const repository = new HouseholdRepository(pool, {
      // Enable only when provider-backed guardian verification and revocation are
      // integrated. An environment flag cannot substitute for that authority.
      allowChildNetwork: false,
      noticeVersion: environment.CONSENT_NOTICE_VERSION ?? '',
      ...(configured ? { sessionStatus: new SupabaseSessionVerifier(issuer!) } : {}),
    });
    const server = createHTTPServer({ repository, verifier, billing: new BillingService(appleGatewayFromEnvironment(environment)), ...(webOrigin ? { webOrigin } : {}) });
    server.requestTimeout = 15_000;
    server.headersTimeout = 10_000;
    return { server, pool };
  } catch (error) {
    await pool.end();
    throw error;
  }
}
