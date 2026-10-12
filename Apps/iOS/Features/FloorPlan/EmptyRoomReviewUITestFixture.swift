#if DEBUG
import AtlasCore
import Foundation

/// Explicit synthetic source for exercising the real review UI. It contains no
/// camera capture or fake model, is outside project Captures, and is only opened
/// with the test launch argument. Operator decisions use the production store.
struct EmptyRoomReviewUITestFixture: Identifiable, Sendable {
    let id = UUID()
    let document: EmptyRoomDocument
    let directory: URL
    let review: EmptyRoomSurfaceReview

    static func prepare(project: AtlasProject, root: URL) async throws -> Self {
        let captureID = UUID(uuidString: "C0610000-1234-4000-8000-000000000001")!
        let derivativeID = UUID(uuidString: "C0610000-1234-4000-8000-000000000002")!
        let directory = root.appendingPathComponent("UITestReviewFixtures", isDirectory: true)
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent("room-" + captureID.uuidString, isDirectory: true)
            .appendingPathComponent("empty-room", isDirectory: true)
            .appendingPathComponent(derivativeID.uuidString, isDirectory: true)
        let transform = EmptyRoomTransform(columns: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,1,0,1])
        let surfaces = [EmptyRoomSurfaceKind.door, .window, .opening].enumerated().map { index, kind in
            EmptyRoomSurface(id: UUID(uuidString: "C0610000-1234-4000-8000-00000000010\(index + 1)")!,
                parentID: nil, kind: kind, widthMeters: 0.9 + Double(index) * 0.1,
                heightMeters: 2, thicknessMeters: 0.1, transform: transform,
                polygonCorners: [], isCurved: false, confidence: .medium)
        }
        let document = EmptyRoomDocument(sourceRoomID: captureID, captureID: captureID,
            projectID: project.id, frameID: derivativeID, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceRoomJSONSHA256: FieldTransferDigest.sha256(Data("Synthetic UI classification source; no capture".utf8)),
            story: 0, keepStorage: false, removedObjectCount: 0, surfaces: surfaces,
            storage: [], notices: ["Синтетические поверхности для проверки интерфейса. Не результат съёмки."])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let dimensions = directory.appendingPathComponent("dimensions.json")
        if !FileManager.default.fileExists(atPath: dimensions.path) {
            try encoder.encode(document).write(to: dimensions, options: .atomic)
        }
        let file = directory.appendingPathComponent(EmptyRoomSurfaceReviewPolicy.fileName)
        if !FileManager.default.fileExists(atPath: file.path) {
            try encoder.encode(EmptyRoomSurfaceReview(source: document)).write(to: file, options: .atomic)
        }
        let review = try await EmptyRoomSurfaceReviewStore(directory: directory, source: document).load()
        return .init(document: document, directory: directory, review: review)
    }
}
#endif
