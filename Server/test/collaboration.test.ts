import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, rm, writeFile, symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import test, { type TestContext } from 'node:test';
import type { HTTPMethods } from 'fastify';
import { buildApp, type AppOptions } from '../src/app.js';
import type { AssemblySource, AssemblyProcessor, AssemblyContext, AssemblyResult } from '../src/collaboration.js';
import { contentHash, canonical } from '../src/auth.js';
import { Store } from '../src/store.js';
type App = Awaited<ReturnType<typeof buildApp>>;
type Account = { token: string; user: { id: string; email: string }; organization: { id: string } };
type Project = { id: string; organizationID: string };
const hash = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex');
const clock = () => (Date.now() - Date.UTC(2001, 0, 1)) / 1000;
async function fixture(t: TestContext, processor?: AssemblyProcessor) {
  const directory = await mkdtemp(join(tmpdir(), 'terraview-collaboration-'));
  const options: AppOptions = { databasePath: join(directory, 'store.sqlite'), assetDirectory: join(directory, 'assets'), logger: false, rateLimit: false, billingEnvironment: {}, assemblyProcessor: processor };
  let app = await buildApp(options); await app.ready();
  t.after(async () => { await app.close(); await rm(directory, { recursive: true, force: true }); });
  return { get app() { return app; }, options, async restart() { await app.close(); app = await buildApp(options); await app.ready(); } };
}
async function call(app: App, token: string, method: HTTPMethods, url: string, payload?: object) { return app.inject({ method, url, headers: { authorization: `Bearer ${token}` }, ...(payload === undefined ? {} : { payload }) }); }
function ok(response: { statusCode: number; body: string }) { assert.ok(response.statusCode >= 200 && response.statusCode < 300, `${response.statusCode} ${response.body}`); return response.body ? JSON.parse(response.body) : undefined; }
async function account(app: App): Promise<Account> { return ok(await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: `${randomUUID()}@test.example`, password: 'Collaboration-password-2026!', displayName: 'Actual employee', organizationName: 'Local field test' } })); }
async function project(app: App, owner: Account, frameID = randomUUID()): Promise<Project> { return ok(await call(app, owner.token, 'POST', '/v1/projects', { organizationID: owner.organization.id, name: 'Shared sector', kind: 'cemetery', coordinateReference: { localMeters: { frameID } } })); }
async function member(app: App, owner: Account, worker: Account, role = 'surveyor') { ok(await call(app, owner.token, 'POST', `/v1/organizations/${owner.organization.id}/members`, { email: worker.user.email, role })); }
const path = (p: Project, suffix: string) => `/v1/projects/${p.id}/${suffix}`;
function plan(p: Project, frameID: string, workers: Account[]) {
  const boundary = { frameID, vertices: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }], holes: [] };
  const cells = [0, 1].flatMap(row => [0, 1].map(column => ({ id: `r${row}c${column}`, row, column, center: { x: column * 5 + 2.5, y: row * 5 + 2.5 },
    boundsVertices: [{ x: column * 5, y: row * 5 }, { x: column * 5 + 5, y: row * 5 }, { x: column * 5 + 5, y: row * 5 + 5 }, { x: column * 5, y: row * 5 + 5 }], boundaryStatus: 'interior', estimatedWorkAreaSquareMeters: 25, componentID: 0 })));
  const offline = workers.map((_, index) => ({ id: randomUUID(), name: `Field employee ${index + 1}` }));
  return { operationID: randomUUID(), baseRevision: 0, plan: { schemaVersion: 1, id: randomUUID(), projectID: p.id, revision: 0, createdAt: clock(), updatedAt: clock(), coordinateReference: { localMeters: { frameID } },
    sourceBoundary: { metricPolygon: { _0: boundary } }, sourceBoundarySHA256: contentHash({ metricPolygon: { _0: boundary } }), gridFrameID: frameID, boundary, cellSizeMeters: 5, cells, workers: offline,
    assignments: cells.map((cell, index) => ({ cellID: cell.id, workerID: offline[Math.min(offline.length - 1, Math.floor(index / 2))]!.id })), evidence: [], assignmentHistory: [], warnings: ['GPS is not surface coverage'] },
    sourceBoundaryJSON: canonical({ metricPolygon: { _0: boundary } }), workerMappings: offline.map((worker, index) => ({ workerID: worker.id, userID: workers[index]!.user.id })) };
}
async function upload(app: App, owner: Account, p: Project, frameID = randomUUID(), finalize = true, kind = 'mesh') {
  const bytes = Buffer.from(`actual opaque original ${randomUUID()}`), materialID = randomUUID(), captureID = randomUUID(), assetID = randomUUID(), packageID = randomUUID();
  const manifest = { schemaVersion: 1, id: packageID, projectID: p.id, title: 'Actual uploaded segment', createdAt: Date.now(), timeZoneIdentifier: 'Etc/UTC', utcOffsetSeconds: 0,
    materials: [{ id: materialID, sourceEntityID: captureID, kind: kind === 'mesh' ? 'mesh' : 'photo', capturedAt: Date.now(), frameID }],
    assets: [{ id: assetID, materialID, relativePath: 'original.obj', mediaType: 'model/obj', byteCount: bytes.length, sha256: hash(bytes), kind }] };
  ok(await call(app, owner.token, 'POST', path(p, 'materials'), manifest));
  ok(await app.inject({ method: 'PUT', url: path(p, `materials/${packageID}/assets/${assetID}?offset=0`), headers: { authorization: `Bearer ${owner.token}`, 'content-type': 'application/octet-stream' }, payload: bytes }));
  if (finalize) ok(await call(app, owner.token, 'POST', path(p, `materials/${packageID}/finalize`), {}));
  const source: AssemblySource = { packageID, assetID, captureID, frameID, sourceSHA256: hash(bytes), sourceVersion: 1, unit: 'meters' };
  return { source, bytes, manifest };
}
function candidate(source: AssemblySource, target: AssemblySource, offset = 0) {
  const transform = { rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1], translation: { x: offset, y: 0, z: 0 } };
  const pair = (x: number, y: number, z: number) => ({ id: randomUUID(), source: { x, y, z }, target: { x: x + offset, y, z }, evidence: 'physicalMarker' });
  return { id: randomUUID(), source, target, transform, controls: [pair(0, 0, 0), pair(2, 0, 0), pair(0, 2, 0)], checkPoints: [pair(1, 1, 1)], proposedAt: Date.now() };
}
async function propose(app: App, owner: Account, p: Project, input: ReturnType<typeof candidate>) { return ok(await call(app, owner.token, 'POST', path(p, 'registrations'), { operationID: randomUUID(), candidate: input })); }
async function approve(app: App, owner: Account, p: Project, registrationID: string, baseRevision = 0) { return ok(await call(app, owner.token, 'POST', path(p, `registrations/${registrationID}/decisions`), { operationID: randomUUID(), baseRevision, verdict: 'approved', note: 'Compared physical control markers and held-out check' })); }
async function assembly(app: App, owner: Account, p: Project, sources: AssemblySource[]) { return ok(await call(app, owner.token, 'POST', path(p, 'assemblies'), { operationID: randomUUID(), id: randomUUID(), kind: 'registeredScene', sources, target: sources[0] })); }

