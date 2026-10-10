import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import type { HTTPMethods } from 'fastify';
import { buildApp } from '../src/app.js';

type App = Awaited<ReturnType<typeof buildApp>>;
type Account = {
  token: string;
  user: { id: string; email: string; displayName: string };
  organization: { id: string; name: string };
};
type Project = {
  id: string;
  organizationID: string;
  coordinateReference: { localMeters: { frameID: string } };
  revision: number;
};
type Operation = {
  operationID: string;
  entity: string;
  action: string;
  id: string;
  baseRevision: number;
  data?: Record<string, unknown>;
};

const password = 'Field-Survey-Strong-Password-2026';

async function fixture(t: TestContext) {
  const directory = await mkdtemp(join(tmpdir(), 'atlas-api-test-'));
  const databasePath = join(directory, 'atlas.sqlite');
  const app = await buildApp({ databasePath, logger: false, rateLimit: false, billingEnvironment: {} });
  await app.ready();
  t.after(async () => {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  });
  return app;
}

async function request(app: App, method: HTTPMethods, url: string,
  token?: string, payload?: Record<string, unknown>) {
  return app.inject({ method, url,
    headers: token ? { authorization: `Bearer ${token}` } : {},
    ...(payload === undefined ? {} : { payload }),
  });
}

function success(response: { statusCode: number; body: string }) {
  assert.ok(response.statusCode >= 200 && response.statusCode < 300,
    `Expected successful response, received ${response.statusCode}: ${response.body}`);
}

async function register(app: App, label = 'owner'): Promise<Account> {
  const email = `${label}-${randomUUID()}@example.test`;
  const response = await request(app, 'POST', '/v1/auth/register', undefined,
    { email, password, displayName: label, organizationName: `${label} organization` });
  success(response);
  const account = response.json<Account>();
  assert.equal(account.user.email, email);
  assert.ok(account.token);
  assert.ok(account.user.id);
  assert.ok(account.organization.id);
  assert.ok(!response.body.includes('password_hash'));
  assert.ok(!response.body.includes(password));
  return account;
}

async function createProject(app: App, account: Account, name = 'Survey',
  options: Record<string, unknown> = {}): Promise<Project> {
  const response = await request(app, 'POST', '/v1/projects', account.token, {
    organizationID: account.organization.id,
    name, kind: 'cemetery',
    coordinateReference: { localMeters: { frameID: randomUUID() } },
    ...options,
  });
  success(response);
  return response.json<Project>();
}

async function addMember(app: App, owner: Account, member: Account, role: string) {
  const response = await request(app, 'POST',
    `/v1/organizations/${owner.organization.id}/members`, owner.token,
    { email: member.user.email, role });
  success(response);
}

function featureOperation(project: Project, overrides: Partial<Operation> = {}): Operation {
  const frameID = project.coordinateReference.localMeters.frameID;
  return {
    operationID: randomUUID(), entity: 'feature', action: 'upsert', id: randomUUID(), baseRevision: 0,
    data: {
      label: 'A-001', category: 'grave',
      geometry: { metricPolygon: { _0: { frameID,
        vertices: [{ x: 0, y: 0 }, { x: 2, y: 0 }, { x: 2, y: 3 }, { x: 0, y: 3 }], holes: [] } } },
      attributes: { source: 'field observation' }, notes: '',
    },
    ...overrides,
  };
}

async function push(app: App, project: Project, account: Account, operations: Operation[]) {
  const response = await request(app, 'POST', `/v1/projects/${project.id}/sync/push`, account.token,
    { operations });
  success(response);
  const body = response.json();
  assert.equal(body.results.length, operations.length);
  return body;
}

async function getFeature(app: App, project: Project, account: Account, id: string) {
  const response = await request(app, 'GET', `/v1/projects/${project.id}/features/${id}`, account.token);
  success(response);
  return response.json();
}

function deniedMutation(response: { statusCode: number; body: string; json: () => any }) {
  if (response.statusCode === 403) return;
  assert.equal(response.statusCode, 200, response.body);
  const results = response.json().results;
  assert.ok(Array.isArray(results) && results.length > 0);
  for (const result of results) {
    assert.equal(result.status, 'rejected');
    assert.ok(result.code);
  }
}

test('registration, login and logout isolate sessions and do not expose password material', async t => {
  const app = await fixture(t);
  const owner = await register(app);

  const duplicate = await request(app, 'POST', '/v1/auth/register', undefined, {
    email: owner.user.email.toUpperCase(), password, displayName: 'Duplicate', organizationName: 'Duplicate',
  });
  assert.equal(duplicate.statusCode, 409);

  for (const email of [owner.user.email, 'unknown@example.test']) {
    const invalid = await request(app, 'POST', '/v1/auth/login', undefined,
      { email, password: 'a-different-long-password' });
    assert.equal(invalid.statusCode, 401);
  }

  const login = await request(app, 'POST', '/v1/auth/login', undefined,
    { email: owner.user.email.toUpperCase(), password });
  success(login);
  const secondToken = login.json().token as string;
  assert.ok(secondToken);
  assert.notEqual(secondToken, owner.token);

  const logout = await request(app, 'POST', '/v1/auth/logout', owner.token);
  success(logout);
  const revoked = await request(app, 'POST', '/v1/projects', owner.token,
    { organizationID: owner.organization.id, name: 'Revoked', kind: 'cemetery', coordinateReference: { wgs84: {} } });
  assert.equal(revoked.statusCode, 401);
  await createProject(app, { ...owner, token: secondToken }, 'Surviving session');
});

