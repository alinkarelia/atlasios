import assert from 'node:assert/strict';
import { randomUUID, X509Certificate } from 'node:crypto';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test, { type TestContext } from 'node:test';
import { buildApp } from '../src/app.js';
import { AppleBilling, appleConfiguration } from '../src/billing.js';
import { ApiError } from '../src/domain.js';
import { Store } from '../src/store.js';

const certificatePath = fileURLToPath(new URL('./fixtures/apple-test-root.pem', import.meta.url));
const environment = {
  APPLE_BUNDLE_ID: 'com.atlasfield.app',
  APPLE_ENVIRONMENT: 'Sandbox',
  APPLE_ROOT_CERT_PATHS: certificatePath,
};
const pro = 'com.atlasfield.pro.monthly';
const business3 = 'com.atlasfield.business3.monthly';
const business10 = 'com.atlasfield.business10.monthly';
const baseline = ['captureLiDAR', 'editGeometry', 'measure', 'exportOwnData'];
const password = 'Atlas-Billing-Regression-Password';
let transactionSequence = 100000;

type Account = { token: string; user: { id: string; email: string }; organization: { id: string } };
type App = Awaited<ReturnType<typeof buildApp>>;
type StoredSubscription = { originalID: string; transactionID: string; signedAt: number; productID: string };

function jsonBase64(value: unknown) { return Buffer.from(JSON.stringify(value)).toString('base64url'); }

function forgedTransaction(accountToken: string, chain: string[] = []) {
  const now = Date.now();
  return `${jsonBase64({ alg: 'ES256', typ: 'JWT', x5c: chain })}.${jsonBase64({
    transactionId: '200000000000001', originalTransactionId: '200000000000001',
    bundleId: environment.APPLE_BUNDLE_ID, environment: 'Sandbox', productId: business10,
    appAccountToken: accountToken, type: 'Auto-Renewable Subscription', inAppOwnershipType: 'PURCHASED',
    quantity: 1, purchaseDate: now - 60_000, expiresDate: now + 86_400_000, signedDate: now,
  })}.${Buffer.alloc(64).toString('base64url')}`;
}

function apiError(status: number, code: string) {
  return (error: unknown) => error instanceof ApiError && error.status === status && error.code === code;
}

function seedIdentity(store: Store, organizationID = randomUUID(), userID = randomUUID(), role = 'owner') {
  const createdAt = new Date().toISOString();
  store.run('INSERT INTO users VALUES (?, ?, ?, ?, ?)', userID, `${userID}@example.test`,
    'Trusted stored account', 'not-an-authentication-fixture', createdAt);
  store.run('INSERT INTO organizations VALUES (?, ?, ?, ?)', organizationID, 'Stored organization', 'free', createdAt);
  store.run('INSERT INTO memberships VALUES (?, ?, ?, ?)', organizationID, userID, role, createdAt);
  return { organizationID, userID };
}

function unitFixture(t: TestContext, overrides: NodeJS.ProcessEnv = {}) {
  const store = new Store(':memory:');
  t.after(() => store.close());
  const billing = new AppleBilling(store, { ...environment, ...overrides });
  assert.equal(billing.configured, true);
  const identity = seedIdentity(store);
  return { store, billing, ...identity };
}

/** These rows represent already verified persisted Apple data, not an HTTP verification bypass. */
function seedSubscription(store: Store, organizationID: string, userID: string,
  options: { productID?: string; originalID?: string; purchasedAt?: number; expiresAt?: number;
    revokedAt?: number | null; upgraded?: boolean; signedAt?: number; graceUntil?: number;
    renewalProductID?: string; renewalSignedAt?: number } = {}): StoredSubscription {
  const now = Date.now();
  const transactionID = String(++transactionSequence);
  const originalID = options.originalID ?? transactionID;
  const productID = options.productID ?? business3;
  const signedAt = options.signedAt ?? now - 1000;
  store.run('INSERT OR IGNORE INTO apple_bindings VALUES (?, ?, ?, ?, ?)',
    originalID, 'Sandbox', organizationID, userID, new Date(now).toISOString());
  store.run('INSERT INTO apple_transactions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    transactionID, 'Sandbox', originalID, productID, userID,
    options.purchasedAt ?? now - 3_600_000, options.expiresAt ?? now + 3_600_000,
    options.revokedAt ?? null, options.upgraded ? 1 : 0, signedAt,
    'trusted-persisted-transaction-hash', new Date(now).toISOString());
  store.run('INSERT INTO billing_state VALUES (?, 1, ?) ON CONFLICT(organization_id) DO UPDATE SET revision = revision + 1, updated_at = excluded.updated_at',
    organizationID, new Date(now).toISOString());
  if (options.graceUntil !== undefined) {
    store.run('INSERT INTO apple_renewals VALUES (?, ?, ?, ?, ?, ?)', originalID, 'Sandbox',
      options.renewalProductID ?? productID, options.graceUntil, options.renewalSignedAt ?? signedAt + 1,
      'trusted-persisted-renewal-hash');
  }
  return { originalID, transactionID, signedAt, productID };
}

