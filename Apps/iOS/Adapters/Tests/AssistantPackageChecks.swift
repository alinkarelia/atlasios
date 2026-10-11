import Foundation
import AtlasCore

@main struct AssistantPackageChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terraview-assistant-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = UUID(), otherFrame = UUID()
        let project = AtlasProject(name: "Offline specialist package", kind: .cemetery, coordinateReference: .wgs84)
        var grave = AtlasFeature(projectID: project.id, label: "Known burial, unknown identity", category: .grave,
            geometry: .geographicPoint(.init(longitude: 30, latitude: 60)),
            attributes: ["survey.status": "confirmed"], revision: 2)
        grave = try BurialMetadata(identityStatus: .unknown).applying(to: grave)
        var previous = grave; previous.revision = 1; previous.attributes["survey.status"] = "candidate"
        let outer: [MetricPoint2D] = [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 4), .init(x: 0, y: 4)]
        let hole: [MetricPoint2D] = [.init(x: 1, y: 1), .init(x: 2, y: 1), .init(x: 2, y: 2), .init(x: 1, y: 2)]
        let plan = AtlasFloorPlan(projectID: project.id, frameID: frame, name: "Ground", floorIndex: 1,
            rooms: [PlanRoom(name: "Room", boundary: .init(frameID: frame, vertices: outer, holes: [hole]))])
        let independent = AtlasFloorPlan(projectID: project.id, frameID: otherFrame, name: "Upper", floorIndex: 2)
        let snapshot = AtlasProjectSnapshot(project: project, features: [grave], floorPlans: [plan, independent], scans: [])
        let projectData = try AtlasExporter.export(snapshot, format: .projectJSON).data
        let device = FieldCaptureDevice(model: "fixture", osVersion: "test", appVersion: "test")
        let passport = FieldDeliveryPassport(projectID: project.id, projectName: project.name,
            preparedAt: Date(timeIntervalSince1970: 1_700_000_000), timeZoneIdentifier: "UTC", utcOffsetSeconds: 0,
            device: device, preparedBy: nil, materials: [.init(source: FieldMaterial(id: project.id, sourceEntityID: project.id, kind: .project), captureOperator: nil)],
            assets: [FieldAsset(materialID: project.id, relativePath: "project.json", mediaType: "application/json",
                byteCount: Int64(projectData.count), sha256: FieldTransferDigest.sha256(projectData), kind: .projectSnapshot)], notes: [])
        let files = try AssistantProjectPackage.prepare(snapshot: snapshot,
            passportData: FieldTransferJSON.encode(passport), histories: [.init(featureID: grave.id, revisions: [previous, grave])], staging: root)
        precondition(Set(files.map(\.lastPathComponent)) == ["assistant-index.json", "feature-revisions.json", "READ-ME.txt"])
        let indexData = try Data(contentsOf: root.appendingPathComponent("assistant-index.json"))
        let index = try FieldTransferJSON.decode(AssistantProjectIndex.self, from: indexData)
        precondition(index.projectID == project.id && index.coordinateReference == .wgs84)
        precondition(index.plans.count == 2 && index.plans[0].frameID != index.plans[1].frameID)
        precondition(index.plans[0].summedRoomAreasSquareMeters == 15 && index.plans[0].floorIndex == 1)
        precondition(index.interpretationRules.contains { $0.contains("candidate") && $0.contains("not a confirmed") })
        let history = try FieldTransferJSON.decode(AssistantFeatureHistory.self, from: Data(contentsOf: root.appendingPathComponent(index.historyFile)))
        precondition(history.histories[0].revisions.map(\.revision) == [1, 2])
        precondition(history.histories[0].revisions[0].attributes["survey.status"] == "candidate")
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(index.projectFile))) as! [String: Any]
        precondition((parsed["features"] as? [[String: Any]])?.count == 1)
        let retained = try FieldTransferJSON.decode(AtlasProjectSnapshot.self, from: Data(contentsOf: root.appendingPathComponent(index.projectFile)))
        let retainedMetadata = try BurialMetadata(attributes: retained.features[0].attributes)
        precondition(retainedMetadata.people.isEmpty)
        let final = try FieldTransferJSON.decode(FieldDeliveryPassport.self, from: Data(contentsOf: root.appendingPathComponent(index.provenanceFile)))
        precondition(final.assets.count == 4)
        for asset in final.assets {
            let bytes = try Data(contentsOf: root.appendingPathComponent(asset.relativePath))
            precondition(asset.byteCount == bytes.count && asset.sha256 == FieldTransferDigest.sha256(bytes))
        }
        print("Assistant package: structural units, independent floor frames, hole area, unknown identity, retained history and every member digest passed.")
    }
}