test('authenticated account mapping, manager roles and cross-project isolation protect immutable plan baselines', async t => {
  const fx = await fixture(t), owner = await account(fx.app), worker = await account(fx.app), outsider = await account(fx.app); await member(fx.app, owner, worker);
  const frame = randomUUID(), p = await project(fx.app, owner, frame), another = await project(fx.app, owner), input = plan(p, frame, [owner, worker]);
  assert.equal((await fx.app.inject({ method: 'GET', url: path(p, 'collaboration') })).statusCode, 401);
  assert.equal((await call(fx.app, outsider.token, 'GET', path(p, 'collaboration'))).statusCode, 404);
  assert.equal((await call(fx.app, worker.token, 'POST', path(p, 'collaboration/plan'), input)).statusCode, 403);
  assert.equal((await call(fx.app, owner.token, 'POST', path(another, 'collaboration/plan'), input)).statusCode, 400);
  const forged = structuredClone(input); forged.workerMappings[1]!.userID = outsider.user.id;
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), forged)).json().error.code, 'worker_mapping_required');
  const created = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), input)); assert.equal(created.revision, 1); assert.equal(created.plan.revision, 0);
  assert.deepEqual(created.workerMappings, input.workerMappings); assert.equal(created.coverageByCell.r0c0, 'unobserved');
  const duplicate = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), input)); assert.deepEqual(duplicate, created);
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), { ...input, operationID: randomUUID() })).json().error.code, 'revision_conflict');
  await fx.restart(); const reopened = ok(await call(fx.app, worker.token, 'GET', path(p, 'collaboration'))); assert.deepEqual(reopened.plan, created);
});

test('plan field, projection, geometry, grid and mapping bounds reject invented shapes before persistence', async t => {
  const fx = await fixture(t), owner = await account(fx.app), frame = randomUUID(), p = await project(fx.app, owner, frame), input = plan(p, frame, [owner]);
  const cases = [
    (x: typeof input) => { x.plan.cells[0]!.boundsVertices[0]!.x = 1; },
    (x: typeof input) => { x.plan.cells[0]!.center.x = 500; },
    (x: typeof input) => { x.plan.cells[0]!.estimatedWorkAreaSquareMeters = 26; },
    (x: typeof input) => { x.plan.cellSizeMeters = 0; },
    (x: typeof input) => { x.plan.gridFrameID = randomUUID(); },
    (x: typeof input) => { x.plan.cells.push(x.plan.cells[0]!); },
    (x: typeof input) => { x.plan.assignments[0]!.workerID = randomUUID(); },
    (x: typeof input) => { x.plan.boundary.vertices[1] = { x: 0, y: 10 }; },
    (x: typeof input) => { x.plan.sourceBoundarySHA256 = '0'.repeat(64); },
    (x: typeof input) => { x.sourceBoundaryJSON = '{}'; },
    (x: typeof input) => { x.plan.workers[0]!.name = 'я'.repeat(140); },
  ];
  for (const change of cases) { const value = structuredClone(input); change(value); const response = await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), value); assert.equal(response.statusCode, 400, response.body); }
  assert.equal(ok(await call(fx.app, owner.token, 'GET', path(p, 'collaboration'))).plan, null);
});

