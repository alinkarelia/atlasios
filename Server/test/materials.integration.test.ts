import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, rm, readFile, appendFile, writeFile, stat, symlink, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import type { HTTPMethods } from 'fastify';
import { buildApp } from '../src/app.js';

type App = Awaited<ReturnType<typeof buildApp>>;
type Account = { token: string; user: { id: string; email: string; displayName: string }; organization: { id: string } };
type Project = { id: string; organizationID: string };
const password = 'Materials-Field-Strong-Password-2026';
const sha = (bytes: Buffer) => createHash('sha256').update(bytes).digest('hex');
const headers = (token: string) => ({ authorization: `Bearer ${token}` });
async function fixture(t: TestContext, limits: { maxOrganizationAssetBytes?: number } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'atlas-materials-test-'));
  const options = { databasePath: join(directory, 'atlas.sqlite'), assetDirectory: join(directory, 'assets'), logger: false, rateLimit: false, billingEnvironment: {}, ...limits };
  let app = await buildApp(options); await app.ready();
  t.after(async () => { await app.close(); await rm(directory, { recursive: true, force: true }); });
  return { get app() { return app; }, directory, options, async restart() { await app.close(); app = await buildApp(options); await app.ready(); } };
}
async function request(app: App, method: HTTPMethods, url: string, token: string, payload?: object) {
  return app.inject({ method, url, headers: headers(token), ...(payload === undefined ? {} : { payload }) });
}
function success(response: { statusCode: number; body: string }) { assert.ok(response.statusCode >= 200 && response.statusCode < 300, `${response.statusCode}: ${response.body}`); }
async function register(app: App, name = 'Operator'): Promise<Account> {
  const result = await app.inject({ method: 'POST', url: '/v1/auth/register', payload: { email: `${randomUUID()}@example.test`, password, displayName: name, organizationName: 'Field team' } });
  success(result); return result.json();
}
async function project(app: App, owner: Account): Promise<Project> {
  const result = await request(app, 'POST', '/v1/projects', owner.token, { organizationID: owner.organization.id, name: 'Cemetery sector', kind: 'cemetery', coordinateReference: { wgs84: {} } });
  success(result); return result.json();
}
async function member(app: App, owner: Account, account: Account, role: string) {
  const result = await request(app, 'POST', `/v1/organizations/${owner.organization.id}/members`, owner.token, { email: account.user.email, role }); success(result);
}
function manifest(projectID: string, bytes = Buffer.from('original photo with EXIF-like bytes')) {
  const materialID = randomUUID();
  return { schemaVersion: 1, id: randomUUID(), projectID, title: 'Sector 4 / grave 128', createdAt: 1791691200456,
    timeZoneIdentifier: 'Europe/Moscow', utcOffsetSeconds: 10800, device: { model: 'iPhone16Pro', osVersion: '26.2', appVersion: '0.4.0' },
    materials: [{ id: materialID, sourceEntityID: randomUUID(), kind: 'photo', capturedAt: 1791691150123, importedAt: 1791691160234, frameID: randomUUID(),
      geoTag: { automaticFix: { coordinate: { latitude: 61.79, longitude: 34.36 }, altitudeMeters: 77.5,
        horizontalAccuracyMeters: 6.5, verticalAccuracyMeters: 10.5, observedAt: 1791691149001, source: 'deviceLocation', isSimulated: false },
        corrections: [{ id: randomUUID(), coordinate: { latitude: 61.7901, longitude: 34.3601 }, estimatedAccuracyMeters: 2,
          altitudeMeters: 78, note: 'Adjusted after checking grave map', changedAt: 1791691180002 },
        { id: randomUUID(), note: 'Restored original observation', changedAt: 1791691190003 }] } }],
    assets: [{ id: randomUUID(), materialID, relativePath: `photos/${randomUUID()}/original.heic`, mediaType: 'image/heic', byteCount: bytes.length, sha256: sha(bytes), kind: 'originalPhoto' }] };
}
const route = (project: Project, captureID?: string, assetID?: string) => `/v1/projects/${project.id}/materials${captureID ? `/${captureID}` : ''}${assetID ? `/assets/${assetID}` : ''}`;
async function chunk(app: App, project: Project, body: ReturnType<typeof manifest>, token: string, bytes: Buffer, offset: number, assetID = body.assets[0]!.id) {
  return app.inject({ method: 'PUT', url: `${route(project, body.id, assetID)}?offset=${offset}`, headers: { ...headers(token), 'content-type': 'application/octet-stream' }, payload: bytes });
}

