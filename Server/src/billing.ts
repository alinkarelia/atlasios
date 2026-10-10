import { readFileSync } from 'node:fs';
import { X509Certificate } from 'node:crypto';
import { SignedDataVerifier, Environment, InAppOwnershipType, Type, VerificationException,
  VerificationStatus, type JWSTransactionDecodedPayload, type JWSRenewalInfoDecodedPayload } from '@apple/app-store-server-library';
import { Store } from './store.js';
import { ApiError, id, object, keys, enumeration, integer, text } from './domain.js';
import { tokenHash } from './auth.js';

export type PaidPlan = 'pro' | 'business' | 'enterprise';
export interface AppleProduct { productID: string; plan: PaidPlan; editorSeats: number }
export interface AppleConfiguration {
  bundleID: string; appID?: number; environment: Environment.SANDBOX | Environment.PRODUCTION;
  rootCertificates: Buffer[]; products: AppleProduct[];
}
interface TransactionRow {
  transaction_id: string; environment: string; original_id: string; product_id: string; account_token: string;
  purchased_at: number; expires_at: number; revoked_at: number | null; upgraded: number; signed_at: number;
  jws_hash: string; updated_at: string;
}
interface Binding { original_id: string; environment: string; organization_id: string; purchaser_id: string }
const baseline = ['captureLiDAR', 'editGeometry', 'measure', 'exportOwnData'];
const currentTime = () => new Date().toISOString();
const ranks: Record<PaidPlan, number> = { pro: 1, business: 2, enterprise: 3 };
export const atlasAppleProducts: AppleProduct[] = [
  { productID: 'com.atlasfield.pro.monthly', plan: 'pro', editorSeats: 1 },
  { productID: 'com.atlasfield.pro.yearly', plan: 'pro', editorSeats: 1 },
  { productID: 'com.atlasfield.business3.monthly', plan: 'business', editorSeats: 3 },
  { productID: 'com.atlasfield.business3.yearly', plan: 'business', editorSeats: 3 },
  { productID: 'com.atlasfield.business10.monthly', plan: 'business', editorSeats: 10 },
  { productID: 'com.atlasfield.business10.yearly', plan: 'business', editorSeats: 10 },
];
const inactive = () => new ApiError(503, 'billing_not_configured', 'Apple server verification is not configured; no paid entitlement is granted');

function appleID(value: unknown, name: string): string {
  if (typeof value !== 'string' || !/^\d{1,128}$/.test(value)) throw new ApiError(400, 'invalid_apple_transaction', `Invalid Apple ${name}`);
  return value;
}
function timestamp(value: unknown, name: string): number {
  try { return integer(value, name, 1, 8.64e15); }
  catch { throw new ApiError(400, 'invalid_apple_transaction', `Missing or invalid ${name}`); }
}
function futureSafe(value: number) {
  if (value > Date.now() + 300_000) throw new ApiError(400, 'invalid_apple_transaction', 'Apple signed or purchase date is in the future');
}

export function appleConfiguration(env: NodeJS.ProcessEnv): AppleConfiguration | undefined {
  const present = ['APPLE_BUNDLE_ID', 'APPLE_APP_ID', 'APPLE_ENVIRONMENT', 'APPLE_ROOT_CERT_PATHS', 'APPLE_ALLOWED_PRODUCT_IDS'].some(key => Boolean(env[key]));
  if (!present) return undefined;
  const bundleID = text(env.APPLE_BUNDLE_ID, 'APPLE_BUNDLE_ID', 255, 3);
  if (!/^[A-Za-z0-9][A-Za-z0-9.-]+$/.test(bundleID)) throw new Error('Invalid Apple bundle configuration');
  const environmentName = enumeration(env.APPLE_ENVIRONMENT, ['Sandbox', 'Production'], 'APPLE_ENVIRONMENT');
  const environment = environmentName === 'Production' ? Environment.PRODUCTION : Environment.SANDBOX;
  const appID = env.APPLE_APP_ID ? integer(Number(env.APPLE_APP_ID), 'APPLE_APP_ID', 1) : undefined;
  if (environment === Environment.PRODUCTION && appID === undefined) throw new Error('Production requires APPLE_APP_ID');
  const paths = text(env.APPLE_ROOT_CERT_PATHS, 'APPLE_ROOT_CERT_PATHS', 4096, 1).split(',').map(path => path.trim()).filter(Boolean);
  if (paths.length === 0 || paths.length > 8) throw new Error('Configure Apple root certificates');
  const rootCertificates = paths.map(path => {
    const certificate = new X509Certificate(readFileSync(path));
    if (!certificate.ca) throw new Error('Apple trust anchor must be a CA certificate');
    return certificate.raw;
  });
  const allowed = env.APPLE_ALLOWED_PRODUCT_IDS?.split(',').map(value => value.trim()).filter(Boolean) ?? atlasAppleProducts.map(product => product.productID);
  if (allowed.length === 0 || allowed.length > 6 || new Set(allowed).size !== allowed.length) throw new Error('Configure one to six unique Atlas Apple products');
  const products = allowed.map(productID => {
    const product = atlasAppleProducts.find(value => value.productID === productID);
    if (!product) throw new Error('Unknown Atlas Apple product');
    return product;
  });
  return { bundleID, environment, appID, rootCertificates, products };
}

