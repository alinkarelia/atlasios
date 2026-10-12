import Foundation
import AtlasCore

enum ProjectJournalExportChecks {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-journal-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = AtlasProject(name: "Journal originals", kind: .cemetery, coordinateReference: .wgs84)
        let prefix = "Projects/" + project.id.uuidString + "/"
        let captures = root.appendingPathComponent(prefix + "Captures", isDirectory: true)
        let models = root.appendingPathComponent(prefix + "ModelMeasurements", isDirectory: true)
        let stations = captures.appendingPathComponent("StationSurvey", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stations, withIntermediateDirectories: true)
        let original = Data("# Atlas ARKit mesh. metres. Y up.\nv 0 0 0\nv 1 2 3\n".utf8)
        let originalFile = captures.appendingPathComponent("original.obj")
        try original.write(to: originalFile)
        let hash = FieldTransferDigest.sha256(original)
        let modelFile = models.appendingPathComponent(hash + ".json")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func observation(_ id: UUID = UUID(), kind: String = "verticalDistance", role: String = "height",
                         value: Double = 3, gravity: Bool = true, unit: String = "m") -> [String: Any] {
            ["id": id.uuidString, "createdAt": ISO8601DateFormatter().string(from: date),
             "projectID": project.id.uuidString, "sourceSHA256": hash,
             "start": [1.0, 2.0, 3.0], "end": [1.0, 5.0, 3.0], "kind": kind,
             "context": ["role": role, "target": "wall", "position": "lower", "positionNote": "A001 lower"],
             "value": value, "unit": unit, "gravityYKnown": gravity]
        }
        var document: [String: Any] = ["schemaVersion": 1, "projectID": project.id.uuidString,
            "sourceSHA256": hash, "revision": 1, "observations": [observation()]]
        func encoded(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        var modelBytes = try encoded(document)
        try modelBytes.write(to: modelFile, options: .atomic)
        var survey = StationSurvey(projectID: project.id, coordinateReference: .wgs84, at: date)
        let station = try survey.addStation()
        _ = try survey.beginGPS(stationID: station, at: date)
        // Rejected raw numbers have explicit JSON provenance and remain in the
        // original document. They must not be dropped or become accepted fixes.
        let invalid = CemeterySurveySample(coordinate: .init(longitude: .nan, latitude: 60),
            capturedAt: date, horizontalAccuracyMeters: 3)
        try survey.updateGPS(stationID: station, sample: invalid, receivedAt: date)
        for second in 1...3 {
            let time = date.addingTimeInterval(Double(second))
            let sample = CemeterySurveySample(coordinate: .init(longitude: 30 + Double(second) * 0.000_001, latitude: 60),
                capturedAt: time, horizontalAccuracyMeters: 3)
            try survey.updateGPS(stationID: station, sample: sample, receivedAt: time)
        }
        try survey.finishGPS(stationID: station, at: date.addingTimeInterval(10))
        try survey.include(stationID: station, value: false)
        survey.revision = 1
        let stationFile = stations.appendingPathComponent(project.id.uuidString + ".station-survey.json")
        var stationBytes = try JSONEncoder().encode(survey)
        try stationBytes.write(to: stationFile, options: .atomic)
        let snapshot = AtlasProjectSnapshot(project: project, features: [], floorPlans: [], scans: [], measurements: [])
        let scope = FieldTransferScope(serverOrigin: "https://team.example.test", userID: UUID(), organizationID: UUID())
        let device = FieldCaptureDevice(model: "fixture", osVersion: "test", appVersion: "test")
        let assembler = FieldTransferAssembler(directory: root)
        let first = try await assembler.prepare(snapshot: snapshot, assetDirectory: root, scope: scope, device: device)
        precondition(first.count == 1)
        let journalAssets = first.flatMap { $0.manifest.assets }.filter { $0.kind == .metadata }
        precondition(journalAssets.count == 2 && journalAssets.allSatisfy { $0.materialID == project.id })
        precondition(first[0].manifest.materials.count == 1 && first[0].manifest.materials[0].kind == .project)
        let modelPath = prefix + "ModelMeasurements/" + hash + ".json"
        let stationPath = prefix + "Captures/StationSurvey/" + stationFile.lastPathComponent
        let modelAsset = journalAssets.first { $0.relativePath == modelPath }!
        let stationAsset = journalAssets.first { $0.relativePath == stationPath }!
        precondition(modelAsset.sha256 == FieldTransferDigest.sha256(modelBytes))
        precondition(stationAsset.sha256 == FieldTransferDigest.sha256(stationBytes))
        let modelChunk = try await assembler.readChunk(asset: modelAsset, offset: 0, length: modelBytes.count)
        let stationChunk = try await assembler.readChunk(asset: stationAsset, offset: 0, length: stationBytes.count)
        precondition(modelChunk == modelBytes && stationChunk == stationBytes)
        let unchanged = try await assembler.prepare(snapshot: snapshot, assetDirectory: root, scope: scope, device: device,
            previous: first.map(\.manifest))
        precondition(unchanged.isEmpty)

        document["revision"] = 2
        document["observations"] = [observation(), observation(kind: "distance", role: "surfaceHeight")]
        modelBytes = try encoded(document)
        try modelBytes.write(to: modelFile, options: .atomic)
        let modelDelta = try await assembler.prepare(snapshot: snapshot, assetDirectory: root, scope: scope, device: device,
            previous: first.map(\.manifest))
        precondition(modelDelta.count == 1)
        precondition(modelDelta[0].manifest.assets.filter { $0.kind == .metadata }.map(\.relativePath) == [modelPath])
        precondition(modelDelta[0].snapshot.scans.isEmpty && modelDelta[0].snapshot.features.isEmpty)
        let secondStation = try survey.addStation()
        try survey.enter(stationID: secondStation, position: .geographicPoint(.init(longitude: 30.1, latitude: 60.1)),
            reason: "Manual control reading", at: date.addingTimeInterval(20))
        survey.revision = 2
        stationBytes = try JSONEncoder().encode(survey)
        try stationBytes.write(to: stationFile, options: .atomic)
        let stationDelta = try await assembler.prepare(snapshot: snapshot, assetDirectory: root, scope: scope, device: device,
            previous: (first + modelDelta).map(\.manifest))
        precondition(stationDelta.count == 1)
        precondition(stationDelta[0].manifest.assets.filter { $0.kind == .metadata }.map(\.relativePath) == [stationPath])
        let observed = try JSONDecoder().decode(StationSurvey.self, from: stationBytes)
        precondition(observed.stations[0].attempts[0].observations.count == 4)
        precondition(observed.stations[0].attempts[0].observations[0].rejection == "invalidCoordinate")
        precondition(!observed.stations[0].included)

        let passportData = try await assembler.deliveryPassport(snapshot: snapshot, assetDirectory: root, device: device, preparedBy: nil)
        let passport = try FieldTransferJSON.decode(FieldDeliveryPassport.self, from: passportData)
        let entries = try ProjectJournalExport.archiveEntries(project: project, assetDirectory: root, passportAssets: passport.assets)
        precondition(Set(entries.map(\.relativePath)) == ["ModelMeasurements/" + modelFile.lastPathComponent,
            "Captures/StationSurvey/" + stationFile.lastPathComponent])
        precondition(passport.assets.filter { $0.kind == .metadata }.allSatisfy { $0.materialID == project.id })
        let zip = root.appendingPathComponent("journals.zip")
        try AtlasArchiveWriter.write(entries: entries, to: zip)
        let previousZIP = try Data(contentsOf: zip)
        try (modelBytes + Data(" ".utf8)).write(to: modelFile, options: .atomic)
        do { try AtlasArchiveWriter.write(entries: entries, to: zip); preconditionFailure("Changed journal must not publish") }
        catch { let retainedZIP = try Data(contentsOf: zip); precondition(retainedZIP == previousZIP) }
        try modelBytes.write(to: modelFile, options: .atomic)
        var forgedAssets = passport.assets
        let index = forgedAssets.firstIndex { $0.relativePath.hasPrefix("ModelMeasurements/") }!
        let asset = forgedAssets[index]
        forgedAssets[index] = FieldAsset(id: asset.id, materialID: asset.materialID, relativePath: asset.relativePath,
            mediaType: asset.mediaType, byteCount: asset.byteCount, sha256: String(repeating: "0", count: 64), kind: asset.kind)
        reject("passport hash binding") { _ = try ProjectJournalExport.archiveEntries(project: project, assetDirectory: root, passportAssets: forgedAssets) }
        forgedAssets[index] = FieldAsset(id: asset.id, materialID: asset.materialID, relativePath: asset.relativePath,
            mediaType: asset.mediaType, byteCount: asset.byteCount + 1, sha256: asset.sha256, kind: asset.kind)
        reject("passport byte count binding") { _ = try ProjectJournalExport.archiveEntries(project: project, assetDirectory: root, passportAssets: forgedAssets) }
        try FileManager.default.removeItem(at: modelFile)
        reject("missing passport journal") { _ = try ProjectJournalExport.archiveEntries(project: project, assetDirectory: root, passportAssets: passport.assets) }
        try modelBytes.write(to: modelFile, options: .atomic)
        reject("unlisted original journal") { _ = try ProjectJournalExport.archiveEntries(project: project, assetDirectory: root,
            passportAssets: passport.assets.filter { !$0.relativePath.hasPrefix("ModelMeasurements/") }) }

        func collect() throws { try ProjectJournalExport.forEachFile(project: project, assetDirectory: root) { _ in } }
        let validDocument = document
        for key in ["schemaVersion", "revision"] {
            document = validDocument; document[key] = 0
            try encoded(document).write(to: modelFile, options: .atomic)
            reject(key) { try collect() }
        }
        document = validDocument; document["projectID"] = UUID().uuidString
        try encoded(document).write(to: modelFile, options: .atomic)
        reject("foreign project envelope") { try collect() }
        document = validDocument; document["sourceSHA256"] = String(repeating: "0", count: 64)
        try encoded(document).write(to: modelFile, options: .atomic)
        reject("source/filename mismatch") { try collect() }
        let same = observation()
        document = validDocument; document["observations"] = [same, same]
        try encoded(document).write(to: modelFile, options: .atomic)
        reject("duplicate observations") { try collect() }
        for row in [observation(value: 4), observation(gravity: false), observation(unit: "model-unit"),
                    observation(kind: "distance"), observation(kind: "verticalDistance", role: "surfaceHeight")] {
            document = validDocument; document["observations"] = [row]
            try encoded(document).write(to: modelFile, options: .atomic)
            reject("incompatible derived value/gravity/units/role") { try collect() }
        }
        document = validDocument; document["observations"] = (0..<2_001).map { _ in observation() }
        try encoded(document).write(to: modelFile, options: .atomic)
        reject("bounded observation count") { try collect() }
        try Data(repeating: 32, count: ProjectJournalExport.maximumModelBytes + 1).write(to: modelFile)
        reject("bounded model read") { try collect() }
        try modelBytes.write(to: modelFile, options: .atomic)
        var foreign = StationSurvey(projectID: UUID(), coordinateReference: .wgs84, at: date)
        foreign.revision = 1
        try JSONEncoder().encode(foreign).write(to: stationFile, options: .atomic)
        reject("foreign station project") { try collect() }
        let otherReference = StationSurvey(projectID: project.id, coordinateReference: .localMeters(frameID: UUID()), at: date)
        try JSONEncoder().encode(otherReference).write(to: stationFile, options: .atomic)
        reject("station coordinate reference") { try collect() }
        try Data(repeating: 32, count: ProjectJournalExport.maximumStationBytes + 1).write(to: stationFile)
        reject("bounded station read") { try collect() }
        try stationBytes.write(to: stationFile, options: .atomic)
        let wrongName = stations.appendingPathComponent(UUID().uuidString + ".station-survey.json")
        try stationBytes.write(to: wrongName)
        reject("foreign station filename") { try collect() }
        try FileManager.default.removeItem(at: wrongName)

        let foreignRoot = root.appendingPathComponent("Projects/" + UUID().uuidString + "/ModelMeasurements", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        let outside = foreignRoot.appendingPathComponent(modelFile.lastPathComponent)
        try modelBytes.write(to: outside)
        try FileManager.default.removeItem(at: modelFile)
        try FileManager.default.createSymbolicLink(at: modelFile, withDestinationURL: outside)
        reject("file symlink inside managed root") { try collect() }
        try FileManager.default.removeItem(at: modelFile)
        try modelBytes.write(to: modelFile)
        let retained = models.deletingLastPathComponent().appendingPathComponent("retained-models")
        try FileManager.default.moveItem(at: models, to: retained)
        try FileManager.default.createSymbolicLink(at: models, withDestinationURL: foreignRoot)
        reject("directory symlink inside managed root") { try collect() }
        try FileManager.default.removeItem(at: models)
        try FileManager.default.moveItem(at: retained, to: models)

        // Project-only metadata must survive the real automatic batching path.
        var many = snapshot
        many.features = (0..<1_001).map { index in
            AtlasFeature(projectID: project.id, label: "Station metadata batch \(index)", category: .grave,
                geometry: .geographicPoint(.init(longitude: 30, latitude: 60)))
        }
        let batches = try await assembler.prepare(snapshot: many, assetDirectory: root, scope: scope, device: device)
        precondition(batches.count >= 2)
        let batchedJournals = batches.flatMap { $0.manifest.assets }.filter { $0.kind == .metadata }
        precondition(batchedJournals.count == 2 && Set(batchedJournals.map(\.relativePath)) == [modelPath, stationPath])
        for batch in batches {
            try batch.manifest.validate()
            precondition(batch.manifest.materials.filter { $0.id == project.id }.count == 1)
        }
        let sameMetadata = batches.first { $0.manifest.assets.contains(where: { $0.kind == .metadata }) }!.manifest
        let crossProject = FieldTransferManifest(id: sameMetadata.id, projectID: UUID(), title: sameMetadata.title,
            createdAt: sameMetadata.createdAt, device: device, materials: sameMetadata.materials, assets: sameMetadata.assets)
        let isolated = try await assembler.prepare(snapshot: snapshot, assetDirectory: root, scope: scope, device: device,
            previous: [crossProject])
        precondition(isolated.flatMap { $0.manifest.assets }.filter { $0.kind == .metadata }.count == 2)
        let retainedOriginal = try Data(contentsOf: originalFile)
        precondition(retainedOriginal == original)
        print("Project journal export: exact original bytes, raw rejected/excluded station history, journal-only deltas, project owner, batching, passport/ZIP hash binding, bounded reads, schema/identity/value checks and symlink isolation passed.")
    }

    private static func reject(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected rejection: " + name) }
        catch { }
    }
}
