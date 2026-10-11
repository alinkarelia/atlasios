import Foundation

private struct NamingCheckError: Error { let message: String }

@main
private enum ExportFileNamingChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NamingCheckError(message: message) }
            checks += 1
        }
        func rejects(_ error: ExportFileNamingError, _ operation: () throws -> String) throws {
            var caught: ExportFileNamingError?
            do { _ = try operation() } catch let actual as ExportFileNamingError { caught = actual }
            try check(caught == error, "Expected \(error), received \(String(describing: caught))")
        }
        let project = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let source = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let export = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let date = ISO8601DateFormatter().date(from: "2026-10-11T12:34:56Z")!
        let capture = ISO8601DateFormatter().date(from: "2026-10-10T23:59:59Z")!
        let filename = try ExportFileNaming.project(projectName: "Северное кладбище", projectID: project, role: "objects",
            exportedAt: date, fileExtension: "GeoJSON", exportID: export)
        try check(filename.hasPrefix("TerraView_Северное_кладбище_objects_"), "Readable Unicode label")
        try check(filename.contains("project-" + project.uuidString.lowercased()), "Full project ID")
        try check(filename.contains("export-2026-10-11_12-34-56Z"), "UTC export timestamp")
        try check(filename.hasSuffix(export.uuidString.lowercased() + ".geojson"), "Full export ID and visible extension")
        try check(filename.utf8.count <= 240, "Portable byte bound")
        let sameSecond = try ExportFileNaming.project(projectName: "Северное кладбище", projectID: project, role: "objects",
            exportedAt: date, fileExtension: "geojson")
        try check(filename != sameSecond, "Same-second exports never share a name")
        let compound = try ExportFileNaming.project(projectName: "A", projectID: project, role: "project",
            exportedAt: date, fileExtension: "atlas.json", exportID: export)
        try check(compound.hasSuffix(".atlas.json"), "Compound persisted format extension preserved")
        let original = try ExportFileNaming.source(projectName: "Северное кладбище", projectID: project, role: "photo",
            sourceID: source, capturedAt: capture, exportedAt: date, fileExtension: "HEIC", exportID: export)
        try check(original.contains("source-" + source.uuidString.lowercased()), "Full original source ID")
        try check(original.contains("capture-2026-10-10_23-59-59Z"), "Capture time distinct from export time")
        try check(original.contains("export-2026-10-11_12-34-56Z"), "Shared-copy export time")
        try check(original.hasSuffix(".heic"), "Actual original extension")
        let unknown = try ExportFileNaming.source(projectName: "Проект", projectID: project, role: "photo",
            sourceID: source, capturedAt: nil, exportedAt: date, fileExtension: "jpg", exportID: export)
        try check(unknown.contains("capture-unknown_export-2026-10-11_12-34-56Z"), "Unknown capture time is not invented")
        try check(!unknown.contains("capture-2026"), "Export date must not be relabeled capture date")
        let unsafe = try ExportFileNaming.project(projectName: "../CON: папка\\<a>|\n\"?* .", projectID: project,
            role: "../exports\\", exportedAt: date, fileExtension: "zip", exportID: export)
        try check(!unsafe.contains("..") && !unsafe.contains("/") && !unsafe.contains("\\"), "No traversal from labels")
        try check(!unsafe.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, "No control characters")
        try check(!unsafe.contains(":") && !unsafe.contains("?") && !unsafe.contains("*"), "Windows punctuation safe")
        try check(!unsafe.hasSuffix(" ") && !unsafe.hasSuffix("."), "No trailing Windows dot/space")
        let empty = try ExportFileNaming.project(projectName: "...", projectID: project, role: "\n/", exportedAt: date,
            fileExtension: "zip", exportID: export)
        try check(empty.hasPrefix("TerraView_project_export_"), "Safe empty-label fallback")
        let decomposed = try ExportFileNaming.project(projectName: "Cafe\u{301}", projectID: project, role: "plan",
            exportedAt: date, fileExtension: "svg", exportID: export)
        try check(decomposed.contains("Café"), "Normalized Unicode naming")
        let huge = try ExportFileNaming.source(projectName: String(repeating:"🏡\u{200D}🌳Оченьдлинныйпроект",count:200),
            projectID: project, role: String(repeating:"роль",count:200), sourceID: source, capturedAt: capture,
            exportedAt: date, fileExtension: "abcdefghijklmnop", exportID: export)
        try check(huge.utf8.count <= 240, "Long multibyte source names remain bounded")
        try check(huge.hasSuffix("." + "abcdefghijklmnop"), "Truncation never damages extension")
        try check(huge.contains(project.uuidString.lowercased()) && huge.contains(source.uuidString.lowercased())
                  && huge.contains(export.uuidString.lowercased()), "Truncation never damages identities")
        let timezoneDate=ISO8601DateFormatter().date(from:"2026-10-11T15:34:56+03:00")!
        let utc=try ExportFileNaming.project(projectName:"A",projectID:project,role:"plan",exportedAt:timezoneDate,
            fileExtension:"pdf",exportID:export)
        try check(utc.contains("export-2026-10-11_12-34-56Z"), "Offset date converted to UTC")
        for ext in ["", ".jpg", "../jpg", "jpg/../../x", "jpg\\x", "jpg..json", " jpg", "jpg ", "jpg\n", "jpg:exe", "jпg", String(repeating:"x",count:17)] {
            try rejects(.invalidExtension) {
                try ExportFileNaming.project(projectName:"A",projectID:project,role:"export",exportedAt:date,fileExtension:ext)
            }
        }
        for seconds in [Double.nan,Double.infinity,-Double.infinity,253_402_300_800,-62_135_596_801] {
            try rejects(.invalidDate) {
                try ExportFileNaming.project(projectName:"A",projectID:project,role:"plan",
                    exportedAt:Date(timeIntervalSince1970:seconds),fileExtension:"svg")
            }
        }
        try rejects(.invalidDate) {
            try ExportFileNaming.source(projectName:"A",projectID:project,role:"photo",sourceID:source,
                capturedAt:Date(timeIntervalSince1970:.nan),exportedAt:date,fileExtension:"jpg")
        }
        print("Export naming: \(checks) checks passed")
    }
}