test('account validation rejects weak passwords and malformed email before registration', async t => {
  const app = await fixture(t);
  const defaults = { email: `valid-${randomUUID()}@example.test`, password,
    displayName: 'Field worker', organizationName: 'Survey office' };
  for (const change of [{ password: 'short' }, { email: 'not-an-email' }, { organizationName: '' },
    { displayName: ' \t ' }, { organizationName: '   ' }]) {
    const response = await request(app, 'POST', '/v1/auth/register', undefined, { ...defaults, ...change });
    assert.equal(response.statusCode, 400, response.body);
  }
});

test('tokens and tenant membership protect project creation and feature access', async t => {
  const app = await fixture(t);
  const first = await register(app, 'first');
  const second = await register(app, 'second');
  const project = await createProject(app, first, 'Private cemetery');
  const operation = featureOperation(project);
  assert.equal((await push(app, project, first, [operation])).results[0].status, 'applied');

  for (const token of [undefined, 'not-a-session']) {
    const response = await request(app, 'GET', `/v1/projects/${project.id}/features/${operation.id}`, token);
    assert.equal(response.statusCode, 401);
  }

  const inaccessible = await request(app, 'GET', `/v1/projects/${project.id}/features/${operation.id}`, second.token);
  assert.equal(inaccessible.statusCode, 404);
  assert.ok(!inaccessible.body.includes('A-001'));

  const unauthorizedCreate = await request(app, 'POST', '/v1/projects', second.token, {
    organizationID: first.organization.id, name: 'Intrusion', kind: 'cemetery', coordinateReference: { wgs84: {} },
  });
  assert.equal(unauthorizedCreate.statusCode, 404);

  const unauthorizedPush = await request(app, 'POST', `/v1/projects/${project.id}/sync/push`, second.token,
    { operations: [featureOperation(project)] });
  assert.equal(unauthorizedPush.statusCode, 404);

  const unauthorizedMembership = await request(app, 'POST',
    `/v1/organizations/${first.organization.id}/members`, second.token,
    { email: second.user.email, role: 'admin' });
  assert.equal(unauthorizedMembership.statusCode, 404);
});

test('sync retries apply exactly once and reject reuse of an operation ID with different data', async t => {
  const app = await fixture(t);
  const owner = await register(app);
  const project = await createProject(app, owner);
  const operation = featureOperation(project);
  const first = await push(app, project, owner, [operation]);
  assert.equal(first.results[0].status, 'applied');
  const original = await getFeature(app, project, owner, operation.id);
  assert.equal(original.revision, 1);

  const retry = await push(app, project, owner, [operation]);
  assert.deepEqual(retry.results, first.results);
  assert.equal(retry.cursor, first.cursor);
  assert.deepEqual(await getFeature(app, project, owner, operation.id), original);

  const changedPayload = { ...operation, data: { ...operation.data, label: 'Silently changed on retry' } };
  const reuse = await push(app, project, owner, [changedPayload]);
  assert.equal(reuse.results[0].status, 'rejected');
  assert.ok(reuse.results[0].code);
  assert.deepEqual(await getFeature(app, project, owner, operation.id), original);
});

test('baseRevision detects competing edits and preserves the winning feature', async t => {
  const app = await fixture(t);
  const owner = await register(app);
  const project = await createProject(app, owner);
  const initial = featureOperation(project);
  assert.equal((await push(app, project, owner, [initial])).results[0].status, 'applied');
  const editA = { ...initial, operationID: randomUUID(), baseRevision: 1,
    data: { ...initial.data, label: 'Edit A' } };
  const editB = { ...initial, operationID: randomUUID(), baseRevision: 1,
    data: { ...initial.data, label: 'Edit B' } };
  const [resultA, resultB] = await Promise.all([
    push(app, project, owner, [editA]), push(app, project, owner, [editB]),
  ]);
  assert.deepEqual([resultA.results[0].status, resultB.results[0].status].sort(), ['applied', 'conflict']);
  const current = await getFeature(app, project, owner, initial.id);
  assert.equal(current.revision, 2);
  const winner = resultA.results[0].status === 'applied' ? resultA : resultB;
  const loser = resultA.results[0].status === 'conflict' ? resultA : resultB;
  assert.deepEqual(current, winner.results[0].record);
  assert.deepEqual(loser.results[0].current, current);

  const staleDelete: Operation = { operationID: randomUUID(), entity: 'feature', action: 'delete',
    id: initial.id, baseRevision: 1 };
  assert.equal((await push(app, project, owner, [staleDelete])).results[0].status, 'conflict');
  assert.deepEqual(await getFeature(app, project, owner, initial.id), current);
});

