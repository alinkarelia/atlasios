#!/usr/bin/env bash
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
checks_directory="$(mktemp -d -t terraview-mesh-export.XXXXXX)"
trap 'rm -rf "$checks_directory"' EXIT
swift_compiler="${SWIFTC:-swiftc}"
"$swift_compiler" -swift-version 6 -strict-concurrency=complete -O -D TERRAVIEW_MESH_EXPORT_CHECKS \
  "$test_directory/../../Features/Projects/OBJPreviewLoader.swift" \
  "$test_directory/../MeshExportService.swift" \
  "$test_directory/MeshExportChecks.swift" -o "$checks_directory/checks"
"$checks_directory/checks" "$checks_directory/fixtures"
python3 - "$checks_directory/fixtures/files.json" <<'PY'
"""Read the emitted wire formats independently of the Swift exporter."""
import json, math, pathlib, struct, sys

files = json.loads(pathlib.Path(sys.argv[1]).read_text())

def close(actual, expected):
    assert len(actual) == len(expected)
    assert all(math.isfinite(a) and abs(a-b) <= 2e-6 for a, b in zip(actual, expected)), (actual, expected)

def normal(face):
    a, b, c = face
    u, v = [b[i]-a[i] for i in range(3)], [c[i]-a[i] for i in range(3)]
    n = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
    length = math.sqrt(sum(x*x for x in n))
    return [x/length for x in n] if length else None

def stl(path, unit):
    data = pathlib.Path(path).read_bytes()
    assert ('units='+unit).encode('ascii') in data[:80]
    count, = struct.unpack_from('<I', data, 80)
    assert len(data) == 84 + count * 50
    faces, normals = [], []
    for i in range(count):
        values = struct.unpack_from('<12fH', data, 84+i*50)
        assert values[-1] == 0
        normals.append(values[:3])
        faces.append([values[3:6], values[6:9], values[9:12]])
    return faces, normals

def ply(path, unit):
    data = pathlib.Path(path).read_bytes()
    end = data.index(b'end_header\n') + len(b'end_header\n')
    lines = data[:end].decode('ascii').splitlines()
    assert lines[:2] == ['ply', 'format binary_little_endian 1.0']
    assert 'comment TerraView; units='+unit+'; source local frame' in lines
    vertex_count = int(next(x for x in lines if x.startswith('element vertex ')).split()[-1])
    face_count = int(next(x for x in lines if x.startswith('element face ')).split()[-1])
    properties = [x for x in lines if x.startswith('property ')]
    assert properties == ['property float '+x for x in ['x', 'y', 'z', 'nx', 'ny', 'nz']] + ['property list uchar uint vertex_indices']
    assert len(data) == end + 24*vertex_count + 13*face_count
    vertices, vertex_normals = [], []
    for i in range(vertex_count):
        values = struct.unpack_from('<6f', data, end+i*24)
        vertices.append(values[:3]); vertex_normals.append(values[3:])
    faces, normals = [], []
    for i in range(face_count):
        count, *indices = struct.unpack_from('<B3I', data, end+vertex_count*24+i*13)
        assert count == 3 and all(j < vertex_count for j in indices)
        faces.append([vertices[j] for j in indices])
        normals.append(vertex_normals[indices[0]])
        for j in indices[1:]: close(vertex_normals[j], normals[-1])
    return faces, normals

