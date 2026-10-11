import AtlasCore
import SwiftUI
import UIKit
import AVFoundation
@preconcurrency import RoomPlan

/// A separate designer workflow. Raw capture remains immutable; the operator
/// deliberately produces a reviewed-later structural derivative in its frame.
struct EmptyRoomScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @StateObject private var room = RoomCaptureAdapter()
    @StateObject private var location = LocationCaptureService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDimensions = true
    @State private var keepStorage = false
    @State private var isWorking = false
    @State private var finishRequested = false
    @State private var result: EmptyRoomExport?
    @State private var controller: EmptyRoomSceneController?
    @State private var issue: String?
    @State private var savedSources: [SavedEmptyRoomSource] = []
    @State private var showsSources = false
    @State private var showsExit = false
    @State private var presentationSaved = false
    @State private var pendingExit = false
    @State private var sceneReady = false
    @State private var isStarting = false
    @State private var startTicket = UUID()
    @State private var isVisible = true

    private var busy: Bool { isStarting || isWorking || room.state == .preparing || room.state == .processing || room.state == .exporting }
    private var hasCameraDenied: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro
                settings
                if let result {
                    if let controller { structuralPreview(controller, result: result) }
                    else if isWorking { ProgressView("Открываем структурную модель…").frame(maxWidth: .infinity) }
                    else {
                        ContentUnavailableView("Предпросмотр не открыт", systemImage: "cube.transparent", description: Text("Сохранённые USDZ, OBJ и JSON доступны для выгрузки ниже."))
                        Button("Повторить предпросмотр", systemImage: "arrow.clockwise") { Task { await loadPreview(result) } }
                    }
                    exportControls(result)
                } else if RoomCaptureAdapter.isSupported {
                    capturePreview
                    captureControls
                } else {
                    ContentUnavailableView("Нужен LiDAR и RoomPlan", systemImage: "camera.metering.unknown", description: Text("Съёмка чистого помещения доступна на совместимом iPhone или iPad. Симулятор не запускает камеру и LiDAR. Сохранённый RoomPlan можно открыть ниже."))
                        .accessibilityIdentifier("emptyRoom.unavailable")
                }
                if busy { ProgressView(isStarting ? "Подготавливаем доступ и геометку…" : (room.state == .processing ? "RoomPlan обрабатывает обмер…" : "Сохраняем исходник и структурную модель…")).frame(maxWidth: .infinity) }
                if let message = room.errorMessage { notice(message, symbol: "exclamationmark.triangle", warning: true) }
                if let message = issue { notice(message, symbol: "exclamationmark.triangle", warning: true) }
                savedRoomActions
                NavigationLink { FloorPlanScreen(model: model, project: project, initialPlanID: result?.document.sourceRoomID) } label: {
                    Label("Ручная правка плана", systemImage: "pencil.and.outline")
                }.accessibilityIdentifier("emptyRoom.editPlan")
                NavigationLink { BuildingPlansScreen(model: model, project: project) } label: {
                    Label("Этажи и квартиры здания", systemImage: "building.2")
                }
                Text("Ручная правка плана сохраняется отдельно и не меняет исходную 3D-модель. Независимые комнаты и этажи требуют явного совмещения координат.")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            }.padding(20)
        }
        .background(Color.atlasCanvas).foregroundStyle(Color.atlasInk).tint(.atlasAccent)
        .navigationTitle("Чистое помещение").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(room.state == .recording || busy)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Закрыть", systemImage: "xmark") { requestExit() }.labelStyle(.iconOnly)
                    .accessibilityIdentifier("emptyRoom.close")
            }
        }
        .task {
            isVisible = true
            await refreshSources()
            if result == nil && RoomCaptureAdapter.isSupported { await room.preparePreview() }
        }
        .onChange(of: room.state) { _, state in
            if state == .captured && finishRequested {
                finishRequested = false
                Task { await buildStructural(saveFloorPlan: true) }
            }
        }
        .onChange(of: location.currentFix) { _, fix in room.updateAutomaticLocation(fix) }
        .onChange(of: keepStorage) { _, _ in
            if result != nil && !busy { Task { await buildStructural(saveFloorPlan: false) } }
        }
        .onChange(of: scenePhase) { _, phase in
            controller?.setActive(phase == .active)
            if phase == .background {
                startTicket = UUID()
                location.stop(); room.suspendForDismissal()
            } else if result == nil, room.state == .ready, RoomCaptureAdapter.isSupported {
                Task { await room.preparePreview() }
            }
        }
        .onDisappear { isVisible = false; startTicket = UUID(); location.stop(); room.suspendForDismissal(); controller?.setActive(false) }
        .confirmationDialog("Завершить съёмку и сохранить доступный обмер?", isPresented: $showsExit, titleVisibility: .visible) {
            Button("Завершить и сохранить") { pendingExit = true; finishRequested = true; room.stop() }
            Button("Продолжить съёмку", role: .cancel) {}
        } message: { Text("RoomPlan обработает доступные данные. Исходный черновик сохраняется до создания чистой модели.") }
        .sheet(isPresented: $showsSources) { savedSourceSheet }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Режим для проектирования", systemImage: "cube.transparent").font(.caption.weight(.semibold)).foregroundStyle(Color.atlasAccent)
            Text("Структура без мебели").font(.title2.bold())
            Text("RoomPlan сохраняет стены, пол, окна, двери и проёмы. Бытовые предметы убираются из отдельной производной модели; оригинал остаётся на устройстве.")
                .font(.subheadline).foregroundStyle(Color.atlasMuted)
            notice("Семантический черновик. Проверьте закрытые мебелью стены и контрольные размеры. Потолок не наблюдён и не дорисовывается.", symbol: "ruler", warning: false)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Размеры на модели", isOn: $showDimensions).accessibilityIdentifier("emptyRoom.dimensions")
            Text("Длины сторон пола, размеры стен и проёмов из реальной геометрии RoomPlan. Этот выбор действует и для PNG/PDF.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            Toggle("Сохранить шкафы / хранение", isOn: $keepStorage).disabled(busy || room.state == .recording)
                .accessibilityIdentifier("emptyRoom.keepStorage")
            Text("Сохраняется распознанная категория storage. Приложение не определяет, встроен ли шкаф: проверьте оставленные объекты.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        }.padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var capturePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(room.state == .recording ? "Идёт обмер" : "Камера · запись не идёт", systemImage: room.state == .recording ? "record.circle" : "camera")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(room.state == .recording ? Color.red : Color.atlasAccent)
                Spacer()
                if room.state == .recording { Text("● REC").font(.caption.monospaced().bold()).foregroundStyle(.red) }
            }
            EmptyRoomCaptureSurface(adapter: room).frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityIdentifier("emptyRoom.camera")
            Text(room.isCameraReady ? room.instruction : room.cameraStatus).font(.subheadline).foregroundStyle(Color.atlasMuted)
            if room.state == .recording || room.state == .processing || room.state == .captured {
                Text("Стен: \(room.wallCount) · Проёмов: \(room.openingCount)").font(.caption.monospaced())
            }
            if hasCameraDenied {
                Button("Открыть доступ к камере в Настройках", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
    }

    @ViewBuilder private var captureControls: some View {
        switch room.state {
        case .ready, .saved:
            AtlasPrimaryButton(title: "Начать чистый обмер", systemImage: "record.circle") { Task { await startCapture() } }
                .disabled(busy || !room.isCameraReady).accessibilityIdentifier("emptyRoom.start")
        case .recording:
            AtlasPrimaryButton(title: "Завершить и очистить", systemImage: "stop.circle") {
                finishRequested = true; room.stop()
            }.accessibilityIdentifier("emptyRoom.finish")
            Text("Обойдите помещение медленно, покажите пол, стены целиком и проёмы. Закрытые участки нужно проверить после съёмки.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
        case .captured:
            AtlasPrimaryButton(title: "Сохранить структурную модель", systemImage: "square.and.arrow.down") {
                Task { await buildStructural(saveFloorPlan: true) }
            }.disabled(busy)
        case .preparing, .processing, .exporting, .unavailable:
            EmptyView()
        }
    }

    private func structuralPreview(_ controller: EmptyRoomSceneController, result: EmptyRoomExport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Структурный черновик", systemImage: "cube").font(.headline)
                Spacer()
                Button("Вписать", systemImage: "arrow.counterclockwise") { controller.reset() }.labelStyle(.iconOnly)
            }
            EmptyRoomSceneView(controller: controller, showDimensions: showDimensions, isActive: scenePhase == .active)
                .frame(height: 380).clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("emptyRoom.scene").accessibilityLabel("Реальная структурная модель RoomPlan с размерами")
                .accessibilityHint("Проведите пальцем для поворота, два пальца меняют масштаб.")
                .onReceive(controller.$hasRendered) { sceneReady = $0 }
            Text("Поверните модель пальцем · Масштаб двумя пальцами").font(.caption).foregroundStyle(Color.atlasMuted)
            Text("На устройстве · Этаж \(result.document.story) · Удалено объектов: \(result.document.removedObjectCount)").font(.caption)
            if result.document.surfaces.contains(where: { $0.kind == .floor && $0.floorAreaSquareMeters > 0 }) {
                Text("Площадь контуров пола в горизонтальной проекции: \(result.document.floorAreaSquareMeters.formatted(.number.precision(.fractionLength(2)))) м²")
                    .font(.subheadline)
            } else {
                notice("Контур пола не распознан. Добавьте его в ручном редакторе плана; синтетический пол не строится.", symbol: "square.dashed", warning: true)
            }
            Text("Поверхностей с неполной/невысокой уверенностью классификации: \(result.document.uncertainSurfaceCount). Это не оценка точности размеров.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            if showDimensions {
                if result.document.dimensions.count > EmptyRoomSceneController.maximumModelAnnotations {
                    notice("На 3D-модели и PNG показаны первые 500 подписей. Полная ведомость остаётся в JSON; PDF поддерживает до 10 000 размеров.", symbol: "text.badge.plus", warning: false)
                }
                DisclosureGroup("Размеры RoomPlan · \(result.document.dimensions.count)") {
                    ForEach(result.document.dimensions) { dimension in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(dimension.label).font(.subheadline)
                            Text("\(dimension.sourceID.uuidString.prefix(8)) · Классификация: \(dimension.confidence.title)").font(.caption2).foregroundStyle(Color.atlasMuted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func exportControls(_ result: EmptyRoomExport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Для дизайнера").font(.headline)
            HStack(spacing: 20) {
                ShareLink(item: result.usdzURL) { Label("USDZ", systemImage: "cube") }
                if let obj = result.objURL { ShareLink(item: obj) { Label("OBJ", systemImage: "square.and.arrow.up") } }
                ShareLink(item: result.documentURL) { Label("JSON", systemImage: "curlybraces") }
            }.font(.subheadline.weight(.medium))
            AtlasPrimaryButton(title: "Сохранить PNG и PDF", systemImage: "photo.on.rectangle") { Task { await savePresentation() } }
                .disabled(busy || controller == nil || !sceneReady).accessibilityIdentifier("emptyRoom.exportPresentation")
            if presentationSaved {
                HStack(spacing: 20) {
                    ShareLink(item: result.documentURL.deletingLastPathComponent().appendingPathComponent("model.png")) { Label("PNG", systemImage: "photo") }
                    ShareLink(item: result.documentURL.deletingLastPathComponent().appendingPathComponent("measurements.pdf")) { Label("PDF", systemImage: "doc.richtext") }
                }
            }
            Text("USDZ/OBJ содержат геометрию. JSON сохраняет систему координат, исходный SHA-256, уверенность и размеры. PNG/PDF используют текущий ракурс и переключатель размеров.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            if let message = result.document.objExportIssue { notice(message, symbol: "exclamationmark.triangle", warning: true) }
            Text("Потолок: неизвестен · Геопривязка и совмещение комнат: не подтверждены").font(.caption.weight(.semibold)).foregroundStyle(Color.atlasMuted)
        }.padding(16).background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var savedRoomActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Открыть сохранённый RoomPlan", systemImage: "folder") {
                Task { await refreshSources(); showsSources = true }
            }.disabled(busy || room.state == .recording).accessibilityIdentifier("emptyRoom.openSaved")
            if result != nil && RoomCaptureAdapter.isSupported {
                Button("Новый чистый обмер", systemImage: "plus") {
                    result = nil; controller = nil; presentationSaved = false; issue = nil
                    Task { await room.preparePreview() }
                }.disabled(busy)
            }
        }
    }

    private var savedSourceSheet: some View {
        NavigationStack {
            List {
                if savedSources.isEmpty {
                    ContentUnavailableView("Нет сохранённых RoomPlan", systemImage: "folder", description: Text("Сначала снимите помещение. Сохранённые исходники можно повторно очистить после перезапуска приложения."))
                }
                ForEach(savedSources) { source in
                    Button {
                        showsSources = false
                        Task { await open(source) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(source.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("RoomPlan · \(source.id.uuidString.prefix(8)) · На устройстве").font(.caption).foregroundStyle(Color.atlasMuted)
                        }
                    }
                }
            }.navigationTitle("Исходные обмеры")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showsSources = false } } }
        }.tint(.atlasAccent)
    }

    private func notice(_ text: String, symbol: String, warning: Bool) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(warning ? Color.orange : Color.atlasMuted)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.atlasCard, in: RoundedRectangle(cornerRadius: 12))
    }

    @MainActor private func startCapture() async {
        guard !busy, room.isCameraReady else { return }
        isStarting = true
        let ticket = UUID(); startTicket = ticket
        defer { isStarting = false }
        issue = nil; result = nil; controller = nil; presentationSaved = false; finishRequested = false
        // A first-time GPS permission sheet makes the scene inactive. Settle it
        // before RoomPlan recording so willResignActive cannot end a new scan.
        // Denied/disabled GPS still permits a scan without an automatic GeoTag.
        location.start()
        while location.authorizationStatus == .notDetermined && location.status != .servicesDisabled {
            guard ticket == startTicket, isVisible, !Task.isCancelled else { location.stop(); return }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { location.stop(); return }
        }
        while scenePhase == .inactive {
            guard ticket == startTicket, isVisible, !Task.isCancelled else { location.stop(); return }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { location.stop(); return }
        }
        guard ticket == startTicket, isVisible, scenePhase == .active, !Task.isCancelled else { location.stop(); return }
        room.updateAutomaticLocation(location.currentFix)
        await room.start(projectID: project.id, projectName: project.name, outputDirectory: model.captureDirectory(for: project))
        if room.state != .recording { location.stop() }
    }

    @MainActor private func buildStructural(saveFloorPlan: Bool) async {
        guard !isWorking else { return }
        isWorking = true; issue = nil; presentationSaved = false; location.stop()
        defer { isWorking = false }
        do {
            let exported = try await room.exportStructuralRoom(keepStorage: keepStorage)
            result = exported
            guard await model.registerCapture(manifest: exported.manifestURL, project: project) else {
                throw EmptyRoomScreenError.catalog(model.issue ?? "Файлы сохранены, но каталог проекта не обновился. Повторите сохранение.")
            }
            if saveFloorPlan {
                var plan = room.asFloorPlan(projectID: project.id, frameID: room.frameID)
                    ?? AtlasFloorPlan(projectID: project.id, frameID: exported.document.frameID, floorIndex: exported.document.story)
                plan.id = exported.document.sourceRoomID
                plan.name = "Чистое помещение · RoomPlan"
                let existing = await model.plans(in: project)
                // Reopening an original must not overwrite a manually repaired plan.
                if !existing.contains(where: { $0.id == plan.id }) {
                    guard await model.savePlan(plan) != nil else {
                        throw EmptyRoomScreenError.catalog(model.issue ?? "Модель сохранена, но сохранить план не удалось.")
                    }
                }
            }
            try await prepareScene(exported)
            await refreshSources()
            if pendingExit { pendingExit = false; dismiss() }
        } catch { issue = error.localizedDescription; pendingExit = false }
    }

    @MainActor private func prepareScene(_ exported: EmptyRoomExport) async throws {
        let url = exported.usdzURL
        let worker = Task.detached(priority: .userInitiated) { try OBJPreviewLoader.load(url) }
        let payload = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        controller = EmptyRoomSceneController(mesh: payload, document: exported.document)
    }
    @MainActor private func loadPreview(_ exported: EmptyRoomExport) async {
        guard !busy else { return }
        isWorking = true; issue = nil
        defer { isWorking = false }
        do { try await prepareScene(exported) }
        catch { issue = error.localizedDescription }
    }

    @MainActor private func savePresentation() async {
        guard !busy, let controller, let result else { return }
        isWorking = true; issue = nil; presentationSaved = false
        defer { isWorking = false }
        do {
            controller.setDimensions(showDimensions)
            let image = EmptyRoomPNGExporter.render(image: try controller.snapshot(), document: result.document, showDimensions: showDimensions)
            guard let png = image.pngData() else { throw EmptyRoomError.noRenderedImage }
            let pdf = try EmptyRoomPDFExporter.render(image: image, document: result.document, showDimensions: showDimensions)
            let manifest = try await room.saveStructuralPresentation(result, png: png, pdf: pdf)
            guard await model.registerCapture(manifest: manifest, project: project) else {
                throw EmptyRoomScreenError.catalog(model.issue ?? "PNG/PDF сохранены, но каталог не обновился. Повторите сохранение.")
            }
            presentationSaved = true
        } catch { issue = error.localizedDescription }
    }

    @MainActor private func open(_ source: SavedEmptyRoomSource) async {
        guard !busy else { return }
        do {
            result = nil; controller = nil; issue = nil; presentationSaved = false
            try await room.loadSavedRoom(at: source.directory, projectID: project.id)
            await buildStructural(saveFloorPlan: true)
        } catch { issue = error.localizedDescription }
    }

    @MainActor private func refreshSources() async {
        do {
            let listing = try await RoomCaptureAdapter.savedRooms(in: model.captureDirectory(for: project), projectID: project.id)
            savedSources = listing.rooms
            if !listing.issues.isEmpty { issue = "Некоторые RoomPlan не прочитаны:\n" + listing.issues.joined(separator: "\n") }
        }
        catch { issue = "Не удалось прочитать список RoomPlan: \(error.localizedDescription)" }
    }
    private func requestExit() {
        if room.state == .recording { showsExit = true }
        else if busy { issue = "Дождитесь обработки и сохранения исходного обмера перед выходом." }
        else { dismiss() }
    }
}

private enum EmptyRoomScreenError: LocalizedError {
    case catalog(String)
    var errorDescription: String? { switch self { case .catalog(let text): text } }
}

private struct EmptyRoomCaptureSurface: UIViewRepresentable {
    @ObservedObject var adapter: RoomCaptureAdapter
    func makeUIView(context: Context) -> RoomCaptureView { adapter.captureView }
    func updateUIView(_ view: RoomCaptureView, context: Context) {}
}