test('assignment CAS and durable operation IDs preserve both competing employees and exact previous ownership', async t => {
  const fx = await fixture(t), owner = await account(fx.app), worker = await account(fx.app); await member(fx.app, owner, worker); const frame = randomUUID(), p = await project(fx.app, owner, frame), input = plan(p, frame, [owner, worker]);
  ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), input));
  const change = { operationID: randomUUID(), baseRevision: 1, cellIDs: ['r0c0'], workerID: input.plan.workers[1]!.id, eventID: randomUUID(), timestamp: clock() };
  const changed = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/assignments'), change)); assert.equal(changed.revision, 2); assert.equal(changed.plan.assignmentHistory[0].previousWorkerIDs.r0c0, input.plan.workers[0]!.id);
  await fx.restart(); assert.deepEqual(ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/assignments'), change)), changed);
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/assignments'), { ...change, workerID: input.plan.workers[0]!.id })).json().error.code, 'operation_mismatch');
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/assignments'), { ...change, operationID: randomUUID() })).json().error.code, 'revision_conflict');
  const page = ok(await call(fx.app, worker.token, 'GET', path(p, 'collaboration/plan/revisions?limit=1'))); assert.equal(page.hasMore, true); assert.equal(page.nextRevision, 1);
  const next = ok(await call(fx.app, worker.token, 'GET', path(p, 'collaboration/plan/revisions?afterRevision=1&limit=1'))); assert.equal(next.revisions[0].revision, 2); assert.equal(next.hasMore, false);
  const original = ok(await call(fx.app, worker.token, 'GET', path(p, 'collaboration/plan/revisions/1'))); assert.equal(original.plan.assignments[0].workerID, input.plan.workers[0]!.id);
  const db = new Store(fx.options.databasePath!); assert.throws(() => db.run('UPDATE collaboration_plans SET content_hash = ? WHERE revision = 1', '0'.repeat(64)), /immutable/); db.close();
});

test('walked GPS is separate from actual hash-bound capture and completeness review, including unresolved rescan requests', async t => {
  const fx = await fixture(t), owner = await account(fx.app), worker = await account(fx.app); await member(fx.app, owner, worker); const frame = randomUUID(), p = await project(fx.app, owner, frame), input = plan(p, frame, [owner, worker]);
  ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), input));
  const evidence = { id: randomUUID(), workerID: input.plan.workers[0]!.id, kind: 'gpsWalk', timestamp: clock(), cellIDs: ['r0c0'], quality: 'unknown', referencedEvidenceIDs: [], boundaryReviewed: false, note: '', horizontalAccuracyMeters: 7 };
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), { operationID: randomUUID(), baseRevision: 1, evidence: { ...evidence, note: 'я'.repeat(2070) } })).statusCode, 400);
  const walked = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), { operationID: randomUUID(), baseRevision: 1, evidence })); assert.equal(walked.coverageByCell.r0c0, 'walked');
  assert.equal((await call(fx.app, worker.token, 'POST', path(p, 'collaboration/evidence'), { operationID: randomUUID(), baseRevision: 2, evidence: { ...evidence, id: randomUUID() } })).statusCode, 403);
  const uploaded = await upload(fx.app, owner, p, randomUUID());
  const source = { packageID: uploaded.source.packageID, assetID: uploaded.source.assetID, captureID: uploaded.source.captureID, sourceSHA256: uploaded.source.sourceSHA256, frameID: uploaded.source.frameID };
  const observed = { ...evidence, id: randomUUID(), kind: 'captureObserved', captureID: source.captureID, sourceSHA256: source.sourceSHA256, sourceFrameID: source.frameID,
    footprintProvenance: 'operatorMapped', footprint: input.plan.boundary, quality: 'usable' };
  const saved = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), { operationID: randomUUID(), baseRevision: 2, evidence: observed, source })); assert.equal(saved.coverageByCell.r0c0, 'observed');
  const reviewed = { ...evidence, id: randomUUID(), kind: 'operatorVerified', quality: 'usable', referencedEvidenceIDs: [observed.id], boundaryReviewed: true, note: 'Compared visible coverage against original boundary' };
  const verified = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), { operationID: randomUUID(), baseRevision: 3, evidence: reviewed })); assert.equal(verified.coverageByCell.r0c0, 'verified');
  const rescan = { ...observed, id: randomUUID(), quality: 'needsRescan', timestamp: observed.timestamp - 86400 };
  const olderOfflineReport = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), { operationID: randomUUID(), baseRevision: 4, evidence: rescan, source })); assert.equal(olderOfflineReport.coverageByCell.r0c0, 'needsRescan'); assert.equal(olderOfflineReport.plan.evidence[3].timestamp, rescan.timestamp);
  const resolved = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), { operationID: randomUUID(), baseRevision: 5, evidence: { ...reviewed, id: randomUUID(), referencedEvidenceIDs: [observed.id, rescan.id] } })); assert.equal(resolved.coverageByCell.r0c0, 'verified');
  await fx.restart(); const reopened = ok(await call(fx.app, owner.token, 'GET', path(p, 'collaboration'))); assert.equal(reopened.plan.plan.evidence.length, 5); assert.equal(reopened.plan.coverageByCell.r0c0, 'verified');
  const sourceHistory = ok(await call(fx.app, owner.token, 'GET', path(p, 'collaboration/evidence?limit=2'))); assert.equal(sourceHistory.hasMore, true); assert.equal(sourceHistory.evidence[1].source.sourceSHA256, source.sourceSHA256); assert.equal(sourceHistory.evidence[1].actorID, owner.user.id); assert.equal(sourceHistory.evidence[1].appliedPlanRevision, 3);
});

