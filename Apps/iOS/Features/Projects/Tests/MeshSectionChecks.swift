import Foundation

@main struct MeshSectionChecks {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("triangle.obj")
        let text = "v -1 -1 0\nv 1 -1 0\nv 0 1 0\nf 1 2 3\n"
        try Data(text.utf8).write(to: source)
        let mesh = try OBJPreviewLoader.load(source)
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "Section", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let originalArea = try MeshSectionProcessor.surfaceArea(mesh)
        try require(abs(originalArea - 2) < 0.000001, "Source triangle area")
        let half = try MeshSectionProcessor.clipped(mesh, belowY: 0)
        try require(half.triangleCount == 2 && half.vertexCount == 6, "Clipping creates a correctly triangulated quadrilateral")
        let area = try MeshSectionProcessor.surfaceArea(half)
        try require(abs(area - 1.5) < 0.000001, "Clipped area follows analytic triangle geometry")
        let points = half.positions.withUnsafeBytes { bytes in
            (0..<half.vertexCount).map { index in
                SIMD3(bytes.loadUnaligned(fromByteOffset: index * 12, as: Float.self),
                      bytes.loadUnaligned(fromByteOffset: index * 12 + 4, as: Float.self),
                      bytes.loadUnaligned(fromByteOffset: index * 12 + 8, as: Float.self))
            }
        }
        try require(points.allSatisfy { $0.y <= 0 && $0.z == 0 }, "Every retained point respects cut plane")
        try require(points.contains { $0 == SIMD3<Float>(-0.5, 0, 0) } && points.contains { $0 == SIMD3<Float>(0.5, 0, 0) }, "Intersections interpolate actual coordinates")
        for face in 0..<half.triangleCount {
            let a = points[face * 3], b = points[face * 3 + 1], c = points[face * 3 + 2]
            let signed = (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
            try require(signed > 0, "Winding is preserved at cut")
        }
        let removed = try MeshSectionProcessor.clipped(mesh, belowY: -2)
        try require(removed.vertexCount == 0 && removed.triangleCount == 0, "Fully removed surface yields empty view geometry")
        let retained = try MeshSectionProcessor.clipped(mesh, belowY: 2)
        try require(retained.positions == mesh.positions && retained.indices == mesh.indices, "Full retention preserves source coordinates")
        try require(try Data(contentsOf: source) == Data(text.utf8), "Original file is untouched")
        do {
            _ = try MeshSectionProcessor.clipped(mesh, belowY: .nan)
            throw NSError(domain: "Section", code: 2, userInfo: [NSLocalizedDescriptionKey: "NaN cut unexpectedly accepted"])
        } catch OBJPreviewError.invalidMesh {}
        let invalid = OBJPreviewPayload(positions: Data(), normals: Data(), indices: Data(count: 4),
            vertexCount: 3, sourceVertexCount: 3, triangleCount: 1,
            minimum: .zero, maximum: .zero, isAtlasCapture: false)
        do {
            _ = try MeshSectionProcessor.surfaceArea(invalid)
            throw NSError(domain: "Section", code: 3)
        } catch OBJPreviewError.invalidMesh {}
        do {
            _ = try MeshSectionProcessor.clipped(invalid, belowY: 0)
            throw NSError(domain: "Section", code: 4)
        } catch OBJPreviewError.invalidMesh {}
        print("MeshSection: 13 analytic geometry, malformed buffer and source-preservation checks passed.")
    }
}
