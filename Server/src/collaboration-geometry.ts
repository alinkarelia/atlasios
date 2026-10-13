/**
 * Deterministic counterpart of AtlasCore's bounded survey grid. The input
 * polygon must first pass the server's topology validator. Rectangles describe
 * the grid only: clipped concave rings are integrated for area, never published
 * as traversable work polygons or a proof that a whole cell was scanned.
 */
export interface CollaborativeGridPoint { x: number; y: number }
export interface CollaborativeGridPolygon {
  frameID: string;
  vertices: CollaborativeGridPoint[];
  holes: CollaborativeGridPoint[][];
}
export interface CanonicalCollaborativeCell {
  id: string;
  row: number;
  column: number;
  center: CollaborativeGridPoint;
  boundsVertices: CollaborativeGridPoint[];
  boundaryStatus: 'interior' | 'partialRequiresReview';
  estimatedWorkAreaSquareMeters: number;
  componentID: number;
}
interface CellDraft {
  id: string; row: number; column: number; center: CollaborativeGridPoint;
  rectangle: CollaborativeGridPoint[]; area: number; partial: boolean;
}
const maximumCells = 20_000;

function pointDistance(a: CollaborativeGridPoint, b: CollaborativeGridPoint): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}
function segmentDistance(p: CollaborativeGridPoint, a: CollaborativeGridPoint, b: CollaborativeGridPoint): number {
  const dx = b.x - a.x, dy = b.y - a.y, square = dx * dx + dy * dy;
  const t = square > 0 ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / square)) : 0;
  return Math.hypot(p.x - a.x - t * dx, p.y - a.y - t * dy);
}
function rings(polygon: CollaborativeGridPolygon): CollaborativeGridPoint[][] {
  return [polygon.vertices, ...polygon.holes];
}
function insideRing(point: CollaborativeGridPoint, ring: CollaborativeGridPoint[]): boolean {
  let inside = false;
  for (let index = 0; index < ring.length; index++) {
    const a = ring[index]!, b = ring[(index + 1) % ring.length]!;
    if (segmentDistance(point, a, b) <= 1e-9) return true;
    if ((a.y > point.y) !== (b.y > point.y)
      && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
  }
  return inside;
}
function contains(point: CollaborativeGridPoint, polygon: CollaborativeGridPolygon): boolean {
  return insideRing(point, polygon.vertices) && !polygon.holes.some(ring => insideRing(point, ring));
}
function distanceToBoundary(point: CollaborativeGridPoint, polygon: CollaborativeGridPolygon): number {
  let result = Infinity;
  for (const ring of rings(polygon)) for (let i = 0; i < ring.length; i++) {
    result = Math.min(result, segmentDistance(point, ring[i]!, ring[(i + 1) % ring.length]!));
  }
  return result;
}
export function containsStrictly(point: CollaborativeGridPoint, polygon: CollaborativeGridPolygon): boolean {
  return contains(point, polygon) && distanceToBoundary(point, polygon) > 1e-9;
}
function signedArea(ring: CollaborativeGridPoint[]): number {
  if (!ring.length) return 0;
  const origin = ring[0]!;
  let twiceArea = 0, compensation = 0;
  for (let i = 0; i < ring.length; i++) {
    const a = ring[i]!, b = ring[(i + 1) % ring.length]!;
    const term = (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x);
    const corrected = term - compensation, next = twiceArea + corrected;
    compensation = (next - twiceArea) - corrected; twiceArea = next;
  }
  return twiceArea / 2;
}
function clip(ring: CollaborativeGridPoint[], rectangle: CollaborativeGridPoint[]): CollaborativeGridPoint[] {
  const minimum = rectangle[0]!, maximum = rectangle[2]!;
  let result = ring;
  for (let side = 0; side < 4; side++) {
    const input = result; result = [];
    if (!input.length) break;
    const inside = (p: CollaborativeGridPoint) => side === 0 ? p.x >= minimum.x : side === 1 ? p.x <= maximum.x
      : side === 2 ? p.y >= minimum.y : p.y <= maximum.y;
    const intersection = (a: CollaborativeGridPoint, b: CollaborativeGridPoint): CollaborativeGridPoint => {
      if (side < 2) {
        const x = side === 0 ? minimum.x : maximum.x, fraction = (x - a.x) / (b.x - a.x);
        return { x, y: a.y + fraction * (b.y - a.y) };
      }
      const y = side === 2 ? minimum.y : maximum.y, fraction = (y - a.y) / (b.y - a.y);
      return { x: a.x + fraction * (b.x - a.x), y };
    };
    for (let i = 0; i < input.length; i++) {
      const a = input[(i + input.length - 1) % input.length]!, b = input[i]!;
      if (inside(b)) { if (!inside(a)) result.push(intersection(a, b)); result.push(b); }
      else if (inside(a)) result.push(intersection(a, b));
    }
  }
  return result;
}
function intersectionArea(polygon: CollaborativeGridPolygon, rectangle: CollaborativeGridPoint[]): number {
  const exterior = Math.abs(signedArea(clip(polygon.vertices, rectangle)));
  const holes = polygon.holes.reduce((sum, ring) => sum + Math.abs(signedArea(clip(ring, rectangle))), 0);
  return Math.max(0, exterior - holes);
}
function representative(polygon: CollaborativeGridPolygon, rectangle: CollaborativeGridPoint[]): CollaborativeGridPoint {
  const minimum = rectangle[0]!, maximum = rectangle[2]!;
  const center = { x: (minimum.x + maximum.x) / 2, y: (minimum.y + maximum.y) / 2 };
  const strictlyInside = (p: CollaborativeGridPoint) => containsStrictly(p, polygon);
  if (strictlyInside(center)) return center;
  const allRings = rings(polygon);
  const rawLevels = [minimum.y, maximum.y, ...allRings.flatMap(ring => clip(ring, rectangle).map(point => point.y))];
  const levels = [...new Set(rawLevels.filter(y => Number.isFinite(y) && y >= minimum.y && y <= maximum.y))]
    .sort((a, b) => a - b);
  let best: CollaborativeGridPoint | undefined, width = -Infinity;
  for (let i = 1; i < levels.length; i++) {
    if (levels[i]! <= levels[i - 1]!) continue;
    const y = (levels[i]! + levels[i - 1]!) / 2, crossings = [minimum.x, maximum.x];
    for (const ring of allRings) for (let edge = 0; edge < ring.length; edge++) {
      const a = ring[edge]!, b = ring[(edge + 1) % ring.length]!;
      if ((a.y > y) !== (b.y > y)) {
        const x = a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x);
        if (x > minimum.x && x < maximum.x) crossings.push(x);
      }
    }
    crossings.sort((a, b) => a - b);
    for (let pair = 1; pair < crossings.length; pair++) {
      const point = { x: (crossings[pair]! + crossings[pair - 1]!) / 2, y };
      const span = crossings[pair]! - crossings[pair - 1]!;
      if (span > width && strictlyInside(point)) { width = span; best = point; }
    }
  }
  if (!best) throw new RangeError('A positive-area cell has no safe interior representative');
  return best;
}
function edgePassesInterior(a: CollaborativeGridPoint, b: CollaborativeGridPoint, rectangle: CollaborativeGridPoint[]): boolean {
  const minimum = rectangle[0]!, maximum = rectangle[2]!;
  let lower = 0, upper = 1;
  for (const [origin, delta, min, max] of [[a.x, b.x - a.x, minimum.x, maximum.x], [a.y, b.y - a.y, minimum.y, maximum.y]]) {
    if (delta! === 0) { if (origin! < min! || origin! > max!) return false; continue; }
    const first = (min! - origin!) / delta!, second = (max! - origin!) / delta!;
    lower = Math.max(lower, Math.min(first, second)); upper = Math.min(upper, Math.max(first, second));
    if (upper <= lower) return false;
  }
  const fraction = (lower + upper) / 2, x = a.x + fraction * (b.x - a.x), y = a.y + fraction * (b.y - a.y);
  return x > minimum.x && x < maximum.x && y > minimum.y && y < maximum.y;
}
function segmentInside(a: CollaborativeGridPoint, b: CollaborativeGridPoint, polygon: CollaborativeGridPolygon): boolean {
  const fractions = [0, 1], dx = b.x - a.x, dy = b.y - a.y;
  for (const ring of rings(polygon)) for (let i = 0; i < ring.length; i++) {
    const c = ring[i]!, d = ring[(i + 1) % ring.length]!, ex = d.x - c.x, ey = d.y - c.y;
    const denominator = dx * ey - dy * ex;
    if (Math.abs(denominator) < 1e-14) continue;
    const qx = c.x - a.x, qy = c.y - a.y;
    const t = (qx * ey - qy * ex) / denominator, u = (qx * dy - qy * dx) / denominator;
    if (t > 0 && t < 1 && u >= 0 && u <= 1) fractions.push(t);
  }
  fractions.sort((x, y) => x - y);
  for (let i = 1; i < fractions.length; i++) {
    const t = (fractions[i]! + fractions[i - 1]!) / 2;
    if (!contains({ x: a.x + t * dx, y: a.y + t * dy }, polygon)) return false;
  }
  return true;
}
function partition(drafts: CellDraft[], components: number[][], adjacency: number[][], workerCount: number): number[] {
  const owners = Array<number>(drafts.length).fill(-1), loads = Array<number>(workerCount).fill(0);
  const area = (component: number[]) => component.reduce((sum, index) => sum + drafts[index]!.area, 0);
  const ordered = [...components].sort((a, b) => area(b) - area(a) || a[0]! - b[0]!);
  for (const component of ordered) {
    const active = Array.from({ length: workerCount }, (_, i) => i).sort((a, b) => loads[a]! - loads[b]! || a - b)
      .slice(0, Math.min(workerCount, component.length));
    const seeds: number[] = [], frontiers = Array.from({ length: workerCount }, () => [] as number[]);
    const heads = Array<number>(workerCount).fill(0);
    for (const worker of active) {
      let seed = component[0]!;
      if (seeds.length) {
        let greatest = -Infinity;
        for (const candidate of component) {
          if (seeds.includes(candidate)) continue;
          const nearest = Math.min(...seeds.map(index => pointDistance(drafts[candidate]!.center, drafts[index]!.center)));
          if (nearest > greatest || (nearest === greatest && candidate < seed)) { greatest = nearest; seed = candidate; }
        }
      }
      seeds.push(seed); owners[seed] = worker; loads[worker]! += drafts[seed]!.area;
      frontiers[worker] = [...adjacency[seed]!];
    }
    let remaining = component.length - seeds.length;
    while (remaining > 0) {
      const sorted = [...active].sort((a, b) => loads[a]! - loads[b]! || a - b);
      let advanced = false;
      for (const worker of sorted) {
        while (heads[worker]! < frontiers[worker]!.length && owners[frontiers[worker]![heads[worker]!]!] !== -1) heads[worker]!++;
        if (heads[worker]! >= frontiers[worker]!.length) continue;
        const index = frontiers[worker]![heads[worker]!]!; heads[worker]!++;
        owners[index] = worker; loads[worker]! += drafts[index]!.area;
        frontiers[worker]!.push(...adjacency[index]!); remaining--; advanced = true; break;
      }
      if (!advanced) throw new RangeError('A connected grid component could not be allocated');
    }
  }
  return owners;
}