test('wrong source hash, foreign package, incomplete original and unregistered frame never become captured coverage', async t => {
  const fx = await fixture(t), owner = await account(fx.app), frame = randomUUID(), p = await project(fx.app, owner, frame), other = await project(fx.app, owner), input = plan(p, frame, [owner]); ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), input));
  const uploaded = await upload(fx.app, owner, p), foreign = await upload(fx.app, owner, other), incomplete = await upload(fx.app, owner, p, randomUUID(), false);
  const request = (source: AssemblySource, hashOverride = source.sourceSHA256) => ({ operationID: randomUUID(), baseRevision: 1, evidence: { id: randomUUID(), workerID: input.plan.workers[0]!.id,
    kind: 'captureObserved', timestamp: clock(), cellIDs: ['r0c0'], captureID: source.captureID, sourceSHA256: hashOverride, sourceFrameID: source.frameID, footprintProvenance: 'registeredCapture', footprint: input.plan.boundary, quality: 'usable', referencedEvidenceIDs: [], boundaryReviewed: false, note: '' },
    source: { packageID: source.packageID, assetID: source.assetID, captureID: source.captureID, sourceSHA256: hashOverride, frameID: source.frameID } });
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), request(uploaded.source, '0'.repeat(64)))).json().error.code, 'source_mismatch');
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), request(foreign.source))).statusCode, 404);
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), request(incomplete.source))).json().error.code, 'package_incomplete');
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/evidence'), request(uploaded.source))).json().error.code, 'registration_required');
  assert.equal(ok(await call(fx.app, owner.token, 'GET', path(p, 'collaboration'))).plan.plan.evidence.length, 0);
});

test('independent residuals, proper rotations, held-out checks, physical controls and gravity gate operator approval', async t => {
  const fx = await fixture(t), owner = await account(fx.app), p = await project(fx.app, owner), a = await upload(fx.app, owner, p), b = await upload(fx.app, owner, p);
  const valid = candidate(a.source, b.source, 3); const accepted = await propose(fx.app, owner, p, valid); assert.equal(accepted.quality.acceptable, true); assert.equal(accepted.decision, null);
  const noChecks = { ...candidate(a.source, b.source), checkPoints: [] }; const unchecked = await propose(fx.app, owner, p, noChecks); assert.equal(unchecked.quality.acceptable, false);
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, `registrations/${unchecked.id}/decisions`), { operationID: randomUUID(), baseRevision: 0, verdict: 'approved', note: 'Not enough actual controls' })).json().error.code, 'registration_quality_failed');
  const badFit = candidate(a.source, b.source); badFit.transform.translation.x = .2; const residual = await propose(fx.app, owner, p, badFit); assert.equal(residual.quality.acceptable, false);
  const badCheck = candidate(a.source, b.source); badCheck.checkPoints[0]!.target.x += .16; assert.equal((await propose(fx.app, owner, p, badCheck)).quality.acceptable, false);
  const nonIndependent = candidate(a.source, b.source); nonIndependent.checkPoints[0]!.source = nonIndependent.controls[0]!.source;
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'registrations'), { operationID: randomUUID(), candidate: nonIndependent })).statusCode, 400);
  for (const rotation of [[2, 0, 0, 0, 1, 0, 0, 0, 1], [-1, 0, 0, 0, 1, 0, 0, 0, 1]]) {
    assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'registrations'), { operationID: randomUUID(), candidate: { ...candidate(a.source, b.source), transform: { rotation, translation: { x: 0, y: 0, z: 0 } } } })).statusCode, 400);
  }
  const gps = candidate(a.source, b.source); gps.controls[0]!.evidence = 'gpsOnly'; assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'registrations'), { operationID: randomUUID(), candidate: gps })).statusCode, 400);
  const gravity = { ...candidate(a.source, b.source), gravityConstraint: { sourceUp: { x: 0, y: 1, z: 0 }, targetUp: { x: 1, y: 0, z: 0 }, maximumDeviationDegrees: 5 } };
  assert.equal((await propose(fx.app, owner, p, gravity)).quality.acceptable, false);
  const approved = await approve(fx.app, owner, p, accepted.id); assert.equal(approved.decision.actorID, owner.user.id); assert.equal(approved.decision.revision, 1);
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, `registrations/${accepted.id}/decisions`), { operationID: randomUUID(), baseRevision: 0, verdict: 'rejected', note: 'Stale operator decision' })).json().error.code, 'revision_conflict');
});

