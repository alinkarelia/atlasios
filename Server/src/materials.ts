import type { FastifyInstance, FastifyRequest } from 'fastify';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, mkdir, open, rm, type FileHandle } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { contentHash, canonical } from './auth.js';
import { ApiError, enumeration, id, integer, invalid, keys, object, text, type Role } from './domain.js';
import type { Store } from './store.js';

const CHUNK_BYTES = 1024 * 1024;
const FILE_BYTES = 512 * 1024 * 1024;
const PACKAGE_BYTES = 1024 * 1024 * 1024;
const materialKinds = ['photo', 'mesh', 'floorPlan', 'feature', 'measurement', 'project'] as const;
const assetKinds = ['originalPhoto', 'mesh', 'roomPlan', 'metadata', 'floorPlan', 'feature', 'measurement', 'projectSnapshot', 'preview', 'other'] as const;
const writers: Role[] = ['owner', 'admin', 'manager', 'surveyor'];
const notFound = () => new ApiError(404, 'not_found', 'Resource not found');
const forbidden = () => new ApiError(403, 'forbidden', 'Your role does not permit this action');

interface ManifestAsset { id: string; materialID: string; relativePath: string; mediaType: string; byteCount: number; sha256: string; kind: string }
interface Manifest { schemaVersion: 1; id: string; projectID: string; title: string; createdAt: number; timeZoneIdentifier: string;
  utcOffsetSeconds: number; device?: { model: string; osVersion: string; appVersion: string }; materials: Record<string, unknown>[]; assets: ManifestAsset[] }
interface PackageRow { id: string; organization_id: string; project_id: string; author_id: string; author_name: string;
  manifest_json: string; manifest_hash: string; total_bytes: number; state: 'incomplete' | 'complete'; received_at: string; completed_at: string | null }
interface AssetRow { package_id: string; id: string; byte_count: number; sha256: string; uploaded_bytes: number; verified: number }
interface Scope { row: { id: string; organization_id: string }; role: Role }
interface MaterialOptions {
  assetDirectory: string; maxOrganizationBytes?: number;
  scope(projectID: string, request: FastifyRequest): Scope;
  user(request: FastifyRequest): { id: string; display_name: string };
  audit(organizationID: string, actorID: string, action: string, subjectID: string): void;
}

function finite(value: unknown, name: string, min = -Number.MAX_VALUE, max = Number.MAX_VALUE): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) invalid(`Invalid ${name}`);
  return value;
}
function date(value: unknown, name: string): number { return integer(value, name, -8640000000000000, 8640000000000000); }
function optionalNumber(value: unknown, name: string, min = -Number.MAX_VALUE) {
  if (value !== undefined && value !== null) finite(value, name, min);
}
function coordinate(value: unknown) {
  const point = object(value, 'coordinate'); keys(point, ['latitude', 'longitude']);
  finite(point.latitude, 'latitude', -90, 90); finite(point.longitude, 'longitude', -180, 180);
}
function geoTag(input: unknown) {
  const tag = object(input, 'geoTag'); keys(tag, ['automaticFix', 'corrections']);
  if (tag.automaticFix != null) {
    const fix = object(tag.automaticFix, 'automaticFix');
    keys(fix, ['coordinate', 'altitudeMeters', 'horizontalAccuracyMeters', 'verticalAccuracyMeters', 'observedAt', 'source', 'isSimulated']);
    coordinate(fix.coordinate); date(fix.observedAt, 'observedAt');
    enumeration(fix.source, ['deviceLocation', 'photoEXIF'], 'automatic source');
    if (typeof fix.isSimulated !== 'boolean') invalid('isSimulated must be a boolean');
    optionalNumber(fix.altitudeMeters, 'altitudeMeters');
    optionalNumber(fix.horizontalAccuracyMeters, 'horizontalAccuracyMeters', 0);
    optionalNumber(fix.verticalAccuracyMeters, 'verticalAccuracyMeters', 0);
  }
  if (!Array.isArray(tag.corrections) || tag.corrections.length > 1000) invalid('Invalid correction history');
  const seen = new Set<string>();
  for (const raw of tag.corrections) {
    const correction = object(raw, 'correction'); keys(correction, ['id', 'coordinate', 'altitudeMeters', 'estimatedAccuracyMeters', 'note', 'changedAt']);
    const correctionID = id(correction.id); if (seen.has(correctionID)) invalid('Duplicate correction ID'); seen.add(correctionID);
    correction.id = correctionID; date(correction.changedAt, 'changedAt'); text(correction.note, 'note', 4096);
    if (correction.coordinate != null) {
      coordinate(correction.coordinate); optionalNumber(correction.altitudeMeters, 'altitudeMeters');
      optionalNumber(correction.estimatedAccuracyMeters, 'estimatedAccuracyMeters', 0);
    } else if (correction.altitudeMeters != null || correction.estimatedAccuracyMeters != null) invalid('A location reset cannot contain altitude or accuracy');
  }
}