test('invalid geometry cannot be persisted or masquerade as accurately georeferenced data', async t => {
  const app = await fixture(t);
  const owner = await register(app);
  const project = await createProject(app, owner);
  const frameID = project.coordinateReference.localMeters.frameID;
  const geometries = [
    { metricPolygon: { _0: { frameID: randomUUID(),
      vertices: [{ x: 0, y: 0 }, { x: 2, y: 0 }, { x: 0, y: 2 }], holes: [] } } },
    { metricPolygon: { _0: { frameID,
      vertices: [{ x: 0, y: 0 }, { x: 2, y: 2 }, { x: 0, y: 2 }, { x: 2, y: 0 }], holes: [] } } },
    { metricPolygon: { _0: { frameID,
      vertices: [{ x: 0, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 2 }], holes: [] } } },
    { metricPolygon: { _0: { frameID,
      vertices: [{ x: 0, y: 0 }, { x: 3, y: 0 }, { x: 3, y: 3 }, { x: 0, y: 3 }],
      holes: [[{ x: 5, y: 5 }, { x: 6, y: 5 }, { x: 5, y: 6 }]] } } },
    { geographicPolygon: { _0: {
      vertices: [{ longitude: 37, latitude: 55 }, { longitude: 37.001, latitude: 55 },
        { longitude: 37, latitude: 55.001 }], holes: [] } } },
  ];
  for (const geometry of geometries) {
    const operation = featureOperation(project);
    operation.data = { ...operation.data, geometry };
    const result = await push(app, project, owner, [operation]);
    assert.equal(result.results[0].status, 'rejected');
    assert.equal(result.results[0].code, 'invalid_input');
    const response = await request(app, 'GET', `/v1/projects/${project.id}/features/${operation.id}`, owner.token);
    assert.equal(response.statusCode, 404);
  }
});

test('viewer and reviewer can inspect features but cannot bypass their mutation permissions', async t => {
  const app = await fixture(t);
  const owner = await register(app, 'owner');
  const viewer = await register(app, 'viewer');
  const reviewer = await register(app, 'reviewer');
  await addMember(app, owner, viewer, 'viewer');
  await addMember(app, owner, reviewer, 'reviewer');
  const project = await createProject(app, owner);
  const initial = featureOperation(project);
  assert.equal((await push(app, project, owner, [initial])).results[0].status, 'applied');
  const original = await getFeature(app, project, owner, initial.id);

  for (const account of [viewer, reviewer]) {
    assert.deepEqual(await getFeature(app, project, account, initial.id), original);
    const edit = featureOperation(project, { id: initial.id, baseRevision: 1,
      data: { ...initial.data, label: 'Unauthorized modification' } });
    deniedMutation(await request(app, 'POST', `/v1/projects/${project.id}/sync/push`, account.token,
      { operations: [edit] }));
    assert.deepEqual(await getFeature(app, project, owner, initial.id), original);

    const membership = await request(app, 'POST',
      `/v1/organizations/${owner.organization.id}/members`, account.token,
      { email: account.user.email, role: 'admin' });
    assert.equal(membership.statusCode, 403);
  }

  const viewerReview = await request(app, 'POST', `/v1/projects/${project.id}/reviews`, viewer.token,
    { operationID: randomUUID(), featureID: initial.id, revision: 1, verdict: 'accepted' });
  assert.equal(viewerReview.statusCode, 403);
  const review = await request(app, 'POST', `/v1/projects/${project.id}/reviews`, reviewer.token,
    { operationID: randomUUID(), featureID: initial.id, revision: 1, verdict: 'accepted' });
  success(review);
});

test('cross-project links, cross-project record IDs and foreign assignees are rejected', async t => {
  const app = await fixture(t);
  const owner = await register(app, 'owner');
  const outsider = await register(app, 'outsider');
  const project = await createProject(app, owner, 'Sector A');
  const otherProject = await createProject(app, owner, 'Sector B');
  const target = featureOperation(otherProject);
  assert.equal((await push(app, otherProject, owner, [target])).results[0].status, 'applied');
  const originalTarget = await getFeature(app, otherProject, owner, target.id);

  const invalidLink = featureOperation(project);
  invalidLink.data = { ...invalidLink.data, links: [{ relation: 'parent', targetID: target.id }] };
  assert.equal((await push(app, project, owner, [invalidLink])).results[0].status, 'rejected');

  const hijack = featureOperation(project, { id: target.id, baseRevision: 1 });
  assert.equal((await push(app, project, owner, [hijack])).results[0].status, 'rejected');
  assert.deepEqual(await getFeature(app, otherProject, owner, target.id), originalTarget);

  const validFeature = featureOperation(project);
  assert.equal((await push(app, project, owner, [validFeature])).results[0].status, 'applied');
  const invalidTasks: Operation[] = [
    { operationID: randomUUID(), entity: 'task', action: 'upsert', id: randomUUID(), baseRevision: 0,
      data: { title: 'Outside project', targetFeatureID: target.id, assigneeID: owner.user.id } },
    { operationID: randomUUID(), entity: 'task', action: 'upsert', id: randomUUID(), baseRevision: 0,
      data: { title: 'Outside organization', targetFeatureID: validFeature.id, assigneeID: outsider.user.id } },
    { operationID: randomUUID(), entity: 'task', action: 'upsert', id: randomUUID(), baseRevision: 0,
      data: { title: 'Missing assignee', assigneeID: randomUUID() } },
  ];
  const invalidResult = await push(app, project, owner, invalidTasks);
  assert.ok(invalidResult.results.every((result: { status: string }) => result.status === 'rejected'));

  const validTask: Operation = {
    operationID: randomUUID(), entity: 'task', action: 'upsert', id: randomUUID(), baseRevision: 0,
    data: { title: 'Inspect place', targetFeatureID: validFeature.id, assigneeID: owner.user.id },
  };
  assert.equal((await push(app, project, owner, [validTask])).results[0].status, 'applied');
});