def glb(path, unit):
    data = pathlib.Path(path).read_bytes()
    magic, version, length = struct.unpack_from('<III', data)
    assert magic == 0x46546c67 and version == 2 and length == len(data)
    offset, chunks = 12, []
    while offset < len(data):
        size, kind = struct.unpack_from('<II', data, offset)
        assert size % 4 == 0 and offset+8+size <= len(data)
        chunks.append((kind, data[offset+8:offset+8+size]))
        offset += 8+size
    assert offset == len(data) and [x[0] for x in chunks] == [0x4e4f534a, 0x004e4942]
    doc, binary = json.loads(chunks[0][1]), chunks[1][1]
    assert doc['asset']['version'] == '2.0'
    assert unit == 'metres' and doc['asset']['extras']['units'] == 'metres'
    assert doc['asset']['extras']['coordinateFrame'] == 'source local frame'
    assert doc['scene'] == 0 and doc['scenes'] == [{'nodes': [0]}] and doc['nodes'] == [{'mesh': 0}]
    assert len(doc['meshes']) == 1 and len(doc['meshes'][0]['primitives']) == 1
    primitive = doc['meshes'][0]['primitives'][0]
    assert primitive['mode'] == 4 and set(primitive['attributes']) == {'POSITION', 'NORMAL'}
    assert not any(x in doc for x in ['textures', 'images', 'materials', 'samplers'])
    assert len(doc['buffers']) == 1 and doc['buffers'][0] == {'byteLength': len(binary)}
    assert len(doc['bufferViews']) == 3 and len(doc['accessors']) == 3
    spans = []
    def accessor(index, expected_type, expected_component, fmt, components):
        a = doc['accessors'][index]; view = doc['bufferViews'][a['bufferView']]
        assert a['type'] == expected_type and a['componentType'] == expected_component
        assert view['buffer'] == 0 and view['byteOffset'] % 4 == 0
        assert view['target'] == (34963 if expected_type == 'SCALAR' else 34962)
        start = view['byteOffset'] + a.get('byteOffset', 0)
        size = a['count']*components*4
        assert view['byteLength'] == size and start+size <= len(binary)
        spans.append((start, start+size))
        return [struct.unpack_from('<'+fmt*components, binary, start+i*components*4) for i in range(a['count'])]
    vertices = accessor(primitive['attributes']['POSITION'], 'VEC3', 5126, 'f', 3)
    vertex_normals = accessor(primitive['attributes']['NORMAL'], 'VEC3', 5126, 'f', 3)
    indices = [x[0] for x in accessor(primitive['indices'], 'SCALAR', 5125, 'I', 1)]
    assert len(vertices) == len(vertex_normals) == len(indices) and len(indices)%3 == 0
    assert sorted(spans) == [(0, len(vertices)*12), (len(vertices)*12, len(vertices)*24), (len(vertices)*24, len(binary))]
    position_accessor = doc['accessors'][primitive['attributes']['POSITION']]
    close(position_accessor['min'], [min(p[i] for p in vertices) for i in range(3)])
    close(position_accessor['max'], [max(p[i] for p in vertices) for i in range(3)])
    assert all(index < len(vertices) for index in indices)
    faces, normals = [], []
    for i in range(0, len(indices), 3):
        tri = indices[i:i+3]
        faces.append([vertices[j] for j in tri]); normals.append(vertex_normals[tri[0]])
        for j in tri[1:]: close(vertex_normals[j], normals[-1])
    return faces, normals

a, b, c, d = (1.25, -2., .5), (3.25, -2., .5), (1.25, 1., .5), (1.25, -2., 4.5)
expected = {'regular': [[a,b,c], [a,d,b], [b,d,c], [a,c,d]],
            'degenerate': [[(0.,0.,0.), (1.,0.,0.), (2.,0.,0.)]],
            'streamed': [[(0.,0.,0.), (2.,0.,0.), (0.,3.,0.)]] * 10000}
expected['unknown'] = expected['regular']
expected['explicit-metres'] = expected['regular']
expected['native-usdz'] = [[(10.,0.,20.), (12.,0.,20.), (10.,3.,24.)]]
readers = {'stl': stl, 'ply': ply, 'glb': glb}
exports = 0
for fixture, formats in files.items():
    for format, path in formats.items():
        unit = 'unknown (source units)' if fixture == 'unknown' else 'metres'
        faces, normals = readers[format](path, unit)
        assert len(faces) == len(expected[fixture])
        for face, expected_face, n in zip(faces, expected[fixture], normals):
            for point, expected_point in zip(face, expected_face): close(point, expected_point)
            calculated = normal(expected_face)
            close(n, calculated if calculated else ((0.,0.,0.) if format == 'stl' else (0.,1.,0.)))
        print(f'Independent {format.upper()} parser: {fixture}, {len(faces)} triangles, coordinates/winding/normals passed')
        exports += 1
print(f'{exports} real binary exports validated; exact metre/unknown-unit labels, two-metre edge and actual GLB bounds passed')
PY