async function appFixture(t: TestContext, billingEnvironment: NodeJS.ProcessEnv = environment) {
  const directory = await mkdtemp(join(tmpdir(), 'atlas-apple-billing-test-'));
  const databasePath = join(directory, 'atlas.sqlite');
  const app = await buildApp({ databasePath, logger: false, rateLimit: false, billingEnvironment });
  const store = new Store(databasePath);
  t.after(async () => {
    await app.close();
    store.close();
    await rm(directory, { recursive: true, force: true });
  });
  return { app, store };
}

async function register(app: App, name = 'Billing owner'): Promise<Account> {
  const response = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: {
    email: `${randomUUID()}@example.test`, password, displayName: name, organizationName: `${name} office`,
  } });
  assert.equal(response.statusCode, 201, response.body);
  return response.json<Account>();
}

function auth(account: Account) { return { authorization: `Bearer ${account.token}` }; }

test('real Apple SignedDataVerifier rejects forged JWS and cannot create a paid entitlement', async t => {
  const { app, store } = await appFixture(t);
  const owner = await register(app);
  const root = new X509Certificate(await readFile(certificatePath)).raw.toString('base64');
  const tokens = [forgedTransaction(owner.user.id), forgedTransaction(owner.user.id, [root, root, root])];

  const initial = await app.inject({ method: 'GET',
    url: `/v1/organizations/${owner.organization.id}/billing`, headers: auth(owner) });
  assert.equal(initial.statusCode, 200);
  assert.equal(initial.json().appleVerificationAvailable, true);
  assert.equal(initial.json().prototypeMode, false);
  assert.equal(initial.json().verifiedEntitlement, null);

  for (const signedTransaction of tokens) {
    const verification = await app.inject({ method: 'POST',
      url: `/v1/organizations/${owner.organization.id}/billing/apple/verify`,
      headers: auth(owner), payload: { signedTransaction } });
    assert.equal(verification.statusCode, 400, verification.body);
    assert.equal(verification.json().error.code, 'invalid_apple_signature');
  }
  const notification = await app.inject({ method: 'POST', url: '/v1/billing/apple/notifications',
    payload: { signedPayload: `${jsonBase64({ alg: 'none' })}.${jsonBase64({
      notificationUUID: randomUUID(), notificationType: 'TEST', signedDate: Date.now(),
      data: { bundleId: environment.APPLE_BUNDLE_ID, environment: 'Sandbox' },
    })}.` } });
  assert.equal(notification.statusCode, 400);
  assert.equal(notification.json().error.code, 'invalid_apple_signature');

  const after = await app.inject({ method: 'GET',
    url: `/v1/organizations/${owner.organization.id}/billing`, headers: auth(owner) });
  assert.deepEqual(after.json(), initial.json());
  for (const table of ['apple_transactions', 'apple_bindings', 'apple_notifications', 'billing_state']) {
    assert.equal(store.get<{ n: number }>(`SELECT COUNT(*) AS n FROM ${table}`)!.n, 0);
  }
});

