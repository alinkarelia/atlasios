import Combine
import AtlasCore
import SceneKit
import simd
import SwiftUI
import UIKit

struct MeshPreviewScreen: View {
    let url: URL
    let projectID: UUID?
    let journalDirectory: URL?
    init(url: URL, projectID: UUID? = nil, journalDirectory: URL? = nil) {
        self.url = url; self.projectID = projectID; self.journalDirectory = journalDirectory
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: MeshPreviewController?
    @State private var issue: String?
    @State private var isLoading = true
    @State private var loadAttempt = 0
    @State private var isVisible = false
    @State private var latestSceneIsActive = false

    var body: some View {
        // Keep one presentation identity while loading/content branches change;
        // removing the placeholder must not deactivate the newly installed scene.
        ZStack {
            if let controller {
                MeshPreviewContent(controller: controller, url: url)
            } else {
                VStack(spacing: 20) {
                    if isLoading {
                        ProgressView().controlSize(.large).tint(.atlasBlue)
                        Text("Готовим 3D-модель").font(.title3.bold())
                        Text("Читаем геометрию и рассчитываем поверхность…")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted)
                    } else {
                        Image(systemName: "cube.transparent").font(.system(size: 44)).foregroundStyle(Color.atlasMuted)
                        Text("Модель не открылась").font(.title3.bold())
                        Text(issue ?? "Не удалось прочитать файл модели.")
                            .font(.subheadline).foregroundStyle(Color.atlasMuted).multilineTextAlignment(.center)
                        Button("Попробовать снова") { loadAttempt += 1 }
                            .buttonStyle(.borderedProminent).foregroundStyle(Color.atlasAccentInk).accessibilityIdentifier("viewer.retry")
                        ShareLink(item: url) { Label("Выгрузить исходный файл", systemImage: "square.and.arrow.up") }
                    }
                }
                .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(Color.atlasInk).background(Color.atlasCanvas)
            }
        }
        .navigationTitle("3D-модель")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.atlasBlue)
        .task(id: "\(url.path)-\(loadAttempt)") { await load() }
        .onAppear {
            isVisible = true
            latestSceneIsActive = scenePhase == .active
            controller?.setActive(latestSceneIsActive)
        }
        .onDisappear { isVisible = false; controller?.setActive(false) }
        .onChange(of: scenePhase) { _, phase in
            latestSceneIsActive = phase == .active
            controller?.setActive(isVisible && latestSceneIsActive)
        }
    }

    @MainActor private func load() async {
        controller?.stopMoving()
        isLoading = true; issue = nil; controller = nil
        let sourceURL = url
        let worker = Task.detached(priority: .userInitiated) {
            let before = try MeshDimensionSource.inspect(sourceURL, atlasOBJ: false)
            let mesh = try OBJPreviewLoader.load(sourceURL)
            let evidence = try MeshDimensionSource.inspect(sourceURL, atlasOBJ: mesh.isAtlasCapture)
            guard before.sha256 == evidence.sha256 else { throw OBJPreviewError.invalidMesh }
            return (mesh, try MeshSectionProcessor.surfaceArea(mesh), evidence)
        }
        await withTaskCancellationHandler {
            do {
                let (payload, area, dimensionSource) = try await worker.value
                try Task.checkCancellation()
                // Parsing, world transforms and normal generation already ran
                // off the UI actor. SceneKit only receives three data buffers.
                await Task.yield()
                let prepared = MeshPreviewController(mesh: payload, sourceURL: sourceURL, surfaceArea: area, dimensionSource: dimensionSource,
                    projectID: projectID, journalDirectory: journalDirectory, isActive: isVisible && latestSceneIsActive)
                await prepared.loadMeasurements()
                try Task.checkCancellation()
                controller = prepared
                // Loading the journal suspends this task. A scene-phase event
                // during that await sees controller == nil, so reconcile the
                // current phase after installing the prepared controller.
                prepared.setActive(isVisible && latestSceneIsActive)
                isLoading = false
            } catch is CancellationError {
                // Leaving the screen cancels the read/normal worker.
            } catch {
                issue = error.localizedDescription
                isLoading = false
            }
        } onCancel: { worker.cancel() }
    }
}

private struct MeshPreviewContent: View {
    @ObservedObject var controller: MeshPreviewController
    let url: URL
    @State private var showsInfo = false
    @State private var sharedURL: URL?
    @State private var exportIssue: String?
    @State private var exporting = false