/** Versioned transfer JSON uses AtlasJSON's numeric milliseconds, preserving original observations. */
export function materialManifest(input: unknown): Manifest {
  const value = object(input, 'manifest');
  keys(value, ['schemaVersion', 'id', 'projectID', 'title', 'createdAt', 'timeZoneIdentifier', 'utcOffsetSeconds', 'device', 'materials', 'assets']);
  if (value.schemaVersion !== 1) invalid('Unsupported material schema version');
  value.id = id(value.id); value.projectID = id(value.projectID, 'projectID');
  text(value.title, 'title', 240, 1); date(value.createdAt, 'createdAt');
  text(value.timeZoneIdentifier, 'timeZoneIdentifier', 100, 1);
  try { new Intl.DateTimeFormat('en', { timeZone: value.timeZoneIdentifier as string }); } catch { invalid('Invalid timeZoneIdentifier'); }
  integer(value.utcOffsetSeconds, 'utcOffsetSeconds', -64800, 64800);
  if (value.device != null) {
    const device = object(value.device, 'device'); keys(device, ['model', 'osVersion', 'appVersion']);
    text(device.model, 'model', 160, 1); text(device.osVersion, 'osVersion', 160, 1); text(device.appVersion, 'appVersion', 160, 1);
  }
  if (!Array.isArray(value.materials) || value.materials.length < 1 || value.materials.length > 1000) invalid('A package requires 1–1000 materials');
  const materialIDs = new Set<string>();
  for (const raw of value.materials) {
    const material = object(raw, 'material');
    keys(material, ['id', 'sourceEntityID', 'kind', 'capturedAt', 'endedAt', 'importedAt', 'frameID', 'geoTag']);
    material.id = id(material.id); material.sourceEntityID = id(material.sourceEntityID, 'sourceEntityID');
    if (materialIDs.has(material.id as string)) invalid('Duplicate material ID'); materialIDs.add(material.id as string);
    enumeration(material.kind, materialKinds, 'material kind');
    for (const field of ['capturedAt', 'endedAt', 'importedAt']) if (material[field] != null) date(material[field], field);
    if (material.endedAt != null && (material.capturedAt == null || (material.endedAt as number) < (material.capturedAt as number))) invalid('endedAt requires an earlier or equal capturedAt');
    if (material.frameID != null) material.frameID = id(material.frameID, 'frameID');
    if (material.geoTag != null) geoTag(material.geoTag);
  }
  if (!Array.isArray(value.assets) || value.assets.length < 1 || value.assets.length > 2048) invalid('A package requires 1–2048 assets');
  const assetIDs = new Set<string>(); const paths = new Set<string>(); let totalBytes = 0;
  for (const raw of value.assets) {
    const asset = object(raw, 'asset'); keys(asset, ['id', 'materialID', 'relativePath', 'mediaType', 'byteCount', 'sha256', 'kind']);
    asset.id = id(asset.id); asset.materialID = id(asset.materialID, 'materialID');
    if (!materialIDs.has(asset.materialID as string)) invalid('Asset material does not exist in this package');
    if (assetIDs.has(asset.id as string)) invalid('Duplicate asset ID'); assetIDs.add(asset.id as string);
    const path = text(asset.relativePath, 'relativePath', 1024, 1);
    if (Buffer.byteLength(path, 'utf8') > 1024) invalid('relativePath exceeds 1024 UTF-8 bytes');
    const segments = path.split('/');
    if (path.includes('\\') || /[\x00-\x1f\x7f]/.test(path) || segments.some(part => part === '' || part === '.' || part === '..' || part.includes(':'))) invalid('Unsafe relativePath');
    if (paths.has(path)) invalid('Duplicate asset path'); paths.add(path);
    const mediaType = text(asset.mediaType, 'mediaType', 100, 3);
    if (!/^[a-zA-Z0-9!#$&^_.+-]+\/[a-zA-Z0-9!#$&^_.+-]+$/.test(mediaType)) invalid('Invalid mediaType');
    enumeration(asset.kind, assetKinds, 'asset kind');
    totalBytes += integer(asset.byteCount, 'byteCount', 0, FILE_BYTES);
    const sha = text(asset.sha256, 'sha256', 64, 64); if (!/^[0-9a-f]{64}$/.test(sha)) invalid('sha256 must be lowercase hexadecimal');
    if (asset.byteCount === 0 && sha !== createHash('sha256').digest('hex')) invalid('Empty asset hash is invalid');
  }
  if (totalBytes > PACKAGE_BYTES) invalid('Package exceeds 1 GiB; split it into smaller packages');
  return value as unknown as Manifest;
}

/** One private root, per-ID filenames, bounded handles/buffers; never resolve client relative paths. */
class PrivateAssetStorage {
  readonly root: string;
  constructor(path: string) { this.root = resolve(path); }
  async ready() { await mkdir(this.root, { recursive: true, mode: 0o700 }); await this.directory(this.root); }
  private async directory(path: string) {
    const stat = await lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('ASSET_DIRECTORY must contain real private directories');
    if (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) throw new Error('ASSET_DIRECTORY and its managed directories require private 0700 permissions');
  }
  async handle(row: PackageRow, assetID: string): Promise<FileHandle> {
    let directory = this.root;
    for (const component of [row.organization_id, row.project_id, row.id]) {
      directory = join(directory, id(component));
      try { await mkdir(directory, { mode: 0o700 }); } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; }
      await this.directory(directory);
    }
    const handle = await open(join(directory, `${id(assetID)}.bin`), constants.O_CREAT | constants.O_RDWR | constants.O_NOFOLLOW, 0o600);
    const stat = await handle.stat();
    if (!stat.isFile() || (process.platform !== 'win32' && (stat.mode & 0o077) !== 0)) {
      await handle.close(); throw new Error('Asset storage must be a private regular file');
    }
    return handle;
  }
  async remove(row: PackageRow) {
    let directory = this.root;
    for (const component of [row.organization_id, row.project_id, row.id]) {
      directory = join(directory, id(component));
      try { await this.directory(directory); } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return; throw error; }
    }
    await rm(directory, { recursive: true, force: true });
  }
}
async function hashFile(handle: FileHandle, bytes: number): Promise<string> {
  const hash = createHash('sha256');
  if (bytes) for await (const chunk of handle.createReadStream({ start: 0, end: bytes - 1, autoClose: false })) hash.update(chunk);
  return hash.digest('hex');
}