test('acceptance identifies an immutable feature revision while later edits create a new draft', async t => {
  const app = await fixture(t);
  const owner = await register(app, 'owner');
  const reviewer = await register(app, 'reviewer');
  await addMember(app, owner, reviewer, 'reviewer');
  const project = await createProject(app, owner);
  const initial = featureOperation(project);
  assert.equal((await push(app, project, owner, [initial])).results[0].status, 'applied');
  const historicalURL = `/v1/projects/${project.id}/features/${initial.id}/revisions/1`;
  const beforeReview = await request(app, 'GET', historicalURL, reviewer.token);
  success(beforeReview);
  const originalRevision = beforeReview.json();
  assert.equal(originalRevision.revision, 1);
  assert.ok(originalRevision.contentHash);
  assert.ok(originalRevision.snapshot);

  const reviewPayload = { operationID: randomUUID(), featureID: initial.id, revision: 1,
    verdict: 'accepted', note: 'Verified against field photographs' };
  const accepted = await request(app, 'POST', `/v1/projects/${project.id}/reviews`, reviewer.token, reviewPayload);
  success(accepted);
  const acceptedCurrent = await getFeature(app, project, owner, initial.id);
  assert.equal(acceptedCurrent.reviewStatus, 'reviewed');
  assert.equal(acceptedCurrent.acceptedRevision, 1);
  const reverseAcceptance = await request(app, 'POST', `/v1/projects/${project.id}/reviews`, reviewer.token,
    { operationID: randomUUID(), featureID: initial.id, revision: 1,
      verdict: 'changes_requested', note: 'Attempt to modify an accepted revision' });
  assert.equal(reverseAcceptance.statusCode, 409);
  assert.equal(reverseAcceptance.json().error.code, 'already_accepted');
  const retry = await request(app, 'POST', `/v1/projects/${project.id}/reviews`, reviewer.token, reviewPayload);
  success(retry);
  assert.deepEqual(retry.json(), accepted.json());

  const edit = { ...initial, operationID: randomUUID(), baseRevision: 1,
    data: { ...initial.data, label: 'A-001 corrected', notes: 'New field observation' } };
  assert.equal((await push(app, project, owner, [edit])).results[0].status, 'applied');
  const current = await getFeature(app, project, owner, initial.id);
  assert.equal(current.revision, 2);
  assert.equal(current.reviewStatus, 'draft');
  assert.equal(current.acceptedRevision, 1);

  const afterEdit = await request(app, 'GET', historicalURL, reviewer.token);
  success(afterEdit);
  const historical = afterEdit.json();
  assert.deepEqual(historical.snapshot, originalRevision.snapshot);
  assert.equal(historical.contentHash, originalRevision.contentHash);
  assert.equal(historical.reviews.length, 1);
  assert.equal(historical.reviews[0].verdict, 'accepted');

  const fakeReviewed = featureOperation(project, { id: initial.id, baseRevision: 2,
    data: { ...edit.data, reviewStatus: 'reviewed' } });
  assert.equal((await push(app, project, owner, [fakeReviewed])).results[0].status, 'rejected');
  assert.equal((await getFeature(app, project, owner, initial.id)).revision, 2);
});

test('stored sessions, feature revisions and retry receipts survive a server restart', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'atlas-api-restart-test-'));
  const databasePath = join(directory, 'atlas.sqlite');
  let app = await buildApp({ databasePath, logger: false, rateLimit: false, billingEnvironment: {} });
  t.after(async () => {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  });
  const owner = await register(app);
  const project = await createProject(app, owner);
  const operation = featureOperation(project);
  const first = await push(app, project, owner, [operation]);
  assert.equal(first.results[0].status, 'applied');
  const beforeRestart = await getFeature(app, project, owner, operation.id);

  await app.close();
  app = await buildApp({ databasePath, logger: false, rateLimit: false, billingEnvironment: {} });
  assert.deepEqual(await getFeature(app, project, owner, operation.id), beforeRestart);
  const receipt = await push(app, project, owner, [operation]);
  assert.deepEqual(receipt, first);
  const login = await request(app, 'POST', '/v1/auth/login', undefined,
    { email: owner.user.email, password });
  success(login);
  const afterRestartToken = login.json().token as string;
  const historical = await request(app, 'GET',
    `/v1/projects/${project.id}/features/${operation.id}/revisions/1`, afterRestartToken);
  success(historical);
  assert.equal(historical.json().snapshot.label, 'A-001');
});