    private var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TerraViewExports", isDirectory: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MeshSceneSurface(controller: controller)
                    .accessibilityIdentifier("viewer.scene")
                    .accessibilityLabel("Трёхмерная модель")
                    .accessibilityValue(controller.accessibilityPose)
                    .accessibilityHint(controller.mode == .orbit ? "Проведите пальцем для поворота. Щипок меняет масштаб." : "Проведите пальцем, чтобы осмотреться. Кнопки ниже перемещают камеру.")
                if !controller.hasRendered {
                    ProgressView("Рисуем модель…")
                        .tint(.atlasAccent).foregroundStyle(Color.atlasInk)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.atlasCanvas)
                }
                if controller.isMeasuring, let overlay = controller.dimensionOverlay {
                    MeasurementDimensionDrawing(overlay: overlay)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Label(controller.mode == .orbit ? "Обзор модели" : "Свободный просмотр", systemImage: controller.mode == .orbit ? "rotate.3d" : "figure.walk")
                        .font(.subheadline.weight(.semibold))
                    Text(controller.mode == .orbit ? "Поверните пальцем · масштаб двумя" : "Осмотритесь пальцем · двигайтесь стрелками")
                        .font(.caption)
                }
                .foregroundStyle(.white).padding(12)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                .padding(16).allowsHitTesting(false)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { controller.reset() } label: { Image(systemName: "arrow.counterclockwise").font(.body.weight(.semibold)).frame(width: 46, height: 46) }
                            .foregroundStyle(.white).background(.black.opacity(0.55), in: Circle())
                            .accessibilityLabel("Вернуть исходный ракурс")
                            .accessibilityIdentifier("viewer.reset")
                    }.padding(16)
                }
            }
            .frame(minHeight: controller.isMeasuring ? 180 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.atlasGraphite)
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    modeButton(.orbit, title: "Модель", symbol: "cube", identifier: "viewer.mode.orbit")
                    modeButton(.walk, title: "Прогулка", symbol: "figure.walk", identifier: "viewer.mode.walkthrough")
                    Button { controller.toggleWireframe() } label: {
                        Image(systemName: "square.3.layers.3d")
                            .font(.body.weight(.semibold)).frame(width: 46, height: 46)
                    }
                    .background(controller.isWireframe ? Color.atlasBlue.opacity(0.15) : Color.atlasLine.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(controller.isWireframe ? "Показать поверхность" : "Показать рёбра сетки")
                    .accessibilityIdentifier("viewer.wireframe")
                }
                HStack(spacing: 8) {
                    Button { controller.toggleMeasurement() } label: {
                        Label("Размер", systemImage: "ruler").frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .background(controller.isMeasuring ? Color.atlasAccent.opacity(0.2) : Color.atlasLine.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("viewer.measure")
                    .accessibilityAddTraits(controller.isMeasuring ? .isSelected : [])
                    Button { controller.toggleSection() } label: {
                        Label("Срез", systemImage: "square.3.layers.3d.slash").frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .background(controller.isSectioned ? Color.atlasAccent.opacity(0.2) : Color.atlasLine.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("viewer.section")
                    .accessibilityAddTraits(controller.isSectioned ? .isSelected : [])
                    Button {
                        do { sharedURL = try controller.saveSnapshot(to: exportDirectory) }
                        catch { exportIssue = error.localizedDescription }
                    } label: { Image(systemName: "camera").frame(width: 44, height: 44) }
                    .accessibilityIdentifier("viewer.snapshot").accessibilityLabel("Сохранить изображение текущего ракурса PNG")
                }.font(.subheadline.weight(.semibold))
                if controller.isMeasuring {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Размер", selection: Binding(get: { controller.measurementRole }, set: { controller.setMeasurementRole($0) })) {
                                ForEach(MeasurementRole.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) }
                            }.accessibilityIdentifier("viewer.measurementRole")
                            Picker("Расчёт", selection: Binding(get: { controller.measurementKind }, set: { controller.setMeasurementKind($0) })) {
                                Text("3D · прямая").tag(MeasurementKind.distance)
                                Text("Плоскость XZ").tag(MeasurementKind.horizontalDistance)
                                Text(controller.gravityYKnown ? "Высота · Y" : "Ось Y модели").tag(MeasurementKind.verticalDistance)
                            }.accessibilityIdentifier("viewer.measurementProjection")
                        }.font(.caption)
                        HStack {
                            Picker("Объект", selection: Binding(get: { controller.measurementTarget }, set: { controller.setMeasurementTarget($0) })) { ForEach(MeasurementTarget.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }.accessibilityIdentifier("viewer.measurementTarget")
                            Picker("Место", selection: $controller.samplePosition) { ForEach(MeasurementSamplePosition.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }.accessibilityIdentifier("viewer.measurementPosition")
                        }.font(.caption)
                        Picker("Границы размера", selection: $controller.measurementDefinition) { ForEach(MeasurementDefinition.allCases, id: \.self) { Text($0.fieldMeasurementTitle).tag($0) } }.font(.caption).accessibilityIdentifier("viewer.measurementDefinition")
                        HStack {
                            TextField("Участок замера", text: $controller.measurementPositionNote).font(.caption).accessibilityIdentifier("viewer.measurementPositionNote")
                            Button("Другой объект") { controller.newMeasurementProfile() }.font(.caption).accessibilityIdentifier("viewer.measurementNewProfile")
                        }
                        HStack {
                        Text(controller.measurementLabel).font(.subheadline.monospacedDigit())
                            .accessibilityIdentifier("viewer.measurementValue")
                        Spacer()
                        Button("Сброс") { controller.clearMeasurement() }
                        }
                        Button(controller.hasProjectJournal ? "Сохранить отдельный замер" : "Запомнить до закрытия", systemImage: "checkmark") { controller.saveMeasurement() }
                            .disabled(!controller.hasMeasurementPair || controller.savingMeasurement)
                            .accessibilityIdentifier("viewer.measurementSave")
                        Text(controller.gravityYKnown ? "H — |ΔY| по силе тяжести; наклон A–B показан отдельно. Исходные A/B сохраняются в системе модели." : "Ось Y файла не подтверждена как вертикаль. Масштаб и единицы файла требуют проверки; физическая высота H не заявляется.")
                            .font(.caption2).foregroundStyle(Color.atlasMuted)
                        if !controller.hasProjectJournal { Text("Просмотр без проекта: размеры хранятся только до закрытия этой модели.").font(.caption2).foregroundStyle(Color.atlasMuted) }
                        DisclosureGroup("Сохранённые замеры · \(controller.savedMeasurements.count)") {
                            ForEach(controller.savedMeasurements.suffix(20).reversed()) { reading in
                                Text(reading.context.role.symbol + " " + String(format: "%.3f %@", reading.value, reading.unit == "m" ? "м" : "ед.") + " · " + reading.context.position.fieldMeasurementTitle + " · " + reading.createdAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).accessibilityIdentifier("viewer.measurementSaved." + reading.id.uuidString)
                            }
                            Text("Каждый замер имеет отдельные A/B и время. Файл модели остаётся неизменным.").font(.caption2).foregroundStyle(Color.atlasMuted)
                        }.font(.caption).accessibilityIdentifier("viewer.measurementJournal")
                    }
                    }.frame(maxHeight: 250).scrollDismissesKeyboard(.interactively)
                }
                if controller.isSectioned {
                    HStack {
                        Text("Высота среза").font(.caption)
                        Slider(value: Binding(get: { controller.sectionFraction }, set: { controller.setSectionFraction($0) }), in: 0.01...1)
                            .accessibilityIdentifier("viewer.section.height")
                        if controller.sectionBusy { ProgressView().controlSize(.small) }
                    }
                    Text("Верх скрыт только в просмотре. Исходная модель сохраняется полностью.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
                if let issue = controller.toolIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                if controller.mode == .walk {
                    movementControls
                    Text("Свободное перемещение в границах модели. Стены не останавливают камеру.")
                        .font(.caption).foregroundStyle(Color.atlasMuted).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text("\(controller.triangleCount.formatted()) треугольников")
                        .font(.caption.weight(.medium)).foregroundStyle(Color.atlasMuted)
                    Spacer()
                    Button { showsInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("Информация о модели")
                    Menu {
                        ShareLink(item: url) { Label("Исходный \(url.pathExtension.uppercased())", systemImage: "doc") }
                        ForEach(MeshExportFormat.allCases) { format in
                            Button(format.title) { exportModel(format) }
                                .accessibilityIdentifier("viewer.export.\(format.rawValue)")
                        }
                    } label: {
                        if exporting { ProgressView() }
                        else { Image(systemName: "square.and.arrow.up") }
                    }.disabled(exporting).accessibilityIdentifier("viewer.export")
                        .accessibilityLabel("Форматы экспорта 3D-модели")
                }
            }
            .padding(16).background(Color.atlasCanvas)
        }
        .sheet(isPresented: $showsInfo) {
            NavigationStack {
                List {
                    LabeledContent("Вершины", value: controller.vertexCount.formatted())
                    LabeledContent("Треугольники", value: controller.triangleCount.formatted())
                    LabeledContent("Формат", value: url.pathExtension.uppercased())
                    LabeledContent("Габариты", value: controller.dimensionsLabel)
                    LabeledContent("Площадь сетки", value: controller.areaLabel)
                    Text("Площадь рассчитана по треугольникам исходной сетки. Перекрывающиеся поверхности и пропуски влияют на результат.")
                    Text(controller.isAtlasCapture ? "Измеренная LiDAR-сетка · локальные метры." : "Масштаб и единицы исходной модели.")
                    Text("Поверхность показана с чёткими гранями, без фототекстуры. Исходный файл выгружается полностью. Открытые края и пропуски могут быть частью съёмки.")
                    Text("Прогулка — ручной просмотр модели, без распознавания пола или проверки столкновений со стенами.")
                }
                .navigationTitle("О модели").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showsInfo = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { sharedURL != nil }, set: { if !$0 { sharedURL = nil } })) {
            if let sharedURL { MeshFileShareSheet(url: sharedURL) }
        }
        .alert("Экспорт", isPresented: Binding(get: { exportIssue != nil }, set: { if !$0 { exportIssue = nil } })) {
            Button("Готово", role: .cancel) { exportIssue = nil }
        } message: { Text(exportIssue ?? "") }
    }

    private func exportModel(_ format: MeshExportFormat) {
        exporting = true
        let source = url, destination = exportDirectory
        Task {
            defer { exporting = false }
            do { sharedURL = try await Task.detached(priority: .utility) {
                try MeshExportService.export(source: source, format: format, outputDirectory: destination)
            }.value }
            catch { exportIssue = error.localizedDescription }
        }
    }

    private func modeButton(_ mode: MeshPreviewController.Mode, title: String, symbol: String, identifier: String) -> some View {
        Button { controller.setMode(mode) } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).frame(height: 46)
        }
        .buttonStyle(.plain)
        .foregroundStyle(controller.mode == mode ? Color.atlasBlue : Color.atlasMuted)
        .background(controller.mode == mode ? Color.atlasBlue.opacity(0.15) : Color.atlasLine.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityAddTraits(controller.mode == mode ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var movementControls: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 5) {
                movement(.forward, symbol: "arrow.up", label: "Вперёд", identifier: "viewer.move.forward")
                HStack(spacing: 5) {
                    movement(.left, symbol: "arrow.left", label: "Влево", identifier: "viewer.move.left")
                    movement(.backward, symbol: "arrow.down", label: "Назад", identifier: "viewer.move.back")
                    movement(.right, symbol: "arrow.right", label: "Вправо", identifier: "viewer.move.right")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("Высота камеры").font(.caption).foregroundStyle(Color.atlasMuted)
                HStack(spacing: 6) {
                    movement(.up, symbol: "arrow.up.to.line", label: "Поднять камеру", identifier: "viewer.move.up")
                    movement(.down, symbol: "arrow.down.to.line", label: "Опустить камеру", identifier: "viewer.move.down")
                }
                Menu {
                    ForEach(MeshPreviewController.Speed.allCases) { speed in
                        Button(speed.title) { controller.speed = speed }
                    }
                } label: {
                    Label(controller.speed.title, systemImage: "speedometer").font(.caption.weight(.semibold))
                }.accessibilityLabel("Скорость перемещения")
            }
        }
    }

    private func movement(_ direction: MeshPreviewController.Direction, symbol: String, label: String, identifier: String) -> some View {
        MeshMovementButton(controller: controller, direction: direction, symbol: symbol, label: label, identifier: identifier)
            .frame(width: 46, height: 46)
    }
}

