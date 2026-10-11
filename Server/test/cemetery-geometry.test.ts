import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { ApiError, featureData, geometry, type Reference } from '../src/domain.js';

const frameID = randomUUID();
const local: Reference = { type: 'localMeters', frameID };
const global: Reference = { type: 'wgs84' };
const invalid = (body: unknown, reference = local) => assert.throws(() => geometry(body, reference),
  (error: unknown) => error instanceof ApiError && error.status === 400 && error.code === 'invalid_input');

test('cemetery geometry accepts synthesized Swift points and open lines without fabricated polygons', () => {
  const metricPoint = { metricPoint: { frameID, point: { x: 0, y: 0 } } };
  const metricLine = { metricPolyline: { _0: { frameID, vertices: [{ x: 0, y: 0 }, { x: 3, y: 4 }, { x: 6, y: 4 }] } } };
  const geographicPoint = { geographicPoint: { _0: { longitude: 37, latitude: 55 } } };
  const geographicLine = { geographicPolyline: { _0: { vertices: [{ longitude: 37, latitude: 55 }, { longitude: 37.0001, latitude: 55.0001 }] } } };
  geometry(metricPoint, local); geometry(metricLine, local);
  geometry(geographicPoint, global); geometry(geographicLine, global);
  for (const category of ['cemetery', 'road', 'entrance', 'wasteBin', 'fence', 'wasteDump', 'tree', 'shrub']) {
    const source = { label: 'Объект', category, geometry: metricPoint, attributes: { 'survey.status': 'candidate' } };
    const validated = featureData(source, local);
    assert.deepEqual(validated.geometry, metricPoint);
    assert.equal(validated.category, category);
  }
});

test('point and line validators enforce scope, finite coordinates, bounds and genuine vertex counts', () => {
  invalid({ metricPoint: { frameID: randomUUID(), point: { x: 0, y: 0 } } });
  invalid({ metricPoint: { frameID, point: { x: Infinity, y: 0 } } });
  invalid({ metricPoint: { frameID, point: { x: 1e13, y: 0 } } });
  invalid({ geographicPoint: { _0: { longitude: 181, latitude: 0 } } }, global);
  invalid({ geographicPoint: { _0: { longitude: 37, latitude: 55 } } });
  invalid({ geographicPolyline: { _0: { vertices: [{ longitude: 179, latitude: 10 }, { longitude: -179, latitude: 10 }] } } }, global);
  invalid({ metricPolyline: { _0: { frameID, vertices: [{ x: 1, y: 1 }] } } });
  invalid({ metricPolyline: { _0: { frameID, vertices: [{ x: 1, y: 1 }, { x: 1, y: 1 }] } } });
  invalid({ metricPolyline: { _0: { frameID, vertices: Array.from({ length: 2049 }, (_, x) => ({ x, y: 0 })) } } });
  // A crossing road is valid as a line, and does not imply an enclosed parcel.
  geometry({ metricPolyline: { _0: { frameID, vertices: [{ x: 0, y: 0 }, { x: 4, y: 4 }, { x: 0, y: 4 }, { x: 4, y: 0 }] } } }, local);
});

test('tagged DTO and legacy polygon representations remain accepted and strictly shaped', () => {
  geometry({ type: 'metricPoint', frameID, point: { x: 3, y: 4 } }, local);
  geometry({ type: 'geographicPoint', point: { longitude: 37, latitude: 55 } }, global);
  geometry({ type: 'geographicPoint', longitude: 37, latitude: 55 }, global);
  geometry({ type: 'metricPolyline', frameID, vertices: [{ x: 0, y: 0 }, { x: 1, y: 1 }] }, local);
  geometry({ metricPolygon: { _0: { frameID, vertices: [{ x: 0, y: 0 }, { x: 4, y: 0 }, { x: 4, y: 4 }], holes: [] } } }, local);
  invalid({ type: 'geographicPoint', point: { longitude: 37, latitude: 55 }, longitude: 37, latitude: 55 }, global);
  invalid({ metricPoint: { frameID, point: { x: 0, y: 0 }, holes: [] } });
  invalid({ metricPolyline: { _0: { frameID, vertices: [{ x: 0, y: 0 }, { x: 1, y: 1 }], holes: [] } } });
});

test('confirmation and unknown identity remain independent attributes under the existing review trust boundary', () => {
  const data = featureData({ label: 'Неизвестное захоронение', category: 'grave',
    geometry: { metricPoint: { frameID, point: { x: 2, y: 4 } } }, reviewStatus: 'needsReview',
    attributes: { 'survey.status': 'confirmed', 'grave.identityStatus': 'unknown', 'grave.persons': '[]', 'positionalUncertaintyMeters': '40' } }, local);
  assert.deepEqual(data.attributes, { 'survey.status': 'confirmed', 'grave.identityStatus': 'unknown', 'grave.persons': '[]', 'positionalUncertaintyMeters': '40' });
  assert.throws(() => featureData({ ...data, reviewStatus: 'reviewed' }, local), ApiError);
});