test('disconnected 3D pieces need explicit approval, and unconfigured processor never claims a fused scene', async t => {
  const fx = await fixture(t), owner = await account(fx.app), p = await project(fx.app, owner), a = await upload(fx.app, owner, p), b = await upload(fx.app, owner, p);
  const waiting = await assembly(fx.app, owner, p, [a.source, b.source]); assert.equal(waiting.state, 'waitingForRegistration'); assert.equal(waiting.outcome.readiness.disconnectedSourceKeys.length, 1);
  const registration = await propose(fx.app, owner, p, candidate(b.source, a.source, 3)); await approve(fx.app, owner, p, registration.id);
  const refreshed = ok(await call(fx.app, owner.token, 'POST', path(p, `assemblies/${waiting.id}/refresh`), { operationID: randomUUID(), baseRevision: 1 })); assert.equal(refreshed.state, 'queued'); assert.equal(refreshed.outcome.code, 'processor_unconfigured');
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, `assemblies/${waiting.id}/process`), { operationID: randomUUID(), baseRevision: 2 })).statusCode, 503);
  await fx.restart(); const reopened = ok(await call(fx.app, owner.token, 'GET', path(p, `assemblies/${waiting.id}`))); assert.equal(reopened.state, 'queued'); assert.equal(reopened.processorConfigured, false); assert.equal(reopened.events.length, 2);
  assert.equal(reopened.currentReadiness.registrations.find((x: { sourceKey: string; transform: { translation: { x: number } } }) => x.transform.translation.x === 3)?.transform.translation.x, 3);
});

test('approved locally accurate edges with inconsistent global cycles remain separate until human reconciliation', async t => {
  const fx = await fixture(t), owner = await account(fx.app), p = await project(fx.app, owner), sources = await Promise.all([upload(fx.app, owner, p), upload(fx.app, owner, p), upload(fx.app, owner, p)]);
  for (const [a, b, offset] of [[0, 1, 0], [1, 2, 0], [2, 0, 1]]) { const registration = await propose(fx.app, owner, p, candidate(sources[a!]!.source, sources[b!]!.source, offset)); await approve(fx.app, owner, p, registration.id); }
  const result = await assembly(fx.app, owner, p, sources.map(x => x.source)); assert.equal(result.state, 'waitingForRegistration'); assert.equal(result.outcome.readiness.disconnectedSourceKeys.length, 0); assert.ok(result.outcome.readiness.conflictingRegistrationIDs.length > 0);
});

test('source package ownership, hashes, frames and original bytes remain frozen across job replay and restarts', async t => {
  const fx = await fixture(t), owner = await account(fx.app), p = await project(fx.app, owner), other = await project(fx.app, owner), a = await upload(fx.app, owner, p), foreign = await upload(fx.app, owner, other), pending = await upload(fx.app, owner, p, randomUUID(), false);
  const payload = { operationID: randomUUID(), id: randomUUID(), kind: 'registeredScene', sources: [a.source], target: a.source };
  const created = ok(await call(fx.app, owner.token, 'POST', path(p, 'assemblies'), payload));
  await fx.restart(); assert.deepEqual(ok(await call(fx.app, owner.token, 'POST', path(p, 'assemblies'), payload)), created);
  for (const source of [foreign.source, pending.source, { ...a.source, sourceSHA256: '0'.repeat(64) }, { ...a.source, frameID: randomUUID() }]) {
    const response = await call(fx.app, owner.token, 'POST', path(p, 'assemblies'), { ...payload, operationID: randomUUID(), id: randomUUID(), sources: [source], target: source }); assert.ok([404, 409].includes(response.statusCode), response.body);
  }
  const downloaded = await call(fx.app, owner.token, 'GET', path(p, `materials/${a.source.packageID}/assets/${a.source.assetID}`)); assert.deepEqual(downloaded.rawPayload, a.bytes);
  assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'assemblies'), { ...payload, kind: 'photoTour' })).json().error.code, 'operation_mismatch');
});

