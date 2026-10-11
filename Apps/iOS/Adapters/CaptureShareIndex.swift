import Foundation

struct NamedSourceExportResult: Sendable {
    let files: [URL]
    let indexURL: URL
    let manifestAliasURL: URL?
}

/// Flat-file sharing preserves original relative references through this map.
/// Consumers verify SHA-256 and rebuild the declared capture-relative layout;
/// neither common GPS nor a shared project registers independent AR origins.
struct CaptureShareIndex: Codable, Sendable {
    struct File: Codable, Sendable {
        let aliasFileName: String
        /// Relative to the project's full Captures root, also usable in a ZIP.
        let originalRelativePath: String
        /// Relative to this capture's manifest folder when a manifest is known.
        let originalCaptureRelativePath: String?
        let projectID: UUID
        let captureID: UUID
        let sourceID: UUID
        let segmentID: UUID?
        let frameID: UUID?
        let capturedAt: Date?
        let byteCount: Int64
        let sha256: String
    }

    var schemaVersion = 1
    var application = "TerraView"
    let id: UUID
    let projectID: UUID
    let captureID: UUID
    let exportedAt: Date
    var timestampEncoding = "Unix epoch milliseconds; capturedAt absent means unknown; exportedAt is not capture time"
    let files: [File]
    var interpretationRules = [
        "Verify each alias SHA-256 before rebuilding original relative paths.",
        "Send this index together with all selected files, including manifests and video/room sidecars.",
        "Source metadata paths refer to originalCaptureRelativePath; aliasFileName maps the shared flat filenames.",
        "Independent frameIDs remain independent. GPS, filenames, dates and shared project membership do not register or merge frames.",
        "This index covers selected files only; a complete project ZIP also carries photos, checkpoints, features and edit history."
    ]
}
