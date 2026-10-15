import SwiftUI
import AtlasCore

struct AtlasRootScreen: View {
    @ObservedObject var model: AtlasAppModel
    var body: some View { AtlasStaffRoot(model: model, staff: model.staff) }
}

private struct AtlasStaffRoot: View {
    @ObservedObject var model: AtlasAppModel
    @ObservedObject var staff: StaffAccountSession
    var body: some View {
        Group {
            if !model.ready {
                VStack(spacing: 20) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 46, weight: .medium)).foregroundStyle(Color.atlasAccent)
                    ProgressView("Открываем проекты…").tint(.atlasAccent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.storeAvailable {
                AtlasEmptyState(title: "Данные недоступны", message: model.issue ?? "Проверьте свободное место на устройстве.", symbol: "externaldrive.badge.exclamationmark")
            } else if !StaffWorkAccess.diagnosticFixtures &&
                (!staff.workAllowed || model.selectedProject.map({ !staff.projectIsBound($0.id) }) != false) {
                NavigationStack { StaffAccountScreen(model:model,staff:staff) }
            } else {
                VStack(spacing:0) {
                    if !StaffWorkAccess.diagnosticFixtures {
                        HStack {
                            Image(systemName:"location.fill")
                            Text(staff.location.message).font(.caption).lineLimit(1)
                            Spacer()
                            Button("Пауза") { staff.pauseWorkSession() }.font(.caption.weight(.semibold))
                        }.foregroundStyle(Color.atlasInk).padding(10).background(Color.atlasCard)
                    }
                TabView {
                    NavigationStack { ProjectsScreen(model: model) }
                        .tabItem { Label("Проекты", systemImage: "folder.fill") }
                    NavigationStack {
                        if let project = model.selectedProject { GeometryEditorScreen(model: model, project: project).id(project.id) }
                        else { AtlasEmptyState(title: "Нет проекта", message: "Создайте проект, чтобы работать с полигонами.", symbol: "map") }
                    }.tabItem { Label("Карта", systemImage: "map") }
                    NavigationStack { CaptureToolsScreen(model: model) }
                        .tabItem { Label("Съёмка", systemImage: "viewfinder") }
                    NavigationStack { SettingsScreen(model: model) }
                        .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                }
                .toolbarBackground(Color.atlasCanvas, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                }
            }
        }
        .foregroundStyle(Color.atlasInk)
        .background(Color.atlasCanvas.ignoresSafeArea())
        .tint(.atlasAccent)
        .preferredColorScheme(.dark)
        .alert(AppBrand.displayName, isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
            Button("Понятно", role: .cancel) { model.issue = nil }
        } message: { Text(model.issue ?? "") }
    }
}

/// Capture opens through navigation so its Close action returns to this screen.
/// Every tool uses the same selected project and existing storage callbacks.
private struct CaptureToolsScreen: View {
    @ObservedObject var model: AtlasAppModel

    var body: some View {
        Group {
            if let project = model.selectedProject {
                List {
                    Section("Текущий проект") {
                        Picker("Проект", selection: Binding(
                            get: { model.selectedProject?.id },
                            set: { model.selectedProjectID = $0 }
                        )) {
                            ForEach(model.projects) { item in
                                Text(item.name).tag(Optional(item.id))
                            }
                        }.accessibilityIdentifier("tools.project")
                        Label(project.kind.title, systemImage: project.kind.symbol)
                            .foregroundStyle(Color.atlasMuted)
                    }.listRowBackground(Color.atlasCard)
                    Section {
                        NavigationLink {
                            CaptureScreen(project: project, outputDirectory: model.captureDirectory(for: project), onSaved: { manifest in
                                Task { await model.registerCapture(manifest: manifest, project: project) }
                            }, onFloorPlan: { plan in
                                Task { await model.savePlan(plan) }
                            }, onEvidenceSaved: {
                                model.fieldMaterialsDidChange(projectID: project.id)
                            })
                        } label: {
                            Label("Начать съёмку", systemImage: "viewfinder")
                        }.accessibilityIdentifier("tools.startCapture")
                        NavigationLink {
                            ObjectCaptureScreen(project: project, directory: model.directory, onSaved: { manifest in
                                Task { await model.registerCapture(manifest: manifest, project: project) }
                            })
                        } label: {
                            Label("3D-объект по фотографиям", systemImage: "camera.viewfinder")
                        }.accessibilityIdentifier("tools.objectCapture")
                    } header: { Text("Пространство · Объект · План · Фото") } footer: {
                        Text("Режим выбирается на экране камеры. Исходники и геометки сохраняются в выбранном проекте.")
                    }.listRowBackground(Color.atlasCard)
                    Section("Полевые инструменты") {
                        NavigationLink {
                            TourScreen(model: model, project: project)
                        } label: { Label("Прогулка · фото и карточки", systemImage: "figure.walk") }
                            .accessibilityIdentifier("tools.tour")
                        NavigationLink {
                            BuildingPlansScreen(model: model, project: project)
                        } label: { Label("Здание · этажи и квартиры", systemImage: "building.2") }
                            .accessibilityIdentifier("tools.buildingPlans")
                        NavigationLink {
                            CemeteryFieldworkScreen(model: model, project: project)
                        } label: { Label("Обследование кладбища", systemImage: "map.fill") }
                            .accessibilityIdentifier("tools.cemetery")
                        NavigationLink {
                            EmptyRoomScreen(model: model, project: project)
                        } label: { Label("Чистое помещение · для дизайнера", systemImage: "square.dashed") }
                            .accessibilityIdentifier("tools.emptyRoom")
                        NavigationLink {
                            MeasurementToolsScreen(model: model, project: project)
                        } label: { Label("Рулетка, уровень и компас", systemImage: "ruler") }
                            .accessibilityIdentifier("tools.measurements")
                        NavigationLink {
                            FloorPlanScreen(model: model, project: project)
                        } label: { Label("Планы здания", systemImage: "square.split.2x2") }
                            .accessibilityIdentifier("tools.floorPlans")
                        NavigationLink {
                            GeometryEditorScreen(model: model, project: project)
                        } label: { Label("Полигоны и карточки", systemImage: "map") }
                            .accessibilityIdentifier("tools.polygons")
                        NavigationLink {
                            ProjectLocationScreen(model: model, project: project)
                        } label: { Label("Геометки съёмок и фото", systemImage: "mappin.and.ellipse") }
                            .accessibilityIdentifier("tools.locations")
                        NavigationLink {
                            ApplyMeasurementScreen(model: model, project: project)
                        } label: { Label("Контрольный размер плана", systemImage: "checkmark.rectangle") }
                            .accessibilityIdentifier("tools.controlMeasurement")
                    }.listRowBackground(Color.atlasCard)
                    Section("Результаты") {
                        NavigationLink {
                            ProjectDetailScreen(model: model, project: project)
                        } label: { Label("Модели, материалы и экспорт", systemImage: "cube.transparent") }
                            .accessibilityIdentifier("tools.projectMaterials")
                    }.listRowBackground(Color.atlasCard)
                }
                .scrollContentBackground(.hidden)
            } else {
                AtlasEmptyState(title: "Выберите проект", message: "Создайте проект во вкладке «Проекты». Съёмка и измерения будут сохраняться в нём.", symbol: "viewfinder")
            }
        }
        .foregroundStyle(Color.atlasInk)
        .background(Color.atlasCanvas)
        .navigationTitle("Инструменты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}
