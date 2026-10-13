import Foundation
import AtlasCore

@main struct FragmentAssemblyChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-fragment-checks-" + UUID().uuidString)
        let root = directory.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID(), firstFrame = UUID(), secondFrame = UUID()
        let epoch = Date(timeIntervalSince1970: 1_790_000_000)
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func reject(_ message: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure(message) } catch { checks += 1 }
        }
        func fixture(frame: UUID, name: String) throws -> (ScanRecord, Data, URL) {
            let path = "Projects/\(projectID.uuidString)/Captures/\(name)/model.obj"
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data("# Atlas ARKit mesh. metres. Y up. local frame \(frame.uuidString)\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8)
            try data.write(to: file)
            let asset = SourceAssetReference(relativePath: path, kind: .mesh, byteCount: Int64(data.count), sha256: FieldTransferDigest.sha256(data))
            return (.init(projectID: projectID, source: .liDAR, status: .ready, frameID: frame, assets: [asset], createdAt: epoch), data, file)
        }
        let (firstScan, firstBytes, firstURL) = try fixture(frame: firstFrame, name: "first")
        let (secondScan, secondBytes, secondURL) = try fixture(frame: secondFrame, name: "second")
        let store = FragmentAssemblyStore(projectID: projectID, assetDirectory: root)
        let empty = try await store.load(); expect(empty == nil, "Initial journal must be absent")
        let initial = try await store.bootstrap(scans: [secondScan, firstScan], anchorCaptureID: firstScan.id)
        expect(initial.registry.anchor.captureID == firstScan.id, "Chosen anchor must retain original identity")
        expect(initial.sourceBindings.count == 2, "Both exact originals must be bound")
        expect(initial.sourceBindings[1].source.sourceSHA256 == FieldTransferDigest.sha256(secondBytes), "Source digest must refer to actual bytes")
        expect(initial.registry.projectFrameID == firstFrame, "Project frame must be original anchor frame")
        let reopened = try await store.load(); expect(reopened == initial, "Protected atomic journal must persist")
        let file = await store.fileURL, initialJournal = try Data(contentsOf: file)
        do { _ = try await store.bootstrap(scans: [firstScan, secondScan], anchorCaptureID: firstScan.id); preconditionFailure("Bootstrap cannot overwrite journal") }
        catch { checks += 1 }
        expect(try Data(contentsOf: file) == initialJournal, "Failed bootstrap must retain previous journal")
        let output = directory.appendingPathComponent("assembled")
        reject("Unapproved fragments must not export") { _ = try FragmentMeshAssemblyExporter.export(document: initial, assetDirectory: root, outputDirectory: output) }
        expect(!FileManager.default.fileExists(atPath: output.path), "Rejected output must not leave a partial derivative")
        func target(_ p: MetricPoint3D) -> MetricPoint3D { .init(x: p.z + 10, y: p.y + 3, z: -p.x + 5) }
        let points = [MetricPoint3D(x: 0, y: 0, z: 0), .init(x: 2, y: 0, z: 0), .init(x: 0, y: 2, z: 0)]
        let controls = points.map { FragmentControlPointPair(source: $0, target: target($0)) }
        let check = MetricPoint3D(x: 1, y: 1, z: 1)
        var registry = initial.registry
        let registrationID = try registry.propose(source: initial.sourceBindings[1].source, target: initial.sourceBindings[0].source,
            controls: controls, checkPoints: [.init(source: check, target: target(check))], gravityConstraint: .iPhoneYUp,
            at: epoch, expectedRevision: registry.revision)
        try registry.decide(registrationID: registrationID, state: .approved, operatorID: UUID(), reason: "Held-out marker verified",
                            at: epoch, expectedRevision: registry.revision)
        let accepted = try await store.saveRegistry(registry, expectedSHA256: initial.currentSHA256)
        expect(accepted.currentSHA256 != initial.currentSHA256, "Approval changes CAS digest")
        expect(accepted.sourceBindings == initial.sourceBindings, "Source bindings cannot be rewritten")
        let result = try FragmentMeshAssemblyExporter.export(document: accepted, assetDirectory: root, outputDirectory: output)
        expect(result.vertexCount == 6 && result.triangleCount == 2, "Actual triangles from both sources must be retained")
        let text = try String(contentsOf: result.meshURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        let vertices = lines.filter { $0.hasPrefix("v ") }.map { $0.split(separator: " ").dropFirst().map { Double($0)! } }
        let expected = [[0.0, 0, 0], [1, 0, 0], [0, 1, 0], [10, 3, 5], [10, 3, 4], [10, 4, 5]]
        expect(vertices.count == expected.count && zip(vertices, expected).allSatisfy { a, b in zip(a, b).allSatisfy { abs($0 - $1) < 1e-8 } }, "Independent OBJ parser must recover rotated and translated coordinates")
        let normals = lines.filter { $0.hasPrefix("vn ") }.map { $0.split(separator: " ").dropFirst().map { Double($0)! } }
        expect(normals.count == 2 && abs(normals[0][2] - 1) < 1e-8 && abs(normals[1][0] - 1) < 1e-8 && abs(normals[1][2]) < 1e-8, "Normals must rotate without translation")
        let faces = lines.filter { $0.hasPrefix("f ") }.map(String.init)
        expect(faces == ["f 1//1 2//1 3//1", "f 4//2 5//2 6//2"], "Fragment indices and normal indices must use correct global offsets")
        expect(try Data(contentsOf: firstURL) == firstBytes && Data(contentsOf: secondURL) == secondBytes, "Original bytes must remain unchanged")
        let report = try requireDictionary(JSONSerialization.jsonObject(with: Data(contentsOf: result.reportURL)))
        let derivative = try requireDictionary(report["derivative"]!)
        expect(derivative["sha256"] as? String == FieldTransferDigest.sha256(try Data(contentsOf: result.meshURL)), "Report binds actual derivative digest")
        expect((derivative["byteCount"] as? NSNumber)?.int64Value == Int64(try Data(contentsOf: result.meshURL).count), "Report binds actual derivative byte count")
        expect(report["sourceDocumentSHA256"] as? String == accepted.currentSHA256, "Report binds source registry revision")
        let retained = try Data(contentsOf: result.meshURL)
        reject("Existing output must never overwrite") { _ = try FragmentMeshAssemblyExporter.export(document: accepted, assetDirectory: root, outputDirectory: output) }
        expect(try Data(contentsOf: result.meshURL) == retained, "Existing derivative retained after failed export")
        reject("Result must not be written into managed originals") { _ = try FragmentMeshAssemblyExporter.export(document: accepted, assetDirectory: root, outputDirectory: root.appendingPathComponent("assembled")) }
        try (secondBytes + Data("# changed\n".utf8)).write(to: secondURL)
        let changedOutput = directory.appendingPathComponent("changed-output")
        reject("Changed original must not reuse transform") { _ = try FragmentMeshAssemblyExporter.export(document: accepted, assetDirectory: root, outputDirectory: changedOutput) }
        expect(!FileManager.default.fileExists(atPath: changedOutput.path), "Changed original must not publish derivative")
        try secondBytes.write(to: secondURL)
        do { _ = try await store.saveRegistry(registry, expectedSHA256: initial.currentSHA256); preconditionFailure("Stale CAS accepted") }
        catch { checks += 1 }
        let currentJournal = try Data(contentsOf: file)
        var stripped = try requireDictionary(JSONSerialization.jsonObject(with: currentJournal))
        var strippedRegistry = try requireDictionary(stripped["registry"]!)
        var strippedRecords = strippedRegistry["registrations"] as! [[String: Any]]
        var strippedCandidate = strippedRecords[0]["candidate"] as! [String: Any]
        strippedCandidate.removeValue(forKey: "gravityConstraint"); strippedCandidate.removeValue(forKey: "gravityDeviationDegrees")
        strippedRecords[0]["candidate"] = strippedCandidate; strippedRegistry["registrations"] = strippedRecords; stripped["registry"] = strippedRegistry
        let strippedDocument = try JSONDecoder().decode(FragmentAssemblyDocument.self, from: JSONSerialization.data(withJSONObject: stripped))
        reject("Native approval must not strip the known gravity gate") { try strippedDocument.validate() }
        try Data(repeating: 32, count: FragmentAssemblyStore.maximumBytes + 1).write(to: file)
        do { _ = try await store.load(); preconditionFailure("Oversized journal accepted") }
        catch { checks += 1 }
        try currentJournal.write(to: file)
        var mutations: [FragmentRegistrationRegistry] = []
        for _ in 0..<8 {
            var next = accepted.registry
            _ = try next.propose(source: accepted.sourceBindings[1].source, target: accepted.sourceBindings[0].source,
                controls: controls, checkPoints: [.init(source: check, target: target(check))], gravityConstraint: .iPhoneYUp,
                at: epoch, expectedRevision: next.revision)
            mutations.append(next)
        }
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for next in mutations { group.addTask {
                let writer = FragmentAssemblyStore(projectID: projectID, assetDirectory: root)
                do { _ = try await writer.saveRegistry(next, expectedSHA256: accepted.currentSHA256); return true }
                catch { return false }
            } }
            var wins = 0
            for await successful in group { if successful { wins += 1 } }
            return wins
        }
        expect(wins == 1, "Exactly one of concurrent actor writers may win CAS")
        let final = try await store.load(); expect(final?.registry.revision == accepted.registry.revision + 1, "Concurrent write cannot drop or add uncounted history")
        let linked = root.appendingPathComponent("Projects/\(projectID.uuidString)/Captures/link")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: secondURL.deletingLastPathComponent())
        reject("Even internal directory symlinks must be rejected") {
            _ = try FragmentAssemblySourceVerifier.resolve("Projects/\(projectID.uuidString)/Captures/link/model.obj", projectID: projectID, root: root)
        }
        let wrongFrame = secondScan.frameID
        let wrongHeader = Data("# Atlas ARKit mesh. metres. Y up. local frame \(UUID().uuidString)\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8)
        try wrongHeader.write(to: secondURL)
        let wrong = ScanRecord(projectID: projectID, source: .liDAR, status: .ready, frameID: wrongFrame,
            assets: [.init(relativePath: secondScan.assets[0].relativePath, kind: .mesh, byteCount: Int64(wrongHeader.count))], createdAt: epoch)
        reject("Original header must bind actual frame identity") { _ = try FragmentAssemblySourceVerifier.bind(scan: wrong, projectID: projectID, root: root) }
        print("Fragment assembly storage and actual OBJ export: \(checks) checks passed")
    }
    private static func requireDictionary(_ value: Any) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw FragmentAssemblyError.invalidDocument }; return result
    }
}
