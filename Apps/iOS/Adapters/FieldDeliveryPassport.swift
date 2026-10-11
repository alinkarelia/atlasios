import Foundation
import AtlasCore

/// A capture operator is recorded at capture time. An uploader or archive
/// preparer must never be substituted for an unknown original operator.
struct FieldCaptureOperator: Codable, Hashable, Sendable {
    var userID: UUID?
    var displayName: String
    init(userID: UUID? = nil, displayName: String) {
        self.userID = userID; self.displayName = displayName
    }
}

struct FieldDeliveryPassport: Codable, Sendable {
    struct Material: Codable, Sendable {
        var source: FieldMaterial
        var captureOperator: FieldCaptureOperator?
    }
    var schemaVersion = 1
    var projectID: UUID
    var projectName: String
    var preparedAt: Date
    var timeZoneIdentifier: String
    var utcOffsetSeconds: Int
    var device: FieldCaptureDevice
    /// Describes who prepared the archive, separately from capture authors.
    var preparedBy: FieldCaptureOperator?
    var materials: [Material]
    /// Paths and hashes refer to the actual ZIP members, including project.json.
    var assets: [FieldAsset]
    var notes: [String]
}