test('financial records are omitted from field users in reads and sync, with a usable cursor', async t => {
  const app = await fixture(t);
  const owner = await register(app, 'owner');
  const surveyor = await register(app, 'surveyor');
  const viewer = await register(app, 'viewer');
  await addMember(app, owner, surveyor, 'surveyor');
  await addMember(app, owner, viewer, 'viewer');
  const project = await createProject(app, owner);
  const feature = featureOperation(project);
  const workorder: Operation = {
    operationID: randomUUID(), entity: 'workorder', action: 'upsert', id: randomUUID(), baseRevision: 0,
    data: { title: 'Private pricing', clientName: 'Confidential client', currency: 'USD', estimatedAmountMinor: 125000 },
  };
  const writes = await push(app, project, owner, [feature, workorder]);
  assert.ok(writes.results.every((result: { status: string }) => result.status === 'applied'));

  for (const member of [surveyor, viewer]) {
    for (const route of ['workorders', `workorders/${workorder.id}`, `workorders/${workorder.id}/revisions/1`]) {
      const response = await request(app, 'GET', `/v1/projects/${project.id}/${route}`, member.token);
      assert.equal(response.statusCode, 403);
      assert.ok(!response.body.includes('Confidential client'));
    }
    const pull = await request(app, 'GET', `/v1/projects/${project.id}/sync/pull?cursor=0&limit=1`, member.token);
    success(pull);
    const body = pull.json();
    assert.equal(body.changes.length, 1);
    assert.equal(body.changes[0].entity, 'feature');
    assert.ok(!pull.body.includes('Confidential client'));
    assert.equal(body.cursor, writes.cursor);
    const next = await request(app, 'GET', `/v1/projects/${project.id}/sync/pull?cursor=${body.cursor}`, member.token);
    success(next);
    assert.deepEqual(next.json().changes, []);
  }

  const managerPull = await request(app, 'GET', `/v1/projects/${project.id}/sync/pull`, owner.token);
  success(managerPull);
  assert.ok(managerPull.json().changes.some((change: { entity: string }) => change.entity === 'workorder'));
});

test('membership downgrade revokes writes immediately and prevents replaying an earlier authorized operation', async t => {
  const app = await fixture(t);
  const owner = await register(app, 'owner');
  const surveyor = await register(app, 'surveyor');
  await addMember(app, owner, surveyor, 'surveyor');
  const project = await createProject(app, owner);
  const operation = featureOperation(project);
  assert.equal((await push(app, project, surveyor, [operation])).results[0].status, 'applied');
  const original = await getFeature(app, project, owner, operation.id);

  const downgrade = await request(app, 'PATCH',
    `/v1/organizations/${owner.organization.id}/members/${surveyor.user.id}`, owner.token, { role: 'viewer' });
  success(downgrade);
  const replay = await push(app, project, surveyor, [operation]);
  assert.equal(replay.results[0].status, 'rejected');
  assert.equal(replay.results[0].code, 'forbidden');
  assert.deepEqual(await getFeature(app, project, surveyor, operation.id), original);

  const removal = await request(app, 'DELETE',
    `/v1/organizations/${owner.organization.id}/members/${surveyor.user.id}`, owner.token);
  success(removal);
  const read = await request(app, 'GET', `/v1/projects/${project.id}/features/${operation.id}`, surveyor.token);
  assert.equal(read.statusCode, 404);

  for (const method of ['DELETE', 'PATCH'] as const) {
    const removeLastOwner = await request(app, method,
      `/v1/organizations/${owner.organization.id}/members/${owner.user.id}`, owner.token,
      method === 'PATCH' ? { role: 'viewer' } : undefined);
    assert.equal(removeLastOwner.statusCode, 409);
    assert.equal(removeLastOwner.json().error.code, 'last_owner');
  }
});

