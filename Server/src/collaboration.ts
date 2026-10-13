import type { FastifyInstance, FastifyRequest } from 'fastify';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { contentHash, canonical } from './auth.js';
import { ApiError, id, integer, enumeration, invalid, keys, object, text, coordinateReference, geometry, type Role } from './domain.js';
import type { Store } from './store.js';
import { canonicalCollaborativeGrid, containsStrictly } from './collaboration-geometry.js';

/** No API key/client-side worker is accepted here. An installed server adapter is optional. */
export interface AssemblyProcessor {
  readonly name: string;
  process(context: AssemblyContext): Promise<AssemblyResult>;
}
export interface AssemblyContext {
  jobID: string; projectID: string; kind: AssemblyKind; target: AssemblySource;
  sources: AssemblySource[]; sourceManifestHashes: Record<string, string>;
  registrations: { sourceKey: string; transform: RigidTransform }[];
  /** Consume every source through this bounded, SHA-checked reader before returning an output. */
  readSource(source: AssemblySource): AsyncIterable<Buffer>;
}
export interface AssemblyResult {
  outputSources: AssemblySource[];
  sourceManifestHashes: Record<string, string>;
  targetFrameID: string;
  /** A worker's actual method/version, not a generated natural-language claim. */
  method: string;
}
interface Scope { row: { id: string; organization_id: string }; role: Role }
interface Options {
  scope(projectID: string, request: FastifyRequest): Scope;
  user(request: FastifyRequest): { id: string };
  audit(organizationID: string, actorID: string, action: string, subjectID: string): void;
  processor?: AssemblyProcessor;
  assetDirectory: string;
}
export interface AssemblySource {
  packageID: string; assetID: string; captureID: string; frameID: string;
  sourceSHA256: string; sourceVersion: 1; unit: 'meters';
}
export interface Point3 { x: number; y: number; z: number }
export interface RigidTransform { rotation: number[]; translation: Point3 }
type AssemblyKind = 'registeredScene' | 'orthomosaic' | 'photoTour';
type JobState = 'queued' | 'running' | 'waitingForRegistration' | 'ready' | 'failed';
interface PackageRow { id: string; project_id: string; state: string; manifest_json: string; manifest_hash: string; author_id: string }
interface RegistrationRow { id: string; project_id: string; source_key: string; target_key: string; data_json: string; content_hash: string; author_id: string; created_at: string }
interface PlanRow { project_id: string; revision: number; data_json: string; content_hash: string; author_id: string; created_at: string }
interface JobRequest { id: string; kind: AssemblyKind; sources: AssemblySource[]; target: AssemblySource }
interface JobRow { id: string; project_id: string; request_json: string; request_hash: string; revision: number; state: JobState; outcome_json: string; actor_id: string; created_at: string; updated_at: string }
const managers: Role[] = ['owner', 'admin', 'manager'];
const writers: Role[] = [...managers, 'surveyor'];
const reviewers: Role[] = [...managers, 'reviewer'];
const timestamp = () => new Date().toISOString();
const notFound = () => new ApiError(404, 'not_found', 'Resource not found');
const conflict = (code: string, message: string) => new ApiError(409, code, message);
function requireRole(role: Role, allowed: Role[]) { if (!allowed.includes(role)) throw new ApiError(403, 'forbidden', 'Your role does not permit this action'); }
function finite(value: unknown, name: string, min = -1e6, max = 1e6): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) invalid(`Invalid ${name}`);
  return value;
}
function sha(value: unknown): string { const result = text(value, 'sha256', 64, 64); if (!/^[0-9a-f]{64}$/.test(result)) invalid('SHA256 must be lowercase hexadecimal'); return result; }
function bounded(input: unknown, maxBytes = 512 * 1024) { if (Buffer.byteLength(JSON.stringify(input), 'utf8') > maxBytes) invalid('Collaboration document exceeds its byte limit'); }
function deepFreeze<T>(value: T): T { if (value && typeof value === 'object') { for (const child of Object.values(value)) deepFreeze(child); Object.freeze(value); } return value; }
function point3(input: unknown): Point3 { const value = object(input, 'point'); keys(value, ['x', 'y', 'z']); return { x: finite(value.x, 'x'), y: finite(value.y, 'y'), z: finite(value.z, 'z') }; }
export function assemblySource(input: unknown): AssemblySource {
  const value = object(input, 'source'); keys(value, ['packageID', 'assetID', 'captureID', 'frameID', 'sourceSHA256', 'sourceVersion', 'unit']);
  if (value.sourceVersion !== 1) invalid('An immutable uploaded-original source reference must have sourceVersion 1');
  if (value.unit !== 'meters') invalid('Registration requires explicitly declared meters');
  return { packageID: id(value.packageID), assetID: id(value.assetID), captureID: id(value.captureID), frameID: id(value.frameID), sourceSHA256: sha(value.sourceSHA256), sourceVersion: 1, unit: 'meters' };
}
const sourceKey = (source: AssemblySource) => contentHash(source);
interface Point2 { x: number; y: number }
interface Polygon2 { frameID: string; vertices: Point2[]; holes: Point2[][] }
interface PlanCell { id: string; row: number; column: number; center: Point2; boundsVertices: Point2[]; boundaryStatus: string; estimatedWorkAreaSquareMeters: number; componentID: number }
interface PlanData { schemaVersion: 1; id: string; projectID: string; revision: number; createdAt: number; updatedAt: number;
  coordinateReference: unknown; sourceBoundary: unknown; sourceBoundarySHA256: string; gridFrameID: string; projection?: unknown;
  boundary: Polygon2; cellSizeMeters: number; cells: PlanCell[]; workers: { id: string; name: string }[];
  assignments: { cellID: string; workerID: string }[]; evidence: Evidence[]; assignmentHistory: Record<string, unknown>[]; warnings: string[] }
interface Evidence { id: string; workerID: string; kind: 'gpsWalk' | 'captureObserved' | 'operatorVerified'; timestamp: number;
  cellIDs: string[]; captureID?: string; sourceFrameID?: string; registrationID?: string; footprint?: Polygon2;
  sourceSHA256?: string; footprintProvenance?: 'operatorMapped' | 'registeredCapture';
  horizontalAccuracyMeters?: number; quality: 'unknown' | 'usable' | 'needsRescan'; referencedEvidenceIDs: string[]; boundaryReviewed: boolean; note: string }
interface PlanEnvelope { plan: PlanData; workerMappings: { workerID: string; userID: string }[]; sourceBoundaryJSON: string }
function point2(input: unknown): Point2 { const p = object(input); keys(p, ['x', 'y']); return { x: finite(p.x, 'x'), y: finite(p.y, 'y') }; }
function polygon(input: unknown, frameID: string): Polygon2 {
  const p = object(input, 'polygon'); keys(p, ['frameID', 'vertices', 'holes']);
  if (id(p.frameID) !== frameID) invalid('Polygon frame must match the plan grid');
  geometry({ metricPolygon: p }, { type: 'localMeters', frameID });
  return { frameID, vertices: (p.vertices as unknown[]).map(point2), holes: ((p.holes ?? []) as unknown[][]).map(r => r.map(point2)) };
}
function ringContains(point: Point2, ring: Point2[]) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i]!, b = ring[j]!;
    const cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
    if (Math.abs(cross) < 1e-8 && point.x >= Math.min(a.x, b.x) - 1e-8 && point.x <= Math.max(a.x, b.x) + 1e-8 && point.y >= Math.min(a.y, b.y) - 1e-8 && point.y <= Math.max(a.y, b.y) + 1e-8) return true;
    if ((a.y > point.y) !== (b.y > point.y) && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}
