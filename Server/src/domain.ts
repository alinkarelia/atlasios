export class ApiError extends Error {
  constructor(public readonly status: number, public readonly code: string, message: string) { super(message); }
}

export type Role = 'owner' | 'admin' | 'manager' | 'surveyor' | 'reviewer' | 'viewer';
export type Entity = 'feature' | 'task' | 'workorder' | 'review';
export const roles: Role[] = ['owner', 'admin', 'manager', 'surveyor', 'reviewer', 'viewer'];
export const uuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
const uuid = new RegExp(uuidPattern);

export function invalid(message: string): never { throw new ApiError(400, 'invalid_input', message); }
export function object(value: unknown, name = 'data'): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid(`${name} must be an object`);
  return value as Record<string, unknown>;
}
export function keys(value: Record<string, unknown>, allowed: string[]) {
  if (Object.keys(value).some(key => !allowed.includes(key))) invalid('Unexpected input field');
}
export function text(value: unknown, name: string, max = 4096, min = 0): string {
  if (typeof value !== 'string' || value.length < min || value.length > max || (min > 0 && value.trim().length < min)) invalid(`${name} must contain ${min}–${max} characters`);
  return value;
}
export function id(value: unknown, name = 'id'): string {
  if (typeof value !== 'string' || !uuid.test(value)) invalid(`${name} must be a UUID`);
  return value.toLowerCase();
}
export function enumeration<T extends string>(value: unknown, options: readonly T[], name: string): T {
  if (typeof value !== 'string' || !options.includes(value as T)) invalid(`Invalid ${name}`);
  return value as T;
}
function finite(value: unknown, name: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) invalid(`${name} must be finite`);
  return value;
}
export function integer(value: unknown, name: string, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  const n = finite(value, name);
  if (!Number.isSafeInteger(n) || n < min || n > max) invalid(`Invalid ${name}`);
  return n;
}
function optionalDate(value: unknown, name: string): string | null {
  if (value === undefined || value === null) return null;
  const date = text(value, name, 40, 10);
  if (!/^\d{4}-\d{2}-\d{2}T/.test(date) || !Number.isFinite(Date.parse(date))) invalid(`Invalid ${name}`);
  return new Date(date).toISOString();
}

export type Reference = { type: 'localMeters'; frameID: string } | { type: 'wgs84' };
export function coordinateReference(input: unknown): Reference {
  const value = object(input, 'coordinateReference');
  if (value.type === 'localMeters') {
    keys(value, ['type', 'frameID']);
    return { type: 'localMeters', frameID: id(value.frameID, 'frameID') };
  }
  if (value.type === 'wgs84') { keys(value, ['type']); return { type: 'wgs84' }; }
  if ('localMeters' in value && Object.keys(value).length === 1) {
    const local = object(value.localMeters);
    keys(local, ['frameID']);
    return { type: 'localMeters', frameID: id(local.frameID, 'frameID') };
  }
  if ('wgs84' in value && Object.keys(value).length === 1) {
    keys(object(value.wgs84), []);
    return { type: 'wgs84' };
  }
  return invalid('Unsupported coordinateReference');
}

type Point = { x: number; y: number };
function equal(a: Point, b: Point) { return a.x === b.x && a.y === b.y; }
function cross(a: Point, b: Point, c: Point) { return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x); }
function onSegment(a: Point, b: Point, p: Point) {
  const tolerance = 1e-9 * Math.max(1, Math.hypot(b.x - a.x, b.y - a.y));
  return Math.abs(cross(a, b, p)) < tolerance && p.x >= Math.min(a.x, b.x) - 1e-9
    && p.x <= Math.max(a.x, b.x) + 1e-9 && p.y >= Math.min(a.y, b.y) - 1e-9 && p.y <= Math.max(a.y, b.y) + 1e-9;
}
function intersects(a: Point, b: Point, c: Point, d: Point) {
  const abC = cross(a, b, c); const abD = cross(a, b, d);
  const cdA = cross(c, d, a); const cdB = cross(c, d, b);
  return (abC * abD < 0 && cdA * cdB < 0) || onSegment(a, b, c) || onSegment(a, b, d)
    || onSegment(c, d, a) || onSegment(c, d, b);
}
function inside(p: Point, ring: Point[]) {
  let result = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[i]!; const b = ring[j]!;
    if (onSegment(a, b, p)) return false;
    if ((a.y > p.y) !== (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) result = !result;
  }
  return result;
}
function validateRing(points: Point[]) {
  if (points.length < 3) invalid('Polygon ring requires at least three different vertices');
  let area = 0;
  const origin = points[0]!;
  for (let i = 0; i < points.length; i++) {
    const a = points[i]!; const b = points[(i + 1) % points.length]!;
    if (equal(a, b)) invalid('Consecutive polygon vertices must differ');
    area += cross(origin, a, b);
    for (let j = i + 1; j < points.length; j++) {
      if (j === i + 1 || (i === 0 && j === points.length - 1)) continue;
      if (intersects(a, b, points[j]!, points[(j + 1) % points.length]!)) invalid('Polygon ring self-intersects');
    }
  }
  if (Math.abs(area) <= 1e-10) invalid('Polygon ring has zero area');
}
function ringsIntersect(a: Point[], b: Point[]) {
  for (let i = 0; i < a.length; i++) for (let j = 0; j < b.length; j++) {
    if (intersects(a[i]!, a[(i + 1) % a.length]!, b[j]!, b[(j + 1) % b.length]!)) return true;
  }
  return false;
}

