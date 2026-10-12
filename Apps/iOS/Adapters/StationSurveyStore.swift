import Foundation
import AtlasCore

enum StationSurveyStoreError: Error, LocalizedError {
    case revisionConflict, tooLarge
    var errorDescription: String? {
        switch self {
        case .revisionConflict: "Журнал уже изменён. Откройте съёмку заново; прежний файл сохранён."
        case .tooLarge: "Журнал станций превышает 16 МБ. Предыдущий файл сохранён; продолжите в отдельном проекте."
        }
    }
}

actor StationSurveyStore {
    static let maximumBytes = 16 * 1_024 * 1_024
    let projectID: UUID
    let reference: CoordinateReference
    let directory: URL
    init(projectID: UUID, reference: CoordinateReference, directory: URL) {
        self.projectID = projectID; self.reference = reference; self.directory = directory
    }
    private var file: URL { directory.appendingPathComponent(projectID.uuidString + ".station-survey.json") }
    func load() throws -> StationSurvey? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try checkPath(file)
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= Self.maximumBytes else { throw StationSurveyStoreError.tooLarge }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maximumBytes else { throw StationSurveyStoreError.tooLarge }
        let document = try JSONDecoder().decode(StationSurvey.self, from: data)
        try document.validate()
        guard document.projectID == projectID, document.coordinateReference == reference else { throw StationSurveyError.invalidDocument }
        return document
    }
    func save(_ document: StationSurvey) throws -> StationSurvey {
        try document.validate()
        guard document.projectID == projectID, document.coordinateReference == reference else { throw StationSurveyError.invalidDocument }
        let previous = try load()
        guard document.revision == (previous?.revision ?? 0) else {
            throw StationSurveyStoreError.revisionConflict
        }
        if let previous { try document.validateTransition(from: previous) }
        guard document.revision < Int64.max else { throw StationSurveyError.invalidDocument }
        var next = document; next.revision += 1
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.maximumBytes else { throw StationSurveyStoreError.tooLarge }
        try checkPath(file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkPath(file)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        return try JSONDecoder().decode(StationSurvey.self, from: data)
    }
    private func checkPath(_ file: URL) throws {
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(parent),
              file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(parent),
              (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw StationSurveyError.invalidDocument
        }
    }
}