test('a real installed adapter can complete only separate finalized derivatives with exact source manifest provenance', async t => {
  let calls = 0; let actualResult: AssemblyResult; const adapter: AssemblyProcessor = { name: 'Local contract fixture', async process(context) { calls++; assert.equal(context.sources.length, 1); for (const source of context.sources) for await (const _bytes of context.readSource(source)) { /* Consume verified actual bytes. */ } return actualResult; } };
  const fx = await fixture(t, adapter), owner = await account(fx.app), p = await project(fx.app, owner), original = await upload(fx.app, owner, p), derivative = await upload(fx.app, owner, p, original.source.frameID);
  const created = await assembly(fx.app, owner, p, [original.source]); const sourceStatus = ok(await call(fx.app, owner.token, 'GET', path(p, `materials/${original.source.packageID}`)));
  actualResult = { outputSources: [derivative.source], sourceManifestHashes: { [original.source.packageID]: contentHash(sourceStatus.manifest) }, targetFrameID: original.source.frameID, method: 'Test adapter returns an actual finalized opaque derivative; no geometric fusion claim' };
  const operation = { operationID: randomUUID(), baseRevision: 1 };
  const completed = ok(await call(fx.app, owner.token, 'POST', path(p, `assemblies/${created.id}/process`), operation)); assert.equal(completed.state, 'ready'); assert.equal(completed.outcome.outputSources[0].sourceSHA256, derivative.source.sourceSHA256); assert.equal(calls, 1);
  const replayed = ok(await call(fx.app, owner.token, 'POST', path(p, `assemblies/${created.id}/process`), operation)); assert.equal(replayed.currentJob.state, 'ready'); assert.equal(calls, 1);
  await fx.restart(); const reopened = ok(await call(fx.app, owner.token, 'GET', path(p, `assemblies/${created.id}`))); assert.equal(reopened.state, 'ready'); assert.deepEqual(reopened.outcome.outputSources, [derivative.source]);
});

test('adapter exception and invented provenance never create a ready result, while a new attempt retains failed history', async t => {
  let behavior = 0, calls = 0;
  const adapter: AssemblyProcessor = { name: 'Failing adapter contract test', async process(context) { calls++; if (behavior === 0) throw new Error('Worker unavailable'); return { outputSources: [context.sources[0]!], sourceManifestHashes: {}, targetFrameID: context.target.frameID, method: 'Invented result' }; } };
  const fx = await fixture(t, adapter), owner = await account(fx.app), p = await project(fx.app, owner), original = await upload(fx.app, owner, p), created = await assembly(fx.app, owner, p, [original.source]);
  const failed = ok(await call(fx.app, owner.token, 'POST', path(p, `assemblies/${created.id}/process`), { operationID: randomUUID(), baseRevision: 1 })); assert.equal(failed.state, 'failed'); assert.equal(failed.revision, 3);
  behavior = 1; const failedAgain = ok(await call(fx.app, owner.token, 'POST', path(p, `assemblies/${created.id}/process`), { operationID: randomUUID(), baseRevision: 3 })); assert.equal(failedAgain.state, 'failed'); assert.equal(calls, 2);
  const history = ok(await call(fx.app, owner.token, 'GET', path(p, `assemblies/${created.id}`))); assert.deepEqual(history.events.map((x: { state: string }) => x.state), ['queued', 'running', 'failed', 'running', 'failed']);
});

test('restart of a claimed worker records interruption rather than fabricated completion', async t => {
  const fx = await fixture(t), owner = await account(fx.app), p = await project(fx.app, owner), original = await upload(fx.app, owner, p), created = await assembly(fx.app, owner, p, [original.source]);
  const db = new Store(fx.options.databasePath!); db.run("UPDATE assembly_jobs SET revision = 2, state = 'running', outcome_json = ? WHERE id = ?", JSON.stringify({ code: 'processing' }), created.id); db.run('INSERT INTO assembly_job_events VALUES (?, ?, ?, ?, ?, ?)', created.id, 2, 'running', '{}', owner.user.id, new Date().toISOString()); db.close();
  await fx.restart(); const recovered = ok(await call(fx.app, owner.token, 'GET', path(p, `assemblies/${created.id}`))); assert.equal(recovered.state, 'failed'); assert.equal(recovered.outcome.code, 'processor_interrupted'); assert.equal(recovered.revision, 3);
});

test('an adapter that skips source reads cannot return a ready checksum-only claim', async t => {
  let response: AssemblyResult;
  const adapter: AssemblyProcessor = { name: 'Unread source test', async process() { return response; } };
  const fx = await fixture(t, adapter), owner = await account(fx.app), p = await project(fx.app, owner), original = await upload(fx.app, owner, p), derivative = await upload(fx.app, owner, p, original.source.frameID);
  response = { outputSources: [derivative.source], sourceManifestHashes: { [original.source.packageID]: contentHash(original.manifest) }, targetFrameID: original.source.frameID, method: 'Claimed processing without input bytes' };
  const created = await assembly(fx.app, owner, p, [original.source]);
  const result = ok(await call(fx.app, owner.token, 'POST', path(p, `assemblies/${created.id}/process`), { operationID: randomUUID(), baseRevision: 1 })); assert.equal(result.state, 'failed'); assert.equal(result.outcome.code, 'processor_failed');
});

