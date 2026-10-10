import Foundation
import SwiftUI
import AtlasCore

@MainActor
final class AtlasAppModel: ObservableObject {
    @Published private(set) var projects: [AtlasProject] = []
    @Published var selectedProjectID: UUID?
    @Published var issue: String?
    @Published private(set) var ready = false
    @Published private(set) var storeAvailable = false
    let purchases = PurchaseService()
    let team = TeamService()
    let directory: URL
    let business: BusinessStore?
    private var measurementRepository: MeasurementRepository?
    private var store: AtlasStore?
    private var started = false

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atlas", isDirectory: true)
        var startupIssues: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            store = try AtlasStore(path: directory.appendingPathComponent("atlas.sqlite").path)
            storeAvailable = true
        } catch {
            store = nil
            startupIssues.append("Не удалось открыть проекты: \(error.localizedDescription). Исходные файлы сохранены на устройстве.")
        }
        do { business = try BusinessStore(directory: directory.appendingPathComponent("Business", isDirectory: true)) }
        catch { business = nil; startupIssues.append("Бизнес-данные недоступны: \(error.localizedDescription). Проекты доступны независимо.") }
        do { measurementRepository = try MeasurementRepository(directory: directory.appendingPathComponent("Measurements", isDirectory: true)) }
        catch { startupIssues.append("Журнал измерений недоступен: \(error.localizedDescription). Проекты доступны независимо.") }
        issue = startupIssues.isEmpty ? nil : startupIssues.joined(separator: "\n")
    }

    var selectedProject: AtlasProject? { projects.first { $0.id == selectedProjectID } ?? projects.first }

    func start() async {
        guard !started else { return }
        started = true
        await reload()
        await seedPreviewMeshIfRequested()
        ready = true
        await purchases.startup()
        if team.connected { await team.refresh() }
        await configureCommerceAccount()
    }

    func reload() async {
        guard let store else { return }
        do { projects = try await store.projects() }
        catch { issue = error.localizedDescription }
    }

    func createProject(name: String, kind: ProjectKind, geographic: Bool = false) async -> AtlasProject? {
        guard let store else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { issue = "Укажите название проекта."; return nil }
        do {
            let project = try await store.saveProject(AtlasProject(
                name: clean, kind: kind,
                coordinateReference: geographic ? .wgs84 : .localMeters(frameID: UUID())))
            selectedProjectID = project.id
            await reload()
            return project
        } catch { issue = error.localizedDescription; return nil }
    }

    func features(in project: AtlasProject) async -> [AtlasFeature] {
        do { return try await store?.features(projectID: project.id) ?? [] }
        catch { issue = error.localizedDescription; return [] }
    }

    func plans(in project: AtlasProject) async -> [AtlasFloorPlan] {
        do { return try await store?.floorPlans(projectID: project.id) ?? [] }
        catch { issue = error.localizedDescription; return [] }
    }

    func scans(in project: AtlasProject) async -> [ScanRecord] {
        do { return try await store?.scans(projectID: project.id) ?? [] }
        catch { issue = error.localizedDescription; return [] }
    }

    func measurements(in project: AtlasProject) async -> [MeasurementRecord] {
        guard let measurementRepository else { issue = "Журнал измерений недоступен."; return [] }
        do {
            try await measurementRepository.reload()
            return await measurementRepository.measurements(projectID: project.id)
        }
        catch { issue = error.localizedDescription; return [] }
    }

    @discardableResult
    func saveMeasurement(_ measurement: MeasurementRecord) async -> MeasurementRecord? {
        guard projects.contains(where: { $0.id == measurement.projectID }) else { issue = "Проект измерения не найден."; return nil }
        guard let measurementRepository else { issue = "Журнал измерений недоступен."; return nil }
        do { return try await measurementRepository.save(measurement) }
        catch { issue = error.localizedDescription; return nil }
    }

    func correctGeoTag(of scan: ScanRecord, with correction: GeoTagCorrection) async throws -> ScanRecord {
        guard let store else { throw TeamError.rejected("Каталог съёмок недоступен.") }
        var updated = scan
        var tag = updated.geoTag ?? GeoTag()
        tag.corrections.append(correction)
        try GeoTagPolicy.validate(tag)
        updated.geoTag = tag
        return try await store.saveScan(updated)
    }

    func configureCommerceAccount() async {
        await purchases.configureAccount(userID: team.user?.id, evidenceSink: team.purchaseSink())
    }

    func snapshot(of project: AtlasProject) async -> AtlasProjectSnapshot? {
        do {
            guard var snapshot = try await store?.snapshot(projectID: project.id) else { return nil }
            guard let measurementRepository else {
                throw TeamError.rejected("Журнал измерений недоступен. Полный экспорт проекта нельзя завершить без этих данных.")
            }
            try await measurementRepository.reload()
            snapshot.measurements = await measurementRepository.measurements(projectID: project.id)
            return snapshot
        }
        catch { issue = error.localizedDescription; return nil }
    }

    @discardableResult
    func registerCapture(manifest: URL, project: AtlasProject) async -> Bool {
        guard let store else { return false }
        do {
            let root = directory
            let records = try await Task.detached(priority: .utility) {
                try CaptureCatalog.records(at: manifest, relativeTo: root)
            }.value
            let previous = try await store.scans(projectID: project.id)
            for var record in records {
                guard record.projectID == project.id else { throw TeamError.rejected("Съёмка относится к другому проекту.") }
                if let existing = previous.first(where: { $0.id == record.id }) {
                    record.revision = existing.revision
                    if var retained = existing.geoTag {
                        // Recovery must not replace the original or operator history.
                        if retained.automaticFix == nil { retained.automaticFix = record.geoTag?.automaticFix }
                        record.geoTag = retained
                    }
                }
                _ = try await store.saveScan(record)
            }
            await reload()
            return true
        } catch { issue = "Файлы съёмки сохранены, но каталог не обновился: \(error.localizedDescription). Откройте восстановление съёмок."; return false }
    }

    @discardableResult
    func saveFeature(_ feature: AtlasFeature) async -> AtlasFeature? {
        do { return try await store?.saveFeature(feature) }
        catch { issue = error.localizedDescription; return nil }
    }

    @discardableResult
    func savePlan(_ plan: AtlasFloorPlan) async -> AtlasFloorPlan? {
        do { return try await store?.saveFloorPlan(plan) }
        catch { issue = error.localizedDescription; return nil }
    }

    func export(project: AtlasProject, format: ExportFormat) async -> URL? {
        guard let snapshot = await snapshot(of: project) else { return nil }
        do {
            let artifact = try AtlasExporter.export(snapshot, format: format)
            let exportDirectory = directory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let url = exportDirectory.appendingPathComponent(artifact.fileName)
            try artifact.data.write(to: url, options: .atomic)
            if !artifact.warnings.isEmpty { issue = artifact.warnings.joined(separator: "\n") }
            return url
        } catch { issue = error.localizedDescription; return nil }
    }

    func captureDirectory(for project: AtlasProject) -> URL {
        directory.appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    func exportArchive(project: AtlasProject) async -> URL? {
        guard let snapshot = await snapshot(of: project) else { return nil }
        do {
            let exportDirectory = directory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let staging = exportDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let metadata = staging.appendingPathComponent("project.json")
            try AtlasExporter.export(snapshot, format: .projectJSON).data.write(to: metadata, options: .atomic)
            let captureRoot = captureDirectory(for: project)
            let destination = exportDirectory.appendingPathComponent("Atlas-\(project.id.uuidString).zip")
            return try await Task.detached(priority: .utility) {
                try Self.writeArchive(metadata: metadata, captureRoot: captureRoot, destination: destination)
            }.value
        } catch { issue = error.localizedDescription; return nil }
    }

    /// DirectoryEnumerator's iterator is synchronous on current Apple SDKs.
    /// The detached utility task calls this helper without moving file IO onto
    /// MainActor or allowing the enumerator to cross a suspension point.
    private nonisolated static func writeArchive(metadata: URL, captureRoot: URL, destination: URL) throws -> URL {
        var entries = [AtlasArchiveEntry(relativePath: "project.json", fileURL: metadata)]
        if let enumerator = FileManager.default.enumerator(at: captureRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw TeamError.rejected("В исходниках обнаружена ссылка на внешний файл.") }
                guard values.isRegularFile == true else { continue }
                if url.lastPathComponent == "manifest.json" {
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
                    guard object?["status"] as? String == "ready" else {
                        throw TeamError.rejected("Сначала завершите или восстановите прерванную съёмку. Затем повторите выгрузку архива.")
                    }
                }
                let components = url.standardizedFileURL.pathComponents.dropFirst(captureRoot.standardizedFileURL.pathComponents.count)
                entries.append(AtlasArchiveEntry(relativePath: "Captures/" + components.joined(separator: "/"), fileURL: url))
            }
        }
        try AtlasArchiveWriter.write(entries: entries, to: destination)
        return destination
    }

    /// Runtime UI checks launch the real app and open a real model through the
    /// normal project repository. This is opt-in fixture data, never a mock
    /// camera session or a replacement renderer in production.
    private func seedPreviewMeshIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--uitest-seed-mesh"), let store else { return }
        let projectID = UUID(uuid: (0xA7, 0x1A, 0x50, 0x00, 0x12, 0x34, 0x40, 0x00,
                                   0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01))
        let frameID = UUID(uuid: (0xA7, 0x1A, 0x50, 0x00, 0x12, 0x34, 0x40, 0x00,
                                 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02))
        do {
            let existing = try await store.project(id: projectID)
            let project: AtlasProject
            if let existing {
                project = existing
            } else {
                project = try await store.saveProject(AtlasProject(id: projectID, name: "Демо · комната", kind: .building,
                    coordinateReference: .localMeters(frameID: frameID),
                    notes: "Синтетическая геометрия для проверки просмотра. Не результат съёмки.",
                    createdAt: Date(timeIntervalSince1970: 0)))
            }
            let output = captureDirectory(for: project)
            let geometry = Data(Self.previewRoomOBJ.utf8)
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try geometry.write(to: output.appendingPathComponent("demo.obj"), options: .atomic)
            }.value
            selectedProjectID = project.id
            await reload()
        } catch {
            issue = "Не удалось подготовить демонстрационную модель: \(error.localizedDescription)"
        }
    }

    /// Twelve actual vertices: floor, three walls and a short inner partition.
    /// The front/ceiling stay open so orbit screenshots show the room's inside.
    /// No ARKit capture marker is used: synthetic data is not an observation.
    private nonisolated static let previewRoomOBJ = """
    # Atlas demonstration. Synthetic room, metres, Y up. Not a capture.
    o DemonstrationRoom
    v -4 0 -3
    v 4 0 -3
    v 4 0 3
    v -4 0 3
    v -4 3 -3
    v 4 3 -3
    v 4 3 3
    v -4 3 3
    v 0 0 -3
    v 0 0 0
    v 0 2.4 0
    v 0 2.4 -3
    f 1 3 2
    f 1 4 3
    f 1 2 6
    f 1 6 5
    f 1 5 8
    f 1 8 4
    f 2 3 7
    f 2 7 6
    f 9 10 11
    f 9 11 12
    """

    func loadDemo() async {
        guard !projects.contains(where: { $0.notes == "atlas-demo" }) else {
            selectedProjectID = projects.first(where: { $0.notes == "atlas-demo" })?.id
            return
        }
        guard let store else { return }
        do {
            let frame = UUID()
            let project = try await store.saveProject(AtlasProject(name: "Северный участок", kind: .cemetery,
                coordinateReference: .localMeters(frameID: frame), notes: "atlas-demo"))
            for row in 0..<3 {
                for column in 0..<4 {
                    let x = Double(column) * 3.4, y = Double(row) * 5.2
                    let polygon = MetricPolygon(frameID: frame, vertices: [
                        MetricPoint2D(x: x, y: y), MetricPoint2D(x: x + 2.4, y: y),
                        MetricPoint2D(x: x + 2.4, y: y + 3.6), MetricPoint2D(x: x, y: y + 3.6)])
                    _ = try await store.saveFeature(AtlasFeature(projectID: project.id,
                        label: String(format: "%03d", row * 4 + column + 1), category: .grave,
                        geometry: .metricPolygon(polygon), attributes: ["source": "demonstration", "sector": "04"],
                        notes: "Демонстрационные данные. Не результат обследования."))
                }
            }
            selectedProjectID = project.id
            await reload()
        } catch { issue = error.localizedDescription }
    }
}

