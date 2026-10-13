import SwiftUI
import AtlasCore
import ImageIO
import UniformTypeIdentifiers

extension ProjectKind {
    var title: String {
        switch self {
        case .cemetery: "Кладбище"
        case .building: "Здание"
        case .objectScan: "3D-объект"
        case .site: "Территория"
        }
    }
    var symbol: String {
        switch self {
        case .cemetery: "square.3.layers.3d"
        case .building: "house"
        case .objectScan: "cube.transparent"
        case .site: "map"
        }
    }
}

struct ProjectsScreen: View {
    @ObservedObject var model: AtlasAppModel
    @State private var showCreate = false
    @State private var showPlanImport = false
    @State private var summary: ProjectSummary?

    private struct ProjectSummary {
        let projectID: UUID
        let scanCount: Int
        let planCount: Int
        let featureCount: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.atlasAccent)
                        Text(AppBrand.displayName.uppercased()).font(.caption.weight(.bold)).tracking(2)
                    }.accessibilityElement(children: .combine)
                    Spacer()
                    NavigationLink {
                        TeamConnectionScreen(model: model)
                    } label: {
                        Label("Команда", systemImage: "person.2")
                    }.buttonStyle(AtlasSecondaryButtonStyle())
                        .accessibilityHint("Подключение к рабочему пространству команды")
                }
                if let project = model.selectedProject {
                    NavigationLink {
                        ProjectDetailScreen(model: model, project: project)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            ProjectPreview(project: project, directory: model.captureDirectory(for: project))
                                .frame(height: 230).clipped()
                                .overlay(alignment: .topLeading) {
                                    Label(project.kind.title, systemImage: project.kind.symbol)
                                        .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(Color.atlasCanvas.opacity(0.9), in: Capsule()).padding(16)
                                }
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(project.name).font(.title2.weight(.bold)).foregroundStyle(Color.atlasInk)
                                        Label(project.notes == "atlas-demo" ? "Демонстрационные данные" : "Сохранён на iPhone", systemImage: "externaldrive")
                                            .font(.caption).foregroundStyle(Color.atlasMuted)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right").foregroundStyle(Color.atlasMuted)
                                        .padding(10).background(Color.atlasCanvas, in: Circle())
                                }
                                if let summary, summary.projectID == project.id {
                                    HStack(spacing: 0) {
                                        projectMetric(summary.scanCount, title: "Съёмок", symbol: "viewfinder")
                                        projectMetric(summary.planCount, title: "Планов", symbol: "square.split.2x2")
                                        projectMetric(summary.featureCount, title: "Объектов", symbol: "map")
                                    }.padding(.top, 2)
                                }
                            }.padding(20)
                        }
                        .background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 24))
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.atlasLine, lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityHint("Открыть модели, планы и данные проекта")
                        .accessibilityIdentifier("projects.openSelected")
                    NavigationLink {
                        CaptureScreen(project: project, outputDirectory: model.captureDirectory(for: project), onSaved: { manifest in
                            Task { await model.registerCapture(manifest: manifest, project: project) }
                        }, onFloorPlan: { plan in
                            Task { await model.savePlan(plan) }
                        }, onEvidenceSaved: { model.fieldMaterialsDidChange(projectID: project.id) })
                    } label: {
                        Label("Начать съёмку", systemImage: "viewfinder")
                    }.buttonStyle(AtlasPrimaryButtonStyle())
                        .accessibilityIdentifier("projects.startCapture")
                    HStack {
                        AtlasSectionLabel(title: "Все проекты")
                        Spacer()
                        Text("\(model.projects.count)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.atlasMuted)
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(model.projects, id: \.id) { item in
                            NavigationLink {
                                ProjectDetailScreen(model: model, project: item)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: item.kind.symbol).font(.title2)
                                        .foregroundStyle(Color.atlasAccent)
                                        .frame(width: 48, height: 48)
                                        .background(Color.atlasCanvas, in: RoundedRectangle(cornerRadius: 16))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.name).font(.headline).foregroundStyle(Color.atlasInk)
                                        Text(item.kind.title).font(.subheadline).foregroundStyle(Color.atlasMuted)
                                    }
                                    Spacer()
                                    if item.id == project.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.atlasAccent)
                                            .accessibilityLabel("Текущий проект")
                                    }
                                    Image(systemName: "chevron.right").foregroundStyle(Color.atlasMuted)
                                }.padding(14).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { model.selectedProjectID = item.id })
                        }
                    }
                } else {
                    emptyProjects
                    AtlasPrimaryButton(title: "Создать проект", systemImage: "plus") { showCreate = true }
                        .accessibilityIdentifier("projects.create")
                    Button { Task { await model.loadDemo() } } label: {
                        Label("Изучить демопроект", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(AtlasSecondaryButtonStyle()).accessibilityIdentifier("projects.demo")
                    Text("Демопроект поможет изучить полигоны и карточки. Его данные не являются результатом обследования.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted).multilineTextAlignment(.center)
                }
            }.padding(20)
        }
        .background(Color.atlasCanvas)
        .navigationTitle("Проекты").navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("План команды", systemImage: "square.and.arrow.down") { showPlanImport = true }
                    .accessibilityIdentifier("projects.importTeamPlan")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Новый проект", systemImage: "plus") { showCreate = true }
                    .accessibilityIdentifier(model.selectedProject == nil ? "projects.createToolbar" : "projects.create")
            }
        }
        .sheet(isPresented: $showCreate) { CreateProjectScreen(model: model) }
        .sheet(isPresented: $showPlanImport) { CollaborativePlanImportScreen(model: model) }
        .task(id: model.selectedProject?.id) { await refreshSummary() }
    }

    private var emptyProjects: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "viewfinder").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(Color.atlasAccent)
                .padding(.bottom, 14)
            Text("От съёмки\nк рабочему проекту").font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            Text("Сканируйте объекты, стройте планы помещений и размечайте территории. Всё начинается с одного проекта.")
                .font(.body).foregroundStyle(Color.atlasMuted).fixedSize(horizontal: false, vertical: true)
            Label("Сохранение на устройстве", systemImage: "externaldrive")
                .font(.caption.weight(.medium)).foregroundStyle(Color.atlasMuted).padding(.top, 4)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.atlasLine, lineWidth: 1))
    }

    private func projectMetric(_ value: Int, title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Color.atlasInk)
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(Color.atlasMuted)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func refreshSummary() async {
        guard let project = model.selectedProject else { summary = nil; return }
        let scans = await model.scans(in: project)
        let plans = await model.plans(in: project)
        let features = await model.features(in: project)
        guard !Task.isCancelled, model.selectedProject?.id == project.id else { return }
        summary = ProjectSummary(projectID: project.id, scanCount: scans.count, planCount: plans.count, featureCount: features.count)
    }
}