/// SceneKit objects never leave MainActor. Preparing a geometry uses immutable
/// buffers; its graph has one mesh, one camera and two cheap lights.
@MainActor private final class MeshPreviewController: ObservableObject {
    enum Mode { case orbit, walk }
    enum Direction { case forward, backward, left, right, up, down }
    enum Speed: String, CaseIterable, Identifiable {
        case slow, normal, fast
        var id: String { rawValue }
        var title: String { switch self { case .slow: "Медленно"; case .normal: "Обычно"; case .fast: "Быстро" } }
        var multiplier: Float { switch self { case .slow: 0.4; case .normal: 1; case .fast: 2 } }
    }
    let scene = SCNScene()
    let camera = SCNNode()
    let vertexCount: Int
    let triangleCount: Int
    let isAtlasCapture: Bool
    let bounds: MeshNavigationBounds
    let originalMesh: OBJPreviewPayload
    let sourceURL: URL
    let surfaceArea: Double
    private let meshNode = SCNNode()
    private let measurementNode = SCNNode()
    private var measurementPoints: [SIMD3<Float>] = []
    private let dimensionSource: MeshDimensionSource
    private let measurementJournal: MeshMeasurementJournal
    private let projectID: UUID?
    let hasProjectJournal: Bool
    @Published private(set) var dimensionOverlay: MeasurementDimensionOverlay?
    @Published private(set) var measurementRole = MeasurementRole.distance
    @Published private(set) var measurementKind = MeasurementKind.distance
    @Published var measurementTarget = MeasurementTarget.unspecified
    @Published var measurementDefinition = MeasurementDefinition.unspecified
    @Published var samplePosition = MeasurementSamplePosition.unspecified
    @Published var measurementPositionNote = ""
    @Published private(set) var savedMeasurements: [MeshDimensionObservation] = []
    @Published private(set) var savingMeasurement = false
    private var measurementProfileID = UUID()
    weak var renderView: SCNView?
    @Published private(set) var isMeasuring = false
    @Published private(set) var isSectioned = false
    @Published private(set) var sectionFraction: Double = 0.65
    @Published private(set) var sectionBusy = false
    @Published private(set) var toolIssue: String?
    @Published private(set) var measurementLabel = "Выберите две точки на поверхности"
    @Published private(set) var visibleTriangleCount: Int
    private var sectionTask: Task<Void, Never>?
    private var sectionTicket = UUID()
    @Published private(set) var mode: Mode = .orbit
    @Published private(set) var isWireframe = false
    @Published private(set) var revision = 0
    @Published private(set) var hasRendered = false
    @Published private(set) var isActive: Bool
    @Published var speed: Speed = .normal
    private let material = SCNMaterial()
    private var orbitYaw: Float = 0.35
    private var orbitPitch: Float = 0.3
    private var orbitDistance: Float
    private var fittedDistance: Float
    private var walkYaw: Float = -0.35
    private var walkPitch: Float = -0.2
    private var walkPosition: SIMD3<Float>
    private var movementTask: Task<Void, Never>?
    private var movingDirection: Direction?

