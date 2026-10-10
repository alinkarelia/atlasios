import Foundation
#if canImport(ModelIO)
import ModelIO
import simd
#endif

struct OBJPreviewPayload: Sendable {
    let positions: Data
    let normals: Data
    let indices: Data
    let vertexCount: Int
    let sourceVertexCount: Int
    let triangleCount: Int
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    let isAtlasCapture: Bool
}

enum OBJPreviewError: LocalizedError {
    case limit, unsupportedFaces, invalidMesh, noGeometry
    var errorDescription: String? {
        switch self {
        case .limit: "Эта модель превышает предел предпросмотра: 64 МБ, 400 000 исходных вершин или 600 000 треугольников. Исходный файл можно выгрузить полностью."
        case .unsupportedFaces: "Предпросмотр поддерживает треугольную OBJ-сетку. Выгрузите исходный файл для просмотра в 3D-редакторе."
        case .invalidMesh: "Модель содержит некорректные координаты или индексы. Исходный файл доступен для выгрузки."
        case .noGeometry: "В файле не найдена треугольная сетка."
        }
    }
}

/// The loader reads bounded chunks away from the UI and transfers only value
/// data. No SceneKit/ModelIO object graph crosses a Swift concurrency boundary.
enum OBJPreviewLoader {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumVertices = 400_000
    static let maximumTriangles = 600_000
    // Hard edges need distinct display vertices for each face. These are
    // derived buffers only; the source file and its source counts stay intact.
    static let maximumRenderVertices = maximumTriangles * 3
    static let maximumGeometryBufferBytes = maximumRenderVertices * (12 + 12 + 4)

    static func load(_ url: URL) throws -> OBJPreviewPayload {
        #if canImport(ModelIO)
        if url.pathExtension.lowercased() == "usdz" { return try loadUSDZ(url) }
        #endif
        return try loadOBJ(url)
    }

    private static func loadOBJ(_ url: URL) throws -> OBJPreviewPayload {
        // A capture file can grow between previews. Foundation may retain URL
        // resource values on Darwin, so a reused URL must refresh its metadata.
        var sourceURL = url
        sourceURL.removeAllCachedResourceValues()
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw OBJPreviewError.invalidMesh }
        guard let byteCount = values.fileSize, byteCount <= maximumBytes else { throw OBJPreviewError.limit }
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        var positions: [Float] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(64_000 * 3)
        indices.reserveCapacity(64_000 * 3)
        var minimum = SIMD3<Float>(repeating: .infinity)
        var maximum = SIMD3<Float>(repeating: -.infinity)
        var isAtlasCapture = false