struct ProjectPreview: View {
    let project: AtlasProject
    let directory: URL
    @State private var previewImage: UIImage?
    @State private var hasModel = false
    var body: some View {
        Group {
            if project.notes == "atlas-demo" {
                Image("SurveyDemo").resizable().scaledToFill()
                    .overlay(alignment: .bottomLeading) {
                        Text("Демонстрация").font(.caption.weight(.semibold)).padding(8)
                            .foregroundStyle(.white).background(.black.opacity(0.75), in: Capsule()).padding(12)
                    }
            } else if let previewImage {
                Image(uiImage: previewImage).resizable().scaledToFill()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: project.kind.symbol).font(.system(size: 48, weight: .light))
                    Text(hasModel ? "3D-модель сохранена" : "Съёмок пока нет").font(.headline)
                    Text(hasModel ? "Откройте модель в проекте" : "Модель появится после сохранения скана").font(.footnote)
                }.foregroundStyle(Color.atlasMuted).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.atlasCanvas)
            }
        }.background(Color.atlasCanvas)
            .accessibilityLabel(project.notes == "atlas-demo" ? "Иллюстрация демонстрационного проекта" : "Предпросмотр проекта")
        .task(id: directory.path) {
            guard project.notes != "atlas-demo" else { return }
            let root = directory
            let load = Task.detached(priority: .utility) { Self.loadPreview(at: root) }
            let result = await withTaskCancellationHandler {
                await load.value
            } onCancel: {
                load.cancel()
            }
            guard !Task.isCancelled else { return }
            previewImage = result.0.flatMap { UIImage(data: $0) }; hasModel = result.1
        }
    }

    nonisolated private static func loadPreview(at directory: URL) -> (Data?, Bool) {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return (nil, false) }
        var hasModel = false
        var newestPhoto: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return (nil, hasModel) }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let fileExtension = url.pathExtension.lowercased()
            if ["obj", "usdz"].contains(fileExtension) { hasModel = true }
            if ["png", "jpg", "jpeg", "heic"].contains(fileExtension) {
                let date = values.contentModificationDate ?? .distantPast
                if newestPhoto == nil || date > newestDate { newestPhoto = url; newestDate = date }
            }
        }
        guard !Task.isCancelled, let url = newestPhoto,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return (nil, hasModel) }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil) else { return (nil, hasModel) }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return (nil, hasModel) }
        return (buffer as Data, hasModel)
    }
}

struct CreateProjectScreen: View {
    @ObservedObject var model: AtlasAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: ProjectKind = .cemetery
    @State private var geographic = false
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Объект") {
                    TextField("Название проекта", text: $name)
                        .accessibilityIdentifier("project.name")
                        .textInputAutocapitalization(.sentences)
                    Picker("Тип", selection: $kind) {
                        ForEach([ProjectKind.cemetery, .building, .objectScan, .site], id: \.self) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                }
                Section {
                    Toggle("Географические координаты WGS84", isOn: $geographic)
                } header: { Text("Координаты") } footer: {
                    Text(geographic ? "Полигоны создаются на карте. Сканы сохраняют отдельную локальную систему до геопривязки." : "Локальная система в метрах для планов и сканов. GeoJSON доступен только после корректной геопривязки.")
                }
                Section {
                    Label("Сохранение и работа без интернета", systemImage: "externaldrive")
                    Label("Основной экспорт собственных данных", systemImage: "square.and.arrow.up")
                }
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas)
            .listRowBackground(Color.atlasCard)
            .navigationTitle("Новый проект")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        saving = true
                        Task {
                            if await model.createProject(name: name, kind: kind, geographic: geographic) != nil { dismiss() }
                            saving = false
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                        .accessibilityIdentifier("project.save")
                }
            }
        }
    }
}

