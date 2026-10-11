import Foundation

enum MeshExportFormat: String, CaseIterable, Identifiable, Sendable {
    case stl, ply, glb
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }
}

enum MeshExportSourceUnit: Sendable {
    case meters, unknown
    var metadata: String { self == .meters ? "metres" : "unknown (source units)" }
}

enum MeshExportError: LocalizedError {
    case invalidBuffers, invalidDestination, unknownUnitForGLB
    var errorDescription: String? {
        switch self {
        case .invalidBuffers: "Сетка содержит некорректные вершины, нормали или индексы. Исходник сохранён."
        case .invalidDestination: "Не удалось создать файл экспорта. Проверьте свободное место."
        case .unknownUnitForGLB: "GLB использует метры. У исходной модели неизвестный масштаб: укажите единицы и приведите координаты к метрам либо выберите STL или PLY."
        }
    }
}

/// Exports bounded triangles in the source local frame without inventing textures.
/// Native captures are in metres; arbitrary OBJ coordinates have unknown units.
/// An explicit `.meters` override means the caller has established metre units;
/// this exporter never guesses a scale or rescales geometry.
/// Call from a utility task: decoding and file IO must stay away from the UI.
enum MeshExportService {
    static func export(source: URL, format: MeshExportFormat, outputDirectory: URL,
                       sourceUnit: MeshExportSourceUnit? = nil) throws -> URL {
        try Task.checkCancellation()
        let mesh = try OBJPreviewLoader.load(source)
        let bounds = try validate(mesh)
        let unit = sourceUnit ?? (mesh.isAtlasCapture || source.lastPathComponent == "room.usdz" || source.lastPathComponent == "object.usdz" ? .meters : .unknown)
        guard format != .glb || unit == .meters else { throw MeshExportError.unknownUnitForGLB }
        guard outputDirectory.isFileURL else { throw MeshExportError.invalidDestination }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let temporary = outputDirectory.appendingPathComponent(".TerraView-mesh-\(identifier).tmp")
        let result = outputDirectory.appendingPathComponent("TerraView-model-\(identifier).\(format.fileExtension)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw MeshExportError.invalidDestination }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: temporary) } }
        let sink = try MeshByteSink(url: temporary)
        do {
            try mesh.positions.withUnsafeBytes { positions in
                try mesh.normals.withUnsafeBytes { normals in
                    try mesh.indices.withUnsafeBytes { indices in
                        switch format {
                        case .stl: try writeSTL(mesh, unit: unit, positions: positions, indices: indices, sink: sink)
                        case .ply: try writePLY(mesh, unit: unit, positions: positions, normals: normals, indices: indices, sink: sink)
                        case .glb: try writeGLB(mesh, bounds: bounds, positions: positions, normals: normals, indices: indices, sink: sink)
                        }
                    }
                }
            }
            try sink.finish()
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: result)
            completed = true
            return result
        } catch {
            sink.cancel()
            throw error
        }
    }