        func consume(_ data: Data.SubSequence) throws {
            guard data.count <= 16_384 else { throw OBJPreviewError.invalidMesh }
            let text = String(decoding: data, as: UTF8.self)
            if text.hasPrefix("# Atlas ARKit mesh. metres. Y up. local frame ") {
                isAtlasCapture = true
            }
            let parts = text.split(whereSeparator: { $0.isWhitespace })
            guard let kind = parts.first, !kind.hasPrefix("#") else { return }
            if kind == "v" {
                guard parts.count >= 4,
                      let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]),
                      [x, y, z].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else {
                    throw OBJPreviewError.invalidMesh
                }
                guard positions.count / 3 < maximumVertices else { throw OBJPreviewError.limit }
                positions.append(contentsOf: [x, y, z])
                let vertex = SIMD3<Float>(x, y, z)
                for component in 0..<3 {
                    let value = vertex[component]
                    minimum[component] = min(minimum[component], value)
                    maximum[component] = max(maximum[component], value)
                }
            } else if kind == "f" {
                // Atlas exports triangles. Fan triangulation of arbitrary concave
                // faces would alter geometry, so unsupported polygons are rejected.
                guard parts.count == 4 else { throw OBJPreviewError.unsupportedFaces }
                guard indices.count / 3 < maximumTriangles else { throw OBJPreviewError.limit }
                let vertexCount = positions.count / 3
                for part in parts.dropFirst() {
                    guard let position = part.split(separator: "/", omittingEmptySubsequences: false).first,
                          let index = Int(position), index != 0 else { throw OBJPreviewError.invalidMesh }
                    let resolved: Int
                    if index > 0 { resolved = index - 1 }
                    else {
                        let (value, overflow) = vertexCount.addingReportingOverflow(index)
                        guard !overflow else { throw OBJPreviewError.invalidMesh }
                        resolved = value
                    }
                    guard resolved >= 0, resolved < vertexCount else { throw OBJPreviewError.invalidMesh }
                    indices.append(UInt32(resolved))
                }
            }
        }

        var buffer = Data()
        var totalBytes = 0
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            totalBytes += chunk.count
            guard totalBytes <= maximumBytes else { throw OBJPreviewError.limit }
            buffer.append(chunk)
            var start = buffer.startIndex
            while let end = buffer[start...].firstIndex(of: 10) {
                try consume(buffer[start..<end])
                start = end + 1
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            guard buffer.count <= 16_384 else { throw OBJPreviewError.invalidMesh }
        }
        if !buffer.isEmpty { try consume(buffer[...]) }
        guard !positions.isEmpty, !indices.isEmpty else { throw OBJPreviewError.noGeometry }

        return try makePayload(positions: positions, indices: indices, minimum: minimum,
                               maximum: maximum, isAtlasCapture: isAtlasCapture)
    }

    /// A shared source vertex can belong to a floor and a perpendicular wall.
    /// Averaging their normals erased the real crease and made an apartment
    /// look like one continuous blue surface. Preserve exact triangles but
    /// expand display vertices so each face owns its geometric normal.
    ///
    /// At the largest supported mesh, the three buffers occupy 50.4 MB total:
    /// 1.8 million display vertices × (12 position + 12 normal + 4 index bytes).
    /// Building them directly in Data avoids another pair of expanded arrays.
    private static func makePayload(positions: [Float], indices: [UInt32], minimum: SIMD3<Float>,
                                    maximum: SIMD3<Float>, isAtlasCapture: Bool) throws -> OBJPreviewPayload {
        guard positions.count.isMultiple(of: 3), indices.count.isMultiple(of: 3),
              !positions.isEmpty, !indices.isEmpty else { throw OBJPreviewError.noGeometry }
        guard positions.count / 3 <= maximumVertices,
              indices.count <= maximumRenderVertices else { throw OBJPreviewError.limit }
        let renderVertexCount = indices.count
        let coordinateBytes = renderVertexCount * 12
        let indexBytes = renderVertexCount * 4
        guard coordinateBytes * 2 + indexBytes <= maximumGeometryBufferBytes else { throw OBJPreviewError.limit }
        var displayPositions = Data(count: coordinateBytes)
        var displayNormals = Data(count: coordinateBytes)
        var displayIndices = Data(count: indexBytes)
        try displayPositions.withUnsafeMutableBytes { (vertices: UnsafeMutableRawBufferPointer) throws -> Void in
            try displayNormals.withUnsafeMutableBytes { (normals: UnsafeMutableRawBufferPointer) throws -> Void in
                try displayIndices.withUnsafeMutableBytes { (elements: UnsafeMutableRawBufferPointer) throws -> Void in
                    try writeFlatBuffers(positions: positions, indices: indices, vertices: vertices,
                                         normals: normals, elements: elements)
                }
            }
        }
        try Task.checkCancellation()
        return OBJPreviewPayload(positions: displayPositions, normals: displayNormals, indices: displayIndices,
                                 vertexCount: renderVertexCount, sourceVertexCount: positions.count / 3,
                                 triangleCount: indices.count / 3, minimum: minimum, maximum: maximum,
                                 isAtlasCapture: isAtlasCapture)
    }

    /// Explicit buffer types keep Data's deprecated typed-pointer overloads
    /// out of Swift 6.1's inference path. Pointers stay inside the synchronous
    /// Data closures and never cross an actor or escape their allocation.
    private static func writeFlatBuffers(positions: [Float], indices: [UInt32],
                                         vertices: UnsafeMutableRawBufferPointer,
                                         normals: UnsafeMutableRawBufferPointer,
                                         elements: UnsafeMutableRawBufferPointer) throws {
        for face in stride(from: 0, to: indices.count, by: 3) {
            if face % 12_288 == 0 { try Task.checkCancellation() }
            let a = Int(indices[face]) * 3
            let b = Int(indices[face + 1]) * 3
            let c = Int(indices[face + 2]) * 3
            guard a + 2 < positions.count, b + 2 < positions.count,
                  c + 2 < positions.count else { throw OBJPreviewError.invalidMesh }
            let ux = Double(positions[b]) - Double(positions[a])
            let uy = Double(positions[b + 1]) - Double(positions[a + 1])
            let uz = Double(positions[b + 2]) - Double(positions[a + 2])
            let vx = Double(positions[c]) - Double(positions[a])
            let vy = Double(positions[c + 1]) - Double(positions[a + 1])
            let vz = Double(positions[c + 2]) - Double(positions[a + 2])
            let cross = SIMD3<Double>(uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx)
            let length = sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
            let normal: SIMD3<Float>
            if length > 0, length.isFinite {
                normal = SIMD3<Float>(Float(cross.x / length), Float(cross.y / length), Float(cross.z / length))
            } else {
                // Degenerate faces keep their original geometry;
                // a finite normal avoids poisoning a GPU buffer.
                normal = SIMD3<Float>(0, 1, 0)
            }
            for corner in 0..<3 {
                let displayIndex = face + corner
                let sourceIndex = Int(indices[displayIndex]) * 3
                for component in 0..<3 {
                    let offset = displayIndex * 12 + component * 4
                    vertices.storeBytes(of: positions[sourceIndex + component], toByteOffset: offset, as: Float.self)
                    normals.storeBytes(of: normal[component], toByteOffset: offset, as: Float.self)
                }
                elements.storeBytes(of: UInt32(displayIndex), toByteOffset: displayIndex * 4, as: UInt32.self)
            }
        }
    }

    #if canImport(ModelIO)
    /// ModelIO objects stay entirely on the background worker. Only flat value
    /// buffers leave it, so no SceneKit/ModelIO graph needs an unchecked Sendable
    /// bridge. RoomPlan's USDZ models use the same orbit and walkthrough viewer.
    private static func loadUSDZ(_ url: URL) throws -> OBJPreviewPayload {
        var sourceURL = url
        sourceURL.removeAllCachedResourceValues()
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw OBJPreviewError.invalidMesh }
        guard let bytes = values.fileSize, bytes <= maximumBytes else { throw OBJPreviewError.limit }
        try Task.checkCancellation()
        let asset = MDLAsset(url: sourceURL)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        var positions: [Float] = []
        var indices: [UInt32] = []
        var minimum = SIMD3<Float>(repeating: .infinity)
        var maximum = SIMD3<Float>(repeating: -.infinity)
        for mesh in meshes {
            try Task.checkCancellation()
            guard mesh.vertexCount >= 0 else { throw OBJPreviewError.invalidMesh }
            guard mesh.vertexCount <= maximumVertices - positions.count / 3 else { throw OBJPreviewError.limit }
            guard let vertices = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
                  vertices.stride >= 12,
                  mesh.vertexCount == 0 || (vertices.bufferSize >= 12 && (mesh.vertexCount - 1) <= (vertices.bufferSize - 12) / vertices.stride) else {
                throw OBJPreviewError.invalidMesh
            }
            let firstIndex = UInt32(positions.count / 3)
            let transform = MDLTransform.globalTransform(with: mesh, atTime: 0)
            for index in 0..<mesh.vertexCount {
                if index % 4_096 == 0 { try Task.checkCancellation() }
                let offset = index * vertices.stride
                let x = vertices.dataStart.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = vertices.dataStart.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                let z = vertices.dataStart.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                let transformed = transform * SIMD4<Float>(x, y, z, 1)
                let point = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                      abs(point.x) <= 1_000_000, abs(point.y) <= 1_000_000, abs(point.z) <= 1_000_000 else {
                    throw OBJPreviewError.invalidMesh
                }
                positions.append(contentsOf: [point.x, point.y, point.z])
                for component in 0..<3 {
                    minimum[component] = min(minimum[component], point[component])
                    maximum[component] = max(maximum[component], point[component])
                }
            }
            let submeshes = mesh.submeshes?.compactMap { $0 as? MDLSubmesh } ?? []
            for submesh in submeshes {
                guard submesh.geometryType == .triangles, submesh.indexCount.isMultiple(of: 3) else {
                    throw OBJPreviewError.unsupportedFaces
                }
                guard submesh.indexCount / 3 <= maximumTriangles - indices.count / 3 else { throw OBJPreviewError.limit }
                let indexWidth: Int
                switch submesh.indexType {
                case .uInt8: indexWidth = 1
                case .uInt16: indexWidth = 2
                case .uInt32: indexWidth = 4
                default: throw OBJPreviewError.invalidMesh
                }
                guard submesh.indexCount >= 0,
                      submesh.indexCount <= submesh.indexBuffer.length / indexWidth else { throw OBJPreviewError.invalidMesh }
                let mapped = submesh.indexBuffer.map()
                for index in 0..<submesh.indexCount {
                    if index % 12_288 == 0 { try Task.checkCancellation() }
                    let local: UInt32
                    switch submesh.indexType {
                    case .uInt8: local = UInt32(mapped.bytes.loadUnaligned(fromByteOffset: index, as: UInt8.self))
                    case .uInt16: local = UInt32(mapped.bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
                    case .uInt32: local = mapped.bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    default: throw OBJPreviewError.invalidMesh
                    }
                    guard Int(local) < mesh.vertexCount else { throw OBJPreviewError.invalidMesh }
                    indices.append(firstIndex + local)
                }
            }
        }
        guard !positions.isEmpty, !indices.isEmpty else { throw OBJPreviewError.noGeometry }
        return try makePayload(positions: positions, indices: indices, minimum: minimum,
                               maximum: maximum, isAtlasCapture: false)
    }
    #endif

}


