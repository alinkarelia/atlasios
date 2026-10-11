import SwiftUI
import AtlasCore

struct ProjectDetailScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @State private var features: [AtlasFeature] = []
    @State private var plans: [AtlasFloorPlan] = []
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var meshURL: URL?
    @State private var captures: [URL] = []
    @State private var loading = true
    @State private var refreshID = UUID()

    private var currentRevision: Int64 {
        model.projects.first(where: { $0.id == project.id })?.revision ?? project.revision
    }

    var body: some View {
        List {
            Section {
                ProjectPreview(project: project, directory: model.captureDirectory(for: project))
                    .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 24))
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                if let firstCapture = captures.first {
                    Button { meshURL = firstCapture } label: {
                        Label("Открыть 3D-модель", systemImage: "cube.transparent")
                    }.buttonStyle(AtlasPrimaryButtonStyle())
                        .accessibilityIdentifier("project.viewer")
                        .accessibilityHint("Вращение модели, масштаб и свободная прогулка")
                        .listRowSeparator(.hidden)
                }
                LabeledContent("Объект", value: project.kind.title)
                LabeledContent("Хранение", value: "На устройстве")
                LabeledContent("Координаты", value: coordinateLabel)
                if project.notes == "atlas-demo" {
                    Label("Демонстрационные данные", systemImage: "info.circle").foregroundStyle(Color.atlasMuted)
                }
            }.listRowBackground(Color.atlasCard)
            Section("Работа с объектом") {
                NavigationLink {
                    CaptureScreen(project: project, outputDirectory: model.captureDirectory(for: project), onSaved: { manifest in
                        Task { await model.registerCapture(manifest: manifest, project: project); await refresh() }
                    }, onFloorPlan: { plan in Task { await model.savePlan(plan); await refresh() } },
                    onEvidenceSaved: { model.fieldMaterialsDidChange(projectID: project.id) })
                } label: { Label("Начать съёмку", systemImage: "viewfinder") }
                    .accessibilityIdentifier("projects.startCapture")
                NavigationLink {
                    ObjectCaptureScreen(project: project, directory: model.directory, onSaved: { manifest in
                        Task { await model.registerCapture(manifest: manifest, project: project); await refresh() }
                    })
                } label: { Label("3D-объект по фотографиям", systemImage: "camera.viewfinder") }
                    .accessibilityIdentifier("projects.objectCapture")
                NavigationLink {
                    GeometryEditorScreen(model: model, project: project)
                } label: { LabeledContent { Text("\(features.count)") } label: { Label("Полигоны и карточки", systemImage: "map") } }
                NavigationLink {
                    FloorPlanScreen(model: model, project: project)
                } label: { LabeledContent { Text("\(plans.count)") } label: { Label("Планы здания", systemImage: "square.split.2x2") } }
                NavigationLink {
                    CaptureRecoveryScreen(model: model, project: project)
                } label: { Label("Восстановить прерванную съёмку", systemImage: "arrow.clockwise") }
                NavigationLink {
                    TeamProjectTransferScreen(model: model, project: project)
                } label: { Label("Материалы и отправка", systemImage: "arrow.up.doc") }
                    .accessibilityIdentifier("projects.fieldTransfer")
                NavigationLink {
                    ProjectLocationScreen(model: model, project: project)
                } label: { Label("Геометки съёмок и фото", systemImage: "mappin.and.ellipse") }
                NavigationLink {
                    MeasurementToolsScreen(model: model, project: project)
                } label: { Label("Рулетка, уровень и компас", systemImage: "ruler") }
                NavigationLink {
                    ApplyMeasurementScreen(model: model, project: project)
                } label: { Label("Применить контрольный размер к плану", systemImage: "checkmark.rectangle") }
            }.listRowBackground(Color.atlasCard)
            Section("Сохранённые модели") {
                if loading, captures.isEmpty {
                    ProgressView("Открываем модели…").tint(.atlasAccent)
                } else if captures.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Моделей пока нет", systemImage: "cube.transparent").font(.headline)
                        Text("Сохраните LiDAR-скан или план помещения. Модель можно будет вращать и осматривать изнутри.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    }.padding(.vertical, 6)
                }
                ForEach(captures, id: \.path) { url in
                    HStack {
                        Button { meshURL = url } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "cube").font(.title3).foregroundStyle(Color.atlasAccent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url.lastPathComponent).font(.headline).foregroundStyle(Color.atlasInk).lineLimit(1)
                                    Text("\(url.pathExtension.uppercased()) · вращение и прогулка")
                                        .font(.caption).foregroundStyle(Color.atlasMuted)
                                }
                            }.padding(.vertical, 4)
                        }.buttonStyle(.plain)
                            .accessibilityLabel("Открыть модель \(url.lastPathComponent)")
                        Spacer()
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Выгрузить \(url.lastPathComponent)")
                    }
                }
            }.listRowBackground(Color.atlasCard)
            Section {
                Button {
                    exporting = true
                    Task { exportURL = await model.exportArchive(project: project); exporting = false }
                } label: {
                    if exporting { HStack { ProgressView(); Text("Собираем архив…") } }
                    else { Label("Проект с исходниками ZIP", systemImage: "archivebox") }
                }.disabled(exporting)
                exportButton("Метаданные проекта JSON", format: .projectJSON)
                exportButton("План и полигоны DXF", format: .dxf)
                exportButton("Географические объекты GeoJSON", format: .geoJSON)
                exportButton("Векторный чертёж SVG", format: .svg)
                exportButton("Таблица объектов и материалов CSV", format: .csv)
                Button("Паспорт материалов CSV · время и геометки") {
                    exporting = true
                    Task { exportURL = await model.exportMaterialTable(project: project); exporting = false }
                }.disabled(exporting).accessibilityIdentifier("export.materialsCSV")
                exportButton("Геометки и полигоны KML", format: .kml)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("Сохранить файл в Файлы", systemImage: "square.and.arrow.up") }
                }
            } header: { Text("Экспорт") } footer: {
                Text("ZIP содержит карточки, планы и исходники съёмки. До 4 ГБ. DXF и SVG сохраняют локальные метры; независимые планы экспортируются отдельно из редактора. GeoJSON и KML сохраняют географические координаты. Форматы 3D доступны в просмотре модели.")
            }.listRowBackground(Color.atlasCard)
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk)
        .navigationTitle(project.name).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: currentRevision) { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: Binding(get: { meshURL != nil }, set: { if !$0 { meshURL = nil } })) {
            if let meshURL {
                NavigationStack {
                    MeshPreviewScreen(url: meshURL)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { self.meshURL = nil } } }
                        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                }
            }
        }
    }
    private var coordinateLabel: String {
        switch project.coordinateReference { case .wgs84: "WGS84"; case .localMeters: "Локальная, метры" }
    }
    private func refresh() async {
        let requestID = UUID()
        refreshID = requestID
        loading = true
        let directory = model.captureDirectory(for: project)
        let worker = Task.detached(priority: .utility) { Self.capturedModels(at: directory) }
        let updatedFeatures = await model.features(in: project)
        let updatedPlans = await model.plans(in: project)
        let updatedCaptures = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, refreshID == requestID else { return }
        features = updatedFeatures
        plans = updatedPlans
        captures = updatedCaptures
        loading = false
    }

    nonisolated private static func capturedModels(at directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { return [] }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true,
                  !url.lastPathComponent.hasPrefix("reconstruction-"),
                  ["obj", "usdz"].contains(url.pathExtension.lowercased()) else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { first, second in
            if first.1 != second.1 { return first.1 > second.1 }
            return first.0.path > second.0.path
        }.map(\.0)
    }
    private func exportButton(_ title: String, format: ExportFormat) -> some View {
        Button(title) { Task { exportURL = await model.export(project: project, format: format) } }
            .accessibilityIdentifier("export.\(format.rawValue)")
    }
}