    private static func validate(_ mesh: OBJPreviewPayload) throws -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        guard mesh.vertexCount > 0, mesh.vertexCount <= OBJPreviewLoader.maximumRenderVertices,
              mesh.triangleCount > 0, mesh.triangleCount <= OBJPreviewLoader.maximumTriangles,
              mesh.vertexCount == mesh.triangleCount * 3,
              mesh.positions.count == mesh.vertexCount * 12,
              mesh.normals.count == mesh.vertexCount * 12,
              mesh.indices.count == mesh.triangleCount * 12 else { throw MeshExportError.invalidBuffers }
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        try mesh.positions.withUnsafeBytes { positions in
            try mesh.normals.withUnsafeBytes { normals in
                try mesh.indices.withUnsafeBytes { indices in
                    for vertex in 0..<mesh.vertexCount {
                        if vertex % 4096 == 0 { try Task.checkCancellation() }
                        guard Int(indices.loadUnaligned(fromByteOffset: vertex * 4, as: UInt32.self)) < mesh.vertexCount else { throw MeshExportError.invalidBuffers }
                        for component in 0..<3 {
                            let p = positions.loadUnaligned(fromByteOffset: vertex * 12 + component * 4, as: Float.self)
                            let n = normals.loadUnaligned(fromByteOffset: vertex * 12 + component * 4, as: Float.self)
                            guard p.isFinite, abs(p) <= 1_000_000, n.isFinite else { throw MeshExportError.invalidBuffers }
                            minimum[component] = min(minimum[component], p)
                            maximum[component] = max(maximum[component], p)
                        }
                    }
                }
            }
        }
        return (minimum, maximum)
    }

    private static func writeSTL(_ mesh: OBJPreviewPayload, unit: MeshExportSourceUnit, positions: UnsafeRawBufferPointer,
                                 indices: UnsafeRawBufferPointer, sink: MeshByteSink) throws {
        var header = Data("TerraView binary STL; units=\(unit.metadata); source local frame".utf8)
        header.append(Data(repeating: 0, count: 80 - header.count))
        try sink.bytes(header); try sink.uint32(UInt32(mesh.triangleCount))
        for face in 0..<mesh.triangleCount {
            if face % 4096 == 0 { try Task.checkCancellation() }
            func point(_ corner: Int) -> SIMD3<Double> {
                let index = Int(indices.loadUnaligned(fromByteOffset: (face * 3 + corner) * 4, as: UInt32.self))
                return SIMD3<Double>(Double(positions.loadUnaligned(fromByteOffset: index * 12, as: Float.self)),
                                     Double(positions.loadUnaligned(fromByteOffset: index * 12 + 4, as: Float.self)),
                                     Double(positions.loadUnaligned(fromByteOffset: index * 12 + 8, as: Float.self)))
            }
            let a = point(0), b = point(1), c = point(2)
            let u = b - a, v = c - a
            let cross = SIMD3<Double>(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
            let length = sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
            for component in 0..<3 { try sink.float(length > 0 ? Float(cross[component] / length) : 0) }
            for vertex in [a, b, c] { for component in 0..<3 { try sink.float(Float(vertex[component])) } }
            try sink.uint16(0)
        }
    }

    private static func writePLY(_ mesh: OBJPreviewPayload, unit: MeshExportSourceUnit, positions: UnsafeRawBufferPointer,
                                 normals: UnsafeRawBufferPointer, indices: UnsafeRawBufferPointer, sink: MeshByteSink) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment TerraView; units=\(unit.metadata); source local frame
        element vertex \(mesh.vertexCount)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        element face \(mesh.triangleCount)
        property list uchar uint vertex_indices
        end_header

        """
        try sink.bytes(Data(header.utf8))
        for vertex in 0..<mesh.vertexCount {
            if vertex % 4096 == 0 { try Task.checkCancellation() }
            for buffer in [positions, normals] {
                for component in 0..<3 { try sink.float(buffer.loadUnaligned(fromByteOffset: vertex * 12 + component * 4, as: Float.self)) }
            }
        }
        for face in 0..<mesh.triangleCount {
            if face % 4096 == 0 { try Task.checkCancellation() }
            try sink.byte(3)
            for corner in 0..<3 { try sink.uint32(indices.loadUnaligned(fromByteOffset: (face * 3 + corner) * 4, as: UInt32.self)) }
        }
    }

    private static func writeGLB(_ mesh: OBJPreviewPayload, bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>), positions: UnsafeRawBufferPointer,
                                 normals: UnsafeRawBufferPointer, indices: UnsafeRawBufferPointer, sink: MeshByteSink) throws {
        let positionBytes = mesh.positions.count, normalBytes = mesh.normals.count, indexBytes = mesh.indices.count
        let binaryBytes = positionBytes + normalBytes + indexBytes
        let document: [String: Any] = [
            "asset": ["version": "2.0", "generator": "TerraView", "extras": ["units": "metres", "coordinateFrame": "source local frame"]],
            "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0, "NORMAL": 1], "indices": 2, "mode": 4]]]],
            "buffers": [["byteLength": binaryBytes]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": positionBytes, "target": 34962],
                            ["buffer": 0, "byteOffset": positionBytes, "byteLength": normalBytes, "target": 34962],
                            ["buffer": 0, "byteOffset": positionBytes + normalBytes, "byteLength": indexBytes, "target": 34963]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": mesh.vertexCount, "type": "VEC3", "min": [bounds.minimum.x, bounds.minimum.y, bounds.minimum.z], "max": [bounds.maximum.x, bounds.maximum.y, bounds.maximum.z]],
                          ["bufferView": 1, "componentType": 5126, "count": mesh.vertexCount, "type": "VEC3"],
                          ["bufferView": 2, "componentType": 5125, "count": mesh.vertexCount, "type": "SCALAR"]]
        ]
        var json = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        while !json.count.isMultiple(of: 4) { json.append(0x20) }
        let total = 12 + 8 + json.count + 8 + binaryBytes
        guard total <= Int(UInt32.max) else { throw MeshExportError.invalidBuffers }
        try sink.uint32(0x46546C67); try sink.uint32(2); try sink.uint32(UInt32(total))
        try sink.uint32(UInt32(json.count)); try sink.uint32(0x4E4F534A); try sink.bytes(json)
        try sink.uint32(UInt32(binaryBytes)); try sink.uint32(0x004E4942)
        // Apple targets are little endian. Stream their already validated buffers
        // directly, rather than allocating an output copy of the entire mesh.
        if UInt32(1).littleEndian == 1 {
            for buffer in [positions, normals, indices] { try sink.rawChunks(buffer) }
            return
        }
        for buffer in [positions, normals] {
            for component in 0..<(buffer.count / 4) {
                if component % 12_288 == 0 { try Task.checkCancellation() }
                try sink.float(buffer.loadUnaligned(fromByteOffset: component * 4, as: Float.self))
            }
        }
        for index in 0..<(indices.count / 4) {
            if index % 12_288 == 0 { try Task.checkCancellation() }
            try sink.uint32(indices.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
        }
    }
}

private final class MeshByteSink {
    private let handle: FileHandle
    private var buffer = Data()
    private var closed = false
    init(url: URL) throws { handle = try FileHandle(forWritingTo: url); buffer.reserveCapacity(65_536) }
    func bytes(_ value: Data) throws { buffer.append(value); if buffer.count >= 65_536 { try flush() } }
    func byte(_ value: UInt8) throws { buffer.append(value); if buffer.count >= 65_536 { try flush() } }
    func uint16(_ value: UInt16) throws { var value = value.littleEndian; try withUnsafeBytes(of: &value) { try append($0) } }
    func uint32(_ value: UInt32) throws { var value = value.littleEndian; try withUnsafeBytes(of: &value) { try append($0) } }
    func float(_ value: Float) throws { try uint32(value.bitPattern) }
    func rawChunks(_ value: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < value.count {
            try Task.checkCancellation()
            let end = min(offset + 65_536, value.count)
            try append(UnsafeRawBufferPointer(rebasing: value[offset..<end]))
            offset = end
        }
    }
    private func append(_ value: UnsafeRawBufferPointer) throws {
        buffer.append(contentsOf: value)
        if buffer.count >= 65_536 { try flush() }
    }
    private func flush() throws { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
    func finish() throws { try flush(); try handle.synchronize(); try handle.close(); closed = true }
    func cancel() { if !closed { try? handle.close(); closed = true } }
    deinit { cancel() }
}
