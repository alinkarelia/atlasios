import Foundation
import SwiftUI
import UIKit
import AtlasCore

@MainActor
final class AtlasAppModel: ObservableObject {
    @Published private(set) var projects: [AtlasProject] = []
    @Published var selectedProjectID: UUID?
    @Published var issue: String?
    @Published private(set) var ready = false
    @Published private(set) var storeAvailable = false
    let team = TeamService()
    let directory: URL
    lazy var transfers = FieldTransferCoordinator(team: team, directory: directory)
    private var measurementRepository: MeasurementRepository?
    private var store: AtlasStore?
    private var started = false
    private var transferPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var transferPreparationTickets: [UUID: UUID] = [:]

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
        await seedCemeteryIfRequested()
        await seedBuildingIfRequested()
        await seedTourIfRequested()
        ready = true
        if team.connected { await team.refresh() }
        await transfers.refresh()
        transfers.sceneBecameActive()
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

    func featureHistory(_ feature: AtlasFeature) async -> [AtlasFeature] {
        do { return try await store?.featureHistory(featureID: feature.id, projectID: feature.projectID) ?? [] }
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
        do {
            let saved = try await measurementRepository.save(measurement)
            fieldMaterialsDidChange(projectID: measurement.projectID)
            return saved
        }
        catch { issue = error.localizedDescription; return nil }
    }