function contains(point: Point2, p: Polygon2) { return ringContains(point, p.vertices) && !p.holes.some(r => ringContains(point, r)); }
function sourcePolygon(input: unknown): Record<string, unknown> {
  const source = object(input), type = source.type;
  if (type === 'metricPolygon' || type === 'geographicPolygon') { const p = { ...source }; delete p.type; return p; }
  const names = Object.keys(source); if (names.length !== 1 || !['metricPolygon', 'geographicPolygon'].includes(names[0]!)) invalid('A plan source must be a polygon');
  const wrapped = object(source[names[0]!]); return '_0' in wrapped ? object(wrapped._0) : wrapped;
}
/** Swift plan dates use seconds since 2001; server-createdAt remains an independent ISO UTC receipt. */
function planData(input: unknown, projectID: string, projectReference: unknown): PlanData {
  const p = object(input, 'plan'); keys(p, ['schemaVersion', 'id', 'projectID', 'revision', 'createdAt', 'updatedAt', 'coordinateReference', 'sourceBoundary', 'sourceBoundarySHA256', 'gridFrameID', 'projection', 'boundary', 'cellSizeMeters', 'cells', 'workers', 'assignments', 'evidence', 'assignmentHistory', 'warnings']); bounded(p, 16 * 1024 * 1024);
  if (p.schemaVersion !== 1 || integer(p.revision, 'plan revision') !== 0 || !Array.isArray(p.evidence) || p.evidence.length || !Array.isArray(p.assignmentHistory) || p.assignmentHistory.length) invalid('Online plan creation requires a new revision-zero plan; import offline evidence through authenticated append operations');
  if (id(p.projectID) !== projectID) invalid('Plan projectID must match the authenticated project');
  const frameID = id(p.gridFrameID), reference = coordinateReference(p.coordinateReference);
  if (canonical(reference) !== canonical(coordinateReference(projectReference))) invalid('Plan and project coordinate references differ');
  geometry(p.sourceBoundary, reference); const original = sourcePolygon(p.sourceBoundary), boundary = polygon(p.boundary, frameID);
  sha(p.sourceBoundarySHA256); const cellSize = finite(p.cellSizeMeters, 'cellSizeMeters', 1, 500);
  const projection = p.projection == null ? undefined : object(p.projection);
  if (reference.type === 'localMeters') {
    if (projection || frameID !== reference.frameID) invalid('A metric source must retain its original local frame');
    const normalized = polygon(original, frameID); if (canonical(normalized) !== canonical(boundary)) invalid('A metric plan must retain its exact original boundary');
  } else {
    if (!projection) invalid('A WGS84 plan requires its explicit local tangent projection'); keys(projection, ['anchor', 'maximumRadiusMeters']);
    const anchor = object(projection.anchor); keys(anchor, ['longitude', 'latitude']);
    const longitude = finite(anchor.longitude, 'longitude', -180, 180), latitude = finite(anchor.latitude, 'latitude', -90, 90), radius = finite(projection.maximumRadiusMeters, 'maximumRadiusMeters', .001, 5000);
    const rings = [original.vertices as unknown[], ...((original.holes ?? []) as unknown[][])];
    if (canonical(rings[0]![0]) !== canonical(anchor)) invalid('Projection anchor must be the original first boundary vertex');
    const ecef = (lon: number, lat: number) => { lon *= Math.PI / 180; lat *= Math.PI / 180; const n = 6378137 / Math.sqrt(1 - 6.6943799901413165e-3 * Math.sin(lat) ** 2); return [n * Math.cos(lat) * Math.cos(lon), n * Math.cos(lat) * Math.sin(lon), n * (1 - 6.6943799901413165e-3) * Math.sin(lat)]; };
    const origin = ecef(longitude, latitude), lon = longitude * Math.PI / 180, lat = latitude * Math.PI / 180;
    const projected = rings.map(ring => ring.map(raw => { const point = object(raw), xyz = ecef(point.longitude as number, point.latitude as number); const dx = xyz[0]! - origin[0]!, dy = xyz[1]! - origin[1]!, dz = xyz[2]! - origin[2]!;
      if (Math.hypot(dx, dy, dz) > radius) invalid('Boundary exceeds the explicit local projection radius');
      return { x: -Math.sin(lon) * dx + Math.cos(lon) * dy, y: -Math.sin(lat) * Math.cos(lon) * dx - Math.sin(lat) * Math.sin(lon) * dy + Math.cos(lat) * dz }; }));
    const actual = [boundary.vertices, ...boundary.holes];
    if (actual.length !== projected.length || actual.some((ring, i) => ring.length !== projected[i]!.length || ring.some((point, j) => Math.hypot(point.x - projected[i]![j]!.x, point.y - projected[i]![j]!.y) > 1e-6))) invalid('Metric boundary does not match the declared WGS84 projection');
  }
  if (!Array.isArray(p.workers) || p.workers.length < 1 || p.workers.length > 64) invalid('A plan needs 1–64 distinct mapped employees');
  const workers = p.workers.map(raw => { const w = object(raw); keys(w, ['id', 'name']); const name = text(w.name, 'worker name', 160, 1); if (Buffer.byteLength(name, 'utf8') > 240) invalid('Worker name exceeds 240 UTF-8 bytes'); return { id: id(w.id), name }; });
  if (new Set(workers.map(w => w.id)).size !== workers.length) invalid('Duplicate worker identity');
  if (!Array.isArray(p.cells) || p.cells.length < 1 || p.cells.length > 20000) invalid('A plan supports 1–20000 grid cells');
  const minX = Math.min(...boundary.vertices.map(x => x.x)), minY = Math.min(...boundary.vertices.map(x => x.y));
  const maxX = Math.max(...boundary.vertices.map(x => x.x)), maxY = Math.max(...boundary.vertices.map(x => x.y));
  const rows = Math.ceil((maxY - minY) / cellSize), columns = Math.ceil((maxX - minX) / cellSize);
  if (rows * columns > 20000) invalid('The bounding grid exceeds 20000 cells');
  const cells = p.cells.map(raw => { const c = object(raw); keys(c, ['id', 'row', 'column', 'center', 'boundsVertices', 'boundaryStatus', 'estimatedWorkAreaSquareMeters', 'componentID']);
    const row = integer(c.row, 'row', 0, rows - 1), column = integer(c.column, 'column', 0, columns - 1), name = text(c.id, 'cellID', 40, 1);
    if (name !== `r${row}c${column}` || !Array.isArray(c.boundsVertices) || c.boundsVertices.length !== 4) invalid('Invalid grid cell identity or rectangle');
    const vertices = c.boundsVertices.map(point2), x = minX + column * cellSize, y = minY + row * cellSize;
    const expected = [{ x, y }, { x: x + cellSize, y }, { x: x + cellSize, y: y + cellSize }, { x, y: y + cellSize }];
    if (vertices.some((v, i) => distance({ ...v, z: 0 }, { ...expected[i]!, z: 0 }) > 1e-6)) invalid('Cell bounds must match their declared grid location');
    const center = point2(c.center); if (!ringContains(center, vertices) || !containsStrictly(center, boundary)) invalid('Cell representative must be strictly inside its original polygon, within its grid bounds and outside holes');
    return { id: name, row, column, center, boundsVertices: vertices, boundaryStatus: enumeration(c.boundaryStatus, ['interior', 'partialRequiresReview'] as const, 'boundaryStatus'),
      estimatedWorkAreaSquareMeters: finite(c.estimatedWorkAreaSquareMeters, 'estimatedWorkAreaSquareMeters', Number.MIN_VALUE, cellSize * cellSize * (1 + 1e-8)), componentID: integer(c.componentID, 'componentID', 0, 20000) }; });
  const cellIDs = new Set(cells.map(c => c.id)); if (cellIDs.size !== cells.length) invalid('Duplicate cell');
  if (!Array.isArray(p.assignments) || p.assignments.length !== cells.length) invalid('Every cell requires exactly one assignment');
  const assignments = p.assignments.map(raw => { const a = object(raw); keys(a, ['cellID', 'workerID']); const cellID = text(a.cellID, 'cellID', 40, 1), workerID = id(a.workerID);
    if (!cellIDs.has(cellID) || !workers.some(w => w.id === workerID)) invalid('Unknown assignment cell or worker'); return { cellID, workerID }; });
  if (new Set(assignments.map(a => a.cellID)).size !== cells.length) invalid('Duplicate assignment cell');
  let regenerated: ReturnType<typeof canonicalCollaborativeGrid>;
  try { regenerated = canonicalCollaborativeGrid(boundary, cellSize, workers.map(w => w.id)); } catch { invalid('The boundary cannot form a valid bounded work grid'); }
  if (regenerated.cells.length !== cells.length || regenerated.cells.some((expected, index) => {
    const actual = cells[index]!;
    return actual.id !== expected.id || actual.row !== expected.row || actual.column !== expected.column || actual.boundaryStatus !== expected.boundaryStatus || actual.componentID !== expected.componentID
      || Math.hypot(actual.center.x - expected.center.x, actual.center.y - expected.center.y) > 1e-6
      || Math.abs(actual.estimatedWorkAreaSquareMeters - expected.estimatedWorkAreaSquareMeters) > Math.max(1e-9, expected.estimatedWorkAreaSquareMeters * 1e-8);
  })) invalid('Cells, clipped areas, edge flags and disconnected components must match the complete original-boundary grid');
  if (canonical(assignments) !== canonical(regenerated.assignments)) invalid('Initial assignments must match deterministic planning; use an audited reassignment operation for changes');
  if (!Array.isArray(p.warnings) || p.warnings.length > 32) invalid('Invalid warnings'); const warnings = p.warnings.map(x => text(x, 'warning', 4096));
  return { ...p, schemaVersion: 1, id: id(p.id), projectID, revision: 0, createdAt: finite(p.createdAt, 'createdAt', -6e10, 6e10), updatedAt: finite(p.updatedAt, 'updatedAt', -6e10, 6e10),
    coordinateReference: p.coordinateReference, sourceBoundary: p.sourceBoundary, sourceBoundarySHA256: sha(p.sourceBoundarySHA256),
    gridFrameID: frameID, boundary, cellSizeMeters: cellSize, cells, workers, assignments, evidence: [], assignmentHistory: [], warnings } as PlanData;
}
const identity = (): RigidTransform => ({ rotation: [1, 0, 0, 0, 1, 0, 0, 0, 1], translation: { x: 0, y: 0, z: 0 } });
function apply(transform: RigidTransform, point: Point3): Point3 {
  const r = transform.rotation; const t = transform.translation;
  return { x: r[0]! * point.x + r[1]! * point.y + r[2]! * point.z + t.x,
    y: r[3]! * point.x + r[4]! * point.y + r[5]! * point.z + t.y,
    z: r[6]! * point.x + r[7]! * point.y + r[8]! * point.z + t.z };
}
function compose(a: RigidTransform, b: RigidTransform): RigidTransform {
  const r = Array.from({ length: 9 }, (_, index) => {
    const row = Math.floor(index / 3), col = index % 3;
    return [0, 1, 2].reduce((sum, k) => sum + a.rotation[row * 3 + k]! * b.rotation[k * 3 + col]!, 0);
  });
  return { rotation: r, translation: apply(a, b.translation) };
}
function inverse(a: RigidTransform): RigidTransform {
  const r = [a.rotation[0]!, a.rotation[3]!, a.rotation[6]!, a.rotation[1]!, a.rotation[4]!, a.rotation[7]!, a.rotation[2]!, a.rotation[5]!, a.rotation[8]!];
  return { rotation: r, translation: apply({ rotation: r, translation: { x: 0, y: 0, z: 0 } }, { x: -a.translation.x, y: -a.translation.y, z: -a.translation.z }) };
}
function distance(a: Point3, b: Point3) { return Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z); }
function rigid(input: unknown): RigidTransform {
  const value = object(input, 'transform'); keys(value, ['rotation', 'translation']);
  if (!Array.isArray(value.rotation) || value.rotation.length !== 9) invalid('Rotation requires nine row-major values');
  const r = value.rotation.map(x => finite(x, 'rotation', -1, 1));
  for (let a = 0; a < 3; a++) for (let b = 0; b < 3; b++) {
    const dot = [0, 1, 2].reduce((sum, k) => sum + r[a * 3 + k]! * r[b * 3 + k]!, 0);
    if (Math.abs(dot - (a === b ? 1 : 0)) > 1e-6) invalid('Rotation must be orthonormal; scale is not permitted');
  }
  const determinant = r[0]! * (r[4]! * r[8]! - r[5]! * r[7]!) - r[1]! * (r[3]! * r[8]! - r[5]! * r[6]!) + r[2]! * (r[3]! * r[7]! - r[4]! * r[6]!);
  if (Math.abs(determinant - 1) > 1e-6) invalid('Reflection is not a proper rigid rotation');
  return { rotation: r, translation: point3(value.translation) };
}
function nonDegenerate(points: Point3[]) {
  const origin = points[0]!; let span = 0, longest = 0;
  for (let i = 1; i < points.length; i++) { const d = distance(origin, points[i]!); if (d > span) { span = d; longest = i; } }
  if (span < .25) return false;
  const a = points[longest]!; const u = { x: a.x - origin.x, y: a.y - origin.y, z: a.z - origin.z };
  return points.some(b => {
    const v = { x: b.x - origin.x, y: b.y - origin.y, z: b.z - origin.z }; const length = Math.hypot(v.x, v.y, v.z);
    return length >= .25 && Math.hypot(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x) / (span * length) >= .01;
  });
}

