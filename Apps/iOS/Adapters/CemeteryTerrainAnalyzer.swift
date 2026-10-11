import Foundation
import AtlasCore

/// Reads real, atomically committed ARKit checkpoint meshes. Different AR
/// segments are selectable independently and are never implicitly welded.
actor CemeteryTerrainAnalyzer {
    struct SourceFrame: Identifiable, Sendable {
        var frameID: UUID
        var captureID: UUID
        var segmentID: UUID
        var createdAt: Date
        var meshDirectory: URL
        var id: UUID { frameID }
    }
    private struct Manifest: Decodable {
        var id: UUID
        var projectID: UUID
        var createdAt: Date
        var source: String
        var segments: [Segment]
        struct Segment: Decodable { var id: UUID; var frameID: UUID }
    }
    private struct Checkpoint: Decodable, Sendable {
        var anchorID: UUID
        var segmentID: UUID
        var vertexCount: Int
        var triangleCount: Int
        var positions: Data
        var indices: Data
        var classifications: Data?
    }

    func availableFrames(directory: URL, projectID: UUID) throws -> [SourceFrame] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("lidar-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(512)
        var results = [SourceFrame]()
        var seenFrames = Set<UUID>()
        for folder in folders {
            guard safe(folder, inside: directory) else { continue }
            let url = folder.appendingPathComponent("manifest.json")
            guard safe(url, inside: directory), let data = try? boundedData(url, maximumBytes: 2_097_152),
                  let manifest = try? decoder().decode(Manifest.self, from: data), manifest.projectID == projectID,
                  manifest.source == "ARKit.sceneReconstruction" else { continue }
            for segment in manifest.segments.prefix(128) {
                guard seenFrames.insert(segment.frameID).inserted else { throw TerrainSurveyError.frameMismatch }
                let meshDirectory = folder.appendingPathComponent("segments/\(segment.id.uuidString)/meshes", isDirectory: true)
                guard safe(meshDirectory, inside: directory), FileManager.default.fileExists(atPath: meshDirectory.path) else { continue }
                results.append(.init(frameID: segment.frameID,captureID:manifest.id,segmentID:segment.id,createdAt:manifest.createdAt,meshDirectory:meshDirectory))
            }
        }
        return results.sorted { $0.createdAt > $1.createdAt }
    }

    func framesForSavedCapture(manifestURL: URL, directory: URL, projectID: UUID) throws -> [SourceFrame] {
        guard safe(manifestURL,inside:directory), manifestURL.lastPathComponent == "manifest.json" else { throw TerrainSurveyError.invalidData }
        let manifest = try decoder().decode(Manifest.self,from:boundedData(manifestURL,maximumBytes:2_097_152))
        guard manifest.projectID == projectID, manifest.source == "ARKit.sceneReconstruction" else { throw TerrainSurveyError.frameMismatch }
        let all = try availableFrames(directory:directory,projectID:projectID)
        return manifest.segments.compactMap { segment in all.first { $0.captureID == manifest.id && $0.segmentID == segment.id && $0.frameID == segment.frameID } }
    }

    func analyze(frame: SourceFrame, project: AtlasProject, cemetery: AtlasFeature, directory: URL, previous: TerrainSurvey?) throws -> TerrainSurvey {
        guard cemetery.projectID == project.id, safe(frame.meshDirectory, inside: directory) else { throw TerrainSurveyError.invalidData }
        let files = try FileManager.default.contentsOfDirectory(at: frame.meshDirectory, includingPropertiesForKeys: [.fileSizeKey,.isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasSuffix(".mesh.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 512 else { throw TerrainSurveyError.invalidData }
        var batches = [TerrainMeshBatch]()
        var fenceTriangles = [FenceTriangle]()
        var vegetationTriangles = [FenceTriangle]()
        let groundBudget = max(12,min(4_000,100_000/max(1,files.count)/4))
        let fenceBudget = max(1,20_000/max(1,files.count))
        for file in files {
            try Task.checkCancellation()
            guard safe(file, inside: directory) else { throw TerrainSurveyError.invalidData }
            let checkpoint = try decoder().decode(Checkpoint.self, from: boundedData(file, maximumBytes: 64*1_024*1_024))
            guard checkpoint.segmentID == frame.segmentID, checkpoint.vertexCount > 0, checkpoint.vertexCount <= 500_000,
                  checkpoint.triangleCount > 0, checkpoint.triangleCount <= 1_000_000,
                  checkpoint.positions.count == checkpoint.vertexCount*12, checkpoint.indices.count == checkpoint.triangleCount*12,
                  checkpoint.classifications == nil || checkpoint.classifications?.count == checkpoint.triangleCount else { throw TerrainSurveyError.invalidData }
            let points = try surfaceSamples(checkpoint,faceBudget:groundBudget)
            if !points.isEmpty { batches.append(.init(frameID:frame.frameID,anchorID:checkpoint.anchorID,captureID:frame.captureID,points:points)) }
            fenceTriangles.append(contentsOf:try verticalSamples(checkpoint,frameID:frame.frameID,faceBudget:fenceBudget))
            vegetationTriangles.append(contentsOf:try spatialSamples(checkpoint,frameID:frame.frameID,faceBudget:fenceBudget))
        }
        let proposals = try FenceDetection.proposals(from:fenceTriangles,frameID:frame.frameID)
        let vegetation = try VegetationDetection.proposals(from:vegetationTriangles,frameID:frame.frameID)
        var terrain:TerrainSurvey
        do { terrain = try TerrainAnalysis.analyze(batches,projectID:project.id,cemeteryID:cemetery.id,frameID:frame.frameID,previous:previous) }
        catch TerrainSurveyError.insufficientSurface {
            guard !proposals.isEmpty || !vegetation.isEmpty,previous == nil || (previous?.frameID == frame.frameID && previous?.projectID == project.id && previous?.cemeteryID == cemetery.id) else { throw TerrainSurveyError.insufficientSurface }
            terrain = TerrainSurvey(id:previous?.id ?? UUID(),projectID:project.id,cemeteryID:cemetery.id,frameID:frame.frameID,sourceCaptureIDs:[frame.captureID],
                referenceHeight:previous?.referenceHeight ?? 0,cells:[],candidates:previous?.candidates ?? [],registration:previous?.registration)
            if let previous { terrain.createdAt = previous.createdAt }
            terrain.warnings.append("Горизонтальная поверхность недостаточно измерена. Показаны отдельные измеренные конструкции и объёмные формы для проверки; рельеф земли не построен.")
        }
        if proposals.count == FenceDetection.maximumProposals { terrain.warnings.append("Достигнут предел предложений ограждений. Разделите большой участок на фрагменты.") }
        if vegetation.count == VegetationDetection.maximumProposals { terrain.warnings.append("Достигнут предел предложений деревьев и кустарников. Разделите большой участок на фрагменты.") }
        return try terrain.includingFenceProposals(proposals).includingVegetationProposals(vegetation)
    }

    func save(_ survey: TerrainSurvey, directory: URL) throws -> URL {
        try survey.validate()
        let folder = directory.appendingPathComponent("TerrainSurveys", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard safe(folder, inside: directory) else { throw TerrainSurveyError.invalidData }
        let url = folder.appendingPathComponent("\(survey.cemeteryID.uuidString)-\(survey.frameID.uuidString).terrain.json")
        guard safe(url,inside:directory) else { throw TerrainSurveyError.invalidData }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(survey).write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    func load(cemeteryID: UUID, frameID: UUID, projectID: UUID, directory: URL) throws -> TerrainSurvey? {
        let url = directory.appendingPathComponent("TerrainSurveys/\(cemeteryID.uuidString)-\(frameID.uuidString).terrain.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        guard safe(url, inside:directory) else { throw TerrainSurveyError.invalidData }
        let survey = try decoder().decode(TerrainSurvey.self,from:boundedData(url,maximumBytes:16*1_024*1_024))
        guard survey.projectID == projectID, survey.cemeteryID == cemeteryID, survey.frameID == frameID, survey.cells.count <= 20_000 else { throw TerrainSurveyError.frameMismatch }
        try survey.validate()
        return survey
    }

    private func decoder() -> JSONDecoder { let result = JSONDecoder(); result.dateDecodingStrategy = .iso8601; return result }
    private func safe(_ url: URL, inside root: URL) -> Bool {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        return true
    }
    private func boundedData(_ url: URL, maximumBytes: Int) throws -> Data {
        let bytes = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= maximumBytes else { throw TerrainSurveyError.invalidData }
        return try Data(contentsOf:url)
    }

    private func surfaceSamples(_ checkpoint: Checkpoint, faceBudget:Int = 4_000) throws -> [TerrainPoint] {
        var result = [TerrainPoint](); result.reserveCapacity(16_000)
        let step = max(1,Int(ceil(Double(checkpoint.triangleCount)/Double(max(1,faceBudget)))))
        return try checkpoint.positions.withUnsafeBytes { (vertices:UnsafeRawBufferPointer) -> [TerrainPoint] in
            try checkpoint.indices.withUnsafeBytes { (faces:UnsafeRawBufferPointer) -> [TerrainPoint] in
                func point(_ index: Int) throws -> TerrainPoint {
                    guard index >= 0, index < checkpoint.vertexCount else { throw TerrainSurveyError.invalidData }
                    let offset = index*12
                    let x = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset,as:UInt32.self))))
                    let h = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset+4,as:UInt32.self))))
                    let z = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset+8,as:UInt32.self))))
                    guard x.isFinite, h.isFinite, z.isFinite else { throw TerrainSurveyError.invalidData }
                    return .init(x:x,z:z,height:h)
                }
                for face in stride(from:0,to:checkpoint.triangleCount,by:step) {
                    let classification = checkpoint.classifications?[face] ?? 0
                    // Apple labels identify surfaces, not graves or fences.
                    guard classification == 0 || classification == 2 else { continue }
                    let indices = (0..<3).map { Int(UInt32(littleEndian:faces.loadUnaligned(fromByteOffset:(face*3+$0)*4,as:UInt32.self))) }
                    let a = try point(indices[0]), b = try point(indices[1]), c = try point(indices[2])
                    let u = SIMD3(b.x-a.x,b.height-a.height,b.z-a.z), v = SIMD3(c.x-a.x,c.height-a.height,c.z-a.z)
                    let normal = SIMD3(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
                    let magnitude = sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)
                    guard magnitude > 1e-9, abs(normal.y)/magnitude >= 0.65,
                          max(hypot(a.x-b.x,a.z-b.z),hypot(a.x-c.x,a.z-c.z),hypot(b.x-c.x,b.z-c.z)) <= 1 else { continue }
                    result.append(contentsOf:[a,b,c,.init(x:(a.x+b.x+c.x)/3,z:(a.z+b.z+c.z)/3,height:(a.height+b.height+c.height)/3)])
                }
                return result
            }
        }
    }

    private func verticalSamples(_ checkpoint:Checkpoint,frameID:UUID,faceBudget:Int) throws -> [FenceTriangle] {
        var result = [FenceTriangle]()
        let step = max(1,Int(ceil(Double(checkpoint.triangleCount)/Double(max(1,faceBudget)))))
        return try checkpoint.positions.withUnsafeBytes { (vertices:UnsafeRawBufferPointer) -> [FenceTriangle] in
            try checkpoint.indices.withUnsafeBytes { (faces:UnsafeRawBufferPointer) -> [FenceTriangle] in
                func point(_ index:Int) throws -> TerrainPoint {
                    guard index >= 0,index < checkpoint.vertexCount else { throw TerrainSurveyError.invalidData }
                    let offset = index*12
                    let x = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset,as:UInt32.self))))
                    let height = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset+4,as:UInt32.self))))
                    let z = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset+8,as:UInt32.self))))
                    guard x.isFinite,height.isFinite,z.isFinite else { throw TerrainSurveyError.invalidData }
                    return .init(x:x,z:z,height:height)
                }
                for face in stride(from:0,to:checkpoint.triangleCount,by:step) {
                    let raw = checkpoint.classifications?[face] ?? 0
                    // Unknown vertical structures can be reviewed. A native
                    // wall label is preserved so the heuristic can exclude it.
                    guard raw == 0 || raw == 1 else { continue }
                    let ia = Int(UInt32(littleEndian:faces.loadUnaligned(fromByteOffset:face*12,as:UInt32.self)))
                    let ib = Int(UInt32(littleEndian:faces.loadUnaligned(fromByteOffset:face*12+4,as:UInt32.self)))
                    let ic = Int(UInt32(littleEndian:faces.loadUnaligned(fromByteOffset:face*12+8,as:UInt32.self)))
                    let a = try point(ia),b = try point(ib),c = try point(ic)
                    let u = SIMD3<Double>(b.x-a.x,b.height-a.height,b.z-a.z)
                    let v = SIMD3<Double>(c.x-a.x,c.height-a.height,c.z-a.z)
                    let normal = SIMD3<Double>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
                    let magnitude = sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)
                    let thirdX = c.x-b.x,thirdY = c.height-b.height,thirdZ = c.z-b.z
                    let edgeAB:Double = sqrt(u.x*u.x+u.y*u.y+u.z*u.z)
                    let edgeAC:Double = sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
                    let edgeBC:Double = sqrt(thirdX*thirdX+thirdY*thirdY+thirdZ*thirdZ)
                    guard magnitude > 1e-9,abs(normal.y)/magnitude <= 0.35,
                          max(edgeAB,edgeAC,edgeBC) <= 2 else { continue }
                    result.append(FenceTriangle(frameID:frameID,anchorID:checkpoint.anchorID,a:a,b:b,c:c,classification:raw == 1 ? .wall : .unknown))
                }
                return result
            }
        }
    }

    /// Full 3D measured faces retain horizontal canopy geometry. Apple mesh
    /// labels do not identify plants; unknown shapes only reach review heuristics.
    private func spatialSamples(_ checkpoint:Checkpoint,frameID:UUID,faceBudget:Int) throws -> [FenceTriangle] {
        var result = [FenceTriangle]()
        let step = max(1,Int(ceil(Double(checkpoint.triangleCount)/Double(max(1,faceBudget)))))
        return try checkpoint.positions.withUnsafeBytes { (vertices:UnsafeRawBufferPointer) -> [FenceTriangle] in
            try checkpoint.indices.withUnsafeBytes { (faces:UnsafeRawBufferPointer) -> [FenceTriangle] in
                func point(_ index:Int) throws -> TerrainPoint {
                    guard index >= 0,index < checkpoint.vertexCount else { throw TerrainSurveyError.invalidData }
                    let offset = index*12
                    let x = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset,as:UInt32.self))))
                    let height = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset+4,as:UInt32.self))))
                    let z = Double(Float(bitPattern:UInt32(littleEndian:vertices.loadUnaligned(fromByteOffset:offset+8,as:UInt32.self))))
                    guard x.isFinite,height.isFinite,z.isFinite else { throw TerrainSurveyError.invalidData }
                    return .init(x:x,z:z,height:height)
                }
                for face in stride(from:0,to:checkpoint.triangleCount,by:step) {
                    let raw = checkpoint.classifications?[face] ?? 0
                    guard raw == 0 || raw == 1 else { continue }
                    let ia = Int(UInt32(littleEndian:faces.loadUnaligned(fromByteOffset:face*12,as:UInt32.self)))
                    let ib = Int(UInt32(littleEndian:faces.loadUnaligned(fromByteOffset:face*12+4,as:UInt32.self)))
                    let ic = Int(UInt32(littleEndian:faces.loadUnaligned(fromByteOffset:face*12+8,as:UInt32.self)))
                    let a = try point(ia),b = try point(ib),c = try point(ic)
                    let u = SIMD3<Double>(b.x-a.x,b.height-a.height,b.z-a.z)
                    let v = SIMD3<Double>(c.x-a.x,c.height-a.height,c.z-a.z)
                    let normal = SIMD3<Double>(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
                    let magnitude = sqrt(normal.x*normal.x+normal.y*normal.y+normal.z*normal.z)
                    let thirdX = c.x-b.x,thirdY = c.height-b.height,thirdZ = c.z-b.z
                    let edgeAB:Double = sqrt(u.x*u.x+u.y*u.y+u.z*u.z)
                    let edgeAC:Double = sqrt(v.x*v.x+v.y*v.y+v.z*v.z)
                    let edgeBC:Double = sqrt(thirdX*thirdX+thirdY*thirdY+thirdZ*thirdZ)
                    guard magnitude > 1e-9,
                          max(edgeAB,edgeAC,edgeBC) <= 1.2 else { continue }
                    result.append(FenceTriangle(frameID:frameID,anchorID:checkpoint.anchorID,a:a,b:b,c:c,classification:raw == 1 ? .wall : .unknown))
                }
                return result
            }
        }
    }
}