/** This adapter only accepts decoded values returned by Apple's signature verifier. */
export class AppleBilling {
  readonly configured: boolean;
  readonly commercialMode: boolean;
  private readonly configuration?: AppleConfiguration;
  private readonly verifier?: SignedDataVerifier;
  private readonly products = new Map<string, AppleProduct>();

  constructor(private readonly store: Store, environment: NodeJS.ProcessEnv = process.env) {
    this.commercialMode = ['APPLE_BUNDLE_ID', 'APPLE_APP_ID', 'APPLE_ENVIRONMENT', 'APPLE_ROOT_CERT_PATHS', 'APPLE_ALLOWED_PRODUCT_IDS'].some(key => Boolean(environment[key]));
    try {
      this.configuration = appleConfiguration(environment);
      if (this.configuration) {
        const config = this.configuration;
        // OCSP and present-time certificate checks stay enabled in every deployed environment.
        this.verifier = new SignedDataVerifier(config.rootCertificates, true, config.environment, config.bundleID, config.appID);
        for (const product of config.products) this.products.set(product.productID, product);
      }
      this.configured = Boolean(this.verifier);
    } catch { this.configured = false; }
  }

  private async verify<T>(operation: () => Promise<T>): Promise<T> {
    if (!this.verifier) throw inactive();
    try { return await operation(); }
    catch (error) {
      if (error instanceof VerificationException && error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
        throw new ApiError(503, 'apple_verification_unavailable', 'Apple certificate verification is temporarily unavailable; retry later');
      }
      throw new ApiError(400, 'invalid_apple_signature', 'Apple signed data could not be verified');
    }
  }

  private decodedTransaction(decoded: JWSTransactionDecodedPayload): TransactionRow {
    const config = this.configuration;
    if (!config || decoded.bundleId !== config.bundleID || decoded.environment !== config.environment) throw new ApiError(400, 'invalid_apple_transaction', 'Apple application or environment does not match');
    const productID = text(decoded.productId, 'productId', 255, 1);
    if (!this.products.has(productID)) throw new ApiError(400, 'unknown_apple_product', 'This product is not configured for Atlas');
    if (decoded.type !== Type.AUTO_RENEWABLE_SUBSCRIPTION || decoded.inAppOwnershipType !== InAppOwnershipType.PURCHASED || decoded.quantity !== 1) {
      throw new ApiError(400, 'invalid_apple_ownership', 'An individually purchased auto-renewable subscription is required');
    }
    const purchased = timestamp(decoded.purchaseDate, 'purchaseDate'); const expires = timestamp(decoded.expiresDate, 'expiresDate');
    const signed = timestamp(decoded.signedDate, 'signedDate'); futureSafe(purchased); futureSafe(signed);
    if (expires <= purchased) throw new ApiError(400, 'invalid_apple_transaction', 'Subscription expiry must follow purchase');
    const revoked = decoded.revocationDate === undefined ? null : timestamp(decoded.revocationDate, 'revocationDate');
    if (revoked !== null) futureSafe(revoked);
    return { transaction_id: appleID(decoded.transactionId, 'transactionId'), original_id: appleID(decoded.originalTransactionId, 'originalTransactionId'),
      environment: config.environment, product_id: productID, account_token: id(decoded.appAccountToken, 'appAccountToken'),
      purchased_at: purchased, expires_at: expires, revoked_at: revoked, upgraded: decoded.isUpgraded ? 1 : 0,
      signed_at: signed, jws_hash: '', updated_at: currentTime() };
  }