export async function registerMaterialRoutes(app: FastifyInstance, store: Store, options: MaterialOptions) {
  const storage = new PrivateAssetStorage(options.assetDirectory); await storage.ready();
  const maxOrganizationBytes = integer(options.maxOrganizationBytes ?? 8 * PACKAGE_BYTES, 'maxOrganizationBytes', PACKAGE_BYTES);
  const locks = new Map<string, Promise<void>>();
  async function locked<T>(key: string, work: () => Promise<T>): Promise<T> {
    const previous = locks.get(key) ?? Promise.resolve(); let release!: () => void;
    const current = new Promise<void>(resolve => { release = resolve; });
    locks.set(key, current); await previous;
    try { return await work(); } finally { release(); if (locks.get(key) === current) locks.delete(key); }
  }
  function scoped(request: FastifyRequest) {
    const params = request.params as { projectID: string; captureID?: string; assetID?: string };
    const scope = options.scope(id(params.projectID), request);
    const captureID = params.captureID === undefined ? undefined : id(params.captureID, 'captureID');
    const assetID = params.assetID === undefined ? undefined : id(params.assetID, 'assetID');
    return { scope, captureID, assetID };
  }
  function packageRow(captureID: string, projectID: string) {
    const row = store.get<PackageRow>('SELECT * FROM material_packages WHERE id = ? AND project_id = ?', captureID, projectID);
    if (!row) throw notFound(); return row;
  }
  function writable(request: FastifyRequest, row?: PackageRow) {
    const { scope } = scoped(request);
    if (!writers.includes(scope.role)) throw forbidden();
    if (row && row.author_id !== options.user(request).id) throw forbidden();
    return scope;
  }
  function status(row: PackageRow) {
    return { captureID: row.id, projectID: row.project_id, state: row.state,
      author: { userID: row.author_id, displayName: row.author_name }, receivedAt: Date.parse(row.received_at),
      ...(row.completed_at ? { completedAt: Date.parse(row.completed_at) } : {}), manifest: JSON.parse(row.manifest_json),
      assets: store.all<AssetRow>('SELECT * FROM material_assets WHERE package_id = ? ORDER BY id', row.id)
        .map(asset => ({ id: asset.id, byteCount: asset.byte_count, uploadedBytes: asset.uploaded_bytes, verified: Boolean(asset.verified) })), chunkSize: CHUNK_BYTES };
  }
  function assetRow(packageID: string, assetID: string) {
    const row = store.get<AssetRow>('SELECT * FROM material_assets WHERE package_id = ? AND id = ?', packageID, assetID);
    if (!row) throw notFound(); return row;
  }
  const assetStatus = (row: AssetRow) => ({ id: row.id, byteCount: row.byte_count, uploadedBytes: row.uploaded_bytes, verified: Boolean(row.verified) });
  app.addContentTypeParser('application/octet-stream', { parseAs: 'buffer', bodyLimit: CHUNK_BYTES }, (_request, body, done) => done(null, body));

  app.post('/v1/projects/:projectID/materials', async (request, reply) => {
    const scope = writable(request); const manifest = materialManifest(request.body);
    if (manifest.projectID !== scope.row.id) invalid('Manifest projectID must match the selected project');
    const hash = contentHash(manifest); const author = options.user(request); const timestamp = new Date().toISOString();
    let created = false;
    const row = store.transaction(() => {
      writable(request);
      const existing = store.get<PackageRow>('SELECT * FROM material_packages WHERE id = ?', manifest.id);
      if (existing) {
        if (existing.project_id !== scope.row.id) throw notFound();
        if (existing.author_id !== author.id) throw forbidden();
        if (existing.manifest_hash !== hash) throw new ApiError(409, 'manifest_mismatch', 'A frozen package cannot be edited; create a new package ID');
        return existing;
      }
      const total = manifest.assets.reduce((sum, asset) => sum + asset.byteCount, 0);
      const reserved = store.get<{ bytes: number }>('SELECT COALESCE(SUM(total_bytes), 0) AS bytes FROM material_packages WHERE organization_id = ?', scope.row.organization_id)!.bytes;
      const incomplete = store.get<{ count: number }>("SELECT COUNT(*) AS count FROM material_packages WHERE organization_id = ? AND state = 'incomplete'", scope.row.organization_id)!.count;
      if (incomplete >= 100) throw new ApiError(409, 'pending_package_limit', 'Complete existing packages before starting another upload');
      if (reserved + total > maxOrganizationBytes) throw new ApiError(413, 'storage_limit', 'Organization storage limit has been reached');
      store.run('INSERT INTO material_packages VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', manifest.id, scope.row.organization_id, scope.row.id,
        author.id, author.display_name, canonical(manifest), hash, total, 'incomplete', timestamp, null);
      for (const asset of manifest.assets) store.run('INSERT INTO material_assets VALUES (?, ?, ?, ?, ?, ?)', manifest.id, asset.id, asset.byteCount, asset.sha256, 0, Number(asset.byteCount === 0));
      options.audit(scope.row.organization_id, author.id, 'materials.started', manifest.id); created = true;
      return packageRow(manifest.id, scope.row.id);
    });
    return reply.code(created ? 201 : 200).send(status(row));
  });
  app.get('/v1/projects/:projectID/materials', async request => {
    const { scope } = scoped(request); const query = request.query as { limit?: string; offset?: string };
    const limit = integer(query.limit === undefined ? 100 : Number(query.limit), 'limit', 1, 200);
    const offset = integer(query.offset === undefined ? 0 : Number(query.offset), 'offset', 0, 1e8);
    const rows = store.all<PackageRow>("SELECT * FROM material_packages WHERE project_id = ? AND state = 'complete' ORDER BY received_at, id LIMIT ? OFFSET ?", scope.row.id, limit + 1, offset);
    return { materials: rows.slice(0, limit).map(status), hasMore: rows.length > limit, nextOffset: offset + Math.min(rows.length, limit) };
  });
  app.get('/v1/projects/:projectID/materials/:captureID', async request => {
    const { scope, captureID } = scoped(request); const row = packageRow(captureID!, scope.row.id);
    if (row.state !== 'complete' && row.author_id !== options.user(request).id) throw notFound();
    return status(row);
  });
  app.delete('/v1/projects/:projectID/materials/:captureID', async (request, reply) => {
    const { scope, captureID } = scoped(request);
    await locked(captureID!, async () => {
      const row = packageRow(captureID!, scope.row.id);
      function allowed() {
        const actual = scoped(request).scope.role;
        if (!writers.includes(actual) || (row.author_id !== options.user(request).id && !['owner', 'admin', 'manager'].includes(actual))) throw forbidden();
      }
      allowed(); if (row.state === 'complete') throw new ApiError(409, 'package_complete', 'Completed packages are immutable');
      await storage.remove(row);
      store.transaction(() => {
        allowed();
        store.run('DELETE FROM material_assets WHERE package_id = ?', row.id);
        store.run('DELETE FROM material_packages WHERE id = ?', row.id);
        options.audit(scope.row.organization_id, options.user(request).id, 'materials.cancelled', row.id);
      });
    });
    return reply.code(204).send();
  });
  app.put('/v1/projects/:projectID/materials/:captureID/assets/:assetID', { bodyLimit: CHUNK_BYTES }, async request => {
    const { scope, captureID, assetID } = scoped(request); const offset = integer(Number((request.query as { offset?: string }).offset), 'offset', 0, FILE_BYTES);
    if (!Buffer.isBuffer(request.body) || request.body.length === 0) invalid('A nonempty binary chunk is required');
    const body: Buffer = request.body;
    return locked(captureID!, async () => {
      const row = packageRow(captureID!, scope.row.id); writable(request, row);
      if (row.state === 'complete') throw new ApiError(409, 'package_complete', 'Completed packages are immutable');
      let asset = assetRow(row.id, assetID!);
      if (offset > asset.uploaded_bytes || offset + body.length > asset.byte_count) throw new ApiError(409, 'offset_conflict', 'Fetch package status and resume at uploadedBytes');
      const handle = await storage.handle(row, asset.id);
      try {
        const diskBytes = (await handle.stat()).size;
        if (diskBytes < asset.uploaded_bytes) {
          await handle.truncate(0); await handle.sync(); writable(request, row);
          store.run('UPDATE material_assets SET uploaded_bytes = 0, verified = 0 WHERE package_id = ? AND id = ?', row.id, asset.id);
          throw new ApiError(409, 'asset_restarted', 'Asset storage was interrupted; fetch status and restart this asset');
        }
        if (diskBytes > asset.uploaded_bytes) await handle.truncate(asset.uploaded_bytes);
        if (offset < asset.uploaded_bytes) {
          if (offset + body.length > asset.uploaded_bytes) throw new ApiError(409, 'offset_conflict', 'Fetch package status and resume at uploadedBytes');
          const previous = Buffer.alloc(body.length); const { bytesRead } = await handle.read(previous, 0, previous.length, offset);
          if (bytesRead !== body.length || !previous.equals(body)) throw new ApiError(409, 'chunk_mismatch', 'Previously received bytes cannot be overwritten');
          writable(request, row); return assetStatus(asset);
        }
        let written = 0;
        while (written < body.length) { const result = await handle.write(body, written, body.length - written, offset + written); if (!result.bytesWritten) throw new Error('Asset write did not progress'); written += result.bytesWritten; }
        await handle.sync(); const uploadedBytes = offset + body.length;
        const verified = uploadedBytes === asset.byte_count && await hashFile(handle, uploadedBytes) === asset.sha256;
        writable(request, row);
        if (uploadedBytes === asset.byte_count && !verified) {
          await handle.truncate(0); await handle.sync(); writable(request, row);
          store.run('UPDATE material_assets SET uploaded_bytes = 0, verified = 0 WHERE package_id = ? AND id = ?', row.id, asset.id);
          throw new ApiError(422, 'hash_mismatch', 'Asset SHA-256 did not match; fetch status and retransmit the original file');
        }
        store.run('UPDATE material_assets SET uploaded_bytes = ?, verified = ? WHERE package_id = ? AND id = ?', uploadedBytes, Number(verified), row.id, asset.id);
        asset = assetRow(row.id, asset.id); return assetStatus(asset);
      } finally { await handle.close(); }
    });
  });
  app.post('/v1/projects/:projectID/materials/:captureID/finalize', async request => {
    keys(object(request.body ?? {}), []); const { scope, captureID } = scoped(request);
    return locked(captureID!, async () => {
      let row = packageRow(captureID!, scope.row.id); writable(request, row);
      if (row.state === 'complete') return status(row);
      const assets = store.all<AssetRow>('SELECT * FROM material_assets WHERE package_id = ?', row.id);
      if (assets.some(asset => !asset.verified || asset.uploaded_bytes !== asset.byte_count)) throw new ApiError(409, 'incomplete_package', 'Every original file must be fully uploaded and verified');
      for (const asset of assets) {
        const handle = await storage.handle(row, asset.id);
        try {
          if ((await handle.stat()).size !== asset.byte_count || await hashFile(handle, asset.byte_count) !== asset.sha256) {
            await handle.truncate(0); await handle.sync(); writable(request, row);
            store.run('UPDATE material_assets SET uploaded_bytes = 0, verified = 0 WHERE package_id = ? AND id = ?', row.id, asset.id);
            throw new ApiError(422, 'hash_mismatch', 'Stored bytes failed final verification; retransmit this asset');
          }
        } finally { await handle.close(); }
      }
      store.transaction(() => {
        writable(request, row);
        store.run("UPDATE material_packages SET state = 'complete', completed_at = ? WHERE id = ?", new Date().toISOString(), row.id);
        options.audit(scope.row.organization_id, options.user(request).id, 'materials.completed', row.id);
      });
      row = packageRow(row.id, scope.row.id); return status(row);
    });
  });
  app.get('/v1/projects/:projectID/materials/:captureID/assets/:assetID', async (request, reply) => {
    const { scope, captureID, assetID } = scoped(request); const row = packageRow(captureID!, scope.row.id);
    if (row.state !== 'complete') throw notFound(); const asset = assetRow(row.id, assetID!);
    const query = request.query as { offset?: string; length?: string };
    const offset = integer(query.offset === undefined ? 0 : Number(query.offset), 'offset', 0, asset.byte_count);
    const length = integer(query.length === undefined ? CHUNK_BYTES : Number(query.length), 'length', 1, CHUNK_BYTES);
    const bytes = Math.min(length, asset.byte_count - offset); const handle = await storage.handle(row, asset.id);
    try {
      if ((await handle.stat()).size !== asset.byte_count) throw new ApiError(503, 'storage_unavailable', 'Original asset is unavailable; retry later or contact the project administrator');
      const result = Buffer.alloc(bytes); const { bytesRead } = await handle.read(result, 0, bytes, offset);
      if (bytesRead !== bytes) throw new ApiError(503, 'storage_unavailable', 'Original asset is temporarily unavailable');
      // Membership may have been revoked while the file was being read.
      scoped(request);
      const manifest = JSON.parse(row.manifest_json) as Manifest; const declared = manifest.assets.find(item => item.id === asset.id)!;
      return reply.type(declared.mediaType).header('X-Asset-SHA256', asset.sha256).header('X-Asset-Byte-Count', asset.byte_count)
        .header('X-Asset-Offset', offset).header('X-Content-Type-Options', 'nosniff')
        .header('Content-Disposition', `attachment; filename="${asset.id}.bin"`).send(result);
    } finally { await handle.close(); }
  });
}