    func correctGeoTag(of scan: ScanRecord, with correction: GeoTagCorrection) async throws -> ScanRecord {
        guard let store else { throw TeamError.rejected("Каталог съёмок недоступен.") }
        var updated = scan
        var tag = updated.geoTag ?? GeoTag()
        tag.corrections.append(correction)
        try GeoTagPolicy.validate(tag)
        updated.geoTag = tag
        let saved = try await store.saveScan(updated)
        fieldMaterialsDidChange(projectID: scan.projectID)
        return saved
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
            fieldMaterialsDidChange(projectID: project.id)
            return true
        } catch { issue = "Файлы съёмки сохранены, но каталог не обновился: \(error.localizedDescription). Откройте восстановление съёмок."; return false }
    }

    @discardableResult
    func saveFeature(_ feature: AtlasFeature) async -> AtlasFeature? {
        do {
            let saved = try await store?.saveFeature(feature)
            if saved != nil { fieldMaterialsDidChange(projectID: feature.projectID) }
            return saved
        }
        catch { issue = error.localizedDescription; return nil }
    }

    @discardableResult
    func savePlan(_ plan: AtlasFloorPlan) async -> AtlasFloorPlan? {
        do {
            let saved = try await store?.saveFloorPlan(plan)
            if saved != nil { fieldMaterialsDidChange(projectID: plan.projectID) }
            return saved
        }
        catch { issue = error.localizedDescription; return nil }
    }

    func export(project: AtlasProject, format: ExportFormat) async -> URL? {
        guard let snapshot = await snapshot(of: project) else { return nil }
        do {
            let artifact = try AtlasExporter.export(snapshot, format: format)
            let exportDirectory = directory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let suffix = artifact.fileName.hasSuffix(".atlas.json") ? "atlas.json" : URL(fileURLWithPath: artifact.fileName).pathExtension
            let name = try ExportFileNaming.project(projectName: project.name, projectID: project.id,
                role: format.rawValue, fileExtension: suffix)
            let url = exportDirectory.appendingPathComponent(name)
            try artifact.data.write(to: url, options: .atomic)
            if !artifact.warnings.isEmpty { issue = artifact.warnings.joined(separator: "\n") }
            return url
        } catch { issue = error.localizedDescription; return nil }
    }

    func exportMaterialTable(project: AtlasProject) async -> URL? {
        guard let snapshot = await snapshot(of: project) else { return nil }
        do {
            let passportData = try await transfers.deliveryPassport(snapshot: snapshot, assetDirectory: directory)
            let passport = try FieldTransferJSON.decode(FieldDeliveryPassport.self, from: passportData)
            let artifact = try await Task.detached(priority: .utility) {
                try AtlasExporter.exportMaterialMetadata(projectID: passport.projectID, projectName: passport.projectName,
                    materials: passport.materials.map(\.source), assets: passport.assets)
            }.value
            let exports = directory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            let name = try ExportFileNaming.project(projectName: project.name, projectID: project.id,
                role: "materials", fileExtension: "csv")
            let file = exports.appendingPathComponent(name)
            try artifact.data.write(to: file, options: .atomic)
            return file
        } catch { issue = error.localizedDescription; return nil }
    }

    /// Saving a source never waits for a server. Capture the destination before
    /// debouncing so a later task switch cannot redirect this saved material.
    func fieldMaterialsDidChange(projectID: UUID) {
        transferPreparationTasks[projectID]?.cancel()
        guard let originalScope = team.transferScope else { return }
        let ticket = UUID()
        transferPreparationTickets[projectID] = ticket
        transferPreparationTasks[projectID] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self else { return }
            defer {
                if self.transferPreparationTickets[projectID] == ticket {
                    self.transferPreparationTasks[projectID] = nil
                    self.transferPreparationTickets[projectID] = nil
                }
            }
            guard !Task.isCancelled,
                  let project = self.projects.first(where: { $0.id == projectID }) else { return }
            do { try self.team.requireCurrentScope(originalScope) } catch { return }
            let preferences = await self.transfers.settings(projectID: projectID)
            guard !Task.isCancelled else { return }
            do { try self.team.requireCurrentScope(originalScope) } catch { return }
            guard preferences.policy == .automatic else { return }
            // Staging is local and durable even offline or after runtime expiry.
            // The coordinator renews before obtaining any network context.
            _ = await self.prepareFieldTransfer(project: project, expectedScope: originalScope)
        }
    }

    @discardableResult
    func prepareFieldTransfer(project: AtlasProject, expectedContext: TeamTransferContext? = nil,
                              expectedScope: FieldTransferScope? = nil) async -> Bool {
        guard let scope = expectedScope ?? expectedContext?.scope ?? team.transferScope else { return false }
        do { try Task.checkCancellation(); try team.requireCurrentScope(scope) } catch { return false }
        guard let snapshot = await snapshot(of: project) else { return false }
        do { try Task.checkCancellation(); try team.requireCurrentScope(scope) } catch { return false }
        return await transfers.prepare(snapshot: snapshot, assetDirectory: directory, expectedScope: scope)
    }

    func sendFieldMaterials(project: AtlasProject) async {
        guard let scope = team.transferScope else { return }
        transferPreparationTasks[project.id]?.cancel()
        transferPreparationTasks[project.id] = nil
        transferPreparationTickets[project.id] = nil
        // Stage source bytes and the operator's intent before any network
        // renewal. A missing connection must not lose a manual send request.
        guard await prepareFieldTransfer(project: project, expectedScope: scope) else { return }
        do { try Task.checkCancellation(); try team.requireCurrentScope(scope) } catch { return }
        await transfers.send(projectID: project.id, expectedScope: scope)
    }

    func openSharedProject(_ remote: RemoteProject) async -> AtlasProject? {
        guard let store else { return nil }
        guard let scope = team.transferScope else { return nil }
        do {
            _ = try await transfers.renewConnection(expectedScope: scope)
            let incoming = try await team.sharedProject(remote)
            try team.requireCurrentScope(scope)
            if let existing = projects.first(where: { $0.id == incoming.id }) {
                guard existing.coordinateReference == incoming.coordinateReference else {
                    throw TeamError.rejected("Система координат локального проекта отличается. Исходники сохранены; автоматическое объединение остановлено.")
                }
                selectedProjectID = existing.id
                return existing
            }
            var local = incoming
            local.revision = 0
            let saved = try await store.saveProject(local)
            selectedProjectID = saved.id
            await reload()
            return saved
        } catch { issue = error.localizedDescription; return nil }
    }

    func captureDirectory(for project: AtlasProject) -> URL {
        directory.appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    /// A shared plan retains its project and boundary IDs on every phone.
    /// Local database revisions remain local; original geometry is never replaced.
    func openCollaborativePlan(_ document: CollaborativeSurveyStoredPlan) async throws -> AtlasProject {
        guard let store else { throw TeamError.rejected("Хранилище проектов недоступно.") }
        try document.validate()
        let existing = try await store.projects().first { $0.id == document.projectID }
        if let existing, existing.coordinateReference != document.plan.coordinateReference {
            throw TeamError.rejected("Система координат проекта отличается от плана команды.")
        }
        let known = try await store.features(projectID: document.projectID).first { $0.id == document.sourceFeatureID }
        if let known, known.geometry != document.plan.sourceBoundary {
            throw TeamError.rejected("Граница этого проекта уже изменена. Исходная граница сохранена; импорт остановлен.")
        }
        if let known, let category = document.sourceFeatureCategory, known.category != category {
            throw TeamError.rejected("Тип исходного участка отличается от плана команды. Проверьте карточку участка; импорт не меняет её автоматически.")
        }
        let project: AtlasProject
        if let existing { project = existing }
        else {
            project = try await store.saveProject(AtlasProject(id: document.projectID,
                name: document.projectName ?? "Совместная съёмка", kind: document.projectKind ?? .site,
                coordinateReference: document.plan.coordinateReference))
        }
        if known == nil {
            let boundary = AtlasFeature(id: document.sourceFeatureID, projectID: project.id,
                label: document.sourceFeatureLabel ?? "Граница совместной съёмки",
                category: document.sourceFeatureCategory ?? .boundary,
                geometry: document.plan.sourceBoundary, attributes: [
                    "collaboration.boundaryOrigin": "plan-import",
                    "collaboration.sourceFeatureRevision": String(document.sourceFeatureRevision),
                    "collaboration.sourceBoundarySHA256": document.plan.sourceBoundarySHA256])
            _ = try await store.saveFeature(boundary)
        }
        return project
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
            let passport = staging.appendingPathComponent("delivery-passport.json")
            let passportData = try await transfers.deliveryPassport(snapshot: snapshot, assetDirectory: directory)
            var histories: [AssistantFeatureHistory.Entry] = []
            var totalRevisions = 0
            if let store {
                for feature in snapshot.features {
                    var values: [AtlasFeature] = []
                    var cursor: Int64? = feature.revision == Int64.max ? nil : feature.revision + 1
                    while true {
                        try Task.checkCancellation()
                        let page = try await store.featureHistory(featureID: feature.id, projectID: project.id,
                                                                  limit: 100, beforeRevision: cursor)
                        if page.isEmpty { break }
                        totalRevisions += page.count
                        guard totalRevisions <= 100_000 else {
                            throw TeamError.rejected("История проекта слишком большая для одного архива. Исходники сохранены; разделите обследование.")
                        }
                        values.insert(contentsOf: page, at: 0)
                        cursor = page.first?.revision
                    }
                    histories.append(.init(featureID: feature.id, revisions: values))
                }
            }
            let retainedHistories = histories
            let captureRoot = captureDirectory(for: project)
            let name = try ExportFileNaming.project(projectName: project.name, projectID: project.id,
                role: "full-project", fileExtension: "zip")
            let destination = exportDirectory.appendingPathComponent(name)
            return try await Task.detached(priority: .utility) {
                let files = try AssistantProjectPackage.prepare(snapshot: snapshot, passportData: passportData,
                    histories: retainedHistories, staging: staging)
                return try Self.writeArchive(metadata: metadata, passport: passport, packageFiles: files,
                                             project: snapshot.project, availableScans: snapshot.scans, captureRoot: captureRoot, destination: destination)
            }.value
        } catch { issue = error.localizedDescription; return nil }
    }

    /// DirectoryEnumerator's iterator is synchronous on current Apple SDKs.
    /// The detached utility task calls this helper without moving file IO onto
    /// MainActor or allowing the enumerator to cross a suspension point.
    private nonisolated static func writeArchive(metadata: URL, passport: URL, packageFiles: [URL],
                                               project: AtlasProject, availableScans: [ScanRecord], captureRoot: URL, destination: URL) throws -> URL {
        let delivery = try FieldTransferJSON.decode(FieldDeliveryPassport.self, from: Data(contentsOf: passport))
        guard delivery.projectID == project.id,
              captureRoot.lastPathComponent == "Captures",
              captureRoot.deletingLastPathComponent().lastPathComponent == project.id.uuidString,
              captureRoot.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Projects" else {
            throw AtlasExportError.entityProjectMismatch
        }
        var hashes: [String: String] = [:]
        for asset in delivery.assets {
            guard hashes.updateValue(asset.sha256, forKey: asset.relativePath) == nil else {
                throw AtlasArchiveError.duplicatePath(asset.relativePath)
            }
        }
        var entries = [AtlasArchiveEntry(relativePath: "project.json", fileURL: metadata,
                                        expectedSHA256: hashes["project.json"]),
                       AtlasArchiveEntry(relativePath: "delivery-passport.json", fileURL: passport)]
        for file in packageFiles {
            guard let hash = hashes[file.lastPathComponent] else { throw AtlasArchiveError.sourceChanged(file.lastPathComponent) }
            entries.append(AtlasArchiveEntry(relativePath: file.lastPathComponent, fileURL: file, expectedSHA256: hash))
        }
        let assetDirectory = captureRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let journalEntries = try ProjectJournalExport.archiveEntries(project: project,
            assetDirectory: assetDirectory, passportAssets: delivery.assets, availableScans: availableScans)
        // StationSurvey is already enumerated as an original Captures member
        // below. Model journals are its sibling at the ZIP root.
        entries.append(contentsOf: journalEntries.filter { $0.relativePath.hasPrefix("ModelMeasurements/") })
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
                let path = "Captures/" + components.joined(separator: "/")
                guard let hash = hashes[path] else { throw AtlasArchiveError.sourceChanged(path) }
                entries.append(AtlasArchiveEntry(relativePath: path, fileURL: url, expectedSHA256: hash))
            }
        }
        guard Set(entries.map(\.relativePath).filter { $0 != "delivery-passport.json" }) == Set(hashes.keys) else {
            throw AtlasArchiveError.sourceChanged("delivery-passport.json")
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

    /// Explicit runtime fixtures exercise normal SQLite/card/map flows. These
    /// records are labelled synthetic; they do not impersonate a sensor survey.
    private func seedCemeteryIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--uitest-seed-cemetery"), let store else { return }
        let projectID = UUID(uuidString: "A71A5000-1234-4000-8000-000000000101")!
        let cemeteryID = UUID(uuidString: "A71A5000-1234-4000-8000-000000000102")!
        do {
            let project: AtlasProject
            if let existing = try await store.project(id: projectID) { project = existing }
            else {
                project = try await store.saveProject(AtlasProject(id: projectID,
                    name: "Демо · полевое обследование", kind: .cemetery, coordinateReference: .wgs84,
                    notes: "Синтетические данные для проверки интерфейса. Не результат обследования."))
                let origin = GeographicCoordinate(longitude: 30.312, latitude: 59.951)
                let cemetery = AtlasFeature(id: cemeteryID, projectID: projectID,
                    label: "Учебное кладбище", category: .cemetery,
                    geometry: .geographicPolygon(.init(vertices: [origin,
                        .init(longitude: 30.313, latitude: 59.951),
                        .init(longitude: 30.313, latitude: 59.9516),
                        .init(longitude: 30.312, latitude: 59.9516)])),
                    attributes: ["source": "demonstration", "survey.status": "confirmed"],
                    notes: "Учебный участок. Требуется уборка у северного входа.")
                _ = try await store.saveFeature(cemetery)
                for (suffix, label, longitude, status) in [(103, "Участок 001", 30.31235, "confirmed"),
                                                          (104, "Аномалия 002", 30.31255, "candidate")] {
                    let id = UUID(uuidString: String(format: "A71A5000-1234-4000-8000-%012d", suffix))!
                    var feature = AtlasFeature(id: id, projectID: projectID, label: label, category: .grave,
                        geometry: .geographicPoint(.init(longitude: longitude, latitude: 59.9513)),
                        attributes: ["source": "demonstration", "survey.status": status],
                        notes: "Синтетическая точка для проверки карточки.")
                    feature = try BurialMetadata(cemeteryID: cemeteryID, visibleSigns: [.mound],
                        condition: "Требует осмотра", identityStatus: .unknown).applying(to: feature)
                    _ = try await store.saveFeature(feature)
                }
                let fence = AtlasFeature(projectID: projectID, label: "Северная ограда", category: .fence,
                    geometry: .geographicPolyline(.init(vertices: [
                        .init(longitude: 30.312, latitude: 59.9516), .init(longitude: 30.313, latitude: 59.9516)])),
                    attributes: ["source": "demonstration", "cemeteryID": cemeteryID.uuidString])
                _ = try await store.saveFeature(fence)
            }
            selectedProjectID = project.id
            await reload()
        } catch { issue = "Не удалось подготовить учебное обследование: \(error.localizedDescription)" }
    }

    private func seedTourIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--uitest-seed-tour"), let store else { return }
        let projectID = UUID(uuidString: "A71A5000-1234-4000-8000-000000000101")!
        guard let project = try? await store.project(id: projectID) else { return }
        let captures = captureDirectory(for: project)
        let tourStore = TourStore()
        do {
            if try await tourStore.load(projectID: projectID, directory: captures).contains(where: { $0.title == "Учебная прогулка" }) { return }
            let cemeteryID = UUID(uuidString: "A71A5000-1234-4000-8000-000000000102")!
            let graveID = UUID(uuidString: "A71A5000-1234-4000-8000-000000000103")!
            let roadID = UUID(uuidString: "A71A5000-1234-4000-8000-000000000105")!
            let known = try await store.features(projectID: projectID)
            if !known.contains(where: { $0.id == roadID }) {
                _ = try await store.saveFeature(AtlasFeature(id: roadID, projectID: projectID, label: "Учебная тропинка", category: .path,
                    geometry: .geographicPolyline(.init(vertices: [.init(longitude: 30.3122, latitude: 59.9511), .init(longitude: 30.3128, latitude: 59.9511)])),
                    attributes: ["source": "demonstration", "cemeteryID": cemeteryID.uuidString]))
            }
            var tour = TourManifest(projectID: projectID, title: "Учебная прогулка")
            let evidence = EvidenceService()
            for index in 1...2 {
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_280, height: 720))
                let data = renderer.pngData { context in
                    UIColor(red: index == 1 ? 0.15 : 0.28, green: 0.3, blue: 0.28, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 1_280, height: 720))
                    UIColor.lightGray.setFill()
                    context.fill(CGRect(x: 430, y: 170, width: 420, height: 380))
                    ("Синтетическая остановка \(index)\nНе результат съёмки" as NSString).draw(at: CGPoint(x: 50, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.white])
                }
                let photo = try await evidence.importPhoto(data: data, projectID: projectID, outputDirectory: captures, recognizeText: false)
                var station = TourStation(photo: photo, number: index)
                station.name = "Учебная остановка \(index)"
                station.comment = "Синтетическая фотография для проверки переходов и карточек."
                station.annotations = [
                    TourAnnotation(featureID: graveID, vertices: [.init(x: 0.33, y: 0.23), .init(x: 0.67, y: 0.23), .init(x: 0.67, y: 0.77), .init(x: 0.33, y: 0.77)]),
                    TourAnnotation(featureID: roadID, vertices: [.init(x: 0.05, y: 0.85), .init(x: 0.95, y: 0.85)], kind: .polyline)
                ]
                tour.stations.append(station)
            }
            _ = try await tourStore.save(tour, directory: captures, projectID: projectID)
        } catch { issue = "Не удалось подготовить учебную прогулку: \(error.localizedDescription)" }
    }

    private func seedBuildingIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--uitest-seed-building"), let store else { return }
        let projectID = UUID(uuidString: "A71A5000-1234-4000-8000-000000000201")!
        let frameID = UUID(uuidString: "A71A5000-1234-4000-8000-000000000202")!
        do {
            let project: AtlasProject
            if let existing = try await store.project(id: projectID) { project = existing }
            else {
                project = try await store.saveProject(AtlasProject(id: projectID, name: "Демо · этажи здания", kind: .building,
                    coordinateReference: .localMeters(frameID: frameID),
                    notes: "Синтетические планы для проверки интерфейса. Не результат обмера."))
                for floor in 1...2 {
                    let localFrame = floor == 1 ? frameID : UUID(uuidString: "A71A5000-1234-4000-8000-000000000205")!
                    let boundary = MetricPolygon(frameID: localFrame, vertices: [
                        .init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 3), .init(x: 0, y: 3)])
                    let walls = boundary.vertices.indices.map { index in
                        PlanWall(start: boundary.vertices[index], end: boundary.vertices[(index + 1) % boundary.vertices.count],
                                 heightMeters: 2.5, thicknessMeters: 0.15)
                    }
                    let id = UUID(uuidString: String(format: "A71A5000-1234-4000-8000-%012d", 202 + floor))!
                    _ = try await store.saveFloorPlan(AtlasFloorPlan(id: id, projectID: project.id, frameID: localFrame,
                        name: "Учебный обмер · этаж \(floor)", floorIndex: floor,
                        rooms: [PlanRoom(name: "Учебная комната", boundary: boundary)], walls: walls))
                }
            }
            selectedProjectID = project.id
            await reload()
        } catch { issue = "Не удалось подготовить учебные планы: \(error.localizedDescription)" }
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