/** Rotation is proposed by the native solver; the server independently checks all physical correspondences. */
function registrationCandidate(input: unknown) {
  const value = object(input, 'registration'); keys(value, ['id', 'source', 'target', 'transform', 'controls', 'checkPoints', 'gravityConstraint', 'proposedAt']); bounded(value, 128 * 1024);
  const source = assemblySource(value.source), target = assemblySource(value.target);
  if (sourceKey(source) === sourceKey(target) || source.frameID === target.frameID || source.captureID === target.captureID) invalid('A registration must join different exact captures and frames');
  const transform = rigid(value.transform);
  if (!Array.isArray(value.controls) || value.controls.length < 3 || value.controls.length > 64 || !Array.isArray(value.checkPoints) || value.checkPoints.length > 64) invalid('Registration requires 3–64 fit controls and at most 64 independent check points');
  const seen = new Set<string>();
  const readPair = (raw: unknown) => { const pair = object(raw, 'pair'); keys(pair, ['id', 'source', 'target', 'evidence']); const pairID = id(pair.id);
    if (seen.has(pairID)) invalid('Duplicate control pair'); seen.add(pairID);
    return { id: pairID, source: point3(pair.source), target: point3(pair.target), evidence: enumeration(pair.evidence, ['physicalMarker', 'operatorMatchedPoint'] as const, 'control evidence') }; };
  const pairs = value.controls.map(readPair), checkPoints = value.checkPoints.map(readPair);
  for (const list of [pairs, checkPoints]) if (new Set(list.map(p => canonical(p.source))).size !== list.length || new Set(list.map(p => canonical(p.target))).size !== list.length) invalid('Distinct controls and check points must refer to distinct physical points');
  if (checkPoints.some(check => pairs.some(fit => distance(check.source, fit.source) <= 1e-6 || distance(check.target, fit.target) <= 1e-6))) invalid('Held-out check points must be physically independent of every fitted control');
  const residuals = pairs.map(pair => ({ pairID: pair.id, meters: distance(apply(transform, pair.source), pair.target) }));
  const maximum = Math.max(...residuals.map(x => x.meters)); const rms = Math.sqrt(residuals.reduce((sum, x) => sum + x.meters ** 2, 0) / residuals.length);
  const geometryUsable = nonDegenerate(pairs.map(x => x.source)) && nonDegenerate(pairs.map(x => x.target));
  const checkResiduals = checkPoints.map(pair => ({ pairID: pair.id, meters: distance(apply(transform, pair.source), pair.target) }));
  const checkMaximum = checkResiduals.length ? Math.max(...checkResiduals.map(x => x.meters)) : null;
  const checkRMS = checkResiduals.length ? Math.sqrt(checkResiduals.reduce((sum, x) => sum + x.meters ** 2, 0) / checkResiduals.length) : null;
  let gravityConstraint: { sourceUp: Point3; targetUp: Point3; maximumDeviationDegrees: number } | null = null, gravityDeviationDegrees: number | null = null;
  if (value.gravityConstraint != null) {
    const gravity = object(value.gravityConstraint); keys(gravity, ['sourceUp', 'targetUp', 'maximumDeviationDegrees']);
    const sourceUp = point3(gravity.sourceUp), targetUp = point3(gravity.targetUp), limit = finite(gravity.maximumDeviationDegrees, 'maximumDeviationDegrees', .001, 5);
    if (Math.abs(Math.hypot(sourceUp.x, sourceUp.y, sourceUp.z) - 1) > 1e-6 || Math.abs(Math.hypot(targetUp.x, targetUp.y, targetUp.z) - 1) > 1e-6) invalid('Gravity axes must be known physical unit vectors');
    const turned = apply({ rotation: transform.rotation, translation: { x: 0, y: 0, z: 0 } }, sourceUp);
    gravityDeviationDegrees = Math.acos(Math.max(-1, Math.min(1, turned.x * targetUp.x + turned.y * targetUp.y + turned.z * targetUp.z))) * 180 / Math.PI;
    gravityConstraint = { sourceUp, targetUp, maximumDeviationDegrees: limit };
  }
  return { id: id(value.id), source, target, transform, controls: pairs, checkPoints, gravityConstraint, proposedAt: integer(value.proposedAt, 'proposedAt', 0, 8640000000000000),
    residuals, checkResiduals, gravityDeviationDegrees, quality: { maximumResidualMeters: maximum, rmsResidualMeters: rms, geometryUsable,
      acceptable: geometryUsable && maximum <= .10 && rms <= .05 && checkMaximum !== null && checkMaximum <= .15 && checkRMS !== null && checkRMS <= .10 && (gravityConstraint === null || gravityDeviationDegrees! <= gravityConstraint.maximumDeviationDegrees), maximumAllowedMeters: .10, rmsAllowedMeters: .05,
      maximumCheckResidualMeters: checkMaximum, checkRMSResidualMeters: checkRMS, minimumIndependentCheckPoints: 1, maximumCheckAllowedMeters: .15, checkRMSAllowedMeters: .10,
      minimumSpanMeters: .25, minimumTriangleSine: .01 }, approval: 'pending' };
}