/** Accept genuine points, open lines and polygons; never expand a point into a synthetic ring. */
export function geometry(input: unknown, reference: Reference): void {
  const value = object(input, 'geometry');
  const kinds = ['metricPolygon', 'geographicPolygon', 'metricPoint', 'geographicPoint', 'metricPolyline', 'geographicPolyline'] as const;
  type Kind = typeof kinds[number];
  let kind: Kind;
  let shape: Record<string, unknown>;
  if (typeof value.type === 'string' && kinds.includes(value.type as Kind)) {
    kind = value.type as Kind;
    shape = { ...value }; delete shape.type;
  } else {
    const variants = Object.keys(value);
    if (variants.length !== 1 || !kinds.includes(variants[0] as Kind)) invalid('Unsupported geometry');
    kind = variants[0] as Kind;
    shape = object(value[kind]);
    if ('_0' in shape) { keys(shape, ['_0']); shape = object(shape._0); }
  }
  const metric = kind.startsWith('metric');
  const point = kind.endsWith('Point');
  const line = kind.endsWith('Polyline');
  keys(shape, point ? (metric ? ['frameID', 'point'] : ['point', 'longitude', 'latitude'])
    : (metric ? ['frameID', 'vertices', ...(line ? [] : ['holes'])] : ['vertices', ...(line ? [] : ['holes'])]));
  if (metric) {
    if (reference.type !== 'localMeters' || id(shape.frameID, 'frameID') !== reference.frameID) invalid('Metric geometry frame must match the project');
  } else if (reference.type !== 'wgs84') invalid('Geographic geometry requires a WGS84 project');
  const readPoint = (item: unknown): Point => {
    const p = object(item, 'coordinate');
    if (metric) {
      keys(p, ['x', 'y']);
      const x = finite(p.x, 'x'); const y = finite(p.y, 'y');
      if (Math.abs(x) > 1e12 || Math.abs(y) > 1e12) invalid('Metric coordinate outside supported range');
      return { x, y };
    }
    keys(p, ['longitude', 'latitude']);
    const x = finite(p.longitude, 'longitude'); const y = finite(p.latitude, 'latitude');
    if (Math.abs(x) > 180 || Math.abs(y) > 90) invalid('WGS84 coordinate outside bounds');
    return { x, y };
  };
  if (point) {
    if (metric) { readPoint(shape.point); return; }
    if ('point' in shape) {
      if ('longitude' in shape || 'latitude' in shape) invalid('Use one geographic point representation');
      readPoint(shape.point);
    } else readPoint(shape);
    return;
  }
  if (!Array.isArray(shape.vertices)) invalid('vertices must be an array');
  const holes = line ? [] : shape.holes ?? [];
  if (!Array.isArray(holes) || holes.length > 64) invalid('Invalid holes');
  const rawRings = [shape.vertices, ...holes];
  if (rawRings.some(r => !Array.isArray(r)) || rawRings.reduce((sum, r) => sum + (r as unknown[]).length, 0) > 2048) invalid('Geometry supports at most 2048 vertices');
  const rings = rawRings.map(raw => (raw as unknown[]).map(readPoint));
  for (const ring of rings) {
    if (!metric) {
      for (let i = 1; i < ring.length; i++) if (Math.abs(ring[i]!.x - ring[i - 1]!.x) > 180) invalid('Split geometry crossing the antimeridian before import');
      if (!line && ring.length && Math.abs(ring[0]!.x - ring.at(-1)!.x) > 180) invalid('Split geometry crossing the antimeridian before import');
    }
  }
  if (line) {
    const vertices = rings[0]!;
    if (vertices.length < 2) invalid('Polyline requires at least two vertices');
    for (let i = 1; i < vertices.length; i++) if (equal(vertices[i - 1]!, vertices[i]!)) invalid('Consecutive line vertices must differ');
    return;
  }
  const origin = rings[0]![0];
  if (!origin) invalid('Polygon ring requires at least three vertices');
  if (!metric) for (const ring of rings) for (const p of ring) {
    if (Math.abs(p.x - origin.x) > 180) invalid('Split polygons crossing the antimeridian before import');
  }
  // Topology checks use a local geographic projection rather than square degrees.
  const projected = metric ? rings : rings.map(ring => ring.map(p => ({
    x: (p.x - origin.x) * Math.cos(origin.y * Math.PI / 180) * 111320,
    y: (p.y - origin.y) * 110574,
  })));
  for (const ring of projected) {
    if (ring.length > 1 && equal(ring[0]!, ring.at(-1)!)) ring.pop();
    validateRing(ring);
  }
  const outer = projected[0]!;
  for (let i = 1; i < projected.length; i++) {
    const hole = projected[i]!;
    if (!inside(hole[0]!, outer) || ringsIntersect(outer, hole)) invalid('Hole must be strictly inside its polygon');
    for (let j = 1; j < i; j++) {
      const previous = projected[j]!;
      if (ringsIntersect(hole, previous) || inside(hole[0]!, previous) || inside(previous[0]!, hole)) invalid('Polygon holes overlap');
    }
  }
}

