import Foundation
import AtlasCore

struct FragmentAssemblyExportResult: Sendable {
    let meshURL: URL
    let reportURL: URL
    let vertexCount: Int
    let triangleCount: Int
    var urls: [URL] { [meshURL, reportURL] }
}

struct FragmentMeshAssemblyReport: Codable, Sendable {
    let schemaVersion: Int
    let projectID: UUID
    let projectFrameID: UUID
    let createdAt: Date
    let timestampEncoding: String
    let sourceDocumentSHA256: String
    let selectedCaptureIDs: [UUID]
    let sourceBindings: [FragmentAssemblySourceBinding]
    let registry: FragmentRegistrationRegistry
    let readiness: FragmentAssemblyReadiness
    let derivative: Derivative
    let limitations: [String]
    struct Derivative: Codable, Sendable {
        let filename: String
        let sha256: String
        let byteCount: Int64
        let vertexCount: Int
        let normalCount: Int
        let triangleCount: Int
        let unit: String
        let transformConvention: String
    }
}

/// Produces one bounded geometry-only OBJ in the anchor's ORIGINAL local frame.
/// Each original is verified before and after reading; its bytes remain unchanged.
/// Vertices shared within one original are deduplicated; coincident triangles
/// BETWEEN originals are deliberately retained and reported, never invented as fused.
enum FragmentMeshAssemblyExporter {
    static let maximumBytes = 64 * 1_024 * 1_024
    static let maximumVertices = OBJPreviewLoader.maximumVertices
    static let maximumTriangles = OBJPreviewLoader.maximumTriangles
    private struct PositionKey: Hashable { let x: UInt32; let y: UInt32; let z: UInt32 }
    private struct NormalKey: Hashable { let x: UInt32; let y: UInt32; let z: UInt32 }
    static func export(document: FragmentAssemblyDocument, assetDirectory: URL, outputDirectory: URL,
                       selectedCaptureIDs: Set<UUID>? = nil) throws -> FragmentAssemblyExportResult {
        try document.validate(); try Task.checkCancellation()
        let selected = selectedCaptureIDs ?? Set(document.sourceBindings.map { $0.source.captureID })
        guard !selected.isEmpty, selected.isSubset(of: Set(document.sourceBindings.map { $0.source.captureID })) else { throw FragmentAssemblyError.invalidDocument }
        let readiness = try document.registry.assemblyReadiness()
        let placements = readiness.placements.filter { selected.contains($0.source.captureID) }
        guard placements.count == selected.count, placements.allSatisfy({ $0.status == .registered && $0.transformToProject != nil }) else {
            throw FragmentAssemblyError.unresolved
        }
        let bindings = document.sourceBindings.filter { selected.contains($0.source.captureID) }
        for binding in bindings { _ = try FragmentAssemblySourceVerifier.verify(binding, projectID: document.projectID, root: assetDirectory) }
        let destination = try prepareOutput(outputDirectory, outside: assetDirectory)
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".terraview-assembly-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }
        let mesh = staging.appendingPathComponent("aligned-fragments.obj")
        guard FileManager.default.createFile(atPath: mesh.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: mesh)
        var closed = false
        defer { if !closed { try? handle.close() } }
        var pending = "", writtenBytes = 0, vertexCount = 0, normalCount = 0, triangleCount = 0
        func flush() throws {
            guard !pending.isEmpty else { return }
            let data = Data(pending.utf8)
            guard data.count <= maximumBytes - writtenBytes else { throw FragmentAssemblyError.limit }
            try handle.write(contentsOf: data); writtenBytes += data.count; pending.removeAll(keepingCapacity: true)
        }
        func append(_ line: String) throws {
            pending += line
            if pending.utf8.count >= 65_536 { try flush() }
        }
        try append("# TerraView aligned fragment derivative. metres. Y up. local frame \(document.registry.projectFrameID.uuidString)\n")
        try append("# Proper rigid transforms only. Geometry retained; no textures, overlap fusion or watertight reconstruction.\n")
        try append("# source-document-sha256 \(document.currentSHA256)\n")
        for binding in bindings {
            try Task.checkCancellation()
            let source = try FragmentAssemblySourceVerifier.verify(binding, projectID: document.projectID, root: assetDirectory)
            let placement = placements.first { $0.source == binding.source }!
            let transform = placement.transformToProject!; try transform.validate()
            let payload = try OBJPreviewLoader.load(source)
            guard payload.isAtlasCapture, payload.positions.count == payload.vertexCount * 12,
                  payload.normals.count == payload.vertexCount * 12, payload.indices.count == payload.triangleCount * 12,
                  payload.triangleCount <= maximumTriangles - triangleCount else { throw FragmentAssemblyError.limit }
            try append("g fragment_\(binding.source.captureID.uuidString)\n# source-sha256 \(binding.source.sourceSHA256)\n")
            var positions: [PositionKey: Int] = [:], normals: [NormalKey: Int] = [:]
            var positionRemap = [Int](repeating: 0, count: payload.vertexCount), normalRemap = [Int](repeating: 0, count: payload.vertexCount)
            // One fragment's bounded payload and lookup tables live at a time.
            try payload.positions.withUnsafeBytes { bytes in
                for index in 0..<payload.vertexCount {
                    if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
                    let x = bytes.loadUnaligned(fromByteOffset: index * 12, as: Float.self)
                    let y = bytes.loadUnaligned(fromByteOffset: index * 12 + 4, as: Float.self)
                    let z = bytes.loadUnaligned(fromByteOffset: index * 12 + 8, as: Float.self)
                    let key = PositionKey(x: x == 0 ? 0 : x.bitPattern, y: y == 0 ? 0 : y.bitPattern, z: z == 0 ? 0 : z.bitPattern)
                    if let existing = positions[key] { positionRemap[index] = existing }
                    else {
                        guard vertexCount < maximumVertices else { throw FragmentAssemblyError.limit }
                        let point = try transform.applying(to: .init(x: Double(x), y: Double(y), z: Double(z)))
                        vertexCount += 1; positions[key] = vertexCount; positionRemap[index] = vertexCount
                        try append("v \(point.x) \(point.y) \(point.z)\n")
                    }
                }
            }
            try payload.normals.withUnsafeBytes { bytes in
                for index in 0..<payload.vertexCount {
                    if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
                    let x = bytes.loadUnaligned(fromByteOffset: index * 12, as: Float.self)
                    let y = bytes.loadUnaligned(fromByteOffset: index * 12 + 4, as: Float.self)
                    let z = bytes.loadUnaligned(fromByteOffset: index * 12 + 8, as: Float.self)
                    let key = NormalKey(x: x == 0 ? 0 : x.bitPattern, y: y == 0 ? 0 : y.bitPattern, z: z == 0 ? 0 : z.bitPattern)
                    if let existing = normals[key] { normalRemap[index] = existing }
                    else {
                        guard normalCount < maximumTriangles else { throw FragmentAssemblyError.limit }
                        let r = transform.rotation
                        let nx = r[0] * Double(x) + r[1] * Double(y) + r[2] * Double(z)
                        let ny = r[3] * Double(x) + r[4] * Double(y) + r[5] * Double(z)
                        let nz = r[6] * Double(x) + r[7] * Double(y) + r[8] * Double(z)
                        let length = sqrt(nx * nx + ny * ny + nz * nz)
                        guard length.isFinite, length > 0 else { throw FragmentAssemblyError.invalidDocument }
                        normalCount += 1; normals[key] = normalCount; normalRemap[index] = normalCount
                        try append("vn \(nx / length) \(ny / length) \(nz / length)\n")
                    }
                }
            }
            try payload.indices.withUnsafeBytes { bytes in
                for triangle in 0..<payload.triangleCount {
                    if triangle.isMultiple(of: 4_096) { try Task.checkCancellation() }
                    let indices = (0..<3).map { Int(bytes.loadUnaligned(fromByteOffset: triangle * 12 + $0 * 4, as: UInt32.self)) }
                    guard indices.allSatisfy({ $0 >= 0 && $0 < positionRemap.count }) else { throw FragmentAssemblyError.invalidDocument }
                    let a = indices[0], b = indices[1], c = indices[2]
                    try append("f \(positionRemap[a])//\(normalRemap[a]) \(positionRemap[b])//\(normalRemap[b]) \(positionRemap[c])//\(normalRemap[c])\n")
                }
            }
            triangleCount += payload.triangleCount
            _ = try FragmentAssemblySourceVerifier.verify(binding, projectID: document.projectID, root: assetDirectory)
        }
        guard vertexCount > 0, triangleCount > 0 else { throw FragmentAssemblyError.invalidDocument }
        try flush(); try handle.synchronize(); try handle.close(); closed = true
        let sha = try FragmentAssemblySourceVerifier.hashFile(mesh)
        let report = FragmentMeshAssemblyReport(schemaVersion: 1, projectID: document.projectID, projectFrameID: document.registry.projectFrameID,
            createdAt: Date(), timestampEncoding: "secondsSince2001UTC", sourceDocumentSHA256: document.currentSHA256,
            selectedCaptureIDs: bindings.map { $0.source.captureID }, sourceBindings: bindings, registry: document.registry, readiness: readiness,
            derivative: .init(filename: mesh.lastPathComponent, sha256: sha, byteCount: Int64(writtenBytes), vertexCount: vertexCount,
                normalCount: normalCount, triangleCount: triangleCount, unit: "m", transformConvention: "target=R*source+t; rotation row-major"),
            limitations: ["Original source files are unchanged and retained separately.",
                "Overlapping triangles between captures remain present; no surface fusion, texture fusion or watertight reconstruction is claimed.",
                "Control and held-out residual thresholds qualify registrations; they do not prove accuracy throughout a large site.",
                "This bounded OBJ is a geometry-only aligned derivative in the anchor's local frame, not a georeferenced orthophoto.",
                "Unselected, disconnected and ambiguous fragments remain described in the readiness report; they are not silently forced into this derivative."])
        let reportURL = staging.appendingPathComponent("assembly-report.json")
        let reportBytes = try FragmentAssemblyDocument.canonical(report)
        guard reportBytes.count <= FragmentAssemblyStore.maximumBytes else { throw FragmentAssemblyError.limit }
        try reportBytes.write(to: reportURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try Task.checkCancellation()
        for binding in bindings { _ = try FragmentAssemblySourceVerifier.verify(binding, projectID: document.projectID, root: assetDirectory) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw FragmentAssemblyError.existingOutput }
        try FileManager.default.moveItem(at: staging, to: destination); committed = true
        return .init(meshURL: destination.appendingPathComponent(mesh.lastPathComponent),
                     reportURL: destination.appendingPathComponent(reportURL.lastPathComponent), vertexCount: vertexCount, triangleCount: triangleCount)
    }
    private static func prepareOutput(_ output: URL, outside root: URL) throws -> URL {
        guard output.isFileURL, root.isFileURL else { throw FragmentAssemblyError.invalidPath }
        let destination = output.standardizedFileURL
        let source = root.standardizedFileURL.resolvingSymlinksInPath()
        guard destination.path != source.path, !destination.resolvingSymlinksInPath().path.hasPrefix(source.path + "/") else { throw FragmentAssemblyError.invalidPath }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw FragmentAssemblyError.existingOutput }
        let parent = destination.deletingLastPathComponent()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path else { throw FragmentAssemblyError.invalidPath }
        return destination
    }
}
