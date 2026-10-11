import Foundation
@preconcurrency import RoomPlan
import AtlasCore
import simd

/// Native RoomPlan values stay on the executor that decoded them. Only this
/// Codable/Sendable sidecar and bytes leave that executor.
enum EmptyRoomNativeDocument {
    static func make(room: CapturedRoom, source: Data, captureID: UUID, projectID: UUID,
                     frameID: UUID, capturedAt: Date, keepStorage: Bool) throws -> EmptyRoomDocument {
        func confidence(_ value: CapturedRoom.Confidence) -> EmptyRoomConfidence {
            switch value { case .high: .high; case .medium: .medium; case .low: .low; @unknown default: .unknown }
        }
        func matrix(_ value: simd_float4x4) -> EmptyRoomTransform {
            .init(columns: (0..<4).flatMap { column in (0..<4).map { Double(value[column][$0]) } })
        }
        func positive(_ value: Float) -> Double? { value.isFinite && value > 0 ? Double(value) : nil }
        func surface(_ value: CapturedRoom.Surface, kind: EmptyRoomSurfaceKind) -> EmptyRoomSurface {
            .init(id: value.identifier, parentID: value.parentIdentifier, kind: kind,
                  widthMeters: positive(value.dimensions.x), heightMeters: positive(value.dimensions.y),
                  thicknessMeters: positive(value.dimensions.z), transform: matrix(value.transform),
                  polygonCorners: value.polygonCorners.map { .init(x: Double($0.x), y: Double($0.y), z: Double($0.z)) },
                  isCurved: value.curve != nil, confidence: confidence(value.confidence))
        }
        let surfaces = room.walls.map { surface($0, kind: .wall) }
            + room.floors.map { surface($0, kind: .floor) }
            + room.windows.map { surface($0, kind: .window) }
            + room.doors.map { surface($0, kind: .door) }
            + room.openings.map { surface($0, kind: .opening) }
        guard surfaces.allSatisfy({ $0.transform.isValid && $0.polygonCorners.allSatisfy(\.isFinite) }),
              Set(surfaces.map(\.id)).count == surfaces.count else { throw EmptyRoomError.invalidGeometry }
        let objects = keepStorage ? room.objects.filter { $0.category == .storage } : []
        let storage = objects.map { object in
            EmptyRoomStorage(id: object.identifier, widthMeters: positive(object.dimensions.x),
                heightMeters: positive(object.dimensions.y), depthMeters: positive(object.dimensions.z),
                transform: matrix(object.transform), confidence: confidence(object.confidence))
        }
        guard storage.allSatisfy({ $0.transform.isValid }) else { throw EmptyRoomError.invalidGeometry }
        return .init(sourceRoomID: room.identifier, captureID: captureID, projectID: projectID, frameID: frameID,
                     capturedAt: capturedAt, sourceRoomJSONSHA256: FieldTransferDigest.sha256(source), story: room.story,
                     keepStorage: keepStorage, removedObjectCount: room.objects.count - objects.count,
                     surfaces: surfaces, storage: storage,
                     notices: ["Семантический черновик RoomPlan: проверьте размеры контрольным обмером и исправьте план вручную.",
                        "Закрытые мебелью стены могут быть восстановлены алгоритмом. Видимые в модели поверхности не гарантируют прямое наблюдение каждой точки.",
                        "Уверенность относится к классификации RoomPlan, а не к точности в сантиметрах.",
                        "Потолок не наблюдён: потолок и крыша не создаются. Высота каждой стены указана отдельно, общей высоты помещения не заявляем.",
                        "Категория storage не определяет, является ли шкаф встроенным. Оставленные шкафы требуют проверки.",
                        "Криволинейная стена: подписан габарит, а не длина дуги. Геометрия сохранена в исходном RoomPlan/USDZ.",
                        "Модель в собственных локальных метрах. Геометка устройства не совмещает разные комнаты или этажи."])
    }
}

/// Writes the actual triangulated native USDZ geometry as OBJ; no wall boxes,
/// guessed floors or fabricated ceiling are substituted for the native model.
enum EmptyRoomOBJWriter {
    private struct VertexKey: Hashable { var x: UInt32; var y: UInt32; var z: UInt32 }
    static func write(_ mesh: OBJPreviewPayload, to url: URL, frameID: UUID) throws {
        guard mesh.positions.count == mesh.vertexCount * 12,
              mesh.indices.count == mesh.triangleCount * 12 else { throw EmptyRoomError.invalidGeometry }
        var lookup: [VertexKey: UInt32] = [:]
        var vertices: [SIMD3<Float>] = []
        var remap: [UInt32] = []
        remap.reserveCapacity(mesh.vertexCount)
        try mesh.positions.withUnsafeBytes { bytes in
            for i in 0..<mesh.vertexCount {
                if i.isMultiple(of: 4096) { try Task.checkCancellation() }
                let x = bytes.loadUnaligned(fromByteOffset: i * 12, as: Float.self)
                let y = bytes.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float.self)
                let z = bytes.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float.self)
                guard x.isFinite, y.isFinite, z.isFinite else { throw EmptyRoomError.invalidGeometry }
                let key = VertexKey(x: x == 0 ? 0 : x.bitPattern, y: y == 0 ? 0 : y.bitPattern, z: z == 0 ? 0 : z.bitPattern)
                if let existing = lookup[key] { remap.append(existing) }
                else {
                    guard vertices.count < OBJPreviewLoader.maximumVertices else { throw OBJPreviewError.limit }
                    let index = UInt32(vertices.count)
                    lookup[key] = index; vertices.append(SIMD3(x, y, z)); remap.append(index)
                }
            }
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var chunk = "# TerraView RoomPlan semantic draft. metres. Y up. local frame \(frameID.uuidString)\n# Native polygonal RoomPlan surfaces; independently verify dimensions. Ceiling not inferred.\n"
        func append(_ line: String) throws {
            chunk += line
            if chunk.utf8.count >= 65_536 { try handle.write(contentsOf: Data(chunk.utf8)); chunk.removeAll(keepingCapacity: true) }
        }
        for vertex in vertices { try append("v \(vertex.x) \(vertex.y) \(vertex.z)\n") }
        try mesh.indices.withUnsafeBytes { bytes in
            for triangle in 0..<mesh.triangleCount {
                if triangle.isMultiple(of: 4096) { try Task.checkCancellation() }
                let indices = (0..<3).map { bytes.loadUnaligned(fromByteOffset: triangle * 12 + $0 * 4, as: UInt32.self) }
                guard indices.allSatisfy({ Int($0) < remap.count }) else { throw EmptyRoomError.invalidGeometry }
                try append("f \(remap[Int(indices[0])] + 1) \(remap[Int(indices[1])] + 1) \(remap[Int(indices[2])] + 1)\n")
            }
        }
        if !chunk.isEmpty { try handle.write(contentsOf: Data(chunk.utf8)) }
        try handle.synchronize()
    }
}