    init(mesh: OBJPreviewPayload, sourceURL: URL, surfaceArea: Double, dimensionSource: MeshDimensionSource,
         projectID: UUID?, journalDirectory: URL?, isActive: Bool) {
        self.dimensionSource = dimensionSource
        self.projectID = projectID; hasProjectJournal = projectID != nil && journalDirectory != nil
        measurementJournal = MeshMeasurementJournal(directory: journalDirectory, projectID: projectID)
        self.originalMesh = mesh; self.sourceURL = sourceURL; self.surfaceArea = surfaceArea
        self.visibleTriangleCount = mesh.triangleCount
        self.isActive = isActive
        vertexCount = mesh.sourceVertexCount; triangleCount = mesh.triangleCount; isAtlasCapture = mesh.isAtlasCapture
        bounds = MeshNavigationBounds(minimum: mesh.minimum, maximum: mesh.maximum)
        fittedDistance = bounds.fittedOrbitDistance(viewportAspect: 1)
        orbitDistance = fittedDistance
        walkPosition = bounds.initialWalkPosition
        let vertexSource = SCNGeometrySource(data: mesh.positions, semantic: .vertex, vectorCount: mesh.vertexCount,
                                             usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let normalSource = SCNGeometrySource(data: mesh.normals, semantic: .normal, vectorCount: mesh.vertexCount,
                                             usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let triangles = SCNGeometryElement(data: mesh.indices, primitiveType: .triangles, primitiveCount: mesh.triangleCount, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [triangles])
        material.diffuse.contents = UIColor(red: 0.54, green: 0.64, blue: 0.70, alpha: 1)
        material.lightingModel = .lambert
        material.isDoubleSided = true
        geometry.materials = [material]
        let center = (mesh.minimum + mesh.maximum) / 2
        meshNode.geometry = geometry
        meshNode.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(meshNode)
        scene.rootNode.addChildNode(measurementNode)
        scene.background.contents = UIColor(Color.atlasGraphite)
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 60
        camera.camera?.projectionDirection = .vertical
        camera.camera?.zNear = Double(max(0.005, bounds.diagonal / 20_000))
        camera.camera?.zFar = Double(max(100, bounds.diagonal * 20))
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 140
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 750
        // A fixed overhead key separates horizontal floors from vertical
        // walls. A diagonal key made their shared smoothed normals equally
        // bright and erased room context when viewing from inside the mesh.
        key.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        scene.rootNode.addChildNode(key)
        updateCamera()
    }

    private var meterScale: Bool {
        dimensionSource.metresKnown
    }
    var gravityYKnown: Bool { dimensionSource.gravityYKnown }
    var hasMeasurementPair: Bool { measurementPoints.count == 2 }
    var dimensionsLabel: String {
        let extent = bounds.halfExtent * 2
        return String(format: "X %.2f · Y %.2f · Z %.2f %@", extent.x, extent.y, extent.z, meterScale ? "м" : "ед.")
    }
    var areaLabel: String { String(format: "%.2f %@", surfaceArea, meterScale ? "м²" : "ед.²") }

    func toggleMeasurement() {
        isMeasuring.toggle()
        if !isMeasuring { clearMeasurement() }
    }

    func clearMeasurement() {
        measurementPoints.removeAll()
        measurementNode.childNodes.forEach { $0.removeFromParentNode() }
        measurementLabel = "Выберите две точки на поверхности"
        dimensionOverlay = nil
        revision &+= 1
    }

    func pick(at position: CGPoint, in view: SCNView) {
        guard isMeasuring else { return }
        let hits = view.hitTest(position, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        guard let hit = hits.first(where: { $0.node === meshNode }) else {
            measurementLabel = "Точка вне поверхности — коснитесь сетки"
            return
        }
        if measurementPoints.count == 2 { clearMeasurement() }
        let point = SIMD3<Float>(hit.worldCoordinates.x, hit.worldCoordinates.y, hit.worldCoordinates.z)
        measurementPoints.append(point)
        rebuildMeasurementGeometry()
        revision &+= 1
    }

    func setMeasurementRole(_ role: MeasurementRole) {
        guard role != .height || gravityYKnown else { toolIssue = "Ось Y этой модели не подтверждена как вертикаль. Используйте 3D-размер или Hₛ вдоль выбранной поверхности."; return }
        measurementRole = role
        if role == .height { measurementKind = .verticalDistance }
        if role == .surfaceHeight { measurementKind = .distance }
        toolIssue = nil; rebuildMeasurementGeometry(); revision &+= 1
    }

    func setMeasurementKind(_ kind: MeasurementKind) {
        measurementKind = kind
        if measurementRole == .height && kind != .verticalDistance { measurementRole = .distance }
        if measurementRole == .surfaceHeight && kind != .distance { measurementRole = .distance }
        if kind == .verticalDistance && gravityYKnown && measurementRole == .distance { measurementRole = .height }
        rebuildMeasurementGeometry(); revision &+= 1
    }

    func setMeasurementTarget(_ target: MeasurementTarget) {
        if measurementTarget != target { measurementTarget = target; newMeasurementProfile() }
    }

    private var projectedMeasurementEnd: SIMD3<Float>? {
        guard measurementPoints.count == 2 else { return nil }
        let a = measurementPoints[0], b = measurementPoints[1]
        switch measurementKind {
        case .distance: return b
        case .horizontalDistance: return .init(b.x, a.y, b.z)
        case .verticalDistance: return .init(a.x, b.y, a.z)
        }
    }

    private var measurementValue: Double? {
        guard let end = projectedMeasurementEnd else { return nil }
        let start = measurementPoints[0]
        let dx = Double(end.x) - Double(start.x), dy = Double(end.y) - Double(start.y), dz = Double(end.z) - Double(start.z)
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private var dimensionValueLabel: String {
        guard let value = measurementValue else { return "Выберите две точки на поверхности" }
        let symbol = measurementKind == .verticalDistance && !gravityYKnown ? "Y" : measurementRole.symbol
        return symbol + String(format: " %.3f %@", value, meterScale ? "м" : "ед.")
    }

    private func rebuildMeasurementGeometry() {
        measurementNode.childNodes.forEach { $0.removeFromParentNode() }
        let radius = CGFloat(max(0.008, bounds.diagonal * 0.003))
        for point in measurementPoints {
            let marker = SCNNode(geometry: SCNSphere(radius: radius))
            marker.geometry?.firstMaterial?.diffuse.contents = UIColor(Color.atlasAccent)
            marker.geometry?.firstMaterial?.lightingModel = .constant
            marker.simdPosition = point; measurementNode.addChildNode(marker)
        }
        if let end = projectedMeasurementEnd {
            let delta = end - measurementPoints[0]
            let length = simd_length(delta)
            let rod = SCNNode(geometry: SCNCylinder(radius: radius * 0.45, height: CGFloat(length)))
            rod.geometry?.firstMaterial?.diffuse.contents = UIColor(Color.atlasAccent)
            rod.geometry?.firstMaterial?.lightingModel = .constant
            rod.simdPosition = (measurementPoints[0] + end) / 2
            if length > 0.00001 { rod.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length) }
            measurementNode.addChildNode(rod)
            let direct = simd_distance(measurementPoints[0], measurementPoints[1])
            measurementLabel = dimensionValueLabel + (measurementKind == .distance ? " · расстояние по прямой" : String(format: " · A–B в 3D %.3f %@", direct, meterScale ? "м" : "ед."))
        } else { measurementLabel = measurementPoints.isEmpty ? "Выберите две точки на поверхности" : "A отмечена — выберите B" }
        refreshMeasurementOverlay()
    }

    private func refreshMeasurementOverlay() {
        guard isMeasuring, let view = renderView, let a = measurementPoints.first else { dimensionOverlay = nil; return }
        let pose = camera.simdWorldTransform
        let origin = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let forward = -SIMD3<Float>(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        func project(_ point: SIMD3<Float>) -> CGPoint? {
            guard simd_dot(point - origin, forward) > 0.01 else { return nil }
            let value = view.projectPoint(SCNVector3(point.x, point.y, point.z))
            guard value.x.isFinite, value.y.isFinite, value.z.isFinite, value.z >= 0, value.z <= 1 else { return nil }
            return .init(x: CGFloat(value.x), y: CGFloat(value.y))
        }
        dimensionOverlay = .init(pointA: project(a), pointB: measurementPoints.count == 2 ? project(measurementPoints[1]) : nil,
            dimensionA: projectedMeasurementEnd == nil ? nil : project(a), dimensionB: projectedMeasurementEnd.flatMap(project),
            label: dimensionValueLabel, preview: false)
    }

    func newMeasurementProfile() { measurementProfileID = UUID(); measurementPositionNote = ""; samplePosition = .unspecified; clearMeasurement() }

    func loadMeasurements() async {
        guard hasProjectJournal else { return }
        do {
            savedMeasurements = try await measurementJournal.load(source: dimensionSource.sha256)
            if let latest = savedMeasurements.last {
                measurementProfileID = latest.context.profileID ?? UUID()
                measurementTarget = latest.context.target
                measurementDefinition = latest.context.effectiveDefinition
                samplePosition = latest.context.position; measurementPositionNote = latest.context.positionNote
                measurementRole = latest.context.role; measurementKind = latest.kind
            }
        } catch { toolIssue = "Сохранённые размеры требуют проверки. Исходная модель сохранена: " + error.localizedDescription }
    }

    func saveMeasurement() {
        guard !savingMeasurement, measurementPoints.count == 2, let value = measurementValue else { return }
        let center = (originalMesh.minimum + originalMesh.maximum) / 2
        let a = measurementPoints[0], b = measurementPoints[1]
        let record = MeshDimensionObservation(sourceSHA256: dimensionSource.sha256, projectID: projectID, frameID: dimensionSource.frameID,
            start: [Double(a.x) + Double(center.x), Double(a.y) + Double(center.y), Double(a.z) + Double(center.z)],
            end: [Double(b.x) + Double(center.x), Double(b.y) + Double(center.y), Double(b.z) + Double(center.z)], kind: measurementKind,
            context: .init(role: measurementRole, target: measurementTarget, targetID: measurementProfileID,
                           profileID: measurementProfileID, position: samplePosition, positionNote: measurementPositionNote, definition: measurementDefinition),
            value: value, unit: meterScale ? "m" : "model-unit", gravityYKnown: gravityYKnown)
        if !hasProjectJournal { savedMeasurements.append(record); clearMeasurement(); return }
        savingMeasurement = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.savingMeasurement = false }
            do { self.savedMeasurements = try await self.measurementJournal.append(record); self.clearMeasurement() }
            catch { self.toolIssue = "Размер не сохранён: " + error.localizedDescription }
        }
    }

    func toggleSection() {
        isSectioned.toggle()
        clearMeasurement()
        if isSectioned { setSectionFraction(sectionFraction) }
        else {
            sectionTask?.cancel(); sectionTicket = UUID(); sectionBusy = false
            installGeometry(originalMesh)
        }
    }

    func setSectionFraction(_ value: Double) {
        sectionFraction = value
        guard isSectioned else { return }
        sectionTask?.cancel()
        let ticket = UUID(); sectionTicket = ticket
        let payload = originalMesh
        let height = payload.minimum.y + Float(value) * (payload.maximum.y - payload.minimum.y)
        sectionBusy = true; toolIssue = nil
        sectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { try MeshSectionProcessor.clipped(payload, belowY: height) }
            await withTaskCancellationHandler {
                do {
                    let cut = try await worker.value
                    guard let self, !Task.isCancelled, self.sectionTicket == ticket else { return }
                    self.installGeometry(cut); self.sectionBusy = false
                } catch {
                    guard let self, !Task.isCancelled, self.sectionTicket == ticket else { return }
                    self.sectionBusy = false; self.toolIssue = error.localizedDescription
                }
            } onCancel: { worker.cancel() }
        }
    }

    private func installGeometry(_ mesh: OBJPreviewPayload) {
        let positions = SCNGeometrySource(data: mesh.positions, semantic: .vertex, vectorCount: mesh.vertexCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let normals = SCNGeometrySource(data: mesh.normals, semantic: .normal, vectorCount: mesh.vertexCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let triangles = SCNGeometryElement(data: mesh.indices, primitiveType: .triangles,
            primitiveCount: mesh.triangleCount, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [positions, normals], elements: [triangles])
        geometry.materials = [material]
        meshNode.geometry = geometry
        visibleTriangleCount = mesh.triangleCount
        revision &+= 1
    }

    func saveSnapshot(to directory: URL) throws -> URL {
        guard let view = renderView, hasRendered else { throw OBJPreviewError.noGeometry }
        let image = view.snapshot()
        guard let data = image.pngData() else { throw OBJPreviewError.invalidMesh }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("TerraView-view-\(UUID().uuidString).png")
        try data.write(to: output, options: .atomic)
        return output
    }

    var accessibilityPose: String {
        let position = camera.position
        return String(format: "%@ %@ x:%.3f y:%.3f z:%.3f yaw:%.3f pitch:%.3f section:%@ triangles:%d", mode == .orbit ? "orbit" : "walk", hasRendered ? "rendered" : "preparing", position.x, position.y, position.z,
                      mode == .orbit ? orbitYaw : walkYaw, mode == .orbit ? orbitPitch : walkPitch,
                      isSectioned ? "on" : "off", visibleTriangleCount)
    }

    func setMode(_ mode: Mode) {
        stopMoving()
        self.mode = mode
        updateCamera()
    }

    func reset() {
        stopMoving()
        orbitYaw = 0.35; orbitPitch = 0.3; orbitDistance = fittedDistance
        walkYaw = -0.35; walkPitch = -0.2; walkPosition = bounds.initialWalkPosition
        updateCamera()
    }

    func rotate(horizontal: Float, vertical: Float) {
        if mode == .orbit {
            orbitYaw -= horizontal * 0.006
            orbitPitch = min(1.4, max(-1.4, orbitPitch + vertical * 0.006))
        } else {
            walkYaw -= horizontal * 0.005
            walkPitch = min(1.2, max(-1.2, walkPitch - vertical * 0.005))
        }
        updateCamera()
    }

    func zoom(scale: Float) {
        guard scale.isFinite, scale > 0, mode == .orbit else { return }
        orbitDistance = min(fittedDistance * 6, max(bounds.diagonal * 0.12, orbitDistance / scale))
        updateCamera()
    }

    func toggleWireframe() {
        isWireframe.toggle()
        material.fillMode = isWireframe ? .lines : .fill
        revision &+= 1
    }

    func moveStep(_ direction: Direction, elapsed: Float = 0.16) {
        guard mode == .walk else { return }
        let distance = max(0.08, min(1.5, bounds.diagonal / 10)) * speed.multiplier * elapsed
        let forward: Float = direction == .forward ? 1 : (direction == .backward ? -1 : 0)
        let sideways: Float = direction == .right ? 1 : (direction == .left ? -1 : 0)
        let vertical: Float = direction == .up ? 1 : (direction == .down ? -1 : 0)
        walkPosition = bounds.moved(walkPosition, forward: forward, sideways: sideways, vertical: vertical, yaw: walkYaw, distance: distance)
        updateCamera()
    }

    func startMoving(_ direction: Direction) {
        guard isActive else { return }
        stopMoving()
        movingDirection = direction
        moveStep(direction)
        movementTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
                guard let self, self.mode == .walk else { return }
                self.moveStep(direction, elapsed: 0.033)
            }
        }
    }

    /// Touch-up, cancellation, backgrounding and leaving the view all stop the
    /// only periodic task. A stationary model never requests continuous frames.
    func stopMoving() {
        movementTask?.cancel(); movementTask = nil; movingDirection = nil
    }

    func finishMoving(_ direction: Direction) {
        // UIKit/VoiceOver accessibility activation may emit touchUpInside alone.
        if movingDirection == nil { moveStep(direction) }
        stopMoving()
    }

    func setActive(_ active: Bool) {
        if !active {
            stopMoving(); sectionTask?.cancel(); sectionTicket = UUID(); sectionBusy = false
        }
        isActive = active
        if active, isSectioned { setSectionFraction(sectionFraction) }
    }

    func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let next = bounds.fittedOrbitDistance(viewportAspect: Float(size.width / size.height))
        guard abs(next - fittedDistance) > 0.0001 else { return }
        orbitDistance *= next / fittedDistance
        fittedDistance = next
        updateCamera()
    }