test('original video and camera-pose metadata retain their types, clocks and exact binary bytes', async t => {
  const fx = await fixture(t); const owner = await register(fx.app); const p = await project(fx.app, owner);
  // Transfer treats source video as opaque bytes; physical AVAssetWriter validation belongs to native checks.
  const bytes = Buffer.from('opaque original movie binary\\0unchanged');
  const poses = Buffer.from('{"frameID":"local-frame","timestamps":[0,0.033],"coordinateSystem":"ARKit Y up"}');
  const base = manifest(p.id, bytes);
  const body = { ...base,
    materials: [{ ...base.materials[0]!, kind: 'video', endedAt: base.materials[0]!.capturedAt + 18_000 }],
    assets: [{ ...base.assets[0]!, relativePath: 'scans/segment-01/original.mov', mediaType: 'video/quicktime', kind: 'originalVideo' },
      { id: randomUUID(), materialID: base.materials[0]!.id, relativePath: 'scans/segment-01/poses.json', mediaType: 'application/json',
        byteCount: poses.length, sha256: sha(poses), kind: 'metadata' }] };
  success(await request(fx.app, 'POST', route(p), owner.token, body));
  success(await chunk(fx.app, p, body, owner.token, bytes, 0));
  success(await chunk(fx.app, p, body, owner.token, poses, 0, body.assets[1]!.id));
  const finalized = await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {}); success(finalized);
  assert.deepEqual(finalized.json().manifest, body);
  await fx.restart();
  const movie = await request(fx.app, 'GET', `${route(p, body.id, body.assets[0]!.id)}?offset=0&length=1048576`, owner.token);
  success(movie); assert.deepEqual(movie.rawPayload, bytes);
  assert.match(String(movie.headers['content-type']), /^video\/quicktime/);
  assert.equal(movie.headers['x-asset-sha256'], sha(bytes));
  const sidecar = await request(fx.app, 'GET', `${route(p, body.id, body.assets[1]!.id)}?offset=0&length=1048576`, owner.token);
  success(sidecar); assert.deepEqual(sidecar.rawPayload, poses);
  const originalPhoto = manifest(p.id); success(await request(fx.app, 'POST', route(p), owner.token, originalPhoto));
});

test('material packages preserve originals, capture clocks, GPS provenance, corrections and authenticated operator', async t => {
  const fx = await fixture(t); const owner = await register(fx.app, 'Actual operator'); const p = await project(fx.app, owner);
  const bytes = Buffer.from('original HEIC binary\0 with unchanged EXIF'); const body = manifest(p.id, bytes);
  const created = await request(fx.app, 'POST', route(p), owner.token, body); assert.equal(created.statusCode, 201, created.body);
  const state = created.json(); assert.equal(state.state, 'incomplete'); assert.deepEqual(state.manifest, body);
  assert.deepEqual(state.author, { userID: owner.user.id, displayName: 'Actual operator' }); assert.equal(typeof state.receivedAt, 'number');
  assert.equal(state.chunkSize, 1048576); assert.equal(state.assets[0].uploadedBytes, 0); assert.equal(state.assets[0].verified, false);
  const invisible = await request(fx.app, 'GET', route(p), owner.token); assert.deepEqual(invisible.json().materials, []);
  assert.equal((await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {})).statusCode, 409);
  assert.equal((await request(fx.app, 'GET', `${route(p, body.id, body.assets[0]!.id)}?offset=0`, owner.token)).statusCode, 404);
  const upload = await chunk(fx.app, p, body, owner.token, bytes, 0); success(upload); assert.equal(upload.json().verified, true);
  const complete = await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {}); success(complete);
  assert.equal(complete.json().state, 'complete'); assert.deepEqual(complete.json().manifest, body); assert.equal(typeof complete.json().completedAt, 'number');
  const finalRetry = await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {}); assert.deepEqual(finalRetry.json(), complete.json());
  const list = await request(fx.app, 'GET', route(p), owner.token); assert.equal(list.json().materials.length, 1); assert.deepEqual(list.json().materials[0], complete.json());
  const download = await request(fx.app, 'GET', `${route(p, body.id, body.assets[0]!.id)}?offset=0&length=1048576`, owner.token);
  success(download); assert.deepEqual(download.rawPayload, bytes); assert.equal(download.headers['x-asset-sha256'], sha(bytes));
  assert.equal(download.headers['x-asset-byte-count'], String(bytes.length)); assert.equal(download.headers['x-asset-offset'], '0');
  assert.match(String(download.headers['content-type']), /^image\/heic/); assert.equal(download.headers['cache-control'], 'no-store');
  const stored = join(fx.options.assetDirectory, owner.organization.id, p.id, body.id, `${body.assets[0]!.id}.bin`);
  assert.deepEqual(await readFile(stored), bytes); assert.equal((await stat(stored)).mode & 0o077, 0);
  assert.equal((await chunk(fx.app, p, body, owner.token, bytes, 0)).statusCode, 409);
});