test('UUID case does not duplicate projects, features, coordinate frames or retry receipts', async t => {
  const app = await fixture(t);
  const owner = await register(app);
  const projectID = randomUUID();
  const frameID = randomUUID();
  const create = await request(app, 'POST', '/v1/projects', owner.token, {
    id: projectID.toUpperCase(), organizationID: owner.organization.id.toUpperCase(),
    name: 'Swift UUID interoperability', kind: 'cemetery',
    coordinateReference: { localMeters: { frameID: frameID.toUpperCase() } },
  });
  success(create);
  const project = create.json<Project>();
  assert.equal(project.id, projectID);
  assert.equal(project.coordinateReference.localMeters.frameID, frameID);
  const operation = featureOperation(project);
  const first = await push(app, project, owner, [operation]);
  assert.equal(first.results[0].status, 'applied');

  const alternateCase: Operation = {
    ...operation, operationID: operation.operationID.toUpperCase(), id: operation.id.toUpperCase(),
    data: { ...operation.data, geometry: { metricPolygon: { _0: {
      frameID: frameID.toUpperCase(),
      vertices: [{ x: 0, y: 0 }, { x: 2, y: 0 }, { x: 2, y: 3 }, { x: 0, y: 3 }], holes: [],
    } } } },
  };
  const retry = await request(app, 'POST', `/v1/projects/${project.id.toUpperCase()}/sync/push`, owner.token,
    { operations: [alternateCase] });
  success(retry);
  assert.deepEqual(retry.json().results, first.results);
  const uppercaseRead = await request(app, 'GET',
    `/v1/projects/${project.id.toUpperCase()}/features/${operation.id.toUpperCase()}`, owner.token);
  success(uppercaseRead);
  assert.equal(uppercaseRead.json().revision, 1);
  const list = await request(app, 'GET', `/v1/projects/${project.id}/features`, owner.token);
  success(list);
  assert.equal(list.json().features.length, 1);
});

test('UUID normalization preserves user-supplied attribute text', async t => {
  const app = await fixture(t);
  const owner = await register(app);
  const project = await createProject(app, owner);
  const operation = featureOperation(project);
  const externalID = randomUUID().toUpperCase();
  const attributes = { id: externalID, frameID: externalID, organizationID: externalID,
    source: 'ORIGINAL Archive Text' };
  operation.data = { ...operation.data, attributes };
  const result = await push(app, project, owner, [operation]);
  assert.equal(result.results[0].status, 'applied');
  const stored = await getFeature(app, project, owner, operation.id);
  assert.deepEqual(stored.attributes, attributes);
});

test('independent-review policy forbids accepting your own geometry revision', async t => {
  const app = await fixture(t);
  const owner = await register(app, 'owner');
  const reviewer = await register(app, 'reviewer');
  await addMember(app, owner, reviewer, 'reviewer');
  const project = await createProject(app, owner, 'Independent acceptance', { requiresIndependentReview: true });
  const initial = featureOperation(project);
  assert.equal((await push(app, project, owner, [initial])).results[0].status, 'applied');
  const selfReview = await request(app, 'POST', `/v1/projects/${project.id}/reviews`, owner.token,
    { operationID: randomUUID(), featureID: initial.id, revision: 1, verdict: 'accepted' });
  assert.equal(selfReview.statusCode, 403);
  assert.equal(selfReview.json().error.code, 'independent_review_required');
  const current = await getFeature(app, project, owner, initial.id);
  assert.equal(current.reviewStatus, 'draft');
  assert.equal(current.acceptedRevision, null);

  const accepted = await request(app, 'POST', `/v1/projects/${project.id}/reviews`, reviewer.token,
    { operationID: randomUUID(), featureID: initial.id, revision: 1, verdict: 'accepted' });
  success(accepted);
  assert.equal((await getFeature(app, project, owner, initial.id)).reviewStatus, 'reviewed');
});

test('task acceptance requires reviewed geometry and respects reviewer and surveyor roles', async t => {
  const app = await fixture(t);
  const owner = await register(app, 'owner');
  const surveyor = await register(app, 'surveyor');
  const reviewer = await register(app, 'reviewer');
  await addMember(app, owner, surveyor, 'surveyor');
  await addMember(app, owner, reviewer, 'reviewer');
  const project = await createProject(app, owner);
  const feature = featureOperation(project);
  assert.equal((await push(app, project, owner, [feature])).results[0].status, 'applied');
  const task: Operation = {
    operationID: randomUUID(), entity: 'task', action: 'upsert', id: randomUUID(), baseRevision: 0,
    data: { title: 'Inspect cemetery place', targetFeatureID: feature.id, assigneeID: surveyor.user.id },
  };
  assert.equal((await push(app, project, owner, [task])).results[0].status, 'applied');

  const acceptance = { ...task, operationID: randomUUID(), baseRevision: 1,
    data: { ...task.data, status: 'accepted' } };
  const selfAcceptance = await push(app, project, surveyor, [acceptance]);
  assert.equal(selfAcceptance.results[0].status, 'rejected');
  assert.equal(selfAcceptance.results[0].code, 'forbidden');
  const uncheckedGeometry = await push(app, project, reviewer, [acceptance]);
  assert.equal(uncheckedGeometry.results[0].status, 'rejected');
  assert.equal(uncheckedGeometry.results[0].code, 'feature_not_accepted');

  const changedTask = { ...acceptance, operationID: randomUUID(),
    data: { ...acceptance.data, title: 'Reviewer edits task content' } };
  const changed = await push(app, project, reviewer, [changedTask]);
  assert.equal(changed.results[0].status, 'rejected');
  assert.equal(changed.results[0].code, 'forbidden');

  const acceptedGeometry = await request(app, 'POST', `/v1/projects/${project.id}/reviews`, reviewer.token,
    { operationID: randomUUID(), featureID: feature.id, revision: 1, verdict: 'accepted' });
  success(acceptedGeometry);
  const acceptedTask = await push(app, project, reviewer, [{ ...acceptance, operationID: randomUUID() }]);
  assert.equal(acceptedTask.results[0].status, 'applied');
  assert.equal(acceptedTask.results[0].record.status, 'accepted');

  const deletion: Operation = { operationID: randomUUID(), entity: 'feature', action: 'delete',
    id: feature.id, baseRevision: 1 };
  const deleteInUse = await push(app, project, owner, [deletion]);
  assert.equal(deleteInUse.results[0].status, 'rejected');
  assert.equal(deleteInUse.results[0].code, 'feature_in_use');
  assert.equal((await getFeature(app, project, owner, feature.id)).revision, 1);
});