test('worker reads reject tampered original bytes and filesystem symlinks even after prior finalization', async t => {
  let response: AssemblyResult;
  const adapter: AssemblyProcessor = { name: 'Actual checksum reader', async process(context) { for (const source of context.sources) for await (const _bytes of context.readSource(source)) { /* Full original checksum must pass. */ } return response; } };
  const fx = await fixture(t, adapter), owner = await account(fx.app), p = await project(fx.app, owner), original = await upload(fx.app, owner, p), derivative = await upload(fx.app, owner, p, original.source.frameID);
  response = { outputSources: [derivative.source], sourceManifestHashes: { [original.source.packageID]: contentHash(original.manifest) }, targetFrameID: original.source.frameID, method: 'Valid metadata cannot hide tampered physical bytes' };
  const sourcePath = join(fx.options.assetDirectory!, owner.organization.id, p.id, original.source.packageID, `${original.source.assetID}.bin`);
  await writeFile(sourcePath, Buffer.alloc(original.bytes.length, 7));
  const first = await assembly(fx.app, owner, p, [original.source]); assert.equal(ok(await call(fx.app, owner.token, 'POST', path(p, `assemblies/${first.id}/process`), { operationID: randomUUID(), baseRevision: 1 })).state, 'failed');
  await rm(sourcePath); const outside = join(fx.options.assetDirectory!, 'outside-original'); await writeFile(outside, original.bytes); await symlink(outside, sourcePath);
  const second = await assembly(fx.app, owner, p, [original.source]); assert.equal(ok(await call(fx.app, owner.token, 'POST', path(p, `assemblies/${second.id}/process`), { operationID: randomUUID(), baseRevision: 1 })).state, 'failed');
});

test('assignment to a revoked account, employee impersonation and processing by a surveyor are forbidden', async t => {
  const fx = await fixture(t), owner = await account(fx.app), worker = await account(fx.app); await member(fx.app, owner, worker); const frame = randomUUID(), p = await project(fx.app, owner, frame), input = plan(p, frame, [owner, worker]);
  ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), input)); const original = await upload(fx.app, owner, p), created = await assembly(fx.app, owner, p, [original.source]);
  assert.equal((await call(fx.app, worker.token, 'POST', path(p, `assemblies/${created.id}/process`), { operationID: randomUUID(), baseRevision: 1 })).statusCode, 403);
  ok(await call(fx.app, owner.token, 'DELETE', `/v1/organizations/${owner.organization.id}/members/${worker.user.id}`));
  const result = await call(fx.app, owner.token, 'POST', path(p, 'collaboration/assignments'), { operationID: randomUUID(), baseRevision: 1, cellIDs: ['r0c0'], workerID: input.plan.workers[1]!.id, eventID: randomUUID(), timestamp: clock() });
  assert.equal(result.json().error.code, 'worker_mapping_required'); assert.equal((await call(fx.app, worker.token, 'GET', path(p, 'collaboration'))).statusCode, 404);
});

test('hand-computed clipped triangle and courtyard areas reject missing cells, invented interior flags and arbitrary allocation', async t => {
  const fx = await fixture(t), owner = await account(fx.app), frame = randomUUID(), p = await project(fx.app, owner, frame);
  const input = plan(p, frame, [owner]);
  const triangle = { frameID: frame, vertices: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 0, y: 10 }], holes: [] };
  input.plan.boundary = triangle; input.plan.sourceBoundary = { metricPolygon: { _0: triangle } }; input.sourceBoundaryJSON = canonical(input.plan.sourceBoundary); input.plan.sourceBoundarySHA256 = hash(Buffer.from(input.sourceBoundaryJSON));
  input.plan.cells = input.plan.cells.slice(0, 3); input.plan.cells[1]!.center = { x: 6.25, y: 2.5 }; input.plan.cells[2]!.center = { x: 1.25, y: 7.5 };
  for (const index of [1, 2]) { input.plan.cells[index]!.estimatedWorkAreaSquareMeters = 12.5; input.plan.cells[index]!.boundaryStatus = 'partialRequiresReview'; }
  input.plan.assignments = input.plan.assignments.slice(0, 3);
  const missing = structuredClone(input); missing.plan.cells.pop(); missing.plan.assignments.pop(); assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), missing)).statusCode, 400);
  const understated = structuredClone(input); understated.plan.cells[1]!.estimatedWorkAreaSquareMeters = 1; assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), understated)).statusCode, 400);
  const falseInterior = structuredClone(input); falseInterior.plan.cells[1]!.boundaryStatus = 'interior'; assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), falseInterior)).statusCode, 400);
  const boundaryCenter = structuredClone(input); boundaryCenter.plan.cells[1]!.center = { x: 7.5, y: 2.5 }; assert.equal((await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), boundaryCenter)).statusCode, 400);
  const created = ok(await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), input)); assert.equal(created.plan.cells.reduce((sum: number, cell: { estimatedWorkAreaSquareMeters: number }) => sum + cell.estimatedWorkAreaSquareMeters, 0), 50);
  const courtyardProject = await project(fx.app, owner, frame), courtyard = plan(courtyardProject, frame, [owner]); const hole = [{ x: 3, y: 3 }, { x: 7, y: 3 }, { x: 7, y: 7 }, { x: 3, y: 7 }];
  courtyard.plan.boundary.holes.push(hole); courtyard.plan.sourceBoundary = { metricPolygon: { _0: courtyard.plan.boundary } }; courtyard.sourceBoundaryJSON = canonical(courtyard.plan.sourceBoundary); courtyard.plan.sourceBoundarySHA256 = hash(Buffer.from(courtyard.sourceBoundaryJSON));
  for (const cell of courtyard.plan.cells) { cell.estimatedWorkAreaSquareMeters = 21; cell.boundaryStatus = 'partialRequiresReview'; }
  const actualCourtyard = ok(await call(fx.app, owner.token, 'POST', path(courtyardProject, 'collaboration/plan'), courtyard)); assert.equal(actualCourtyard.plan.cells.reduce((sum: number, cell: { estimatedWorkAreaSquareMeters: number }) => sum + cell.estimatedWorkAreaSquareMeters, 0), 84);
  assert.ok(actualCourtyard.plan.cells.every((cell: { boundaryStatus: string }) => cell.boundaryStatus === 'partialRequiresReview'));
});

