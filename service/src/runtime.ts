import type { PoolConfig } from 'pg';
import {createServer,type IncomingMessage,type Server} from 'node:http';
import {serviceAvailability,maintenanceResponse} from './service-availability.js';
import { isIP } from 'node:net';
import { BillingService } from './billing/service.js';
import { appleGatewayFromEnvironment } from './billing/apple.js';
import { Pool, assertRuntimeRole,type Database } from './database.js';
import { JWTIdentityVerifier, DenyIdentityVerifier, SupabaseSessionVerifier } from './auth.js';
import { HouseholdRepository } from './repository.js';
import { createHTTPServer } from './http.js';
import { BrowserAuthService, SupabaseEmailOTPProvider } from './browser-auth.js';
import { PrivacyService } from './privacy.js';
import { createPrivacyRuntime } from './privacy-runtime.js';
import { guardianRuntime } from './guardian-runtime.js';

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

export type ApplicationRuntime =
 | {mode:'maintenance';server:Server;close:()=>Promise<void>;pool?:never}
 | {mode:'serving';server:Server;close:()=>Promise<void>;pool:Database};

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

export async function createRuntime(environment: NodeJS.ProcessEnv = process.env):Promise<ApplicationRuntime> {
  if(serviceAvailability(environment).mode==='maintenance'){
    const server=createServer(maintenanceResponse);
    server.requestTimeout=15_000;server.headersTimeout=10_000;
    return{mode:'maintenance',server,close:async()=>{}};
  }
  const pool = new Pool(databaseConfiguration(environment));
  pool.on('error', () => { console.error(JSON.stringify({ event: 'database_idle_connection_error' })); });
  let guardianPool:Awaited<ReturnType<typeof guardianRuntime>>['pool'];
  let privacyRuntime:ReturnType<typeof createPrivacyRuntime>|undefined;
  try {
    await assertRuntimeRole(pool);
    const { JWT_ISSUER: issuer, JWT_AUDIENCE: audience, JWT_JWKS_URL: jwksUrl, WEB_ORIGIN: webOrigin } = environment;
    const configured = Boolean(issuer && audience && jwksUrl);
    const verifier = configured ? new JWTIdentityVerifier({ issuer: issuer!, audience: audience!, jwksUrl: jwksUrl! }) : new DenyIdentityVerifier();
    const repository = new HouseholdRepository(pool, {
      // Current clients review shared food through v2; apply migrations before
      // deploying this runtime. Repository authorization still governs access.
      trackingV2: true,
      // Enable only when provider-backed guardian verification and revocation are
      // integrated. An environment flag cannot substitute for that authority.
      allowChildNetwork: false,
      noticeVersion: environment.CONSENT_NOTICE_VERSION ?? '',
      ...(configured ? { sessionStatus: new SupabaseSessionVerifier(issuer!) } : {}),
    });
    const guardian = await guardianRuntime(repository,environment,databaseConfiguration);
    guardianPool=guardian.pool;
    let browserAuth: BrowserAuthService | undefined;
    if (environment.EMAIL_OTP_ENABLED === 'true') {
      if (!configured || !webOrigin || !environment.SUPABASE_URL || !environment.SUPABASE_PUBLISHABLE_KEY || !environment.BFF_TOKEN_ENCRYPTION_KEY) {
        throw new Error('Enabled email sign-in requires complete provider and encryption configuration');
      }
      const childOTP=new SupabaseEmailOTPProvider({ url: environment.SUPABASE_URL, publicKey: environment.SUPABASE_PUBLISHABLE_KEY });
      browserAuth = new BrowserAuthService(repository, verifier,childOTP,
        { encryptionKey: environment.BFF_TOKEN_ENCRYPTION_KEY,childSignin:guardian.service });
      guardian.service.attachChildSignin(browserAuth,childOTP);
    }
    repository.options.allowChildNetwork=guardian.service.notice('en').available&&guardian.service.notice('es').available;
    if(repository.options.allowChildNetwork)repository.options.noticeVersion=guardian.service.notice('en').notice!.version;
    const clientAddress = deploymentClientAddress(environment);
    privacyRuntime=createPrivacyRuntime(pool,environment,'application');
    const privacy = new PrivacyService(repository,privacyRuntime.options);
    const server = createHTTPServer({ repository, verifier, billing: new BillingService(appleGatewayFromEnvironment(environment)),
      privacy,guardian:guardian.service,
      ...(webOrigin ? { webOrigin } : {}), ...(browserAuth ? { browserAuth } : {}), ...(clientAddress ? { clientAddress } : {}) });
    server.requestTimeout = 15_000;
    server.headersTimeout = 10_000;
    let auxiliaryClosing:Promise<void>|undefined,closing:Promise<void>|undefined;
    const closeAuxiliary=()=>auxiliaryClosing??=Promise.all([guardianPool?.end(),privacyRuntime?.close()]).then(()=>{});
    server.once('close',()=>{void closeAuxiliary();});
    const close=()=>closing??=Promise.all([closeAuxiliary(),pool.end()]).then(()=>{});
    return { mode:'serving',server,pool,close };
  } catch (error) {
    await privacyRuntime?.close();
    if(guardianPool)await guardianPool.end();
    await pool.end();
    throw error;
  }
}