export function featureData(input: unknown, reference: Reference): Record<string, unknown> {
  const data = object(input);
  keys(data, ['label', 'category', 'geometry', 'attributes', 'notes', 'reviewStatus', 'links']);
  text(data.label, 'label', 160, 1);
  enumeration(data.category, ['grave', 'sector', 'path', 'building', 'boundary', 'other', 'cemetery', 'road', 'entrance', 'wasteBin', 'fence', 'wasteDump', 'tree', 'shrub'], 'category');
  geometry(data.geometry, reference);
  const attributes = object(data.attributes ?? {}, 'attributes');
  if (Object.keys(attributes).length > 64) invalid('Too many attributes');
  for (const [key, value] of Object.entries(attributes)) {
    if (['__proto__', 'constructor', 'prototype'].includes(key)) invalid('Reserved attribute key');
    text(key, 'attribute name', 80, 1); text(value, 'attribute value', 2048);
  }
  const links = data.links ?? [];
  if (!Array.isArray(links) || links.length > 64) invalid('Invalid links');
  for (const item of links) {
    const link = object(item); keys(link, ['relation', 'targetID']);
    id(link.targetID, 'targetID'); text(link.relation, 'relation', 64, 1);
  }
  return { label: data.label, category: data.category, geometry: data.geometry, attributes,
    notes: text(data.notes ?? '', 'notes'),
    reviewStatus: enumeration(data.reviewStatus ?? 'draft', ['draft', 'needsReview'], 'reviewStatus'), links };
}

export function taskData(input: unknown): Record<string, unknown> {
  const data = object(input);
  keys(data, ['title', 'description', 'status', 'assigneeID', 'targetFeatureID', 'priority', 'dueAt']);
  return {
    title: text(data.title, 'title', 160, 1), description: text(data.description ?? '', 'description'),
    status: enumeration(data.status ?? 'open', ['open', 'in_progress', 'submitted', 'accepted', 'needs_revision', 'blocked', 'cancelled'], 'task status'),
    assigneeID: data.assigneeID == null ? null : id(data.assigneeID, 'assigneeID'),
    targetFeatureID: data.targetFeatureID == null ? null : id(data.targetFeatureID, 'targetFeatureID'),
    priority: enumeration(data.priority ?? 'normal', ['low', 'normal', 'high'], 'priority'), dueAt: optionalDate(data.dueAt, 'dueAt'),
  };
}

export function workorderData(input: unknown): Record<string, unknown> {
  const data = object(input);
  keys(data, ['title', 'clientName', 'description', 'status', 'currency', 'estimatedAmountMinor', 'actualAmountMinor', 'dueAt']);
  const currency = text(data.currency ?? 'USD', 'currency', 3, 3);
  if (!/^[A-Z]{3}$/.test(currency)) invalid('Currency must be an uppercase ISO code');
  return {
    title: text(data.title, 'title', 160, 1), clientName: text(data.clientName ?? '', 'clientName', 200),
    description: text(data.description ?? '', 'description'),
    status: enumeration(data.status ?? 'draft', ['draft', 'quoted', 'approved', 'in_progress', 'delivered', 'accepted', 'closed', 'cancelled'], 'workorder status'),
    currency,
    estimatedAmountMinor: data.estimatedAmountMinor == null ? null : integer(data.estimatedAmountMinor, 'estimatedAmountMinor', 0, 1e12),
    actualAmountMinor: data.actualAmountMinor == null ? null : integer(data.actualAmountMinor, 'actualAmountMinor', 0, 1e12),
    dueAt: optionalDate(data.dueAt, 'dueAt'),
  };
}

export const uuidSchema = { type: 'string', pattern: uuidPattern } as const;
export const stringSchema = (maxLength: number, minLength = 0) => ({ type: 'string', minLength, maxLength });
export function bodySchema(properties: Record<string, unknown>, required: string[]) {
  return { type: 'object', additionalProperties: false, properties, required };
}
export const operationSchema = bodySchema({
  operationID: uuidSchema, entity: { type: 'string', enum: ['feature', 'task', 'workorder', 'review'] },
  action: { type: 'string', enum: ['upsert', 'delete', 'review'] }, id: uuidSchema,
  baseRevision: { type: 'integer', minimum: 0, maximum: Number.MAX_SAFE_INTEGER }, data: { type: 'object' },
}, ['operationID', 'entity', 'action', 'id', 'baseRevision']);
