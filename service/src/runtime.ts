import type { PoolConfig } from 'pg';
import type { IncomingMessage } from 'node:http';
import { isIP } from 'node:net';
import { BillingService } from './billing/service.js';
import { appleGatewayFromEnvironment } from './billing/apple.js';
import { Pool, assertRuntimeRole } from './database.js';
import { JWTIdentityVerifier, DenyIdentityVerifier, SupabaseSessionVerifier } from './auth.js';
import { HouseholdRepository } from './repository.js';
import { createHTTPServer } from './http.js';
import { BrowserAuthService, SupabaseEmailOTPProvider } from './browser-auth.js';
import { PrivacyService } from './privacy.js';

/** Trust Vercel's overwritten edge metadata only inside its deployed runtime.
 * https://vercel.com/docs/headers/request-headers#x-vercel-forwarded-for
 * No header supplied by a direct local HTTP caller establishes client identity.
 */
export function deploymentClientAddress(environment: NodeJS.ProcessEnv): ((request: IncomingMessage) => string | undefined) | undefined {
  if (environment.VERCEL !== '1') return undefined;
  return request => {
    const address = request.headers['x-vercel-forwarded-for'];
    return typeof address === 'string' && !address.includes('%') && isIP(address) !== 0 ? address : undefined;
  };
}

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
    let browserAuth: BrowserAuthService | undefined;
    if (environment.EMAIL_OTP_ENABLED === 'true') {
      if (!configured || !webOrigin || !environment.SUPABASE_URL || !environment.SUPABASE_PUBLISHABLE_KEY || !environment.BFF_TOKEN_ENCRYPTION_KEY) {
        throw new Error('Enabled email sign-in requires complete provider and encryption configuration');
      }
      browserAuth = new BrowserAuthService(repository, verifier,
        new SupabaseEmailOTPProvider({ url: environment.SUPABASE_URL, publicKey: environment.SUPABASE_PUBLISHABLE_KEY }),
        { encryptionKey: environment.BFF_TOKEN_ENCRYPTION_KEY });
    }
    const clientAddress = deploymentClientAddress(environment);
    // Free responsibility preview, existing status receipts and household exit
    // do not depend on an account-deletion provider. The default service keeps
    // accepting new deletion jobs disabled until a reviewed gateway and numeric
    // retention policy are explicitly supplied by the deployment owner.
    const privacy = new PrivacyService(repository);
    const server = createHTTPServer({ repository, verifier, billing: new BillingService(appleGatewayFromEnvironment(environment)),
      privacy,
      ...(webOrigin ? { webOrigin } : {}), ...(browserAuth ? { browserAuth } : {}), ...(clientAddress ? { clientAddress } : {}) });
    server.requestTimeout = 15_000;
    server.headersTimeout = 10_000;
    return { server, pool };
  } catch (error) {
    await pool.end();
    throw error;
  }
}