export function canonicalCollaborativeGrid(boundary: CollaborativeGridPolygon, cellSizeMeters: number, workerIDs: string[]): {
  cells: CanonicalCollaborativeCell[]; assignments: { cellID: string; workerID: string }[];
} {
  if (!Number.isFinite(cellSizeMeters) || cellSizeMeters < 1 || cellSizeMeters > 500
    || workerIDs.length < 1 || workerIDs.length > 64 || new Set(workerIDs).size !== workerIDs.length
    || workerIDs.some(id => !id.length) || boundary.vertices.length < 3 || boundary.holes.length > 64
    || rings(boundary).reduce((sum, ring) => sum + ring.length, 0) > 2048
    || rings(boundary).some(ring => ring.length < 3 || ring.some(p => !Number.isFinite(p.x) || !Number.isFinite(p.y)
      || Math.abs(p.x) > 1e6 || Math.abs(p.y) > 1e6))) throw new RangeError('Invalid bounded grid input');
  const minX = Math.min(...boundary.vertices.map(p => p.x)), maxX = Math.max(...boundary.vertices.map(p => p.x));
  const minY = Math.min(...boundary.vertices.map(p => p.y)), maxY = Math.max(...boundary.vertices.map(p => p.y));
  const columns = Math.ceil((maxX - minX) / cellSizeMeters), rows = Math.ceil((maxY - minY) / cellSizeMeters);
  if (!Number.isFinite(columns) || !Number.isFinite(rows) || columns <= 0 || rows <= 0 || columns * rows > maximumCells)
    throw new RangeError('Bounding grid exceeds its cell limit');
  const drafts: CellDraft[] = [], lookup = new Map<string, number>();
  for (let row = 0; row < rows; row++) for (let column = 0; column < columns; column++) {
    const x = minX + column * cellSizeMeters, y = minY + row * cellSizeMeters;
    const rectangle = [{ x, y }, { x: x + cellSizeMeters, y },
      { x: x + cellSizeMeters, y: y + cellSizeMeters }, { x, y: y + cellSizeMeters }];
    const area = intersectionArea(boundary, rectangle);
    if (!(area > 1e-10)) continue;
    const center = representative(boundary, rectangle);
    const partial = rings(boundary).some(ring => ring.some((a, i) => edgePassesInterior(a, ring[(i + 1) % ring.length]!, rectangle)));
    const id = `r${row}c${column}`; lookup.set(id, drafts.length);
    drafts.push({ id, row, column, center, rectangle, area: Math.min(area, cellSizeMeters * cellSizeMeters), partial });
  }
  if (!drafts.length) throw new RangeError('No positive-area survey cells');
  const adjacency = Array.from({ length: drafts.length }, () => [] as number[]);
  for (let i = 0; i < drafts.length; i++) {
    const cell = drafts[i]!;
    for (const [row, column] of [[cell.row, cell.column + 1], [cell.row + 1, cell.column]]) {
      const other = lookup.get(`r${row}c${column}`);
      if (other !== undefined && segmentInside(cell.center, drafts[other]!.center, boundary)) {
        adjacency[i]!.push(other); adjacency[other]!.push(i);
      }
    }
  }
  const componentIDs = Array<number>(drafts.length).fill(-1), components: number[][] = [];
  for (let start = 0; start < drafts.length; start++) {
    if (componentIDs[start] !== -1) continue;
    const componentID = components.length, queue = [start]; componentIDs[start] = componentID;
    for (let cursor = 0; cursor < queue.length; cursor++) for (const next of adjacency[queue[cursor]!]!) {
      if (componentIDs[next] === -1) { componentIDs[next] = componentID; queue.push(next); }
    }
    components.push(queue.sort((a, b) => a - b));
  }
  const owners = partition(drafts, components, adjacency, workerIDs.length);
  return {
    cells: drafts.map((item, i) => ({ id: item.id, row: item.row, column: item.column, center: item.center,
      boundsVertices: item.rectangle, boundaryStatus: item.partial ? 'partialRequiresReview' : 'interior',
      estimatedWorkAreaSquareMeters: item.area, componentID: componentIDs[i]! })),
    assignments: drafts.map((item, i) => ({ cellID: item.id, workerID: workerIDs[owners[i]!]! }))
  };
}
