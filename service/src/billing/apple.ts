import { readFileSync } from 'node:fs';
import { X509Certificate } from 'node:crypto';
import {
  AppStoreServerAPIClient, Environment, SignedDataVerifier, Status,
  type JWSTransactionDecodedPayload, type JWSRenewalInfoDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from '@apple/app-store-server-library';
import { billingUnavailable, invalidApple, type VerifiedSubscription } from './domain.js';

export interface VerifiedAppleTransaction {
  originalTransactionID: string; transactionID: string; appAccountToken: string;
}
export interface VerifiedAppleNotification {
  notificationID: string;
  transaction: VerifiedAppleTransaction | null;
}
export interface AppleBillingGateway {
  verifyTransaction(jws: string): Promise<VerifiedAppleTransaction>;
  current(originalTransactionID: string): Promise<VerifiedSubscription>;
  verifyNotification(jws: string): Promise<VerifiedAppleNotification>;
}
export interface AppleConfiguration {
  bundleID: string; productID: string; environment: 'Production' | 'Sandbox';
  appAppleID?: number;
  rootCertificates: Buffer[];
  signingKey: string; keyID: string; issuerID: string;
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const transactionID = /^[0-9]{1,64}$/;
const instant = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value > 0 && value < 8.64e15;
function jwsSize(jws: string): void { if (typeof jws !== 'string' || jws.length < 16 || jws.length > 128_000) throw invalidApple(); }

/** Production verifier always checks Apple's certificate chain and online revocation. No local/Xcode environment fallback. */
export class OfficialAppleBillingGateway implements AppleBillingGateway {
  private readonly verifier: SignedDataVerifier;
  private readonly api: AppStoreServerAPIClient;
  constructor(private readonly config: AppleConfiguration) {
    if (!config.bundleID || !config.productID || !config.keyID || !uuid.test(config.issuerID) || !config.signingKey || !config.rootCertificates.length
      || !['Production', 'Sandbox'].includes(config.environment)
      || (config.environment === 'Production' && (!Number.isSafeInteger(config.appAppleID) || config.appAppleID! <= 0))) throw new Error('Incomplete Apple billing configuration');
    if (config.productID === 'local.testing.household.annual') throw new Error('Apple billing product ID must not use the local StoreKit fixture');
    for (const root of config.rootCertificates) {
      const cert = new X509Certificate(root);
      if (!cert.ca || !cert.verify(cert.publicKey)) throw new Error('Apple roots must be trusted self-signed CA certificates from Apple PKI');
    }
    const environment = config.environment === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
    this.verifier = new SignedDataVerifier(config.rootCertificates, true, environment, config.bundleID, config.appAppleID);
    this.api = new AppStoreServerAPIClient(config.signingKey, config.keyID, config.issuerID, config.bundleID, environment);
  }
  private transaction(payload: JWSTransactionDecodedPayload): VerifiedAppleTransaction {
    if (payload.bundleId !== this.config.bundleID || payload.productId !== this.config.productID || payload.environment !== this.config.environment
      || payload.type !== 'Auto-Renewable Subscription' || payload.inAppOwnershipType !== 'PURCHASED'
      || !payload.originalTransactionId || !transactionID.test(payload.originalTransactionId)
      || !payload.transactionId || !transactionID.test(payload.transactionId)
      || !payload.appAccountToken || !uuid.test(payload.appAccountToken)
      || !instant(payload.purchaseDate) || !instant(payload.signedDate) || !instant(payload.expiresDate)
      || payload.signedDate > Date.now() + 60_000 || payload.expiresDate <= payload.purchaseDate
      || (payload.revocationDate !== undefined && !instant(payload.revocationDate))) throw invalidApple();
    return { originalTransactionID: payload.originalTransactionId, transactionID: payload.transactionId, appAccountToken: payload.appAccountToken.toLowerCase() };
  }
  async verifyTransaction(jws: string): Promise<VerifiedAppleTransaction> {
    jwsSize(jws);
    try { return this.transaction(await this.verifier.verifyAndDecodeTransaction(jws)); }
    catch { throw invalidApple(); }
  }
  async verifyNotification(jws: string): Promise<VerifiedAppleNotification> {
    jwsSize(jws);
    let notification: ResponseBodyV2DecodedPayload;
    try { notification = await this.verifier.verifyAndDecodeNotification(jws); }
    catch { throw invalidApple(); }
    if (notification.version !== '2.0' || !notification.notificationUUID || !uuid.test(notification.notificationUUID)
      || !instant(notification.signedDate) || notification.signedDate > Date.now() + 60_000) throw invalidApple();
    if (notification.notificationType === 'TEST') return { notificationID: notification.notificationUUID, transaction: null };
    if (!notification.data?.signedTransactionInfo) throw invalidApple();
    const transaction = await this.verifyTransaction(notification.data.signedTransactionInfo);
    // Nested renewal JWS must also verify; notification status itself is not used as current authority.
    if (notification.data.signedRenewalInfo) {
      let renewal: JWSRenewalInfoDecodedPayload;
      try { renewal = await this.verifier.verifyAndDecodeRenewalInfo(notification.data.signedRenewalInfo); }
      catch { throw invalidApple(); }
      this.checkRenewal(renewal, transaction);
    }
    return { notificationID: notification.notificationUUID, transaction };
  }
  private checkRenewal(renewal: JWSRenewalInfoDecodedPayload, transaction: VerifiedAppleTransaction): void {
    if (renewal.originalTransactionId !== transaction.originalTransactionID || renewal.productId !== this.config.productID
      || renewal.environment !== this.config.environment || !instant(renewal.signedDate) || renewal.signedDate > Date.now() + 60_000
      || (renewal.appAccountToken !== undefined && renewal.appAccountToken.toLowerCase() !== transaction.appAccountToken)
      || (renewal.gracePeriodExpiresDate !== undefined && !instant(renewal.gracePeriodExpiresDate))) throw invalidApple();
  }
  async current(originalTransactionID: string): Promise<VerifiedSubscription> {
    if (!transactionID.test(originalTransactionID)) throw invalidApple();
    let response;
    try { response = await this.api.getAllSubscriptionStatuses(originalTransactionID); }
    catch { throw billingUnavailable(); }
    if (response.environment !== this.config.environment || response.bundleId !== this.config.bundleID
      || (this.config.environment === 'Production' && response.appAppleId !== this.config.appAppleID)) throw invalidApple();
    const entries = (response.data ?? []).flatMap(group => group.lastTransactions ?? []).filter(entry => entry.originalTransactionId === originalTransactionID);
    // Ambiguous or absent subscription state never yields access.
    if (entries.length !== 1 || !entries[0]?.signedTransactionInfo || !entries[0].signedRenewalInfo) throw invalidApple();
    const entry = entries[0];
    let payload: JWSTransactionDecodedPayload, renewal: JWSRenewalInfoDecodedPayload;
    try {
      [payload, renewal] = await Promise.all([
        this.verifier.verifyAndDecodeTransaction(entry.signedTransactionInfo!),
        this.verifier.verifyAndDecodeRenewalInfo(entry.signedRenewalInfo!),
      ]);
    } catch { throw invalidApple(); }
    const transaction = this.transaction(payload);
    if (transaction.originalTransactionID !== originalTransactionID) throw invalidApple();
    this.checkRenewal(renewal, transaction);
    const status = payload.revocationDate !== undefined ? 'revoked'
      : payload.isUpgraded ? 'expired'
      : entry.status === Status.ACTIVE ? 'active'
      : entry.status === Status.BILLING_GRACE_PERIOD ? 'grace'
      : entry.status === Status.BILLING_RETRY ? 'billingRetry'
      : entry.status === Status.EXPIRED ? 'expired'
      : entry.status === Status.REVOKED ? 'revoked' : null;
    if (status === null || (status === 'grace' && !instant(renewal.gracePeriodExpiresDate))) throw invalidApple();
    return { ...transaction, environment: this.config.environment, productID: this.config.productID,
      purchasedAt: payload.purchaseDate!, signedAt: Math.max(payload.signedDate!, renewal.signedDate!),
      expiresAt: payload.expiresDate!, graceExpiresAt: renewal.gracePeriodExpiresDate ?? null, status };
  }
}

/** Paths are deployment-owned files, never client-supplied; credentials remain server-side. */
export function appleGatewayFromEnvironment(env: NodeJS.ProcessEnv = process.env): AppleBillingGateway | null {
  const names = ['APPLE_BUNDLE_ID','APPLE_PRODUCT_ID','APPLE_ENVIRONMENT','APPLE_ROOT_CA_PATHS','APPLE_SIGNING_KEY_PATH','APPLE_KEY_ID','APPLE_ISSUER_ID'] as const;
  if (names.every(name => !env[name]) && !env.APPLE_APP_ID) return null;
  if (names.some(name => !env[name]) || !['Production','Sandbox'].includes(env.APPLE_ENVIRONMENT!)) throw new Error('Incomplete Apple billing environment');
  const appAppleID = env.APPLE_APP_ID ? Number(env.APPLE_APP_ID) : undefined;
  return new OfficialAppleBillingGateway({
    bundleID: env.APPLE_BUNDLE_ID!, productID: env.APPLE_PRODUCT_ID!, environment: env.APPLE_ENVIRONMENT! as 'Production' | 'Sandbox',
    ...(appAppleID === undefined ? {} : { appAppleID }),
    rootCertificates: env.APPLE_ROOT_CA_PATHS!.split(',').map(path => readFileSync(path.trim())),
    signingKey: readFileSync(env.APPLE_SIGNING_KEY_PATH!, 'utf8'), keyID: env.APPLE_KEY_ID!, issuerID: env.APPLE_ISSUER_ID!,
  });
}
