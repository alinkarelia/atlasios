import Foundation

/// Clips measured triangles against a horizontal plane. It changes only the
/// display buffers: originals, coordinates and capture metadata stay intact.
/// The cut is open, so it must never be described as a watertight solid.
enum MeshSectionProcessor {
    static func clipped(_ mesh: OBJPreviewPayload, belowY height: Float) throws -> OBJPreviewPayload {
        try validateBuffers(mesh)
        guard height.isFinite else { throw OBJPreviewError.invalidMesh }
        var vertices = Data(), normals = Data(), indices = Data()
        vertices.reserveCapacity(mesh.positions.count)
        normals.reserveCapacity(mesh.normals.count)
        indices.reserveCapacity(mesh.indices.count)
        var count = 0
        func point(_ index: Int) -> SIMD3<Float> {
            mesh.positions.withUnsafeBytes { bytes in
                SIMD3(bytes.loadUnaligned(fromByteOffset: index * 12, as: Float.self),
                      bytes.loadUnaligned(fromByteOffset: index * 12 + 4, as: Float.self),
                      bytes.loadUnaligned(fromByteOffset: index * 12 + 8, as: Float.self))
            }
        }
        func append(_ value: Float, to data: inout Data) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        for face in 0..<mesh.triangleCount {
            if face % 4_096 == 0 { try Task.checkCancellation() }
            let sourceIndices = mesh.indices.withUnsafeBytes { bytes in
                (0..<3).map { Int(bytes.loadUnaligned(fromByteOffset: face * 12 + $0 * 4, as: UInt32.self).littleEndian) }
            }
            guard sourceIndices.allSatisfy({ $0 < mesh.vertexCount }) else { throw OBJPreviewError.invalidMesh }
            let polygon = sourceIndices.map(point)
            guard polygon.allSatisfy({ point in (0..<3).allSatisfy { point[$0].isFinite && abs(point[$0]) <= 1_000_000 } }) else {
                throw OBJPreviewError.invalidMesh
            }
            var clipped: [SIMD3<Float>] = []
            var previous = polygon[2]
            for current in polygon {
                let previousInside = previous.y <= height
                let currentInside = current.y <= height
                if previousInside != currentInside {
                    let fraction = (height - previous.y) / (current.y - previous.y)
                    var intersection = previous + fraction * (current - previous)
                    intersection.y = height
                    clipped.append(intersection)
                }
                if currentInside { clipped.append(current) }
                previous = current
            }
            guard clipped.count >= 3 else { continue }
            let sourceNormal = mesh.normals.withUnsafeBytes { bytes in
                let offset = sourceIndices[0] * 12
                return SIMD3(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                             bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                             bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
            }
            guard (0..<3).allSatisfy({ sourceNormal[$0].isFinite }) else { throw OBJPreviewError.invalidMesh }
            for corner in 1..<(clipped.count - 1) {
                guard count / 3 < OBJPreviewLoader.maximumTriangles else { throw OBJPreviewError.limit }
                for vertex in [clipped[0], clipped[corner], clipped[corner + 1]] {
                    for axis in 0..<3 { append(vertex[axis], to: &vertices); append(sourceNormal[axis], to: &normals) }
                    var index = UInt32(count).littleEndian
                    withUnsafeBytes(of: &index) { indices.append(contentsOf: $0) }
                    count += 1
                }
            }
        }
        return OBJPreviewPayload(positions: vertices, normals: normals, indices: indices,
            vertexCount: count, sourceVertexCount: mesh.sourceVertexCount, triangleCount: count / 3,
            minimum: mesh.minimum, maximum: mesh.maximum, isAtlasCapture: mesh.isAtlasCapture)
    }

    static func surfaceArea(_ mesh: OBJPreviewPayload) throws -> Double {
        try validateBuffers(mesh)
        var area = 0.0
        try mesh.positions.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            try mesh.indices.withUnsafeBytes { (elements: UnsafeRawBufferPointer) in
                for face in 0..<mesh.triangleCount {
                    if face % 4_096 == 0 { try Task.checkCancellation() }
                    var points = [SIMD3<Double>]()
                    for corner in 0..<3 {
                        let index = Int(elements.loadUnaligned(fromByteOffset: face * 12 + corner * 4, as: UInt32.self).littleEndian)
                        guard index < mesh.vertexCount else { throw OBJPreviewError.invalidMesh }
                        let offset = index * 12
                        points.append(SIMD3(Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)),
                                            Double(bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)),
                                            Double(bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))))
                    }
                    let u = points[1] - points[0], v = points[2] - points[0]
                    let cross = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
                    area += sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z) / 2
                }
            }
        }
        guard area.isFinite else { throw OBJPreviewError.invalidMesh }
        return area
    }

    private static func validateBuffers(_ mesh: OBJPreviewPayload) throws {
        guard mesh.vertexCount >= 0, mesh.vertexCount <= OBJPreviewLoader.maximumRenderVertices,
              mesh.triangleCount >= 0, mesh.triangleCount <= OBJPreviewLoader.maximumTriangles,
              mesh.positions.count == mesh.vertexCount * 12,
              mesh.normals.count == mesh.vertexCount * 12,
              mesh.indices.count == mesh.triangleCount * 12 else { throw OBJPreviewError.invalidMesh }
    }
}