    func markRendered() {
        guard !hasRendered else { return }
        hasRendered = true
    }

    private func orientCamera(yaw: Float, pitch: Float) {
        // Yaw about world Y followed by pitch about the camera's local X.
        // SceneKit's eulerAngles rotation order is intentionally not assumed.
        camera.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    }

    private func updateCamera() {
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        if mode == .orbit {
            let forward = MeshNavigationBounds.cameraForward(yaw: orbitYaw, pitch: -orbitPitch)
            camera.position = SCNVector3(-forward.x * orbitDistance, -forward.y * orbitDistance, -forward.z * orbitDistance)
            orientCamera(yaw: orbitYaw, pitch: -orbitPitch)
        } else {
            camera.position = SCNVector3(walkPosition.x, walkPosition.y, walkPosition.z)
            orientCamera(yaw: walkYaw, pitch: walkPitch)
        }
        SCNTransaction.commit()
        refreshMeasurementOverlay()
        revision &+= 1
    }
}

private struct MeshSceneSurface: UIViewRepresentable {
    @ObservedObject var controller: MeshPreviewController

    func makeUIView(context: Context) -> MeshRenderView {
        let view = MeshRenderView()
        view.scene = controller.scene
        view.pointOfView = controller.camera
        view.backgroundColor = UIColor(Color.atlasGraphite)
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        // Arm the first draw only after the view has a window and a real
        // viewport. Setting this while detached can lose SceneKit's first draw.
        view.rendersContinuously = false
        view.delegate = context.coordinator
        context.coordinator.view = view
        controller.renderView = view
        view.viewportChanged = { [weak controller] size in controller?.updateViewport(size) }
        view.firstFrameRequested = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.requestFirstFrame(in: view)
        }
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "viewer.scene"
        view.accessibilityLabel = "Трёхмерная модель"
        view.accessibilityTraits = [.allowsDirectInteraction]
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: pan)
        view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch); view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: MeshRenderView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.view = view
        controller.renderView = view
        view.viewportChanged = { [weak controller] size in controller?.updateViewport(size) }
        view.firstFrameRequested = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.requestFirstFrame(in: view)
        }
        // Camera revisions must not reinstall an unchanged SceneKit graph.
        if view.scene !== controller.scene {
            view.suspendFirstFrame()
            view.scene = controller.scene
        }
        if view.pointOfView !== controller.camera { view.pointOfView = controller.camera }
        view.accessibilityValue = controller.accessibilityPose
        context.coordinator.requestFirstFrame(in: view)
        view.setNeedsDisplay()
    }

    static func dismantleUIView(_ view: MeshRenderView, coordinator: Coordinator) {
        coordinator.controller.stopMoving()
        view.suspendFirstFrame()
        view.delegate = nil
        view.viewportChanged = nil
        view.firstFrameRequested = nil
        view.scene = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var controller: MeshPreviewController
        weak var view: MeshRenderView?
        init(controller: MeshPreviewController) { self.controller = controller }
        func requestFirstFrame(in view: MeshRenderView) {
            self.view = view
            guard controller.isActive, !controller.hasRendered,
                  view.window != nil, view.bounds.width > 0, view.bounds.height > 0,
                  view.scene === controller.scene else {
                view.suspendFirstFrame()
                if controller.hasRendered { view.delegate = nil }
                return
            }
            if let windowScene = view.window?.windowScene, windowScene.activationState != .foregroundActive {
                view.suspendFirstFrame()
                return
            }
            // A reused representable must retain the CURRENT coordinator until
            // a real delegate callback confirms this exact scene was rendered.
            view.delegate = self
            view.armFirstFrame()
        }
        nonisolated func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            // The renderer and mutable scene stay on SceneKit's callback thread.
            // Only immutable identity crosses to MainActor, not a SceneKit graph.
            let renderedSceneID = ObjectIdentifier(scene)
            Task { @MainActor [weak self] in
                guard let self, let view = self.view, view.window != nil,
                      view.bounds.width > 0, view.bounds.height > 0,
                      self.controller.isActive, ObjectIdentifier(self.controller.scene) == renderedSceneID,
                      view.scene === self.controller.scene else { return }
                if let windowScene = view.window?.windowScene, windowScene.activationState != .foregroundActive { return }
                view.suspendFirstFrame()
                view.delegate = nil
                self.controller.markRendered()
            }
        }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            controller.pick(at: recognizer.location(in: view), in: view)
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let delta = recognizer.translation(in: recognizer.view)
            if recognizer.state == .began || recognizer.state == .changed {
                controller.rotate(horizontal: Float(delta.x), vertical: Float(delta.y))
                recognizer.setTranslation(.zero, in: recognizer.view)
            }
        }
        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .changed {
                controller.zoom(scale: Float(recognizer.scale))
                recognizer.scale = 1
            }
        }
    }
}

