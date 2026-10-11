import Foundation
import AtlasCore

@main struct CaptureCatalogChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = UUID(), scan = UUID(), frame = UUID()
        let folder = root.appendingPathComponent("Projects/\(project)/Captures/Object-\(scan)")
        let images = folder.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let original = Data([1, 2, 3, 4, 5])
        try original.write(to: images.appendingPathComponent("original.HEIC"))
        try Data([6, 7]).write(to: images.appendingPathComponent("depth.bin"))
        let manifestFile = folder.appendingPathComponent("manifest.json")
        var object: [String: Any] = ["schemaVersion": 1, "source": "ObjectCapture", "status": "ready",
            "id": scan.uuidString, "projectID": project.uuidString, "frameID": frame.uuidString,
            "createdAt": "2026-10-11T12:00:00Z", "modelStatus": "unsupported",
            "completedAssets": ["Images/original.HEIC", "Images/depth.bin"],
            "images": [["relativePath": "Images/original.HEIC", "byteCount": 5,
                        "sha256": FieldTransferDigest.sha256(original)]]]
        func write() throws { try JSONSerialization.data(withJSONObject: object).write(to: manifestFile, options: .atomic) }
        func records() throws -> [ScanRecord] { try write(); return try CaptureCatalog.records(at: manifestFile, relativeTo: root) }
        let first = try records()
        precondition(first.count == 1 && first[0].id == scan && first[0].projectID == project && first[0].frameID == frame)
        precondition(first[0].source == .photogrammetry && first[0].status == .ready)
        precondition(first[0].assets.filter { $0.kind == .image }.count == 1 && first[0].assets.allSatisfy { $0.kind != .mesh })
        precondition(first[0].assets.contains { $0.kind == .depth && $0.byteCount == 2 })
        let repeated = try records()
        precondition(first[0].assets.map(\.id) == repeated[0].assets.map(\.id))
        func rejects(_ change: () -> Void) throws {
            let saved = object
            change()
            do { _ = try records(); preconditionFailure("Unsafe ObjectCapture metadata accepted") }
            catch { object = saved }
        }
        try rejects { object["completedAssets"] = ["../outside.HEIC"] }
        try rejects { object["completedAssets"] = ["Images/depth.bin"] }
        try rejects { object["images"] = [] }
        try rejects { object["images"] = [["relativePath": "Images/original.HEIC", "byteCount": 6, "sha256": String(repeating: "a", count: 64)]] }
        try rejects { object["modelRelativePath"] = "missing.usdz" }
        try rejects { object["schemaVersion"] = 2 }
        let outside = root.appendingPathComponent("outside.HEIC")
        try original.write(to: outside)
        let linked = images.appendingPathComponent("linked.HEIC")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        try rejects {
            object["images"] = [["relativePath": "Images/linked.HEIC", "byteCount": 5, "sha256": String(repeating: "a", count: 64)]]
            object["completedAssets"] = ["Images/linked.HEIC"]
        }
        try Data([0x50, 0x4b]).write(to: folder.appendingPathComponent("object.usdz"))
        object["modelRelativePath"] = "object.usdz"
        object["completedAssets"] = ["Images/original.HEIC", "Images/depth.bin", "object.usdz"]
        let modeled = try records()
        precondition(modeled[0].assets.contains { $0.kind == .mesh })
        let retained = try Data(contentsOf: images.appendingPathComponent("original.HEIC"))
        precondition(retained == original)
        // Structural derivatives belong to the original semantic capture/frame.
        // A fixed filename inside a UUID namespace is permitted, arbitrary paths are not.
        let derivativeID = UUID()
        let relative = "empty-room/\(derivativeID.uuidString)/"
        let derived = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        for name in ["room.json", "room-data.json", "room.usdz"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }
        let names = ["structural-room.json", "structural-room.usdz", "structural-room.obj", "dimensions.json", "model.png", "measurements.pdf"]
        for name in names { try Data(name.utf8).write(to: derived.appendingPathComponent(name)) }
        object["source"] = "RoomPlan"
        object["completedAssets"] = ["room.json", "room-data.json", "room.usdz"] + names.map { relative + $0 }
        let structural = try records()
        precondition(structural.count == 1 && structural[0].id == scan && structural[0].frameID == frame)
        precondition(structural[0].assets.filter { $0.kind == .mesh }.count == 3)
        precondition(structural[0].assets.contains { $0.relativePath.hasSuffix("dimensions.json") })
        let derivedAgain = try records()
        precondition(structural[0].assets.map(\.id) == derivedAgain[0].assets.map(\.id))
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", relative + "unexpected.json"] }
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", "empty-room/not-a-uuid/dimensions.json"] }
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", relative + "../dimensions.json"] }
        try rejects { object["completedAssets"] = ["room.json", "room.usdz", "/" + relative + "dimensions.json"] }
        print("CaptureCatalog: 22 dataset readiness, original/derivative identity and path isolation checks passed.")
    }
}