test('unconfigured Apple billing refuses verification and never grants a paid entitlement', async t => {
  const app = await fixture(t);
  const owner = await register(app);
  const billingURL = `/v1/organizations/${owner.organization.id}/billing`;
  const before = await request(app, 'GET', billingURL, owner.token);
  success(before);
  assert.equal(before.json().plan, 'free');
  assert.equal(before.json().verifiedEntitlement, null);

  const verify = await request(app, 'POST', `${billingURL}/apple/verify`, owner.token,
    { signedTransaction: 'unverified-client-supplied-transaction' });
  assert.equal(verify.statusCode, 503);
  assert.equal(verify.json().error.code, 'billing_not_configured');

  const after = await request(app, 'GET', billingURL, owner.token);
  success(after);
  assert.deepEqual(after.json(), before.json());
  assert.equal(after.json().verifiedEntitlement, null);
  assert.equal(after.json().appleVerificationAvailable, false);
});

test('supplied account IDs and spoofing headers cannot replace the authenticated session principal', async t => {
  const app = await fixture(t);
  const owner = await register(app, 'owner');
  const outsider = await register(app, 'outsider');

  for (const field of [{ userID: owner.user.id }, { organizationID: owner.organization.id }]) {
    const login = await request(app, 'POST', '/v1/auth/login', undefined,
      { email: outsider.user.email, password, ...field });
    assert.equal(login.statusCode, 400);
    assert.equal(login.json().error.code, 'invalid_input');
    assert.ok(!login.body.includes('"token"'));

    const signup = await request(app, 'POST', '/v1/auth/register', undefined,
      { email: `spoof-${randomUUID()}@example.test`, password, displayName: 'Spoof',
        organizationName: 'Spoof organization', ...field });
    assert.equal(signup.statusCode, 400);
    assert.equal(signup.json().error.code, 'invalid_input');
  }

  const me = await app.inject({ method: 'GET', url: '/v1/me',
    headers: { authorization: `Bearer ${outsider.token}`,
      'x-user-id': owner.user.id, 'x-organization-id': owner.organization.id } });
  success(me);
  assert.equal(me.json().user.id, outsider.user.id);
  assert.deepEqual(me.json().memberships.map((membership: { organizationID: string }) => membership.organizationID),
    [outsider.organization.id]);

  const project = await createProject(app, owner);
  const privateProject = await app.inject({ method: 'GET', url: `/v1/projects/${project.id}`,
    headers: { authorization: `Bearer ${outsider.token}`,
      'x-user-id': owner.user.id, 'x-organization-id': owner.organization.id } });
  assert.equal(privateProject.statusCode, 404);
});