/// SwiftUI creates the view at zero size; fitting must follow its first real
/// layout and any later rotation/mode change. Defer state publication one turn
/// so no ObservableObject update happens inside a SwiftUI layout transaction.
@MainActor private final class MeshRenderView: SCNView {
    var viewportChanged: ((CGSize) -> Void)?
    var firstFrameRequested: (() -> Void)?
    private var reportedSize: CGSize = .zero
    private var firstFrameArmed = false

    func armFirstFrame() {
        if !firstFrameArmed {
            firstFrameArmed = true
            // Re-arm once per attachment/activation, without restarting the
            // renderer on every camera revision while its first frame is pending.
            rendersContinuously = false
            rendersContinuously = true
        }
        setNeedsDisplay()
    }

    func suspendFirstFrame() {
        firstFrameArmed = false
        rendersContinuously = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { suspendFirstFrame(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.firstFrameRequested?()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { suspendFirstFrame(); return }
        let changed = size != reportedSize
        reportedSize = size
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bounds.size == size else { return }
            if changed { self.viewportChanged?(size) }
            self.firstFrameRequested?()
            self.setNeedsDisplay()
        }
    }
}

/// Native button events make a held arrow continuous and stop it when a finger
/// leaves/cancels the control. Accessibility activation still performs a step.
private struct MeshMovementButton: UIViewRepresentable {
    let controller: MeshPreviewController
    let direction: MeshPreviewController.Direction
    let symbol: String
    let label: String
    let identifier: String

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.tintColor = UIColor(Color.atlasBlue)
        button.backgroundColor = UIColor(Color.atlasBlue.opacity(0.12))
        button.layer.cornerRadius = 12
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addTarget(context.coordinator, action: #selector(Coordinator.down), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.up), for: .touchUpInside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.cancel), for: [.touchUpOutside, .touchCancel, .touchDragExit])
        return button
    }
    func updateUIView(_ view: UIButton, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, direction: direction) }

    @MainActor final class Coordinator: NSObject {
        let controller: MeshPreviewController
        let direction: MeshPreviewController.Direction
        init(controller: MeshPreviewController, direction: MeshPreviewController.Direction) {
            self.controller = controller; self.direction = direction
        }
        @objc func down() { controller.startMoving(direction) }
        @objc func up() { controller.finishMoving(direction) }
        @objc func cancel() { controller.stopMoving() }
    }
}

private struct MeshFileShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
