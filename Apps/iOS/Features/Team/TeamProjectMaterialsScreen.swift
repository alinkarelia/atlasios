import SwiftUI
import AtlasCore

struct TeamProjectMaterialsScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @ObservedObject private var coordinator: FieldTransferCoordinator
    @ObservedObject private var team: TeamService
    @State private var materials: [RemoteFieldMaterial] = []
    @State private var loading = true
    @State private var issue: String?
    @State private var selectedMaterial: RemoteFieldMaterial?
    @State private var requestID = UUID()

    init(model: AtlasAppModel, project: AtlasProject) {
        self.model = model
        self.project = project
        _coordinator = ObservedObject(wrappedValue: model.transfers)
        _team = ObservedObject(wrappedValue: model.team)
    }

    var body: some View {
        List {
            Section {
                Text(project.name).font(.headline)
                Text("Здесь только комплекты, целостность которых подтвердил сервер. Скачать можно исходники вместе с паспортом данных.")
                    .font(.subheadline).foregroundStyle(Color.atlasMuted)
            }.listRowBackground(Color.atlasCard)
            Section {
                if loading {
                    ProgressView("Загружаем список…").tint(.atlasAccent)
                } else if let issue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                    Button("Повторить") { Task { await reload() } }
                } else if materials.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Материалов пока нет", systemImage: "tray")
                            .font(.headline)
                        Text("После полной передачи комплекты сотрудников появятся в этом проекте.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    }.padding(.vertical, 5)
                }
                ForEach(materials) { material in
                    Button { selectedMaterial = material } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.atlasAccent).font(.title3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(material.manifest.title).font(.headline).foregroundStyle(Color.atlasInk)
                                Text(material.author.displayName).font(.subheadline).foregroundStyle(Color.atlasMuted)
                                Text("\(material.manifest.assets.count) файлов · \(byteLabel(material.manifest.totalBytes))")
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                                if let received = material.completedAt {
                                    Text("Получено \(received.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(Color.atlasMuted)
                                }
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").foregroundStyle(Color.atlasMuted)
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("transfer.remote.\(material.captureID.uuidString)")
                }
            } header: { Text("Полученные комплекты") } footer: {
                Text("Получение файлов и проверка карточек — разные этапы. Подтверждение доставки не означает, что специалист проверил сведения и границы объектов.")
            }.listRowBackground(Color.atlasCard)
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk).tint(.atlasAccent)
        .navigationTitle("Материалы команды").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: team.selectedOrganizationID) { await reload() }
        .refreshable { await reload() }
        .onChange(of: team.user?.id) { _, _ in
            materials = []; selectedMaterial = nil
            Task { await reload() }
        }
        .onChange(of: team.selectedOrganizationID) { _, _ in
            materials = []; selectedMaterial = nil
        }
        .sheet(item: $selectedMaterial) { material in
            NavigationStack {
                TeamMaterialDetailScreen(model: model, project: project, material: material)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") { selectedMaterial = nil }
                        }
                    }
            }
        }
    }

    private func reload() async {
        let identifier = UUID()
        requestID = identifier
        loading = true; issue = nil; materials = []
        do {
            let values = try await coordinator.remoteMaterials(projectID: project.id)
            guard requestID == identifier, !Task.isCancelled else { return }
            materials = values.sorted { ($0.completedAt ?? $0.receivedAt) > ($1.completedAt ?? $1.receivedAt) }
        } catch {
            guard requestID == identifier, !Task.isCancelled else { return }
            issue = error.localizedDescription
        }
        loading = false
    }

    private func byteLabel(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct TeamMaterialDetailScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let material: RemoteFieldMaterial
    @ObservedObject private var coordinator: FieldTransferCoordinator
    @State private var downloading = false
    @State private var downloaded: DownloadedFieldMaterial?
    @State private var passportURL: URL?
    @State private var meshURL: URL?
    @State private var issue: String?

    init(model: AtlasAppModel, project: AtlasProject, material: RemoteFieldMaterial) {
        self.model = model; self.project = project; self.material = material
        _coordinator = ObservedObject(wrappedValue: model.transfers)
    }

    var body: some View {
        List {
            Section("Паспорт комплекта") {
                LabeledContent("Проект", value: project.name)
                LabeledContent("Отправил", value: material.author.displayName)
                if let date = material.completedAt {
                    LabeledContent("Получено полностью", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Часовой пояс комплекта", value: material.manifest.timeZoneIdentifier)
                if let device = material.manifest.device {
                    LabeledContent("Комплект подготовлен на", value: device.model)
                    LabeledContent("Система подготовки", value: device.osVersion)
                    LabeledContent("Atlas при подготовке", value: device.appVersion)
                }
                Text("Даты ниже показаны в часовом поясе этого iPhone. Исходные значения времени и геометок сохраняются в паспорте.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }.listRowBackground(Color.atlasCard)
            Section("Материалы и геометки") {
                ForEach(material.manifest.materials) { value in materialRow(value) }
            }.listRowBackground(Color.atlasCard)
            Section {
                Button {
                    Task { await download() }
                } label: {
                    if downloading { ProgressView("Скачиваем и проверяем файлы…").tint(.atlasAccent) }
                    else { Label(downloaded == nil ? "Скачать комплект" : "Проверить и скачать повторно", systemImage: "arrow.down.doc") }
                }.disabled(downloading)
                    .accessibilityIdentifier("transfer.downloadMaterial")
                if let passportURL {
                    ShareLink(item: passportURL) { Label("Поделиться паспортом JSON", systemImage: "square.and.arrow.up") }
                }
                if let downloaded {
                    Label("Копия скачана и проверена", systemImage: "checkmark.shield")
                        .foregroundStyle(Color.atlasAccent)
                    ForEach(material.manifest.assets) { asset in
                        if let url = try? FieldTransferPaths.resolve(relativePath: asset.relativePath, root: downloaded.directory) {
                            if ["obj", "usdz"].contains(url.pathExtension.lowercased()) {
                                Button { meshURL = url } label: {
                                    Label("Открыть 3D-модель", systemImage: "cube.transparent")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("transfer.openModel.\(asset.id.uuidString)")
                                .accessibilityHint("\(url.lastPathComponent): вращение модели, масштаб и свободный просмотр")
                            }
                            ShareLink(item: url) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: asset.relativePath).lastPathComponent)
                                        .lineLimit(2).font(.subheadline)
                                    Text(byteLabel(asset.byteCount)).font(.caption).foregroundStyle(Color.atlasMuted)
                                }
                            }.buttonStyle(.borderless)
                                .accessibilityLabel("Поделиться файлом \(URL(fileURLWithPath: asset.relativePath).lastPathComponent)")
                        }
                    }
                }
            } header: { Text("Исходники") } footer: {
                Text("Скачанная копия хранится отдельно от вашей текущей съёмки. Файлы можно передать через меню «Поделиться». Текущие карточки и исходники проекта не перезаписываются.")
            }.listRowBackground(Color.atlasCard)
            if let issue {
                Section { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange) }
                    .listRowBackground(Color.atlasCard)
            }
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk).tint(.atlasAccent)
        .navigationTitle(material.manifest.title).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: Binding(get: { meshURL != nil }, set: { if !$0 { meshURL = nil } })) {
            if let meshURL {
                NavigationStack {
                    MeshPreviewScreen(url: meshURL)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Закрыть") { self.meshURL = nil }
                            }
                        }
                        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                }
            }
        }
    }

    private func materialRow(_ value: FieldMaterial) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(materialTitle(value.kind)).font(.subheadline.weight(.semibold))
            if let capturedAt = value.capturedAt {
                Text("Снято \(capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            } else if value.kind == .photo || value.kind == .mesh {
                Text("Исходное время съёмки неизвестно")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }
            if let importedAt = value.importedAt {
                Text("Импортировано \(importedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            }
            if let tag = value.geoTag, let fix = tag.effectiveFix {
                Text(String(format: "%.6f, %.6f", fix.coordinate.latitude, fix.coordinate.longitude))
                    .font(.footnote.monospaced()).textSelection(.enabled)
                Text(geoSourceTitle(fix.source)).font(.caption).foregroundStyle(Color.atlasMuted)
                if let accuracy = fix.horizontalAccuracyMeters {
                    Text(String(format: fix.source == .operatorEntered ? "Оценка погрешности оператором ±%.1f м" : "Погрешность положения ±%.1f м", accuracy))
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                } else {
                    Text("Погрешность положения неизвестна").font(.caption).foregroundStyle(Color.atlasMuted)
                }
                if !tag.corrections.isEmpty {
                    Text("Исправлений геометки: \(tag.corrections.count). История сохранена в паспорте.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                if fix.isSimulated {
                    Label("Имитированное положение", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(Color.orange)
                }
            } else if value.kind == .photo || value.kind == .mesh {
                Text("Геометка отсутствует").font(.caption).foregroundStyle(Color.atlasMuted)
            }
        }.padding(.vertical, 4)
    }

    private func download() async {
        guard !downloading else { return }
        downloading = true; issue = nil; downloaded = nil; passportURL = nil; meshURL = nil
        defer { downloading = false }
        do {
            let destination = model.directory.appendingPathComponent("TeamDownloads", isDirectory: true)
                .appendingPathComponent(project.id.uuidString, isDirectory: true)
            let verified = try await coordinator.download(material: material, to: destination)
            let passportDirectory = model.directory.appendingPathComponent("Exports", isDirectory: true)
                .appendingPathComponent("TeamPassports", isDirectory: true)
            let passport = passportDirectory.appendingPathComponent("material-\(material.captureID.uuidString)-\(UUID().uuidString).json")
            let payload = try FieldTransferJSON.encode(material, pretty: true)
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: passportDirectory, withIntermediateDirectories: true)
                try payload.write(to: passport, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }.value
            downloaded = verified
            passportURL = passport
        } catch { issue = error.localizedDescription }
    }

    private func byteLabel(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func materialTitle(_ kind: FieldMaterialKind) -> String {
        switch kind {
        case .photo: "Фотография"
        case .mesh: "3D-съёмка"
        case .floorPlan: "План помещения"
        case .feature: "Карточка и геометрия"
        case .measurement: "Измерение"
        case .project: "Проект"
        }
    }

    private func geoSourceTitle(_ source: GeoFixSource) -> String {
        switch source {
        case .deviceLocation: "Положение определено iPhone"
        case .photoEXIF: "Положение из исходного фото"
        case .operatorEntered: "Положение указано оператором"
        }
    }
}