  private bump(organizationID: string) {
    this.store.run('INSERT INTO billing_state VALUES (?, 1, ?) ON CONFLICT(organization_id) DO UPDATE SET revision = revision + 1, updated_at = excluded.updated_at', organizationID, currentTime());
  }

  private saveTransaction(row: TransactionRow, jws: string, allowRefundReversal = false): boolean {
    const existing = this.store.get<TransactionRow>('SELECT * FROM apple_transactions WHERE transaction_id = ? AND environment = ?', row.transaction_id, row.environment);
    if (existing && (existing.original_id !== row.original_id || existing.account_token !== row.account_token)) throw new ApiError(409, 'apple_transaction_conflict', 'Transaction ownership cannot be reassigned');
    if (existing && existing.signed_at >= row.signed_at) return false;
    if (existing?.revoked_at && !row.revoked_at && !allowRefundReversal) row.revoked_at = existing.revoked_at;
    if (existing?.upgraded) row.upgraded = 1;
    this.store.run(`INSERT INTO apple_transactions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(transaction_id, environment) DO UPDATE SET product_id = excluded.product_id,
      purchased_at = excluded.purchased_at, expires_at = excluded.expires_at, revoked_at = excluded.revoked_at,
      upgraded = excluded.upgraded, signed_at = excluded.signed_at, jws_hash = excluded.jws_hash, updated_at = excluded.updated_at`,
      row.transaction_id, row.environment, row.original_id, row.product_id, row.account_token, row.purchased_at,
      row.expires_at, row.revoked_at, row.upgraded, row.signed_at, tokenHash(jws), row.updated_at);
    return true;
  }

  async verifyPurchase(organizationID: string, userID: string, signedTransaction: string) {
    if (!this.verifier) throw inactive();
    const decoded = await this.verify(() => this.verifier!.verifyAndDecodeTransaction(signedTransaction));
    const transaction = this.decodedTransaction(decoded);
    if (transaction.account_token !== userID) throw new ApiError(403, 'apple_account_mismatch', 'The purchase must be made for the signed-in account');
    this.store.transaction(() => {
      const membership = this.store.get<{ role: string }>('SELECT role FROM memberships WHERE organization_id = ? AND user_id = ?', organizationID, userID);
      if (!membership || !['owner', 'admin'].includes(membership.role)) throw new ApiError(403, 'forbidden', 'Organization management permission is required');
      const binding = this.store.get<Binding>('SELECT * FROM apple_bindings WHERE original_id = ? AND environment = ?', transaction.original_id, transaction.environment);
      if (binding && (binding.organization_id !== organizationID || binding.purchaser_id !== userID)) {
        throw new ApiError(409, 'apple_subscription_bound', 'This subscription is already linked to another organization or purchaser');
      }
      if (!binding) this.store.run('INSERT INTO apple_bindings VALUES (?, ?, ?, ?, ?)', transaction.original_id, transaction.environment, organizationID, userID, currentTime());
      const saved = this.saveTransaction(transaction, signedTransaction);
      if (saved || !binding) this.bump(organizationID);
      this.store.run('UPDATE organizations SET plan = ? WHERE id = ?', this.snapshot(organizationID).plan as string, organizationID);
    });
    return this.snapshot(organizationID);
  }

  private saveRenewal(decoded: JWSRenewalInfoDecodedPayload, transaction: TransactionRow, jws: string): boolean {
    if (decoded.originalTransactionId !== transaction.original_id || decoded.environment !== transaction.environment || !decoded.productId || !this.products.has(decoded.productId)) {
      throw new ApiError(400, 'invalid_apple_renewal', 'Renewal information does not match this subscription');
    }
    if (decoded.appAccountToken && id(decoded.appAccountToken) !== transaction.account_token) throw new ApiError(400, 'invalid_apple_renewal', 'Renewal account does not match');
    const signed = timestamp(decoded.signedDate, 'signedDate'); futureSafe(signed);
    const grace = decoded.gracePeriodExpiresDate === undefined ? null : timestamp(decoded.gracePeriodExpiresDate, 'gracePeriodExpiresDate');
    const previous = this.store.get<{ signed_at: number }>('SELECT signed_at FROM apple_renewals WHERE original_id = ? AND environment = ?', transaction.original_id, transaction.environment);
    if (previous && previous.signed_at >= signed) return false;
    this.store.run(`INSERT INTO apple_renewals VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(original_id, environment)
      DO UPDATE SET product_id = excluded.product_id, grace_expires_at = excluded.grace_expires_at, signed_at = excluded.signed_at, jws_hash = excluded.jws_hash`,
      transaction.original_id, transaction.environment, decoded.productId, grace, signed, tokenHash(jws));
    return true;
  }