test('lost responses, replayed chunks and process restart resume at server offsets without duplicate packages', async t => {
  const fx = await fixture(t); const owner = await register(fx.app); const p = await project(fx.app, owner);
  const bytes = Buffer.alloc(1048576 + 17, 0x5a); const body = manifest(p.id, bytes);
  success(await request(fx.app, 'POST', route(p), owner.token, body));
  const retry = await request(fx.app, 'POST', route(p), owner.token, body); assert.equal(retry.statusCode, 200);
  assert.equal((await request(fx.app, 'POST', route(p), owner.token, { ...body, title: 'Changed frozen payload' })).statusCode, 409);
  const first = bytes.subarray(0, 1048576); success(await chunk(fx.app, p, body, owner.token, first, 0));
  const lostResponseRetry = await chunk(fx.app, p, body, owner.token, first, 0); success(lostResponseRetry); assert.equal(lostResponseRetry.json().uploadedBytes, first.length);
  const overwrite = await chunk(fx.app, p, body, owner.token, Buffer.alloc(first.length, 0x30), 0); assert.equal(overwrite.statusCode, 409);
  const offsetGap = await chunk(fx.app, p, body, owner.token, Buffer.from('x'), first.length + 1); assert.equal(offsetGap.statusCode, 409);
  await fx.restart();
  const afterRestart = await request(fx.app, 'GET', route(p, body.id), owner.token); success(afterRestart); assert.equal(afterRestart.json().assets[0].uploadedBytes, first.length);
  success(await chunk(fx.app, p, body, owner.token, bytes.subarray(first.length), first.length));
  const lastRetry = await chunk(fx.app, p, body, owner.token, bytes.subarray(first.length), first.length); success(lastRetry); assert.equal(lastRetry.json().verified, true);
  success(await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {})); await fx.restart();
  const afterFinalRestart = await request(fx.app, 'GET', route(p), owner.token); assert.equal(afterFinalRestart.json().materials.length, 1);
  const d1 = await request(fx.app, 'GET', `${route(p, body.id, body.assets[0]!.id)}?offset=0&length=1048576`, owner.token);
  const d2 = await request(fx.app, 'GET', `${route(p, body.id, body.assets[0]!.id)}?offset=1048576&length=1048576`, owner.token);
  assert.deepEqual(Buffer.concat([d1.rawPayload, d2.rawPayload]), bytes);
});

test('bad full hashes reset one asset; complete is impossible until every original is verified', async t => {
  const fx = await fixture(t); const owner = await register(fx.app); const p = await project(fx.app, owner);
  const bytes = Buffer.from('correct original'); const body = manifest(p.id, bytes); const second = Buffer.from('second original');
  body.assets.push({ ...body.assets[0]!, id: randomUUID(), relativePath: 'models/second.obj', mediaType: 'model/obj', byteCount: second.length, sha256: sha(second), kind: 'mesh' });
  success(await request(fx.app, 'POST', route(p), owner.token, body));
  const bad = await chunk(fx.app, p, body, owner.token, Buffer.alloc(bytes.length, 1), 0); assert.equal(bad.statusCode, 422); assert.equal(bad.json().error.code, 'hash_mismatch');
  assert.equal((await request(fx.app, 'GET', route(p, body.id), owner.token)).json().assets.find((item: { id: string }) => item.id === body.assets[0]!.id).uploadedBytes, 0);
  success(await chunk(fx.app, p, body, owner.token, bytes, 0));
  assert.equal((await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {})).statusCode, 409);
  success(await chunk(fx.app, p, body, owner.token, second, 0, body.assets[1]!.id));
  success(await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {}));
});