/// Navigation stays within a model's bounding box. This is free exploration,
/// not collision detection or a reconstructed floor/navigation mesh.
struct MeshNavigationBounds: Sendable {
    let halfExtent: SIMD3<Float>
    let diagonal: Float

    init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        halfExtent = (maximum - minimum) / 2
        diagonal = max(0.1, sqrt(4 * (halfExtent.x * halfExtent.x + halfExtent.y * halfExtent.y + halfExtent.z * halfExtent.z)))
    }

    var initialWalkPosition: SIMD3<Float> {
        clamped(SIMD3<Float>(halfExtent.x * 0.22, -halfExtent.y + min(1.6, halfExtent.y * 1.2), halfExtent.z * 0.35))
    }

    /// A bounding sphere fits both view axes, including narrow portrait
    /// windows. A diagonal multiplier alone can crop the model on an iPhone.
    func fittedOrbitDistance(viewportAspect: Float, verticalFieldOfView: Float = 60) -> Float {
        let aspect = min(10, max(0.1, viewportAspect))
        let vertical = min(150, max(10, verticalFieldOfView)) * .pi / 360
        let horizontal = atan(tan(vertical) * aspect)
        let limitingAngle = min(vertical, horizontal)
        return diagonal * 0.5 / sin(limitingAngle) * 1.12
    }

    /// SceneKit cameras look along local -Z. The matching native quaternion
    /// applies yaw about world Y and then pitch about the camera's local X.
    static func cameraForward(yaw: Float, pitch: Float) -> SIMD3<Float> {
        SIMD3<Float>(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    }

    func clamped(_ position: SIMD3<Float>) -> SIMD3<Float> {
        var result = position
        for axis in 0..<3 {
            let limit = max(0, halfExtent[axis] - min(0.05, halfExtent[axis] * 0.04))
            result[axis] = min(limit, max(-limit, position[axis]))
        }
        return result
    }

    func moved(_ position: SIMD3<Float>, forward: Float, sideways: Float, vertical: Float,
               yaw: Float, distance: Float) -> SIMD3<Float> {
        let movement = SIMD3<Float>(-sin(yaw) * forward + cos(yaw) * sideways,
                                    vertical, -cos(yaw) * forward - sin(yaw) * sideways)
        return clamped(position + movement * distance)
    }
}