  async notification(signedPayload: string) {
    if (!this.verifier) throw inactive();
    const decoded = await this.verify(() => this.verifier!.verifyAndDecodeNotification(signedPayload));
    const notificationID = id(decoded.notificationUUID, 'notificationUUID'); const signed = timestamp(decoded.signedDate, 'signedDate'); futureSafe(signed);
    const transactionJWS = decoded.data?.signedTransactionInfo;
    const transaction = transactionJWS ? this.decodedTransaction(await this.verify(() => this.verifier!.verifyAndDecodeTransaction(transactionJWS))) : undefined;
    const renewalJWS = decoded.data?.signedRenewalInfo;
    const renewal = renewalJWS ? await this.verify(() => this.verifier!.verifyAndDecodeRenewalInfo(renewalJWS)) : undefined;
    if (!transaction && decoded.notificationType !== 'TEST') throw new ApiError(400, 'unsupported_apple_notification', 'This notification requires a signed subscription transaction');
    return this.store.transaction(() => {
      const prior = this.store.get<{ jws_hash: string; status: string }>('SELECT * FROM apple_notifications WHERE notification_id = ?', notificationID);
      if (prior) {
        if (prior.jws_hash !== tokenHash(signedPayload)) throw new ApiError(409, 'apple_notification_conflict', 'Notification identifier cannot be reused with another payload');
        return { received: true, status: prior.status };
      }
      let status = 'test';
      if (transaction) {
        const binding = this.store.get<Binding>('SELECT * FROM apple_bindings WHERE original_id = ? AND environment = ?', transaction.original_id, transaction.environment);
        if (binding && binding.purchaser_id !== transaction.account_token) throw new ApiError(400, 'apple_account_mismatch', 'Notification account does not match the subscription binding');
        if (['REFUND', 'REVOKE'].includes(decoded.notificationType ?? '') && !transaction.revoked_at) transaction.revoked_at = signed;
        if (['REFUND', 'REVOKE', 'REFUND_REVERSED'].includes(decoded.notificationType ?? '')) transaction.signed_at = Math.max(transaction.signed_at, signed);
        const changed = this.saveTransaction(transaction, transactionJWS!, decoded.notificationType === 'REFUND_REVERSED');
        const renewalChanged = renewal && renewalJWS ? this.saveRenewal(renewal, transaction, renewalJWS) : false;
        if (binding && (changed || renewalChanged)) {
          this.bump(binding.organization_id);
          this.store.run('UPDATE organizations SET plan = ? WHERE id = ?', this.snapshot(binding.organization_id).plan as string, binding.organization_id);
        }
        status = binding ? 'processed' : 'unbound';
      }
      this.store.run('INSERT INTO apple_notifications VALUES (?, ?, ?, ?, ?, ?, ?)', notificationID, this.configuration!.environment,
        signed, tokenHash(signedPayload), status, transaction?.original_id ?? null, currentTime());
      return { received: true, status };
    });
  }