test('organization/project isolation, role changes and revocation protect every metadata/chunk/download operation', async t => {
  const fx = await fixture(t); const owner = await register(fx.app); const worker = await register(fx.app, 'Surveyor'); const viewer = await register(fx.app, 'Viewer'); const outsider = await register(fx.app);
  const p = await project(fx.app, owner); const another = await project(fx.app, owner); await member(fx.app, owner, worker, 'surveyor'); await member(fx.app, owner, viewer, 'viewer');
  const bytes = Buffer.from('private original'); const body = manifest(p.id, bytes);
  assert.equal((await request(fx.app, 'POST', route(p), viewer.token, body)).statusCode, 403);
  assert.equal((await request(fx.app, 'POST', route(p), outsider.token, body)).statusCode, 404);
  assert.equal((await request(fx.app, 'POST', route(p), worker.token, { ...body, author: { userID: owner.user.id } })).statusCode, 400);
  assert.equal((await request(fx.app, 'POST', route(p), worker.token, { ...body, projectID: another.id })).statusCode, 400);
  success(await request(fx.app, 'POST', route(p), worker.token, body));
  for (const token of [owner.token, viewer.token]) assert.equal((await request(fx.app, 'GET', route(p, body.id), token)).statusCode, 404);
  assert.equal((await chunk(fx.app, p, body, owner.token, bytes, 0)).statusCode, 403);
  assert.equal((await request(fx.app, 'GET', route(another, body.id), worker.token)).statusCode, 404);
  assert.equal((await chunk(fx.app, another, body, worker.token, bytes, 0)).statusCode, 404);
  const downgraded = await request(fx.app, 'PATCH', `/v1/organizations/${owner.organization.id}/members/${worker.user.id}`, owner.token, { role: 'viewer' }); success(downgraded);
  assert.equal((await chunk(fx.app, p, body, worker.token, bytes, 0)).statusCode, 403);
  success(await request(fx.app, 'PATCH', `/v1/organizations/${owner.organization.id}/members/${worker.user.id}`, owner.token, { role: 'surveyor' }));
  success(await chunk(fx.app, p, body, worker.token, bytes, 0)); success(await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, worker.token, {}));
  success(await request(fx.app, 'GET', route(p, body.id), viewer.token)); success(await request(fx.app, 'GET', route(p, body.id, body.assets[0]!.id), viewer.token));
  assert.equal((await request(fx.app, 'GET', route(p, body.id, body.assets[0]!.id), outsider.token)).statusCode, 404);
  success(await request(fx.app, 'DELETE', `/v1/organizations/${owner.organization.id}/members/${worker.user.id}`, owner.token));
  for (const method of ['GET', 'POST'] as const) {
    const response = await request(fx.app, method, method === 'POST' ? `${route(p, body.id)}/finalize` : route(p, body.id), worker.token, method === 'POST' ? {} : undefined); assert.equal(response.statusCode, 404);
  }
  assert.equal((await request(fx.app, 'GET', route(p, body.id, body.assets[0]!.id), worker.token)).statusCode, 404);
  assert.equal((await chunk(fx.app, p, body, worker.token, bytes, 0)).statusCode, 404);
  assert.equal((await fx.app.inject({ method: 'GET', url: route(p, body.id) })).statusCode, 401);
});

