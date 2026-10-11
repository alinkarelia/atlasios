import SwiftUI
import AtlasCore

/// Offers recovery of committed local checkpoints. The app shows indeterminate
/// progress because Apple's processing/export APIs do not supply a percentage.
@MainActor
struct CaptureRecoveryScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @State private var items: [RecoveryItem] = []
    @State private var isLoading = false
    @State private var recoveringID: String?
    @State private var issue: String?
    @State private var completedMessage: String?
    @State private var didLoadSuccessfully = false
    @State private var hasAttemptedLoad = false

    var body: some View {
        List {
            Section {
                Label("Исходники остаются на устройстве", systemImage: "externaldrive.badge.checkmark")
                    .foregroundStyle(Color.atlasBlue)
                Text("Восстановление использует последний полностью записанный фрагмент. Неснятые поверхности и незаписанные кадры не достраиваются.")
                    .font(.subheadline).foregroundStyle(Color.atlasMuted)
            }
            if let completedMessage {
                Section { Label(completedMessage, systemImage: "checkmark.circle.fill").foregroundStyle(Color.atlasBlue) }
            }
            if isLoading || !hasAttemptedLoad {
                Section { ProgressView("Ищем незавершённые съёмки…") }
            } else if !didLoadSuccessfully {
                Section {
                    ContentUnavailableView("Не удалось проверить файлы", systemImage: "exclamationmark.folder",
                        description: Text("Повторите проверку. Записанные исходники остаются на устройстве."))
                }
            } else if items.isEmpty {
                Section {
                    ContentUnavailableView("Нет локальных съёмок", systemImage: "folder",
                        description: Text("После съёмки здесь появятся записанные метаданные и черновики."))
                }
            } else {
                Section("Съёмки на устройстве") {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.source == .lidar ? "cube.transparent" : "square.split.2x2")
                                    .font(.title3).foregroundStyle(Color.atlasBlue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.headline)
                                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(Color.atlasMuted)
                                    Text(item.statusLabel).font(.caption).foregroundStyle(.orange)
                                }
                                Spacer()
                            }
                            if recoveringID == item.id {
                                ProgressView(item.status == "ready" ? "Обновляем каталог…" : "Восстанавливаем файлы и реестр…").tint(Color.atlasBlue)
                            } else {
                                Button {
                                    Task { await recover(item) }
                                } label: {
                                    Label(item.status == "ready" ? "Обновить каталог файлов" : "Восстановить записанный черновик", systemImage: "arrow.counterclockwise")
                                        .frame(minHeight: 36)
                                }.disabled(recoveringID != nil).foregroundStyle(Color.atlasBlue)
                            }
                            ShareLink(item: item.manifest) {
                                Label("Метаданные исходника", systemImage: "doc.text")
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .navigationTitle("Восстановление").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading || recoveringID != nil).accessibilityLabel("Проверить черновики снова")
            }
        }
        .task { await reload() }
        .alert("Восстановление не завершено", isPresented: Binding(
            get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("Понятно", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
    }

    private func reload() async {
        guard !isLoading, recoveringID == nil else { return }
        isLoading = true
        defer { isLoading = false; hasAttemptedLoad = true }
        let captureDirectory = model.captureDirectory(for: project)
        let managedRoot = model.directory
        let projectID = project.id
        do {
            let found = try await Task.detached(priority: .utility) {
                try Self.discover(in: captureDirectory, within: managedRoot, projectID: projectID)
            }.value
            if !Task.isCancelled { items = found; didLoadSuccessfully = true }
        } catch { issue = error.localizedDescription; didLoadSuccessfully = false }
    }

    private func recover(_ item: RecoveryItem) async {
        guard recoveringID == nil else { return }
        recoveringID = item.id
        issue = nil
        defer { recoveringID = nil }
        do {
            let manifest: URL
            if item.status == "ready" { manifest = item.manifest }
            else {
                switch item.source {
                case .lidar:
                    manifest = try await CaptureCoordinator.recoverIncompleteCapture(at: item.manifest.deletingLastPathComponent())
                case .room:
                    manifest = try await RoomCaptureAdapter.recoverIncompleteCapture(at: item.manifest.deletingLastPathComponent())
                case .object:
                    manifest = try await ObjectCaptureAdapter.recoverIncompleteCapture(at: item.manifest.deletingLastPathComponent())
                }
            }
            // Registration validates paths, project identity and independent
            // frames on a detached worker before persisting the catalogue.
            guard await model.registerCapture(manifest: manifest, project: project) else {
                throw RecoveryError.registration(model.issue ?? "Не удалось добавить файлы в каталог")
            }
            items.removeAll { $0.id == item.id }
            completedMessage = item.status == "ready" ? "Каталог файлов обновлён." : "Черновик восстановлен. Проверьте геометрию и размеры."
        } catch {
            issue = "\(error.localizedDescription) Исходные записанные файлы сохранены."
        }
    }

    private nonisolated static func discover(in directory: URL, within root: URL, projectID: UUID) throws -> [RecoveryItem] {
        let captureRoot = directory.standardizedFileURL.resolvingSymlinksInPath()
        let appRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard captureRoot.path.hasPrefix(appRoot.path + "/") else { throw CaptureCatalog.CatalogError.outsideManagedDirectory }
        guard FileManager.default.fileExists(atPath: captureRoot.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: captureRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var result = [RecoveryItem]()
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "manifest.json" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 2 * 1_024 * 1_024,
                  url.resolvingSymlinksInPath().path.hasPrefix(captureRoot.path + "/") else { continue }
            let manifest = try decoder.decode(RecoveryManifest.self, from: Data(contentsOf: url))
            guard manifest.projectID == projectID else { continue }
            let source: RecoverySource
            switch manifest.source {
            case "ARKit.sceneReconstruction": source = .lidar
            case "RoomPlan": source = .room
            case "ObjectCapture": source = .object
            default: continue
            }
            result.append(RecoveryItem(manifest: url, source: source, createdAt: manifest.createdAt,
                status: manifest.status, segmentCount: manifest.segments?.count ?? 1))
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private enum RecoverySource: Sendable { case lidar, room, object }
    private struct RecoveryItem: Identifiable, Sendable {
        var manifest: URL
        var source: RecoverySource
        var createdAt: Date
        var status: String
        var segmentCount: Int
        var id: String { manifest.path }
        var title: String {
            switch source {
            case .lidar: "LiDAR · фрагментов: \(segmentCount)"
            case .room: "Обмер RoomPlan"
            case .object: "Объект · оригинальные фотографии"
            }
        }
        var statusLabel: String {
            switch status {
            case "recording": "Съёмка не завершена"
            case "paused": "Съёмка приостановлена"
            case "interrupted": "Съёмка прервана"
            case "exporting", "processing": "Обработка не завершена"
            case "ready": "Файлы готовы · можно обновить реестр"
            default: "Доступен локальный черновик"
            }
        }
    }
    private struct RecoveryManifest: Decodable {
        struct Segment: Decodable { var id: UUID }
        var source: String
        var projectID: UUID
        var createdAt: Date
        var status: String
        var segments: [Segment]?
    }
    private enum RecoveryError: LocalizedError {
        case registration(String)
        var errorDescription: String? {
            switch self {
            case let .registration(message): "Файлы восстановлены, но не добавлены в реестр: \(message)"
            }
        }
    }
}