export async function registerCollaborationRoutes(app: FastifyInstance, store: Store, options: Options) {
  // A crash never turns a running job into a completed one. A human may retry its durable source request.
  for (const row of store.all<JobRow>("SELECT * FROM assembly_jobs WHERE state = 'running'")) {
    store.transaction(() => updateJob(row, 'failed', { code: 'processor_interrupted', message: 'The previous worker stopped before saving a verified result' }, null));
  }
  function scope(request: FastifyRequest) { return options.scope(id((request.params as { projectID: string }).projectID), request); }
  function replay<T>(request: FastifyRequest, input: Record<string, unknown>, work: (scope: Scope, actorID: string) => T): T {
    const selected = scope(request), actorID = options.user(request).id, operationID = id(input.operationID, 'operationID');
    const requestHash = contentHash({ route: request.routeOptions.url, params: request.params, input });
    return store.transaction(() => {
      const previous = store.get<{ request_hash: string; response_json: string }>('SELECT * FROM collaboration_operations WHERE project_id = ? AND actor_id = ? AND operation_id = ?', selected.row.id, actorID, operationID);
      if (previous) { if (previous.request_hash !== requestHash) throw conflict('operation_mismatch', 'Use a new operationID for different content'); return JSON.parse(previous.response_json) as T; }
      const result = work(scope(request), actorID);
      store.run('INSERT INTO collaboration_operations VALUES (?, ?, ?, ?, ?, ?)', selected.row.id, actorID, operationID, requestHash, canonical(result), timestamp());
      return result;
    });
  }
  function source(input: Pick<AssemblySource, 'packageID' | 'assetID' | 'captureID' | 'sourceSHA256'> & { frameID?: string }, projectID: string, expectedAuthor?: string): PackageRow {
    const row = store.get<PackageRow>('SELECT * FROM material_packages WHERE id = ? AND project_id = ?', input.packageID, projectID);
    if (!row) throw notFound(); if (row.state !== 'complete') throw conflict('package_incomplete', 'Only finalized, hash-verified original packages may participate');
    if (expectedAuthor && row.author_id !== expectedAuthor) throw new ApiError(403, 'source_author_mismatch', 'Capture evidence must belong to the authenticated employee');
    const manifest = JSON.parse(row.manifest_json) as { materials: { id: string; sourceEntityID: string; frameID?: string }[]; assets: { id: string; materialID: string; sha256: string; kind: string }[] };
    const asset = manifest.assets.find(x => x.id === input.assetID);
    const material = asset && manifest.materials.find(x => x.id === asset.materialID);
    const stored = store.get<{ verified: number; sha256: string }>('SELECT verified, sha256 FROM material_assets WHERE package_id = ? AND id = ?', row.id, input.assetID);
    if (!asset || !material || !stored || stored.verified !== 1 || asset.sha256 !== input.sourceSHA256 || stored.sha256 !== input.sourceSHA256
      || material.sourceEntityID !== input.captureID || (input.frameID !== undefined && material.frameID !== input.frameID)) throw conflict('source_mismatch', 'Exact capture, frame, asset and original hash must match the completed manifest');
    return row;
  }
  async function* readVerifiedAsset(input: AssemblySource, projectID: string): AsyncGenerator<Buffer> {
    const row = source(input, projectID), project = store.get<{ organization_id: string }>('SELECT organization_id FROM projects WHERE id = ?', projectID)!;
    let directory = resolve(options.assetDirectory);
    for (const component of ['', project.organization_id, projectID, row.id]) {
      if (component) directory = join(directory, id(component)); const status = await lstat(directory);
      if (!status.isDirectory() || status.isSymbolicLink() || (process.platform !== 'win32' && (status.mode & 0o077) !== 0)) throw new Error('Worker assets require private real directories');
    }
    const asset = store.get<{ byte_count: number }>('SELECT byte_count FROM material_assets WHERE package_id = ? AND id = ?', row.id, input.assetID)!;
    const handle = await open(join(directory, `${id(input.assetID)}.bin`), constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const status = await handle.stat(); if (!status.isFile() || status.size !== asset.byte_count || (process.platform !== 'win32' && (status.mode & 0o077) !== 0)) throw new Error('Worker original size or permissions changed');
      const hash = createHash('sha256'); let position = 0;
      while (position < asset.byte_count) {
        const buffer = Buffer.alloc(Math.min(1024 * 1024, asset.byte_count - position)); const { bytesRead } = await handle.read(buffer, 0, buffer.length, position);
        if (bytesRead === 0) throw new Error('Original was truncated during processing'); const bytes = buffer.subarray(0, bytesRead); hash.update(bytes); position += bytesRead; yield bytes;
      }
      if (hash.digest('hex') !== input.sourceSHA256) throw new Error('Original SHA changed during processing');
    } finally { await handle.close(); }
  }
  function currentPlan(projectID: string) { return store.get<PlanRow>('SELECT * FROM collaboration_plans WHERE project_id = ? ORDER BY revision DESC LIMIT 1', projectID); }
  function planPublic(row: PlanRow) { const envelope = JSON.parse(row.data_json) as PlanEnvelope;
    const coverage: Record<string, string> = {}, rescans = new Map<string, Set<string>>(), resolved = new Map<string, Set<string>>();
    for (const evidence of envelope.plan.evidence) for (const cellID of evidence.cellIDs) {
      if (evidence.kind === 'gpsWalk') { coverage[cellID] ??= 'walked'; }
      else if (evidence.kind === 'captureObserved') { if (coverage[cellID] !== 'verified') coverage[cellID] = 'observed'; if (evidence.quality === 'needsRescan') { const ids = rescans.get(cellID) ?? new Set(); ids.add(evidence.id); rescans.set(cellID, ids); } }
      else { coverage[cellID] = 'verified'; const ids = resolved.get(cellID) ?? new Set(); for (const ref of evidence.referencedEvidenceIDs) ids.add(ref); resolved.set(cellID, ids); }
    }
    for (const [cell, ids] of rescans) if ([...ids].some(ref => !resolved.get(cell)?.has(ref))) coverage[cell] = 'needsRescan';
    for (const cell of envelope.plan.cells) coverage[cell.id] ??= 'unobserved';
    return { revision: row.revision, ...envelope, coverageByCell: coverage, sha256: row.content_hash, authorID: row.author_id, createdAt: row.created_at,
    declaredBoundarySHA256: envelope.plan.sourceBoundarySHA256, serverCanonicalBoundarySHA256: contentHash(envelope.plan.sourceBoundary),
    geometryValidation: 'Original topology and literal source hash, explicit projection, complete clipped-area grid, strict interior representatives, disconnected components and deterministic initial assignment regenerated; areas remain planning estimates' }; }
  function mappedMember(selected: Scope, userID: string) {
    const row = store.get<{ role: Role }>('SELECT role FROM memberships WHERE organization_id = ? AND user_id = ?', selected.row.organization_id, userID);
    if (!row || !writers.includes(row.role)) throw conflict('worker_mapping_required', 'Each employee must map to a current authenticated survey-capable account in this project organization');
  }
  function appendPlan(previous: PlanRow, envelope: PlanEnvelope, actorID: string) {
    const revision = previous.revision + 1, time = timestamp();
    bounded(envelope, 16 * 1024 * 1024);
    store.run('INSERT INTO collaboration_plans VALUES (?, ?, ?, ?, ?, ?)', previous.project_id, revision, canonical(envelope), contentHash(envelope), actorID, time);
    return store.get<PlanRow>('SELECT * FROM collaboration_plans WHERE project_id = ? AND revision = ?', previous.project_id, revision)!;
  }
  function selectedPlan(selected: Scope, base: number) {
    const row = currentPlan(selected.row.id); if (!row) throw notFound(); if (row.revision !== base) throw conflict('revision_conflict', 'Fetch the current plan and rebase the pending operation; assignments and evidence are never overwritten');
    return { row, envelope: JSON.parse(row.data_json) as PlanEnvelope };
  }
  function registrationPublic(row: RegistrationRow) {
    const latest = store.get<{ revision: number; verdict: string; note: string; actor_id: string; created_at: string }>('SELECT * FROM fragment_registration_decisions WHERE registration_id = ? ORDER BY revision DESC LIMIT 1', row.id);
    return { ...JSON.parse(row.data_json), sha256: row.content_hash, authorID: row.author_id, createdAt: row.created_at,
      decision: latest ? { revision: latest.revision, verdict: latest.verdict, note: latest.note, actorID: latest.actor_id, createdAt: latest.created_at } : null };
  }
  function job(row: JobRow) { return { ...JSON.parse(row.request_json), projectID: row.project_id, revision: row.revision, state: row.state,
    outcome: JSON.parse(row.outcome_json), processorConfigured: Boolean(options.processor), processorName: options.processor?.name ?? null,
    createdAt: row.created_at, updatedAt: row.updated_at }; }
  function updateJob(row: JobRow, state: JobState, outcome: unknown, actorID: string | null) {
    const revision = row.revision + 1, time = timestamp();
    const updated = store.run('UPDATE assembly_jobs SET revision = ?, state = ?, outcome_json = ?, updated_at = ? WHERE id = ? AND revision = ?', revision, state, canonical(outcome), time, row.id, row.revision);
    if (updated.changes !== 1) throw conflict('revision_conflict', 'The assembly job changed; fetch its current revision');
    store.run('INSERT INTO assembly_job_events VALUES (?, ?, ?, ?, ?, ?)', row.id, revision, state, canonical(outcome), actorID, time);
    return store.get<JobRow>('SELECT * FROM assembly_jobs WHERE id = ?', row.id)!;
  }
  function getJob(request: FastifyRequest) { const selected = scope(request); const jobID = id((request.params as { jobID: string }).jobID);
    const row = store.get<JobRow>('SELECT * FROM assembly_jobs WHERE id = ? AND project_id = ?', jobID, selected.row.id); if (!row) throw notFound(); return { row, selected }; }
  function registrationReadiness(projectID: string, request: JobRequest) {
    const sources = request.sources; const selectedKeys = new Set(sources.map(sourceKey)); const transforms = new Map<string, RigidTransform>();
    const edges = new Map<string, { neighbor: string; neighborToHere: RigidTransform; registrationID: string | null }[]>();
    const add = (from: string, to: string, toToFrom: RigidTransform, registrationID: string | null) => {
      const list = edges.get(from) ?? []; list.push({ neighbor: to, neighborToHere: toToFrom, registrationID }); edges.set(from, list);
    };
    for (let i = 0; i < sources.length; i++) for (let j = i + 1; j < sources.length; j++) if (sources[i]!.frameID === sources[j]!.frameID) {
      add(sourceKey(sources[i]!), sourceKey(sources[j]!), identity(), null); add(sourceKey(sources[j]!), sourceKey(sources[i]!), identity(), null);
    }
    const approved = store.all<RegistrationRow>(`SELECT r.* FROM fragment_registrations r JOIN fragment_registration_decisions d ON d.registration_id = r.id
      WHERE r.project_id = ? AND d.revision = (SELECT MAX(revision) FROM fragment_registration_decisions WHERE registration_id = r.id) AND d.verdict = 'approved' ORDER BY r.id`, projectID);
    const usedIDs = new Set<string>();
    for (const row of approved) if (selectedKeys.has(row.source_key) && selectedKeys.has(row.target_key)) {
      const candidate = JSON.parse(row.data_json) as ReturnType<typeof registrationCandidate>;
      add(row.target_key, row.source_key, candidate.transform, row.id); add(row.source_key, row.target_key, inverse(candidate.transform), row.id); usedIDs.add(row.id);
    }
    const root = sourceKey(request.target); transforms.set(root, identity()); const pending = [root]; const conflicts = new Set<string>();
    for (let index = 0; index < pending.length; index++) {
      const current = pending[index]!;
      for (const edge of edges.get(current) ?? []) {
        const proposed = compose(transforms.get(current)!, edge.neighborToHere), previous = transforms.get(edge.neighbor);
        if (!previous) { transforms.set(edge.neighbor, proposed); pending.push(edge.neighbor); }
        else {
          const delta = compose(inverse(previous), proposed); const angle = Math.acos(Math.max(-1, Math.min(1, (delta.rotation[0]! + delta.rotation[4]! + delta.rotation[8]! - 1) / 2))) * 180 / Math.PI;
          if (distance(previous.translation, proposed.translation) > .15 || angle > 1) conflicts.add(edge.registrationID ?? 'sharedFrameInconsistency');
        }
      }
    }
    const disconnectedSourceKeys = sources.map(sourceKey).filter(key => !transforms.has(key));
    return { readyForProcessor: disconnectedSourceKeys.length === 0 && conflicts.size === 0, disconnectedSourceKeys,
      conflictingRegistrationIDs: [...conflicts].sort(), approvedRegistrationIDs: [...usedIDs].sort(),
      registrations: sources.filter(x => transforms.has(sourceKey(x))).map(x => ({ sourceKey: sourceKey(x), transform: transforms.get(sourceKey(x))! })),
      cycleTranslationLimitMeters: .15, cycleRotationLimitDegrees: 1, coordinateAssumption: 'Uploaded frame UUIDs and declared meter units are retained; GPS alone does not register a 3D fragment' };
  }

  app.get('/v1/projects/:projectID/collaboration', async request => { const selected = scope(request), current = currentPlan(selected.row.id);
    return { plan: current ? planPublic(current) : null, processorConfigured: Boolean(options.processor), assemblyKinds: ['registeredScene', 'orthomosaic', 'photoTour'],
      workers: store.all<{ user_id: string; display_name: string; role: Role }>('SELECT m.user_id, u.display_name, m.role FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.organization_id = ?', selected.row.organization_id)
        .filter(x => writers.includes(x.role)).map(x => ({ userID: x.user_id, displayName: x.display_name, role: x.role })) }; });
  app.get('/v1/projects/:projectID/collaboration/plan/revisions', async request => {
    const selected = scope(request), query = request.query as { afterRevision?: string; limit?: string };
    const after = integer(query.afterRevision === undefined ? 0 : Number(query.afterRevision), 'afterRevision'), limit = integer(query.limit === undefined ? 50 : Number(query.limit), 'limit', 1, 100);
    const rows = store.all<PlanRow>('SELECT project_id, revision, content_hash, author_id, created_at FROM collaboration_plans WHERE project_id = ? AND revision > ? ORDER BY revision LIMIT ?', selected.row.id, after, limit + 1);
    return { revisions: rows.slice(0, limit).map(row => ({ revision: row.revision, sha256: row.content_hash, authorID: row.author_id, createdAt: row.created_at })), hasMore: rows.length > limit, nextRevision: rows.length ? rows[Math.min(rows.length, limit) - 1]!.revision : after };
  });
  app.get('/v1/projects/:projectID/collaboration/plan/revisions/:revision', async request => {
    const selected = scope(request), revision = integer(Number((request.params as { revision: string }).revision), 'revision', 1);
    const row = store.get<PlanRow>('SELECT * FROM collaboration_plans WHERE project_id = ? AND revision = ?', selected.row.id, revision); if (!row) throw notFound(); return planPublic(row);
  });
  app.get('/v1/projects/:projectID/collaboration/evidence', async request => {
    const selected = scope(request), query = request.query as { offset?: string; limit?: string };
    const offset = integer(query.offset === undefined ? 0 : Number(query.offset), 'offset', 0, 1e8), limit = integer(query.limit === undefined ? 50 : Number(query.limit), 'limit', 1, 200);
    const rows = store.all<{ id: string; plan_revision: number; actor_id: string; data_json: string; content_hash: string; created_at: string }>('SELECT * FROM collaboration_evidence WHERE project_id = ? ORDER BY created_at, id LIMIT ? OFFSET ?', selected.row.id, limit + 1, offset);
    return { evidence: rows.slice(0, limit).map(row => ({ ...JSON.parse(row.data_json), basePlanRevision: row.plan_revision, appliedPlanRevision: row.plan_revision + 1, actorID: row.actor_id, sha256: row.content_hash, receivedAt: row.created_at })), hasMore: rows.length > limit, nextOffset: offset + Math.min(rows.length, limit) };
  });

  app.post('/v1/projects/:projectID/collaboration/plan', { bodyLimit: 16 * 1024 * 1024 }, async request => {
    requireRole(scope(request).role, managers); const input = object(request.body); keys(input, ['operationID', 'baseRevision', 'plan', 'workerMappings', 'sourceBoundaryJSON']);
    if (integer(input.baseRevision, 'baseRevision') !== 0) invalid('A new plan must start at server baseRevision 0');
    return replay(request, input, (selected, actorID) => {
      requireRole(selected.role, managers); if (currentPlan(selected.row.id)) throw conflict('revision_conflict', 'This project already has an immutable planning baseline');
      const project = store.get<{ coordinate_reference: string }>('SELECT coordinate_reference FROM projects WHERE id = ?', selected.row.id)!;
      const plan = planData(input.plan, selected.row.id, JSON.parse(project.coordinate_reference));
      const literalBoundary = text(input.sourceBoundaryJSON, 'sourceBoundaryJSON', 256 * 1024, 1);
      if (createHash('sha256').update(literalBoundary, 'utf8').digest('hex') !== plan.sourceBoundarySHA256) invalid('The declared source boundary hash must match its exact preserved UTF-8 JSON bytes');
      let parsedBoundary: unknown; try { parsedBoundary = JSON.parse(literalBoundary); } catch { invalid('Source boundary JSON is invalid'); }
      geometry(parsedBoundary, coordinateReference(plan.coordinateReference));
      const normalizeBoundary = (value: unknown) => { const p = { ...sourcePolygon(value) }; if (p.frameID !== undefined) p.frameID = id(p.frameID); return p; };
      if (canonical(normalizeBoundary(parsedBoundary)) !== canonical(normalizeBoundary(plan.sourceBoundary))) invalid('The hashed original boundary bytes do not describe this plan boundary');
      if (!Array.isArray(input.workerMappings) || input.workerMappings.length !== plan.workers.length) invalid('Every offline employee ID requires an explicit account mapping');
      const workerMappings = input.workerMappings.map(raw => { const m = object(raw); keys(m, ['workerID', 'userID']); const workerID = id(m.workerID), userID = id(m.userID);
        if (!plan.workers.some(w => w.id === workerID)) invalid('Worker mapping is outside the plan'); mappedMember(selected, userID); return { workerID, userID }; });
      if (new Set(workerMappings.map(m => m.workerID)).size !== plan.workers.length || new Set(workerMappings.map(m => m.userID)).size !== plan.workers.length) invalid('A plan must map each employee to one distinct actual account');
      const envelope = { plan, workerMappings, sourceBoundaryJSON: literalBoundary }, time = timestamp();
      store.run('INSERT INTO collaboration_plans VALUES (?, ?, ?, ?, ?, ?)', selected.row.id, 1, canonical(envelope), contentHash(envelope), actorID, time);
      options.audit(selected.row.organization_id, actorID, 'collaboration.plan.created', plan.id); return planPublic(currentPlan(selected.row.id)!);
    });
  });
  app.post('/v1/projects/:projectID/collaboration/assignments', async request => {
    requireRole(scope(request).role, managers); const input = object(request.body); keys(input, ['operationID', 'baseRevision', 'cellIDs', 'workerID', 'eventID', 'timestamp']);
    const base = integer(input.baseRevision, 'baseRevision', 1), workerID = id(input.workerID), eventID = id(input.eventID), observed = finite(input.timestamp, 'timestamp', -6e10, 6e10);
    if (!Array.isArray(input.cellIDs) || input.cellIDs.length < 1 || input.cellIDs.length > 20000) invalid('Select 1–20000 cells');
    const cellIDs = input.cellIDs.map(x => text(x, 'cellID', 40, 1)); if (new Set(cellIDs).size !== cellIDs.length) invalid('Duplicate assignment cell');
    return replay(request, input, (selected, actorID) => {
      requireRole(selected.role, managers); const { row, envelope } = selectedPlan(selected, base), plan = envelope.plan;
      const mapping = envelope.workerMappings.find(m => m.workerID === workerID); if (!mapping) invalid('Unknown employee'); mappedMember(selected, mapping.userID);
      if (plan.assignmentHistory.length >= 2000) throw conflict('journal_limit', 'Start a new project stage before the assignment history limit');
      if (plan.assignmentHistory.some(e => e.id === eventID)) throw conflict('event_id_conflict', 'Assignment event IDs cannot be reused');
      const known = new Set(plan.cells.map(c => c.id)); if (cellIDs.some(cell => !known.has(cell))) invalid('Unknown assignment cell');
      const changed = plan.assignments.filter(a => cellIDs.includes(a.cellID) && a.workerID !== workerID); if (!changed.length) return planPublic(row);
      if (plan.assignmentHistory.reduce((sum, event) => sum + (event.cellIDs as string[]).length, 0) + changed.length > 100000) throw conflict('journal_limit', 'The assignment history exceeds 100000 total cell references; start another project stage');
      const previousWorkerIDs = Object.fromEntries(changed.map(a => [a.cellID, a.workerID])), ids = new Set(changed.map(a => a.cellID));
      plan.assignments = plan.assignments.map(a => ids.has(a.cellID) ? { cellID: a.cellID, workerID } : a); plan.revision += 1; plan.updatedAt = observed;
      plan.assignmentHistory.push({ id: eventID, revision: plan.revision, cellIDs: changed.map(a => a.cellID), previousWorkerIDs, workerID, timestamp: observed });
      options.audit(selected.row.organization_id, actorID, 'collaboration.assignments.changed', plan.id); return planPublic(appendPlan(row, envelope, actorID));
    });
  });
  app.post('/v1/projects/:projectID/collaboration/evidence', async request => {
    requireRole(scope(request).role, writers); const input = object(request.body); keys(input, ['operationID', 'baseRevision', 'evidence', 'source']);
    const base = integer(input.baseRevision, 'baseRevision', 1), raw = object(input.evidence); keys(raw, ['id', 'workerID', 'kind', 'timestamp', 'cellIDs', 'captureID', 'sourceFrameID', 'registrationID', 'sourceSHA256', 'footprintProvenance', 'footprint', 'horizontalAccuracyMeters', 'quality', 'referencedEvidenceIDs', 'boundaryReviewed', 'note']); bounded(raw, 128 * 1024);
    const kind = enumeration(raw.kind, ['gpsWalk', 'captureObserved', 'operatorVerified'] as const, 'evidence kind');
    if (!Array.isArray(raw.cellIDs) || raw.cellIDs.length < 1 || raw.cellIDs.length > 256 || !Array.isArray(raw.referencedEvidenceIDs) || raw.referencedEvidenceIDs.length > 256 || typeof raw.boundaryReviewed !== 'boolean') invalid('Invalid evidence bounds');
    const evidence: Evidence = { id: id(raw.id), workerID: id(raw.workerID), kind, timestamp: finite(raw.timestamp, 'timestamp', -6e10, 6e10), cellIDs: raw.cellIDs.map(x => text(x, 'cellID', 40, 1)),
      quality: enumeration(raw.quality, ['unknown', 'usable', 'needsRescan'] as const, 'quality'), referencedEvidenceIDs: raw.referencedEvidenceIDs.map(x => id(x)), boundaryReviewed: raw.boundaryReviewed, note: text(raw.note, 'note', 4096) };
    if (Buffer.byteLength(evidence.note, 'utf8') > 4096) invalid('Evidence note exceeds 4096 UTF-8 bytes');
    if (new Set(evidence.cellIDs).size !== evidence.cellIDs.length || new Set(evidence.referencedEvidenceIDs).size !== evidence.referencedEvidenceIDs.length) invalid('Duplicate evidence reference');
    if (raw.horizontalAccuracyMeters != null) evidence.horizontalAccuracyMeters = finite(raw.horizontalAccuracyMeters, 'horizontalAccuracyMeters', 0, 1e6);
    if (evidence.timestamp > (Date.now() - Date.UTC(2001, 0, 1)) / 1000 + 300) invalid('Evidence timestamp is in the future');
    return replay(request, input, (selected, actorID) => {
      requireRole(selected.role, writers); const { row, envelope } = selectedPlan(selected, base), plan = envelope.plan;
      const mapping = envelope.workerMappings.find(m => m.workerID === evidence.workerID); if (!mapping || mapping.userID !== actorID) throw new ApiError(403, 'worker_identity_mismatch', 'Evidence author must map to the authenticated employee, not an imported name'); mappedMember(selected, actorID);
      if (plan.evidence.length >= 10000) throw conflict('journal_limit', 'Start a new project stage before the evidence history limit');
      const cellMap = new Map(plan.cells.map(c => [c.id, c])); if (evidence.cellIDs.some(cell => !cellMap.has(cell))) invalid('Unknown evidence cell');
      let frozenSource: unknown = null;
      if (kind === 'gpsWalk') {
        if (['captureID', 'sourceFrameID', 'registrationID', 'sourceSHA256', 'footprintProvenance', 'footprint'].some(field => raw[field] != null) || input.source != null || evidence.referencedEvidenceIDs.length || evidence.boundaryReviewed || evidence.quality !== 'unknown') invalid('A walked GPS path cannot claim capture or reviewed coverage');
      } else if (kind === 'captureObserved') {
        evidence.captureID = id(raw.captureID); evidence.sourceSHA256 = sha(raw.sourceSHA256);
        evidence.footprintProvenance = enumeration(raw.footprintProvenance, ['operatorMapped', 'registeredCapture'] as const, 'footprintProvenance');
        if (raw.sourceFrameID != null) evidence.sourceFrameID = id(raw.sourceFrameID); if (raw.registrationID != null) evidence.registrationID = id(raw.registrationID);
        evidence.footprint = polygon(raw.footprint, plan.gridFrameID);
        if (evidence.footprint.vertices.length + evidence.footprint.holes.reduce((s, r) => s + r.length, 0) > 512 || evidence.cellIDs.some(cell => !contains(cellMap.get(cell)!.center, evidence.footprint!))) invalid('Each claimed cell representative must be inside the bounded asserted footprint');
        const footprintVertices = (footprint: Polygon2) => footprint.vertices.length + footprint.holes.reduce((sum, ring) => sum + ring.length, 0);
        if (plan.evidence.reduce((sum, item) => sum + (item.footprint ? footprintVertices(item.footprint) : 0), 0) + footprintVertices(evidence.footprint) > 100000) throw conflict('journal_limit', 'The footprint history exceeds 100000 total vertices; start another project stage');
        if (evidence.referencedEvidenceIDs.length || evidence.boundaryReviewed) invalid('A capture observation is separate from an operator completeness review');
        const s = object(input.source, 'source'); keys(s, ['packageID', 'assetID', 'captureID', 'sourceSHA256', 'frameID']);
        const ref = { packageID: id(s.packageID), assetID: id(s.assetID), captureID: id(s.captureID), sourceSHA256: sha(s.sourceSHA256), ...(s.frameID == null ? {} : { frameID: id(s.frameID) }) };
        if (ref.captureID !== evidence.captureID || ref.sourceSHA256 !== evidence.sourceSHA256 || ref.frameID !== evidence.sourceFrameID) invalid('Evidence must refer to the exact actual capture source, preserving an unknown frame');
        const uploaded = source(ref, selected.row.id, actorID), manifest = JSON.parse(uploaded.manifest_json) as { assets: { id: string; kind: string }[] };
        if (!['originalPhoto', 'originalVideo', 'mesh', 'roomPlan'].includes(manifest.assets.find(a => a.id === ref.assetID)!.kind)) invalid('Capture coverage requires an actual photograph, video, mesh or RoomPlan source');
        if (evidence.footprintProvenance === 'operatorMapped') { if (evidence.registrationID) invalid('An operator-mapped footprint is an assertion, not an automatic registration'); }
        else {
          if (!evidence.sourceFrameID) invalid('Registered coverage requires the actual source frame');
          if (evidence.sourceFrameID !== plan.gridFrameID) {
            if (!evidence.registrationID) throw conflict('registration_required', 'Different AR and plan frames need explicit approved physical registration');
            const registration = store.get<RegistrationRow>('SELECT * FROM fragment_registrations WHERE id = ? AND project_id = ?', evidence.registrationID, selected.row.id); if (!registration) throw notFound();
            const candidate = JSON.parse(registration.data_json) as ReturnType<typeof registrationCandidate>, decision = store.get<{ verdict: string }>('SELECT verdict FROM fragment_registration_decisions WHERE registration_id = ? ORDER BY revision DESC LIMIT 1', registration.id);
            if (decision?.verdict !== 'approved' || candidate.source.packageID !== ref.packageID || candidate.source.assetID !== ref.assetID || candidate.source.sourceSHA256 !== ref.sourceSHA256 || candidate.source.frameID !== evidence.sourceFrameID || candidate.target.frameID !== plan.gridFrameID) throw conflict('registration_required', 'The approved registration must bind this exact original to the plan grid');
          } else if (evidence.registrationID) invalid('A capture already in the grid frame does not require another registration');
        }
        frozenSource = ref;
      } else {
        if (['captureID', 'sourceFrameID', 'registrationID', 'sourceSHA256', 'footprintProvenance', 'footprint'].some(field => raw[field] != null) || input.source != null || evidence.quality !== 'usable' || !evidence.note.trim() || !evidence.referencedEvidenceIDs.length) invalid('Completeness review needs actual usable observations and a note');
        const refs = evidence.referencedEvidenceIDs.map(ref => plan.evidence.find(e => e.id === ref));
        if (refs.some(e => !e || e.kind !== 'captureObserved' || !['usable', 'needsRescan'].includes(e.quality)) || evidence.cellIDs.some(cell => !refs.some(e => e!.cellIDs.includes(cell) && e!.quality === 'usable'))) invalid('Review must reference existing usable capture evidence for every selected cell, and may explicitly resolve a rescan request');
        if (!evidence.boundaryReviewed && evidence.cellIDs.some(cell => cellMap.get(cell)!.boundaryStatus !== 'interior')) invalid('Partial boundary cells require an explicit boundary review');
      }
      const previous = store.get<{ project_id: string; data_json: string }>('SELECT project_id, data_json FROM collaboration_evidence WHERE id = ?', evidence.id);
      const frozen = { evidence, source: frozenSource };
      if (previous) { if (previous.project_id !== selected.row.id) throw notFound(); if (canonical(JSON.parse(previous.data_json)) !== canonical(frozen)) throw conflict('evidence_id_conflict', 'A frozen observation ID cannot be reused for different content'); return planPublic(row); }
      plan.evidence.push(evidence); plan.revision += 1; plan.updatedAt = evidence.timestamp;
      store.run('INSERT INTO collaboration_evidence VALUES (?, ?, ?, ?, ?, ?, ?)', evidence.id, selected.row.id, row.revision, actorID, canonical(frozen), contentHash(frozen), timestamp());
      options.audit(selected.row.organization_id, actorID, `collaboration.evidence.${kind}`, evidence.id); return planPublic(appendPlan(row, envelope, actorID));
    });
  });
  // All actual originals and derivative bytes remain in the private material upload API.
  app.post('/v1/projects/:projectID/registrations', async request => {
    requireRole(scope(request).role, writers); const input = object(request.body); keys(input, ['operationID', 'candidate']); const candidate = registrationCandidate(input.candidate);
    return replay(request, input, (selected, actorID) => {
      requireRole(selected.role, writers); source(candidate.source, selected.row.id); source(candidate.target, selected.row.id);
      const existing = store.get<RegistrationRow>('SELECT * FROM fragment_registrations WHERE id = ?', candidate.id);
      if (existing) { if (existing.project_id !== selected.row.id) throw notFound(); if (existing.content_hash !== contentHash(candidate)) throw conflict('candidate_immutable', 'A candidate is frozen; use a new ID for new points or sources'); return registrationPublic(existing); }
      const time = timestamp(); store.run('INSERT INTO fragment_registrations VALUES (?, ?, ?, ?, ?, ?, ?, ?)', candidate.id, selected.row.id, sourceKey(candidate.source), sourceKey(candidate.target), canonical(candidate), contentHash(candidate), actorID, time);
      options.audit(selected.row.organization_id, actorID, 'registration.proposed', candidate.id);
      return registrationPublic(store.get<RegistrationRow>('SELECT * FROM fragment_registrations WHERE id = ?', candidate.id)!);
    });
  });
  app.get('/v1/projects/:projectID/registrations', async request => ({ registrations: store.all<RegistrationRow>('SELECT * FROM fragment_registrations WHERE project_id = ? ORDER BY created_at, id LIMIT 500', scope(request).row.id).map(registrationPublic) }));
  app.post('/v1/projects/:projectID/registrations/:registrationID/decisions', async request => {
    requireRole(scope(request).role, reviewers); const input = object(request.body); keys(input, ['operationID', 'baseRevision', 'verdict', 'note']);
    const base = integer(input.baseRevision, 'baseRevision'), verdict = enumeration(input.verdict, ['approved', 'rejected'] as const, 'verdict'), note = text(input.note, 'note', 4096, 1);
    return replay(request, input, (selected, actorID) => {
      requireRole(selected.role, reviewers); const row = store.get<RegistrationRow>('SELECT * FROM fragment_registrations WHERE id = ? AND project_id = ?', id((request.params as { registrationID: string }).registrationID), selected.row.id); if (!row) throw notFound();
      const candidate = JSON.parse(row.data_json) as ReturnType<typeof registrationCandidate>;
      source(candidate.source, selected.row.id); source(candidate.target, selected.row.id);
      const latest = store.get<{ revision: number }>('SELECT MAX(revision) AS revision FROM fragment_registration_decisions WHERE registration_id = ?', row.id)?.revision ?? 0;
      if (latest !== base) throw conflict('revision_conflict', 'Fetch the latest registration decision before changing it');
      if (verdict === 'approved' && !candidate.quality.acceptable) throw conflict('registration_quality_failed', 'All residuals and control-point geometry must pass before operator approval');
      const project = store.get<{ requires_independent_review: number }>('SELECT requires_independent_review FROM projects WHERE id = ?', selected.row.id)!;
      if (verdict === 'approved' && project.requires_independent_review === 1 && row.author_id === actorID) throw new ApiError(403, 'independent_review_required', 'A different authenticated reviewer must approve this project registration');
      store.run('INSERT INTO fragment_registration_decisions VALUES (?, ?, ?, ?, ?, ?)', row.id, base + 1, verdict, note.trim(), actorID, timestamp());
      options.audit(selected.row.organization_id, actorID, `registration.${verdict}`, row.id); return registrationPublic(row);
    });
  });
  app.post('/v1/projects/:projectID/assemblies', async request => {
    requireRole(scope(request).role, writers); const input = object(request.body); keys(input, ['operationID', 'id', 'kind', 'sources', 'target']); bounded(input);
    if (!Array.isArray(input.sources) || input.sources.length < 1 || input.sources.length > 128) invalid('An assembly requires 1–128 exact sources');
    const sources = input.sources.map(assemblySource); if (new Set(sources.map(sourceKey)).size !== sources.length) invalid('Duplicate assembly source');
    const frozen: JobRequest = { id: id(input.id), kind: enumeration(input.kind, ['registeredScene', 'orthomosaic', 'photoTour'] as const, 'assembly kind'), sources, target: assemblySource(input.target) };
    if (!sources.some(x => sourceKey(x) === sourceKey(frozen.target))) invalid('The target reference must be one of the exact input sources');
    return replay(request, input, (selected, actorID) => {
      requireRole(selected.role, writers); for (const item of sources) source(item, selected.row.id);
      const existing = store.get<JobRow>('SELECT * FROM assembly_jobs WHERE id = ?', frozen.id);
      if (existing) { if (existing.project_id !== selected.row.id) throw notFound(); if (existing.request_hash !== contentHash(frozen)) throw conflict('job_immutable', 'Assembly source requests are immutable; use a new job ID'); return job(existing); }
      const readiness = registrationReadiness(selected.row.id, frozen); const state: JobState = readiness.readyForProcessor ? 'queued' : 'waitingForRegistration';
      const outcome = { readiness, code: !readiness.readyForProcessor ? 'registration_required' : options.processor ? 'awaiting_processor' : 'processor_unconfigured' };
      const time = timestamp(); store.run('INSERT INTO assembly_jobs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', frozen.id, selected.row.id, canonical(frozen), contentHash(frozen), 1, state, canonical(outcome), actorID, time, time);
      store.run('INSERT INTO assembly_job_events VALUES (?, ?, ?, ?, ?, ?)', frozen.id, 1, state, canonical(outcome), actorID, time);
      options.audit(selected.row.organization_id, actorID, 'assembly.created', frozen.id); return job(store.get<JobRow>('SELECT * FROM assembly_jobs WHERE id = ?', frozen.id)!);
    });
  });
  app.get('/v1/projects/:projectID/assemblies', async request => ({ jobs: store.all<JobRow>('SELECT * FROM assembly_jobs WHERE project_id = ? ORDER BY created_at, id LIMIT 200', scope(request).row.id).map(job) }));
  app.get('/v1/projects/:projectID/assemblies/:jobID', async request => { const { row } = getJob(request), readiness = registrationReadiness(row.project_id, JSON.parse(row.request_json) as JobRequest);
    const applied = (JSON.parse(row.outcome_json) as { approvedRegistrationIDs?: string[] }).approvedRegistrationIDs ?? [];
    return { ...job(row), currentReadiness: readiness, resultReviewRequired: row.state === 'ready' && (!readiness.readyForProcessor || canonical(applied) !== canonical(readiness.approvedRegistrationIDs)),
    events: store.all('SELECT revision, state, outcome_json, actor_id, created_at FROM assembly_job_events WHERE job_id = ? ORDER BY revision', row.id).map(raw => { const event = raw as { revision: number; state: string; outcome_json: string; actor_id: string | null; created_at: string }; return { revision: event.revision, state: event.state, outcome: JSON.parse(event.outcome_json), actorID: event.actor_id, createdAt: event.created_at }; }) }; });
  app.post('/v1/projects/:projectID/assemblies/:jobID/refresh', async request => {
    requireRole(scope(request).role, writers); const input = object(request.body); keys(input, ['operationID', 'baseRevision']); const base = integer(input.baseRevision, 'baseRevision', 1);
    return replay(request, input, (selected, actorID) => { requireRole(selected.role, writers); const { row } = getJob(request); if (row.revision !== base) throw conflict('revision_conflict', 'Fetch the latest job revision');
      if (row.state === 'running' || row.state === 'ready') throw conflict('job_state_conflict', 'A running or completed job cannot be refreshed');
      const frozen = JSON.parse(row.request_json) as JobRequest; for (const item of frozen.sources) source(item, selected.row.id);
      const readiness = registrationReadiness(selected.row.id, frozen), state: JobState = readiness.readyForProcessor ? 'queued' : 'waitingForRegistration';
      return job(updateJob(row, state, { readiness, code: !readiness.readyForProcessor ? 'registration_required' : options.processor ? 'awaiting_processor' : 'processor_unconfigured' }, actorID));
    });
  });
  app.post('/v1/projects/:projectID/assemblies/:jobID/process', async request => {
    const { row: before, selected } = getJob(request); requireRole(selected.role, managers);
    const input = object(request.body); keys(input, ['operationID', 'baseRevision']); const base = integer(input.baseRevision, 'baseRevision', 1);
    if (!options.processor) throw new ApiError(503, 'processor_unconfigured', 'No assembly processor is installed; original fragments remain separate');
    const processor = options.processor; let context: AssemblyContext | undefined; const readKeys = new Set<string>();
    const started = replay(request, input, (fresh, actorID) => {
      requireRole(fresh.role, managers); const { row } = getJob(request); if (row.revision !== base) throw conflict('revision_conflict', 'Fetch the latest job revision');
      if (!['queued', 'failed', 'waitingForRegistration'].includes(row.state)) throw conflict('job_state_conflict', 'This job cannot start another worker attempt');
      const frozen = deepFreeze(JSON.parse(row.request_json) as JobRequest), readiness = registrationReadiness(row.project_id, frozen);
      if (!readiness.readyForProcessor) throw conflict('registration_required', 'Disconnected or inconsistent fragments need approved registration');
      const hashes: Record<string, string> = {}; for (const item of frozen.sources) hashes[item.packageID] = source(item, row.project_id).manifest_hash;
      context = deepFreeze({ jobID: row.id, projectID: row.project_id, kind: frozen.kind, target: frozen.target, sources: frozen.sources,
        sourceManifestHashes: hashes, registrations: readiness.registrations,
        readSource: async function* (requested: AssemblySource) {
          const exact = assemblySource(requested), key = sourceKey(exact); if (!frozen.sources.some(s => sourceKey(s) === key)) throw new Error('Worker attempted to read a source outside its immutable job');
          yield* readVerifiedAsset(exact, row.project_id); readKeys.add(key);
        } });
      return job(updateJob(row, 'running', { code: 'processing', processor: processor.name, sourceManifestHashes: hashes,
        approvedRegistrationIDs: readiness.approvedRegistrationIDs }, actorID));
    });
    // A replay never invokes the processor again, including a lost response or an in-flight request.
    if (!context) return { ...started, replayed: true, currentJob: job(getJob(request).row) };
    try {
      const result = await processor.process(context);
      if (context.sources.some(original => !readKeys.has(sourceKey(original)))) throw new Error('Worker must consume and SHA-verify every actual original before declaring a result');
      bounded(result); const resultObject = object(result); keys(resultObject, ['outputSources', 'sourceManifestHashes', 'targetFrameID', 'method']);
      if (canonical(result.sourceManifestHashes) !== canonical(context.sourceManifestHashes) || id(result.targetFrameID) !== context.target.frameID) throw new Error('Worker provenance does not match the immutable source request');
      text(result.method, 'method', 240, 1); if (!Array.isArray(result.outputSources) || result.outputSources.length < 1 || result.outputSources.length > 128) throw new Error('Worker supplied no bounded finalized output');
      const outputs = result.outputSources.map(assemblySource);
      if (new Set(outputs.map(sourceKey)).size !== outputs.length) throw new Error('Worker supplied duplicate outputs');
      for (const output of outputs) {
        if (context.sources.some(original => original.packageID === output.packageID) || output.frameID !== context.target.frameID) throw new Error('Outputs must be separate derivative packages in the target frame');
        source(output, before.project_id);
        for await (const _bytes of readVerifiedAsset(output, before.project_id)) { /* Check actual derivative bytes, not only a row flag. */ }
      }
      return store.transaction(() => {
        const { row, selected: fresh } = getJob(request); requireRole(fresh.role, managers);
        if (row.revision !== started.revision || row.state !== 'running') throw conflict('job_state_conflict', 'This worker attempt is no longer current');
        const readiness = registrationReadiness(row.project_id, JSON.parse(row.request_json) as JobRequest);
        if (!readiness.readyForProcessor || canonical(readiness.approvedRegistrationIDs) !== canonical(context!.registrations.length ? (JSON.parse(row.outcome_json) as { approvedRegistrationIDs: string[] }).approvedRegistrationIDs : [])) {
          throw new Error('Registration decisions changed during processing; result needs a new attempt');
        }
        options.audit(fresh.row.organization_id, options.user(request).id, 'assembly.completed', row.id);
        return job(updateJob(row, 'ready', { code: 'verified_worker_result', processor: processor.name, outputSources: outputs,
          sourceManifestHashes: context!.sourceManifestHashes, approvedRegistrationIDs: readiness.approvedRegistrationIDs,
          method: result.method, targetFrameID: result.targetFrameID }, options.user(request).id));
      });
    } catch {
      return store.transaction(() => {
        const row = store.get<JobRow>('SELECT * FROM assembly_jobs WHERE id = ?', before.id)!;
        if (row.state !== 'running' || row.revision !== started.revision) return job(row);
        return job(updateJob(row, 'failed', { code: 'processor_failed', message: 'The worker did not return a verified derivative with matching provenance; originals are unchanged' }, options.user(request).id));
      });
    }
  });
}
