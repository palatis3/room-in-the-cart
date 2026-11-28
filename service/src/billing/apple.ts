import { mexicoRenewal } from './renewal-facts.js';
import { readFileSync } from 'node:fs';
import { createPrivateKey, X509Certificate } from 'node:crypto';
import {
  AppStoreServerAPIClient, Environment, SignedDataVerifier, Status,
  type JWSTransactionDecodedPayload, type JWSRenewalInfoDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from '@apple/app-store-server-library';
import { billingUnavailable, invalidApple, type VerifiedSubscription } from './domain.js';

export interface VerifiedAppleTransaction {
  originalTransactionID: string; transactionID: string; appAccountToken: string;
}
export type VerifiedAppleNotification =
  | { kind: 'TEST'; notificationID: string }
  | { kind: 'RESCIND_CONSENT'; notificationID: string; environment: 'Production' | 'Sandbox'; signedAt: number }
  | { kind: 'subscription'; notificationID: string; transaction: VerifiedAppleTransaction };
export interface NotificationGateway {
  verifyNotification(jws: string): Promise<VerifiedAppleNotification>;
}
export interface NotificationDestinations {
  primary: NotificationGateway;
  sandbox?: NotificationGateway;
}
export interface AppleBillingGateway extends NotificationGateway {
  verifyTransaction(jws: string): Promise<VerifiedAppleTransaction>;
  current(originalTransactionID: string): Promise<VerifiedSubscription>;
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
type NotificationConfiguration = Pick<AppleConfiguration, 'bundleID' | 'environment' | 'appAppleID' | 'rootCertificates'>;

class OfficialNotificationGateway implements NotificationGateway {
  protected readonly verifier: SignedDataVerifier;
  constructor(protected readonly config: NotificationConfiguration & { productID?: string }) {
    if (!config.bundleID || !config.rootCertificates.length || !['Production', 'Sandbox'].includes(config.environment)
      || (config.environment === 'Production' && (!Number.isSafeInteger(config.appAppleID) || config.appAppleID! <= 0))) throw new Error('Incomplete Apple notification configuration');
    for (const root of config.rootCertificates) {
      const cert = new X509Certificate(root);
      if (!cert.ca || !cert.verify(cert.publicKey)) throw new Error('Apple roots must be trusted self-signed CA certificates from Apple PKI');
    }
    const environment = config.environment === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
    this.verifier = new SignedDataVerifier(config.rootCertificates, true, environment, config.bundleID, config.appAppleID);
  }
  protected transaction(payload: JWSTransactionDecodedPayload): VerifiedAppleTransaction {
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
    if (notification.notificationType === 'TEST') return { kind: 'TEST', notificationID: notification.notificationUUID };
    if (notification.notificationType === 'RESCIND_CONSENT') {
      const app = notification.appData;
      if (!app || notification.data || notification.summary || notification.externalPurchaseToken || 'unclaimInfo' in notification
        || app.bundleId !== this.config.bundleID || app.environment !== this.config.environment
        || (this.config.environment === 'Production' && app.appAppleId !== this.config.appAppleID)) throw invalidApple();
      if (app.signedAppTransactionInfo !== undefined) {
        jwsSize(app.signedAppTransactionInfo);
        try { await this.verifier.verifyAndDecodeAppTransaction(app.signedAppTransactionInfo); }
        catch { throw invalidApple(); }
      }
      // The app download is not an identity in our service, including for Family Sharing.
      return { kind: 'RESCIND_CONSENT', notificationID: notification.notificationUUID, environment: this.config.environment, signedAt: notification.signedDate };
    }
    if (!this.config.productID) throw billingUnavailable();
    if (!notification.data?.signedTransactionInfo) throw invalidApple();
    const transaction = await this.verifyTransaction(notification.data.signedTransactionInfo);
    // Nested renewal JWS must also verify; notification status itself is not used as current authority.
    if (notification.data.signedRenewalInfo) {
      let renewal: JWSRenewalInfoDecodedPayload;
      try { renewal = await this.verifier.verifyAndDecodeRenewalInfo(notification.data.signedRenewalInfo); }
      catch { throw invalidApple(); }
      this.checkRenewal(renewal, transaction);
    }
    return { kind: 'subscription', notificationID: notification.notificationUUID, transaction };
  }
  protected checkRenewal(renewal: JWSRenewalInfoDecodedPayload, transaction: VerifiedAppleTransaction): void {
    if (renewal.originalTransactionId !== transaction.originalTransactionID || renewal.productId !== this.config.productID
      || renewal.environment !== this.config.environment || !instant(renewal.signedDate) || renewal.signedDate > Date.now() + 60_000
      || (renewal.appAccountToken !== undefined && renewal.appAccountToken.toLowerCase() !== transaction.appAccountToken)
      || (renewal.gracePeriodExpiresDate !== undefined && !instant(renewal.gracePeriodExpiresDate))) throw invalidApple();
  }
}
export class OfficialAppleBillingGateway extends OfficialNotificationGateway implements AppleBillingGateway {
  private readonly api: AppStoreServerAPIClient;
  constructor(private readonly billing: AppleConfiguration) {
    super(billing);
    if (!billing.productID || !billing.keyID || !uuid.test(billing.issuerID) || !billing.signingKey) throw new Error('Incomplete Apple billing configuration');
    if (billing.productID === 'local.testing.household.annual') throw new Error('Apple billing product ID must not use the local StoreKit fixture');
    const environment = billing.environment === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
    this.api = new AppStoreServerAPIClient(billing.signingKey, billing.keyID, billing.issuerID, billing.bundleID, environment);
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
    return { ...transaction, environment: this.config.environment, productID: this.billing.productID,
      mxAnnual:payload.storefront==='MEX',
      autoRenewOff:renewal.autoRenewStatus===0,
      noticeFacts:mexicoRenewal(payload,renewal,this.billing.productID),
      purchasedAt: payload.purchaseDate!, signedAt: Math.max(payload.signedDate!, renewal.signedDate!),
      expiresAt: payload.expiresDate!, graceExpiresAt: renewal.gracePeriodExpiresDate ?? null, status };
  }
}

export interface ReviewBilling {
  householdIDs: ReadonlySet<string>;
  sandbox: AppleBillingGateway;
}

/** Configuration and the signing key belong to the deployment. Clients never select a gateway. */
export function appleGatewaysFromEnvironment(env: NodeJS.ProcessEnv = process.env): { primary: AppleBillingGateway | null; review?: ReviewBilling; notifications?: NotificationDestinations } {
  const names = ['APPLE_BUNDLE_ID','APPLE_PRODUCT_ID','APPLE_ENVIRONMENT','APPLE_ROOT_CA_PATHS','APPLE_SIGNING_KEY_PATH','APPLE_SIGNING_KEY_PEM','APPLE_KEY_ID','APPLE_ISSUER_ID'] as const;
  const householdIDs = new Set(env.APPLE_REVIEW_HOUSEHOLD_IDS ? env.APPLE_REVIEW_HOUSEHOLD_IDS.split(',').map(id => id.trim().toLowerCase()) : []);
  if (householdIDs.size && (env.APPLE_ENVIRONMENT !== 'Production' || [...householdIDs].some(id => !uuid.test(id)))) {
    throw new Error('APPLE_REVIEW_HOUSEHOLD_IDS requires a Production billing configuration and comma-separated household UUIDs');
  }
  if (names.every(name => !env[name]) && !env.APPLE_APP_ID) return { primary: null };
  if (!env.APPLE_BUNDLE_ID || !env.APPLE_ROOT_CA_PATHS || !['Production','Sandbox'].includes(env.APPLE_ENVIRONMENT ?? '')) throw new Error('Incomplete Apple notification environment');
  const appAppleID = env.APPLE_APP_ID ? Number(env.APPLE_APP_ID) : undefined;
  const verification: NotificationConfiguration = {
    bundleID: env.APPLE_BUNDLE_ID, environment: env.APPLE_ENVIRONMENT as 'Production' | 'Sandbox',
    ...(appAppleID === undefined ? {} : { appAppleID }),
    rootCertificates: env.APPLE_ROOT_CA_PATHS.split(',').map(path => readFileSync(path.trim())),
  };
  const sandboxVerifier = () => new OfficialNotificationGateway({ ...verification, environment: 'Sandbox' });
  const signingKeyPath = env.APPLE_SIGNING_KEY_PATH;
  const signingKeyPEM = env.APPLE_SIGNING_KEY_PEM;
  const purchaseSettings = [env.APPLE_PRODUCT_ID, signingKeyPEM || signingKeyPath, env.APPLE_KEY_ID, env.APPLE_ISSUER_ID];
  if (purchaseSettings.every(value => !value) && !householdIDs.size) {
    return { primary: null, notifications: { primary: new OfficialNotificationGateway(verification),
      ...(verification.environment === 'Production' ? { sandbox: sandboxVerifier() } : {}) } };
  }
  if (purchaseSettings.some(value => !value)) throw new Error('Incomplete Apple billing environment');
  if (signingKeyPath && signingKeyPEM) throw new Error('Configure exactly one Apple signing key source');
  let signingKey: string;
  try {
    signingKey = signingKeyPEM || readFileSync(signingKeyPath!, 'utf8');
    if (createPrivateKey(signingKey).asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error();
  } catch {
    throw new Error('Apple billing requires a readable P-256 signing key');
  }
  const config: AppleConfiguration = { ...verification, productID: env.APPLE_PRODUCT_ID!,
    signingKey, keyID: env.APPLE_KEY_ID!, issuerID: env.APPLE_ISSUER_ID! };
  const primary = new OfficialAppleBillingGateway(config);
  if (!householdIDs.size) return verification.environment === 'Production' ? { primary, notifications: { primary, sandbox: sandboxVerifier() } } : { primary };
  const sandbox = new OfficialAppleBillingGateway({ ...config, environment: 'Sandbox' });
  return { primary, review: { householdIDs, sandbox } };
}