test('manifest input bounds, unknown dates, safe paths, unique IDs and geo validation are explicit', async t => {
  const fx = await fixture(t); const owner = await register(fx.app); const p = await project(fx.app, owner);
  const base = manifest(p.id);
  const invalids = [
    { ...base, schemaVersion: 2 }, { ...base, timeZoneIdentifier: 'Not/AZone' }, { ...base, utcOffsetSeconds: 999999 },
    { ...base, createdAt: 1791691200456.5 }, { ...base, utcOffsetSeconds: 64801 },
    { ...base, createdAt: '2026-10-11T00:00:00Z' }, { ...base, device: { model: 'Phone', osVersion: '26', appVersion: '1', operatorID: owner.user.id } },
    ...['../original.heic', '/absolute.heic', 'photos\\original.heic', 'C:/photo.heic', 'photos//photo.heic', 'photos/./photo.heic', 'photos/\0photo.heic'].map(relativePath => ({ ...base, assets: [{ ...base.assets[0], relativePath }] })),
    { ...base, assets: [{ ...base.assets[0], sha256: 'bad' }] }, { ...base, assets: [{ ...base.assets[0], materialID: randomUUID() }] },
    { ...base, assets: [base.assets[0], base.assets[0]] }, { ...base, materials: [base.materials[0], base.materials[0]] },
    { ...base, assets: [{ ...base.assets[0], byteCount: 512 * 1024 * 1024 + 1 }] },
    { ...base, materials: [{ ...base.materials[0], geoTag: { ...base.materials[0]!.geoTag, automaticFix: { ...base.materials[0]!.geoTag.automaticFix, source: 'operatorEntered' } } }] },
    { ...base, materials: [{ ...base.materials[0], geoTag: { ...base.materials[0]!.geoTag, corrections: [{ id: randomUUID(), altitudeMeters: 5, note: 'Invalid reset', changedAt: 123 }] } }] },
    { ...base, materials: [{ ...base.materials[0], capturedAt: null, endedAt: 1791691150123 }] },
    { ...base, materials: [{ ...base.materials[0], endedAt: 1791691150122 }] },
    { ...base, assets: [{ ...base.assets[0], relativePath: `${'я'.repeat(512)}.heic` }] },
  ];
  for (const body of invalids) assert.equal((await request(fx.app, 'POST', route(p), owner.token, body)).statusCode, 400);
  const unknown = { ...base, id: randomUUID(), materials: [{ id: base.materials[0]!.id, sourceEntityID: randomUUID(), kind: 'photo', importedAt: 1791691160234 }] };
  const accepted = await request(fx.app, 'POST', route(p), owner.token, unknown); success(accepted); assert.equal(accepted.json().manifest.materials[0].capturedAt, undefined);
  const tooLarge = await chunk(fx.app, p, unknown as ReturnType<typeof manifest>, owner.token, Buffer.alloc(1048577), 0); assert.equal(tooLarge.statusCode, 413);
  assert.equal((await chunk(fx.app, p, unknown as ReturnType<typeof manifest>, owner.token, Buffer.alloc(0), 0)).statusCode, 400);
});

test('crash tails are truncated, truncated durable files restart and finalization rechecks physical hashes', async t => {
  const fx = await fixture(t); const owner = await register(fx.app); const p = await project(fx.app, owner); const bytes = Buffer.from('abcdef'); const body = manifest(p.id, bytes);
  success(await request(fx.app, 'POST', route(p), owner.token, body)); success(await chunk(fx.app, p, body, owner.token, bytes.subarray(0, 3), 0));
  const file = join(fx.options.assetDirectory, owner.organization.id, p.id, body.id, `${body.assets[0]!.id}.bin`);
  await appendFile(file, 'uncommitted after-crash tail'); await fx.restart();
  success(await chunk(fx.app, p, body, owner.token, bytes.subarray(3), 3)); assert.deepEqual(await readFile(file), bytes);
  await writeFile(file, Buffer.from('abcdeg')); const tampered = await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {}); assert.equal(tampered.statusCode, 422);
  assert.equal((await request(fx.app, 'GET', route(p, body.id), owner.token)).json().assets[0].uploadedBytes, 0);
  success(await chunk(fx.app, p, body, owner.token, bytes.subarray(0, 3), 0)); await writeFile(file, Buffer.from('a'));
  const truncated = await chunk(fx.app, p, body, owner.token, bytes.subarray(3), 3); assert.equal(truncated.statusCode, 409); assert.equal(truncated.json().error.code, 'asset_restarted');
  success(await chunk(fx.app, p, body, owner.token, bytes, 0)); success(await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {}));
});

test('zero-byte files verify correctly, downloads are bounded and filesystem symlinks are never followed', async t => {
  const fx = await fixture(t); const owner = await register(fx.app); const p = await project(fx.app, owner); const body = manifest(p.id, Buffer.alloc(0));
  success(await request(fx.app, 'POST', route(p), owner.token, body)); success(await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {}));
  const empty = await request(fx.app, 'GET', route(p, body.id, body.assets[0]!.id), owner.token); success(empty); assert.equal(empty.rawPayload.length, 0);
  assert.equal((await request(fx.app, 'GET', `${route(p, body.id, body.assets[0]!.id)}?length=1048577`, owner.token)).statusCode, 400);
  assert.equal((await request(fx.app, 'GET', `${route(p, body.id, body.assets[0]!.id)}?offset=1`, owner.token)).statusCode, 400);
  const target = join(fx.directory, 'outside-original'); await writeFile(target, 'outside');
  const attack = manifest(p.id, Buffer.from('replacement')); success(await request(fx.app, 'POST', route(p), owner.token, attack));
  const directory = join(fx.options.assetDirectory, owner.organization.id, p.id, attack.id); await mkdir(directory, { mode: 0o700 });
  await symlink(target, join(directory, `${attack.assets[0]!.id}.bin`));
  assert.equal((await chunk(fx.app, p, attack, owner.token, Buffer.from('replacement'), 0)).statusCode, 500); assert.equal(await readFile(target, 'utf8'), 'outside');
});