test('partial or invalid commercial configuration fails closed rather than enabling prototype paid actions', async t => {
  const invalidConfigurations: NodeJS.ProcessEnv[] = [
    { APPLE_BUNDLE_ID: environment.APPLE_BUNDLE_ID },
    { ...environment, APPLE_ENVIRONMENT: 'Production' },
    { ...environment, APPLE_ROOT_CERT_PATHS: '/nonexistent/apple-root.pem' },
    { ...environment, APPLE_ALLOWED_PRODUCT_IDS: 'com.atlasfield.enterprise.monthly' },
  ];
  for (const [index, config] of invalidConfigurations.entries()) {
    await t.test(`configuration ${index + 1}`, async t => {
      const { app, store } = await appFixture(t, config);
      const owner = await register(app);
      const billing = await app.inject({ method: 'GET',
        url: `/v1/organizations/${owner.organization.id}/billing`, headers: auth(owner) });
      assert.equal(billing.statusCode, 200);
      assert.equal(billing.json().plan, 'free');
      assert.equal(billing.json().appleVerificationAvailable, false);
      assert.equal(billing.json().prototypeMode, false);
      assert.equal(billing.json().verifiedEntitlement, null);
      const verification = await app.inject({ method: 'POST',
        url: `/v1/organizations/${owner.organization.id}/billing/apple/verify`, headers: auth(owner),
        payload: { signedTransaction: forgedTransaction(owner.user.id) } });
      assert.equal(verification.statusCode, 503);
      assert.equal(verification.json().error.code, 'billing_not_configured');

      const member = await register(app, 'Member');
      const addition = await app.inject({ method: 'POST',
        url: `/v1/organizations/${owner.organization.id}/members`, headers: auth(owner),
        payload: { email: member.user.email, role: 'surveyor' } });
      assert.equal(addition.statusCode, 503);
      assert.equal(addition.json().error.code, 'billing_not_configured');
      assert.equal(store.get<{ n: number }>('SELECT COUNT(*) AS n FROM apple_transactions')!.n, 0);
    });
  }
});

test('configured Free blocks team and business writes while retaining access to existing project data', async t => {
  const { app, store } = await appFixture(t);
  const owner = await register(app);
  const member = await register(app, 'Member');
  const project = await app.inject({ method: 'POST', url: '/v1/projects', headers: auth(owner), payload: {
    organizationID: owner.organization.id, name: 'Existing cemetery', kind: 'cemetery',
    coordinateReference: { localMeters: { frameID: randomUUID() } },
  } });
  assert.equal(project.statusCode, 201, project.body);
  const projectID = project.json().id;

  const addMember = () => app.inject({ method: 'POST',
    url: `/v1/organizations/${owner.organization.id}/members`, headers: auth(owner),
    payload: { email: member.user.email, role: 'surveyor' } });
  const createWorkorder = () => app.inject({ method: 'POST',
    url: `/v1/projects/${projectID}/workorders`, headers: auth(owner), payload: {
      operationID: randomUUID(), data: { title: 'Preserved estimate', clientName: 'Client',
        currency: 'USD', estimatedAmountMinor: 85000 },
    } });
  assert.equal((await addMember()).statusCode, 402);
  assert.equal((await createWorkorder()).statusCode, 402);

  const subscription = seedSubscription(store, owner.organization.id, owner.user.id);
  assert.equal((await addMember()).statusCode, 201);
  const saved = await createWorkorder();
  assert.equal(saved.statusCode, 201, saved.body);
  const workorderID = saved.json().id;

  store.run('UPDATE apple_transactions SET expires_at = ? WHERE transaction_id = ?',
    Date.now() - 1000, subscription.transactionID);
  const billing = await app.inject({ method: 'GET',
    url: `/v1/organizations/${owner.organization.id}/billing`, headers: auth(owner) });
  assert.equal(billing.json().plan, 'free');
  assert.equal((await createWorkorder()).statusCode, 402);
  const anotherMember = await register(app, 'Another member');
  const newMembership = await app.inject({ method: 'POST',
    url: `/v1/organizations/${owner.organization.id}/members`, headers: auth(owner),
    payload: { email: anotherMember.user.email, role: 'reviewer' } });
  assert.equal(newMembership.statusCode, 402);

  const readWorkorder = await app.inject({ method: 'GET',
    url: `/v1/projects/${projectID}/workorders/${workorderID}`, headers: auth(owner) });
  assert.equal(readWorkorder.statusCode, 200);
  assert.equal(readWorkorder.json().estimatedAmountMinor, 85000);
  const retainedMemberRead = await app.inject({ method: 'GET', url: `/v1/projects/${projectID}`, headers: auth(member) });
  assert.equal(retainedMemberRead.statusCode, 200);
});