  snapshot(organizationID: string): Record<string, unknown> {
    if (!this.configured) return { plan: 'free', paymentProvider: 'not_configured', verifiedEntitlement: null, appleVerificationAvailable: false,
      prototypeMode: !this.commercialMode, configurationStatus: this.commercialMode ? 'invalid_configuration' : 'not_configured' };
    const bindings = this.store.all<Binding>('SELECT * FROM apple_bindings WHERE organization_id = ? AND environment = ?', organizationID, this.configuration!.environment);
    const subscriptions = bindings.map(binding => {
      const transaction = this.store.get<TransactionRow>('SELECT * FROM apple_transactions WHERE original_id = ? AND environment = ? ORDER BY purchased_at DESC, signed_at DESC, transaction_id DESC LIMIT 1', binding.original_id, binding.environment);
      if (!transaction) return undefined;
      const product = this.products.get(transaction.product_id); if (!product) return undefined;
      const renewal = this.store.get<{ grace_expires_at: number | null; product_id: string; signed_at: number }>('SELECT * FROM apple_renewals WHERE original_id = ? AND environment = ?', binding.original_id, binding.environment);
      const grace = renewal && renewal.product_id === transaction.product_id && renewal.signed_at >= transaction.signed_at ? renewal.grace_expires_at : null;
      const status = transaction.revoked_at ? 'revoked' : transaction.upgraded ? 'expired' : transaction.expires_at > Date.now() ? 'active' : grace && grace > Date.now() ? 'billingGrace' : 'expired';
      return { transaction, product, status, validUntil: status === 'billingGrace' ? grace! : transaction.expires_at };
    }).filter((value): value is NonNullable<typeof value> => value !== undefined);
    const usable = subscriptions.filter(subscription => ['active', 'billingGrace'].includes(subscription.status))
      .sort((a, b) => ranks[b.product.plan] - ranks[a.product.plan] || b.product.editorSeats - a.product.editorSeats || b.validUntil - a.validUntil);
    const selected = usable[0] ?? subscriptions.sort((a, b) => b.transaction.purchased_at - a.transaction.purchased_at)[0];
    if (!selected) return { plan: 'free', paymentProvider: 'apple', verifiedEntitlement: null, appleVerificationAvailable: true, prototypeMode: false };
    const active = usable.length > 0;
    const state = this.store.get<{ revision: number; updated_at: string }>('SELECT * FROM billing_state WHERE organization_id = ?', organizationID);
    const capabilities = [...baseline];
    if (active) {
      capabilities.push('advancedPlans');
      if (selected.product.plan !== 'pro') capabilities.push('teamManagement', 'businessWorkflow');
    }
    // No cloudProcessing/cloudUpload/integration claims: those services are not implemented here.
    const entitlement = { tier: selected.product.plan, scope: { organization: { _0: organizationID } }, source: 'serverVerified',
      status: selected.status, capabilities, validUntil: new Date(selected.validUntil).toISOString(),
      offlineValidUntil: active ? new Date(Math.min(selected.validUntil, Date.now() + 24 * 3600 * 1000)).toISOString() : null,
      verifiedAt: state?.updated_at ?? selected.transaction.updated_at, revision: state?.revision ?? 0,
      quotas: { editorSeats: active ? selected.product.editorSeats : 1, cloudStorageBytes: null, computeCredits: null } };
    return { plan: active ? selected.product.plan : 'free', paymentProvider: 'apple', verifiedEntitlement: entitlement,
      appleVerificationAvailable: true, prototypeMode: false };
  }

  requireCapability(organizationID: string, capability: 'teamManagement' | 'businessWorkflow') {
    if (!this.commercialMode) return; // Explicit prototype Free mode, not a paid entitlement.
    if (!this.configured) throw inactive();
    const entitlement = this.snapshot(organizationID).verifiedEntitlement as { capabilities: string[] } | null;
    if (!entitlement?.capabilities.includes(capability)) throw new ApiError(402, 'subscription_required', 'An active Business or Enterprise subscription is required');
  }
  requireSeat(organizationID: string, nextRole: string, existingRole?: string) {
    if (!this.commercialMode || nextRole === 'viewer' || (existingRole && existingRole !== 'viewer')) return;
    if (!this.configured) throw inactive();
    const entitlement = this.snapshot(organizationID).verifiedEntitlement as { quotas: { editorSeats: number } } | null;
    const count = this.store.get<{ n: number }>("SELECT COUNT(*) AS n FROM memberships WHERE organization_id = ? AND role <> 'viewer'", organizationID)!.n;
    if (count >= (entitlement?.quotas.editorSeats ?? 1)) throw new ApiError(402, 'seat_quota_exceeded', 'The organization has used its licensed editor seats');
  }
  requireEditorSeat(organizationID: string, userID: string) {
    if (!this.commercialMode) return;
    const entitlement = this.snapshot(organizationID).verifiedEntitlement as { quotas: { editorSeats: number } } | null;
    const seats = entitlement?.quotas.editorSeats ?? 1;
    const editors = this.store.all<{ user_id: string }>("SELECT user_id FROM memberships WHERE organization_id = ? AND role <> 'viewer' ORDER BY CASE role WHEN 'owner' THEN 0 ELSE 1 END, created_at, user_id LIMIT ?", organizationID, seats);
    if (!editors.some(editor => editor.user_id === userID)) throw new ApiError(402, 'editor_seat_required', 'This account has read access; an active editor seat is required for changes');
  }
}