test('same-offset competing requests cannot overwrite durable bytes and package lists are paginated', async t => {
  const fx = await fixture(t); const owner = await register(fx.app); const p = await project(fx.app, owner); const bytes = Buffer.from('complete bytes'); const body = manifest(p.id, bytes);
  success(await request(fx.app, 'POST', route(p), owner.token, body));
  const responses = await Promise.all([chunk(fx.app, p, body, owner.token, bytes, 0), chunk(fx.app, p, body, owner.token, bytes, 0)]);
  for (const result of responses) { success(result); assert.equal(result.json().uploadedBytes, bytes.length); }
  success(await request(fx.app, 'POST', `${route(p, body.id)}/finalize`, owner.token, {}));
  const second = manifest(p.id, Buffer.alloc(0)); success(await request(fx.app, 'POST', route(p), owner.token, second)); success(await request(fx.app, 'POST', `${route(p, second.id)}/finalize`, owner.token, {}));
  const page = await request(fx.app, 'GET', `${route(p)}?limit=1&offset=0`, owner.token); assert.equal(page.json().materials.length, 1); assert.equal(page.json().hasMore, true); assert.equal(page.json().nextOffset, 1);
  const next = await request(fx.app, 'GET', `${route(p)}?limit=1&offset=1`, owner.token); assert.equal(next.json().materials.length, 1); assert.equal(next.json().hasMore, false);
});

test('reserved storage is bounded and cancelled incomplete packages release their private originals', async t => {
  const fx = await fixture(t, { maxOrganizationAssetBytes: 1024 * 1024 * 1024 });
  const owner = await register(fx.app); const worker = await register(fx.app); const viewer = await register(fx.app); const p = await project(fx.app, owner);
  await member(fx.app, owner, worker, 'surveyor'); await member(fx.app, owner, viewer, 'viewer');
  const declared = () => { const body = manifest(p.id); body.assets[0]!.byteCount = 512 * 1024 * 1024; return body; };
  const first = declared(); const second = declared(); const third = declared();
  success(await request(fx.app, 'POST', route(p), worker.token, first)); success(await request(fx.app, 'POST', route(p), worker.token, second));
  const full = await request(fx.app, 'POST', route(p), worker.token, third); assert.equal(full.statusCode, 413); assert.equal(full.json().error.code, 'storage_limit');
  success(await chunk(fx.app, p, first, worker.token, Buffer.from('partial original'), 0));
  const file = join(fx.options.assetDirectory, owner.organization.id, p.id, first.id, `${first.assets[0]!.id}.bin`); assert.ok((await stat(file)).isFile());
  assert.equal((await request(fx.app, 'DELETE', route(p, first.id), viewer.token)).statusCode, 403);
  success(await request(fx.app, 'DELETE', `/v1/organizations/${owner.organization.id}/members/${worker.user.id}`, owner.token));
  assert.equal((await request(fx.app, 'DELETE', route(p, first.id), worker.token)).statusCode, 404);
  assert.equal((await request(fx.app, 'DELETE', route(p, first.id), owner.token)).statusCode, 204);
  await assert.rejects(stat(file), { code: 'ENOENT' }); assert.equal((await request(fx.app, 'GET', route(p, first.id), owner.token)).statusCode, 404);
  success(await request(fx.app, 'POST', route(p), owner.token, third));
  success(await request(fx.app, 'DELETE', route(p, second.id), owner.token)); success(await request(fx.app, 'DELETE', route(p, third.id), owner.token));
  const complete = manifest(p.id, Buffer.alloc(0)); success(await request(fx.app, 'POST', route(p), owner.token, complete));
  success(await request(fx.app, 'POST', `${route(p, complete.id)}/finalize`, owner.token, {}));
  assert.equal((await request(fx.app, 'DELETE', route(p, complete.id), owner.token)).statusCode, 409);
});
