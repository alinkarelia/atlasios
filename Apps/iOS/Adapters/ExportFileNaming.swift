import Foundation

enum ExportFileNamingError: Error, LocalizedError, Equatable {
    case invalidDate, invalidExtension

    var errorDescription: String? {
        switch self {
        case .invalidDate: "Дата файла отсутствует или выходит за поддерживаемый диапазон."
        case .invalidExtension: "Расширение файла содержит недопустимые символы."
        }
    }
}

/// Names for shared copies only. Immutable capture IDs, original files and the
/// application's internal storage paths are never renamed by this helper.
/// Dates are explicit UTC timestamps. UUIDs distinguish exports made in the
/// same second without ambiguous numeric '(2)' suffixes.
enum ExportFileNaming {
    static let maximumUTF8Bytes = 240

    static func project(projectName: String, projectID: UUID, role: String,
                        exportedAt: Date = Date(), fileExtension: String,
                        exportID: UUID = UUID()) throws -> String {
        let suffix = try validatedExtension(fileExtension)
        let fixed = ["project-" + projectID.uuidString.lowercased(),
                     "export-" + (try timestamp(exportedAt)), exportID.uuidString.lowercased()]
        return name(projectName: projectName, role: role, fixed: fixed, suffix: suffix)
    }

    /// `capturedAt` must come from original capture metadata, not an import or
    /// export date. An absent capture time stays visibly unknown in the name.
    static func source(projectName: String, projectID: UUID, role: String, sourceID: UUID,
                       capturedAt: Date?, exportedAt: Date = Date(), fileExtension: String,
                       exportID: UUID = UUID()) throws -> String {
        let suffix = try validatedExtension(fileExtension)
        let captured = try capturedAt.map { "capture-" + (try timestamp($0)) } ?? "capture-unknown"
        let fixed = ["project-" + projectID.uuidString.lowercased(), "source-" + sourceID.uuidString.lowercased(),
                     captured, "export-" + (try timestamp(exportedAt)), exportID.uuidString.lowercased()]
        return name(projectName: projectName, role: role, fixed: fixed, suffix: suffix)
    }

    private static func name(projectName: String, role: String, fixed: [String], suffix: String) -> String {
        // Reserve the complete IDs/timestamps/extension first. Human labels are
        // truncated on grapheme boundaries within the portable byte limit.
        let fixedBytes = (["TerraView", "", ""] + fixed).joined(separator: "_").utf8.count + 1 + suffix.utf8.count
        let labelBudget = maximumUTF8Bytes - fixedBytes
        let safeRole = boundedLabel(role, fallback: "export", maximumBytes: min(16, labelBudget / 2))
        let safeProject = boundedLabel(projectName, fallback: "project", maximumBytes: min(48, labelBudget - safeRole.utf8.count))
        return (["TerraView", safeProject, safeRole] + fixed).joined(separator: "_") + "." + suffix
    }

    private static func boundedLabel(_ value: String, fallback: String, maximumBytes: Int) -> String {
        var cleaned = "", pendingSeparator = false
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*.").union(.controlCharacters)
        for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
            if forbidden.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                pendingSeparator = !cleaned.isEmpty
            } else {
                if pendingSeparator && !cleaned.hasSuffix("_") { cleaned.append("_") }
                cleaned.unicodeScalars.append(scalar); pendingSeparator = false
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
        if cleaned.isEmpty { cleaned = fallback }
        var result = "", bytes = 0
        for character in cleaned {
            let piece = String(character), size = piece.utf8.count
            guard bytes + size <= maximumBytes else { break }
            result += piece; bytes += size
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
        // A single complex emoji can exceed the entire label allowance.
        return result.isEmpty ? String(fallback.prefix(max(1, min(maximumBytes, fallback.count)))) : result
    }

    private static func validatedExtension(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 16 else { throw ExportFileNamingError.invalidExtension }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        } }) else { throw ExportFileNamingError.invalidExtension }
        return value.lowercased()
    }

    private static func timestamp(_ value: Date) throws -> String {
        let seconds = value.timeIntervalSince1970
        // Four-digit Gregorian years keep files consistently sortable. Never
        // let DateFormatter coerce NaN/infinity into a plausible capture time.
        guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800 else {
            throw ExportFileNamingError.invalidDate
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss'Z'"
        let text = formatter.string(from: value)
        guard text.utf8.count == 20 else { throw ExportFileNamingError.invalidDate }
        return text
    }
}