test('eight actual Swift-exported plans retain their literal boundary hashes and deterministic cells through authenticated server creation', async t => {
  // Synthetic geometry fixture generated by real AtlasCore Swift code, not physical device observations.
  const { readFile } = await import('node:fs/promises');
  const fixtures = JSON.parse(await readFile(new URL('./fixtures/collaborative-swift.json', import.meta.url), 'utf8')) as { name: string; plan: { projectID: string; coordinateReference: object; workers: { id: string }[]; cells: { id: string; center: { x: number; y: number }; estimatedWorkAreaSquareMeters: number; boundaryStatus: string; componentID: number }[]; sourceBoundarySHA256: string }; sourceBoundaryJSON: string }[];
  const fx = await fixture(t), owner = await account(fx.app), workers = [owner];
  for (let index = 1; index < 5; index++) { const worker = await account(fx.app); await member(fx.app, owner, worker); workers.push(worker); }
  let cellCount = 0;
  for (const actual of fixtures) {
    const p = ok(await call(fx.app, owner.token, 'POST', '/v1/projects', { organizationID: owner.organization.id, name: `Native fixture ${actual.name}`, kind: 'site', coordinateReference: actual.plan.coordinateReference }));
    actual.plan.projectID = p.id;
    const response = await call(fx.app, owner.token, 'POST', path(p, 'collaboration/plan'), { operationID: randomUUID(), baseRevision: 0, plan: actual.plan, sourceBoundaryJSON: actual.sourceBoundaryJSON,
      workerMappings: actual.plan.workers.map((worker, index) => ({ workerID: worker.id, userID: workers[index]!.user.id })) });
    assert.equal(response.statusCode, 200, `${actual.name}: ${response.body}`); const accepted = response.json();
    assert.equal(accepted.declaredBoundarySHA256, hash(Buffer.from(actual.sourceBoundaryJSON, 'utf8')));
    assert.deepEqual(accepted.plan.cells, actual.plan.cells); cellCount += actual.plan.cells.length;
  }
  assert.equal(fixtures.length, 8); assert.equal(cellCount, 182);
});

test('a registration rejected during a worker attempt prevents ready output and preserves the failed attempt', async t => {
  let entered!: () => void, release!: () => void, response: AssemblyResult;
  const started = new Promise<void>(resolve => { entered = resolve; }), resume = new Promise<void>(resolve => { release = resolve; });
  const adapter: AssemblyProcessor = { name: 'Concurrent approval contract', async process(context) { for (const source of context.sources) for await (const _bytes of context.readSource(source)) {} entered(); await resume; return response; } };
  const fx = await fixture(t, adapter), owner = await account(fx.app), p = await project(fx.app, owner), a = await upload(fx.app, owner, p), b = await upload(fx.app, owner, p), derivative = await upload(fx.app, owner, p, a.source.frameID);
  const registration = await propose(fx.app, owner, p, candidate(b.source, a.source, 1)); await approve(fx.app, owner, p, registration.id);
  response = { outputSources: [derivative.source], sourceManifestHashes: { [a.source.packageID]: contentHash(a.manifest), [b.source.packageID]: contentHash(b.manifest) }, targetFrameID: a.source.frameID, method: 'Actual byte-read provenance fixture' };
  const created = await assembly(fx.app, owner, p, [a.source, b.source]), processing = call(fx.app, owner.token, 'POST', path(p, `assemblies/${created.id}/process`), { operationID: randomUUID(), baseRevision: 1 });
  await started;
  ok(await call(fx.app, owner.token, 'POST', path(p, `registrations/${registration.id}/decisions`), { operationID: randomUUID(), baseRevision: 1, verdict: 'rejected', note: 'Independent review found a mismatched physical control marker' })); release();
  const result = ok(await processing); assert.equal(result.state, 'failed'); assert.equal(result.outcome.code, 'processor_failed');
  const preserved = ok(await call(fx.app, owner.token, 'GET', path(p, `assemblies/${created.id}`))); assert.equal(preserved.currentReadiness.readyForProcessor, false); assert.deepEqual(preserved.events.map((e: { state: string }) => e.state), ['queued', 'running', 'failed']);
  assert.deepEqual((await call(fx.app, owner.token, 'GET', path(p, `materials/${a.source.packageID}/assets/${a.source.assetID}`))).rawPayload, a.bytes);
});