test('trusted persisted transactions distinguish active, expired, revoked, upgraded and billing grace', async t => {
  const now = Date.now();
  const cases = [
    { name: 'active', options: { expiresAt: now + 3_600_000 }, status: 'active', plan: 'business' },
    { name: 'expired', options: { expiresAt: now - 1000 }, status: 'expired', plan: 'free' },
    { name: 'revoked', options: { revokedAt: now - 1000 }, status: 'revoked', plan: 'free' },
    { name: 'upgraded transaction', options: { upgraded: true }, status: 'expired', plan: 'free' },
    { name: 'billing grace', options: { expiresAt: now - 1000, graceUntil: now + 60_000 }, status: 'billingGrace', plan: 'business' },
    { name: 'ended billing grace', options: { expiresAt: now - 10_000, graceUntil: now - 1000 }, status: 'expired', plan: 'free' },
    { name: 'revocation overrides grace', options: { expiresAt: now - 1000, revokedAt: now - 1000,
      graceUntil: now + 60_000 }, status: 'revoked', plan: 'free' },
    { name: 'stale renewal cannot grant grace', options: { expiresAt: now - 1000, graceUntil: now + 60_000,
      signedAt: now - 1000, renewalSignedAt: now - 2000 }, status: 'expired', plan: 'free' },
    { name: 'different renewal product cannot grant grace', options: { expiresAt: now - 1000,
      graceUntil: now + 60_000, renewalProductID: business10 }, status: 'expired', plan: 'free' },
  ];
  for (const row of cases) {
    await t.test(row.name, t => {
      const { store, billing, organizationID, userID } = unitFixture(t);
      seedSubscription(store, organizationID, userID, row.options);
      const snapshot = billing.snapshot(organizationID) as any;
      assert.equal(snapshot.plan, row.plan);
      assert.equal(snapshot.verifiedEntitlement.status, row.status);
      assert.equal(snapshot.verifiedEntitlement.source, 'serverVerified');
      assert.equal(snapshot.verifiedEntitlement.scope.organization._0, organizationID);
      assert.equal(snapshot.verifiedEntitlement.quotas.editorSeats, row.plan === 'business' ? 3 : 1);
      assert.equal(snapshot.verifiedEntitlement.quotas.cloudStorageBytes, null);
      assert.equal(snapshot.verifiedEntitlement.quotas.computeCredits, null);
      assert.ok(!snapshot.verifiedEntitlement.capabilities.some((value: string) => /cloud|integration/i.test(value)));
      if (row.plan === 'free') {
        assert.deepEqual(snapshot.verifiedEntitlement.capabilities, baseline);
        assert.equal(snapshot.verifiedEntitlement.offlineValidUntil, null);
        assert.throws(() => billing.requireCapability(organizationID, 'teamManagement'), apiError(402, 'subscription_required'));
      } else {
        assert.ok(snapshot.verifiedEntitlement.capabilities.includes('businessWorkflow'));
        const offline = Date.parse(snapshot.verifiedEntitlement.offlineValidUntil);
        assert.ok(offline > Date.now());
        assert.ok(offline <= Date.parse(snapshot.verifiedEntitlement.validUntil));
        assert.ok(offline <= Date.now() + 86_400_000);
      }
    });
  }
});

test('only the six fixed Atlas products grant the documented seat counts and implemented capabilities', async t => {
  const expectedProducts = [
    ['com.atlasfield.pro.monthly', 'pro', 1], ['com.atlasfield.pro.yearly', 'pro', 1],
    ['com.atlasfield.business3.monthly', 'business', 3], ['com.atlasfield.business3.yearly', 'business', 3],
    ['com.atlasfield.business10.monthly', 'business', 10], ['com.atlasfield.business10.yearly', 'business', 10],
  ] as const;
  assert.deepEqual(appleConfiguration(environment)!.products.map(product =>
    [product.productID, product.plan, product.editorSeats]), expectedProducts);
  for (const [productID, plan, editorSeats] of expectedProducts) {
    await t.test(productID, t => {
      const { store, billing, organizationID, userID } = unitFixture(t);
      seedSubscription(store, organizationID, userID, { productID });
      const snapshot = billing.snapshot(organizationID) as any;
      assert.equal(snapshot.plan, plan);
      assert.equal(snapshot.verifiedEntitlement.quotas.editorSeats, editorSeats);
      const expectedCapabilities = [...baseline, 'advancedPlans',
        ...(plan === 'business' ? ['teamManagement', 'businessWorkflow'] : [])];
      assert.deepEqual(snapshot.verifiedEntitlement.capabilities, expectedCapabilities);
      assert.equal(snapshot.verifiedEntitlement.tier, plan);
      if (plan === 'pro') assert.throws(() => billing.requireCapability(organizationID, 'businessWorkflow'), apiError(402, 'subscription_required'));
      else assert.doesNotThrow(() => billing.requireCapability(organizationID, 'businessWorkflow'));
    });
  }
});