test('bounded pull pages return every revision without skipping changes and reject a future cursor', async t => {
  const app = await fixture(t);
  const owner = await register(app);
  const project = await createProject(app, owner, 'Paged project');
  const unrelated = await createProject(app, owner, 'Unrelated sequence gaps');
  const initial = featureOperation(project);
  const expectedSequences: number[] = [];

  for (let revision = 1; revision <= 5; revision++) {
    const operation = { ...initial, operationID: randomUUID(), baseRevision: revision - 1,
      data: { ...initial.data, label: `Version ${revision}` } };
    const written = await push(app, project, owner, [operation]);
    assert.equal(written.results[0].status, 'applied');
    expectedSequences.push(written.results[0].cursor);
    // Changes use a global sequence; another project creates genuine gaps in this feed.
    assert.equal((await push(app, unrelated, owner, [featureOperation(unrelated)])).results[0].status, 'applied');
  }

  let currentCursor = 0;
  const received: { sequence: number; entity: string; id: string; revision: number; data: { label: string } }[] = [];
  for (let pageNumber = 0; pageNumber < 3; pageNumber++) {
    const page = await request(app, 'GET',
      `/v1/projects/${project.id}/sync/pull?cursor=${currentCursor}&limit=2`, owner.token);
    success(page);
    const body = page.json();
    assert.ok(body.changes.length <= 2);
    assert.equal(body.hasMore, pageNumber < 2);
    assert.ok(body.cursor > currentCursor);
    if (body.hasMore) assert.equal(body.cursor, body.changes.at(-1).sequence);
    received.push(...body.changes);
    currentCursor = body.cursor;
  }
  assert.deepEqual(received.map(change => change.sequence), expectedSequences);
  assert.deepEqual(received.map(change => change.revision), [1, 2, 3, 4, 5]);
  assert.deepEqual(received.map(change => change.data.label),
    ['Version 1', 'Version 2', 'Version 3', 'Version 4', 'Version 5']);
  assert.ok(received.every(change => change.id === initial.id && change.entity === 'feature'));
  assert.equal(currentCursor, expectedSequences.at(-1));

  const nextOperation = { ...initial, operationID: randomUUID(), baseRevision: 5,
    data: { ...initial.data, label: 'Version 6' } };
  const nextWrite = await push(app, project, owner, [nextOperation]);
  assert.equal(nextWrite.results[0].status, 'applied');
  const later = await request(app, 'GET',
    `/v1/projects/${project.id}/sync/pull?cursor=${currentCursor}&limit=2`, owner.token);
  success(later);
  assert.deepEqual(later.json().changes.map((change: { revision: number }) => change.revision), [6]);

  const future = await request(app, 'GET',
    `/v1/projects/${project.id}/sync/pull?cursor=${nextWrite.cursor + 1}`, owner.token);
  assert.equal(future.statusCode, 400);
  assert.equal(future.json().error.code, 'invalid_cursor');
  const excessiveLimit = await request(app, 'GET', `/v1/projects/${project.id}/sync/pull?limit=201`, owner.token);
  assert.equal(excessiveLimit.statusCode, 400);
});

test('offline project creation retries survive restart without duplicates and reject changed or foreign collisions', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'atlas-project-retry-test-'));
  const databasePath = join(directory, 'atlas.sqlite');
  let app = await buildApp({ databasePath, logger: false, rateLimit: false, billingEnvironment: {} });
  t.after(async () => {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  });
  const owner = await register(app, 'owner');
  const outsider = await register(app, 'outsider');
  const payload = {
    id: randomUUID(), organizationID: owner.organization.id,
    name: 'Private offline-created cemetery', kind: 'cemetery',
    coordinateReference: { localMeters: { frameID: randomUUID() } },
    notes: 'Original private field notes', requiresIndependentReview: true,
  };
  const first = await request(app, 'POST', '/v1/projects', owner.token, payload);
  assert.equal(first.statusCode, 201, first.body);
  const original = first.json();
  assert.equal(original.id, payload.id);
  assert.equal(original.revision, 1);

  // A lost response causes the outbox to resend the same stable project UUID.
  const retry = await request(app, 'POST', '/v1/projects', owner.token, payload);
  assert.equal(retry.statusCode, 200, retry.body);
  assert.deepEqual(retry.json(), original);
  await app.close();
  app = await buildApp({ databasePath, logger: false, rateLimit: false, billingEnvironment: {} });
  const afterRestart = await request(app, 'POST', '/v1/projects', owner.token, payload);
  assert.equal(afterRestart.statusCode, 200, afterRestart.body);
  assert.deepEqual(afterRestart.json(), original);

  for (const change of [{ notes: 'A changed payload' },
    { coordinateReference: { localMeters: { frameID: randomUUID() } } }]) {
    const changed = await request(app, 'POST', '/v1/projects', owner.token, { ...payload, ...change });
    assert.equal(changed.statusCode, 409);
    assert.equal(changed.json().error.code, 'identifier_unavailable');
  }

  const foreignCollision = await request(app, 'POST', '/v1/projects', outsider.token,
    { ...payload, organizationID: outsider.organization.id });
  assert.equal(foreignCollision.statusCode, 409);
  assert.equal(foreignCollision.json().error.code, 'identifier_unavailable');
  for (const privateValue of [original.name, original.notes, original.organizationID, original.createdAt]) {
    assert.ok(!foreignCollision.body.includes(privateValue));
  }
  assert.deepEqual((await request(app, 'GET', `/v1/projects/${payload.id}`, owner.token)).json(), original);

  const edited = await request(app, 'PATCH', `/v1/projects/${payload.id}`, owner.token,
    { baseRevision: 1, notes: 'Metadata edited after creation' });
  success(edited);
  assert.equal(edited.json().revision, 2);
  for (const retryPayload of [payload, { ...payload, notes: edited.json().notes }]) {
    const staleCreate = await request(app, 'POST', '/v1/projects', owner.token, retryPayload);
    assert.equal(staleCreate.statusCode, 409);
    assert.equal(staleCreate.json().error.code, 'identifier_unavailable');
  }
  const current = await request(app, 'GET', `/v1/projects/${payload.id}`, owner.token);
  success(current);
  assert.deepEqual(current.json(), edited.json());
  const projects = await request(app, 'GET', '/v1/projects', owner.token);
  success(projects);
  assert.equal(projects.json().projects.length, 1);
});
