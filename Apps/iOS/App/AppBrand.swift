import Foundation

/// Display branding is independent of the identifiers used for saved data.
enum AppBrand {
    static let displayName: String = {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.flatMap { $0.isEmpty ? nil : $0 } ?? "TerraView"
    }()
}