test('unknown or non-allowed products in trusted storage cannot grant a paid plan', async t => {
  for (const productID of ['com.atlasfield.enterprise.monthly', 'arbitrary.paid.product', business10]) {
    await t.test(productID, t => {
      const { store, billing, organizationID, userID } = unitFixture(t, { APPLE_ALLOWED_PRODUCT_IDS: pro });
      seedSubscription(store, organizationID, userID, { productID });
      const snapshot = billing.snapshot(organizationID) as any;
      assert.equal(snapshot.plan, 'free');
      assert.equal(snapshot.verifiedEntitlement, null);
      assert.throws(() => billing.requireCapability(organizationID, 'businessWorkflow'), apiError(402, 'subscription_required'));
    });
  }
});

test('an upgraded old transaction cannot override the current product, and active Business 10 wins over Business 3', t => {
  const { store, billing, organizationID, userID } = unitFixture(t);
  const now = Date.now();
  const old = seedSubscription(store, organizationID, userID,
    { productID: business3, upgraded: true, purchasedAt: now - 10_000, expiresAt: now + 172_800_000 });
  seedSubscription(store, organizationID, userID, { productID: business10, originalID: old.originalID,
    purchasedAt: now - 5000, signedAt: now - 1000, expiresAt: now + 86_400_000 });
  assert.equal((billing.snapshot(organizationID).verifiedEntitlement as any).quotas.editorSeats, 10);

  seedSubscription(store, organizationID, userID, { productID: business3, expiresAt: now + 259_200_000 });
  const selected = billing.snapshot(organizationID) as any;
  assert.equal(selected.plan, 'business');
  assert.equal(selected.verifiedEntitlement.quotas.editorSeats, 10);
});

test('Business 3 and Business 10 enforce editor quotas, spare viewers, and retain only the owner seat after expiry', async t => {
  for (const [productID, seats] of [[business3, 3], [business10, 10]] as const) {
    await t.test(`${seats} seats`, t => {
      const { store, billing, organizationID, userID } = unitFixture(t);
      const subscription = seedSubscription(store, organizationID, userID, { productID });
      const editors: string[] = [];
      for (let index = 1; index < seats; index++) {
        assert.doesNotThrow(() => billing.requireSeat(organizationID, 'surveyor'));
        const editorID = randomUUID();
        const createdAt = new Date(Date.now() + index).toISOString();
        store.run('INSERT INTO users VALUES (?, ?, ?, ?, ?)', editorID, `${editorID}@example.test`,
          'Stored editor', 'not-an-authentication-fixture', createdAt);
        store.run('INSERT INTO memberships VALUES (?, ?, ?, ?)', organizationID, editorID, 'surveyor', createdAt);
        editors.push(editorID);
      }
      assert.throws(() => billing.requireSeat(organizationID, 'reviewer'), apiError(402, 'seat_quota_exceeded'));
      assert.doesNotThrow(() => billing.requireSeat(organizationID, 'viewer'));
      assert.doesNotThrow(() => billing.requireEditorSeat(organizationID, userID));
      for (const editorID of editors) assert.doesNotThrow(() => billing.requireEditorSeat(organizationID, editorID));

      store.run('UPDATE apple_transactions SET expires_at = ? WHERE transaction_id = ?', Date.now() - 1000, subscription.transactionID);
      assert.equal(billing.snapshot(organizationID).plan, 'free');
      assert.doesNotThrow(() => billing.requireEditorSeat(organizationID, userID));
      for (const editorID of editors) assert.throws(() => billing.requireEditorSeat(organizationID, editorID), apiError(402, 'editor_seat_required'));
      assert.equal(store.get<{ n: number }>('SELECT COUNT(*) AS n FROM memberships WHERE organization_id = ?', organizationID)!.n, seats);
    });
  }
});
