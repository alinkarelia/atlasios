import SwiftUI
import UIKit
import ImageIO
import AVFoundation
import AtlasCore
@preconcurrency import PhotosUI
@preconcurrency import RealityKit
@preconcurrency import RoomPlan

/// Native device screen: the mesh and room overlays come from Apple capture
/// frameworks, while every statistic represents received geometry or files.
@MainActor
struct CaptureScreen: View {
    private enum Mode: String, CaseIterable {
        case lidar = "LiDAR 3D", room = "План", evidence = "Фото"
        var symbol: String {
            switch self { case .lidar: "cube.transparent"; case .room: "square.split.2x2"; case .evidence: "photo" }
        }
    }

    let project: AtlasProject
    let outputDirectory: URL
    let onSaved: (URL) -> Void
    let onFloorPlan: ((AtlasFloorPlan) -> Void)?
    let onEvidenceSaved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lidar = CaptureCoordinator()
    @StateObject private var room = RoomCaptureAdapter()
    @StateObject private var evidence = EvidenceService()
    @StateObject private var location = LocationCaptureService()
    @StateObject private var photoCamera = PhotoCameraController()
    @State private var showTips = false
    @State private var showDiagnostics = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewGeneration = UUID()
    @State private var preparingPreview = false
    @State private var mode: Mode = .lidar
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var savedManifest: URL?
    @State private var shareableAssets: [URL] = []
    @State private var showExitChoice = false
    @State private var exitAfterSave = false
    @State private var saveRoomWhenReady = false
    @State private var showEvidence = false
    @State private var showGallery = false
    @State private var failure: String?
    @State private var isStarting = false
    @State private var startTask: Task<Void, Never>?
    @State private var startGeneration = UUID()
    @State private var isSaving = false

    private let lime = Color.atlasAccent
    private let graphite = Color.atlasCanvas

    init(project: AtlasProject, outputDirectory: URL, onSaved: @escaping (URL) -> Void,
         onFloorPlan: ((AtlasFloorPlan) -> Void)? = nil,
         onEvidenceSaved: (() -> Void)? = nil) {
        self.project = project; self.outputDirectory = outputDirectory
        self.onSaved = onSaved; self.onFloorPlan = onFloorPlan
        self.onEvidenceSaved = onEvidenceSaved
    }

    var body: some View {
        ZStack {
            graphite.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                cameraContent
                controls
                modeSelector
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(hasOpenCapture || isStarting || isSaving)
        .task {
            schedulePreview()
            await evidence.loadEvidence(projectID: project.id, outputDirectory: outputDirectory)
        }
        .onChange(of: mode) { _, _ in schedulePreview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                stopLocation(); cancelStart(); cancelPreview()
                photoCamera.stop(); lidar.suspendForDismissal(); room.suspendForDismissal()
            } else if phase == .active {
                if hasOpenCapture {
                    // A paused/interrupted scan skips preview preparation.
                    // Restart GPS independently after stopLocation() in background.
                    refreshLocationActivity()
                } else if previewTask == nil { schedulePreview() }
            }
            // Permission sheets also make the scene inactive. Keep preview
            // preparation alive; hardware adapters pause an actual recording.
        }
        .onDisappear {
            cancelPreview(); stopLocation(); cancelStart()
            photoCamera.stop(); lidar.suspendForDismissal(); room.suspendForDismissal()
        }
        .onChange(of: savedManifest) { _, _ in refreshLocationActivity() }
        .onChange(of: location.currentFix) { _, fix in
            lidar.updateAutomaticLocation(fix)
            room.updateAutomaticLocation(fix)
        }
        .onChange(of: lidar.state) { _, state in
            if state == .recording { lidar.updateAutomaticLocation(location.currentFix) }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw EvidenceError.invalidImage }
                    _ = try await evidence.importPhoto(data: data, projectID: project.id, outputDirectory: outputDirectory)
                    onEvidenceSaved?()
                    showEvidence = true
                } catch { failure = error.localizedDescription }
                selectedPhoto = nil
            }
        }
        .onChange(of: room.state) { _, state in
            if state == .recording { room.updateAutomaticLocation(location.currentFix) }
            if state == .captured && saveRoomWhenReady {
                saveRoomWhenReady = false
                Task { await saveRoom() }
            }
        }
        .confirmationDialog("Сохранить съёмку перед выходом?", isPresented: $showExitChoice, titleVisibility: .visible) {
            Button("Сохранить и выйти") {
                guard !navigationLocked else { return }
                exitAfterSave = true
                if mode == .room {
                    if room.state == .recording { saveRoomWhenReady = true; room.stop() }
                    else if room.state == .processing { saveRoomWhenReady = true }
                    else { Task { await saveRoom() } }
                } else { Task { await saveLiDAR() } }
            }
            Button("Выйти, оставив черновик") { lidar.suspendForDismissal(); room.suspendForDismissal(); dismiss() }
            Button("Продолжить", role: .cancel) {}
        } message: {
            Text("Записанные фрагменты остаются на устройстве. Незавершённую обработку можно восстановить из исходных файлов.")
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("Понятно", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        .sheet(isPresented: $showEvidence) {
            if let photo = evidence.latestEvidence { EvidenceDetailSheet(photo: photo, root: outputDirectory) }
        }
        .sheet(isPresented: $showGallery) { EvidenceGallerySheet(evidence: evidence, root: outputDirectory) }
        .sheet(isPresented: $showTips) { captureHelp }
        .sheet(isPresented: $showDiagnostics) { diagnostics }

    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { showTips = true } label: { Label("Советы", systemImage: "lightbulb") }
                .buttonStyle(AtlasSecondaryButtonStyle())
            Spacer()
            Text(project.name).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(Color.atlasMuted)
            Button {
                if hasOpenCapture { showExitChoice = true } else { dismiss() }
            } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .background(Color.atlasCard, in: Circle())
                .disabled(navigationLocked).accessibilityLabel("Закрыть съёмку")
                .accessibilityIdentifier("capture.close")
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var modeSelector: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { value in
                Button {
                    guard !hasOpenCapture, !isStarting, !isSaving else { return }
                    mode = value; savedManifest = nil; shareableAssets = []
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: value.symbol).font(.body)
                        Text(value.rawValue).font(.caption.weight(.semibold))
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(mode == value ? lime : Color.atlasMuted)
                        .background(mode == value ? lime.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 14))
                }.disabled(isStarting || isSaving || working || (hasOpenCapture && value != mode))
                    .accessibilityIdentifier("capture.mode." + modeID(value))
                    .accessibilityAddTraits(mode == value ? .isSelected : [])
            }
        }.padding(.horizontal, 16).padding(.bottom, 4)
    }

    private func modeID(_ value: Mode) -> String {
        switch value { case .lidar: "lidar"; case .room: "room"; case .evidence: "evidence" }
    }

    private var cameraContent: some View {
        ZStack {
            graphite
            if mode == .lidar && CaptureCoordinator.isSupported {
                LiDARCameraView(coordinator: lidar)
                    .accessibilityLabel("Камера LiDAR")
                // These dashed outlines are real detected AR planes projected
                // in exactly the same viewport as the native renderer.
                Canvas { context, _ in
                    for vertices in lidar.detectedPlaneOutlines where vertices.count >= 3 {
                        var path = Path(); path.addLines(vertices); path.closeSubpath()
                        context.stroke(path, with: .color(lime.opacity(0.85)),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            } else if mode == .room && RoomCaptureAdapter.isSupported {
                NativeRoomCaptureView(adapter: room).accessibilityLabel("Камера и контуры помещения")
            } else if mode == .evidence {
                PhotoCameraPreview(controller: photoCamera)
                if photoCamera.state == .unavailable || photoCamera.state == .interrupted {
                    cameraFallback(title: "Камера недоступна", message: photoCamera.errorMessage ?? "Можно импортировать фото из медиатеки.")
                        .accessibilityIdentifier("evidence.cameraUnavailable")
                }
            } else { unavailableContent }
            if supported {
                LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(spacing: 12) {
                    if savedManifest == nil && !showsPhotoFallback {
                        Text(guidanceText).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                            .foregroundStyle(Color.atlasInk).padding(14)
                            .frame(maxWidth: .infinity)
                            .background(graphite.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
                            .padding(16).accessibilityIdentifier("capture.status")
                    }
                    Spacer(minLength: 10)
                    if let savedManifest { savedCard(savedManifest).padding(16) }
                    else if mode != .evidence && hasOpenCapture { metrics.padding(16) }
                    else if mode == .evidence, let photo = evidence.latestEvidence {
                        Button { showGallery = true } label: {
                            Label("Фото сохранено · \(evidence.photos.count)", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.medium)).padding(12)
                                .background(graphite.opacity(0.9), in: Capsule())
                        }.foregroundStyle(lime).accessibilityIdentifier("evidence.latest")
                            .accessibilityValue(String(evidence.photos.count))
                        Text("\(photo.pixelWidth) × \(photo.pixelHeight)").font(.caption).foregroundStyle(.white.opacity(0.7))
                            .padding(.bottom, 16).accessibilityIdentifier("evidence.count")
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 200)
            .clipped().clipShape(RoundedRectangle(cornerRadius: 24)).padding(.horizontal, 8)
    }

    private var guidanceText: String {
        if working { return primaryTitle }
        if awaitingLocationPermission { return "Выберите доступ к геопозиции. Съёмка доступна и без геометки." }
        if mode == .evidence {
            if photoCamera.isReady { return "Наведите камеру на деталь и нажмите кнопку. Геометка добавится автоматически." }
            return photoCamera.errorMessage ?? "Открываем камеру…"
        }
        if mode == .room {
            if room.state == .recording { return room.instruction }
            if room.state == .captured { return "Обмер готов. Сохраните модель и проверьте план." }
            return room.isCameraReady ? "Покажите комнату и нажмите запись. Затем медленно обойдите все стены." : room.cameraStatus
        }
        if lidar.state == .recording || lidar.state == .paused || lidar.state == .interrupted { return lidar.trackingMessage }
        return lidar.isCameraReady ? "Наведите камеру на объект и нажмите запись. Пунктир показывает обнаруженные поверхности." : lidar.cameraStatus
    }

    private func cameraFallback(title: String, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(lime)
            Text(title).font(.title2.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(Color.atlasMuted).multilineTextAlignment(.center)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.atlasCard)
    }

    private var unavailableContent: some View {
        VStack(spacing: 18) {
            cameraFallback(title: "Для этого режима нужен LiDAR", message: "На совместимых iPhone Pro и iPad Pro доступны 3D и RoomPlan. Фото, измерения камерой и редактор участков работают без LiDAR.")
            Button("Перейти к фото") { mode = .evidence }.buttonStyle(AtlasSecondaryButtonStyle()).padding(.bottom, 24)
        }.background(Color.atlasCard).accessibilityIdentifier("capture.unavailable")
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            if mode == .lidar {
                metric(value: "≈ " + lidar.observedSurfaceArea.formatted(.number.precision(.fractionLength(1))) + " м²", label: "Поверхность сетки")
                Divider().overlay(.white.opacity(0.1)).frame(height: 32)
                metric(value: lidar.triangleCount.formatted(), label: "Треугольников")
                Divider().overlay(.white.opacity(0.1)).frame(height: 32)
                metric(value: String(lidar.segmentCount), label: "Фрагментов")
            } else {
                metric(value: String(room.wallCount), label: "Стен")
                Divider().overlay(.white.opacity(0.1)).frame(height: 32)
                metric(value: String(room.openingCount), label: "Проёмов")
                Divider().overlay(.white.opacity(0.1)).frame(height: 32)
                metric(value: room.hasCheckpoint ? "Есть" : "—", label: "Локальный черновик")
            }
        }.padding(.vertical, 16).background(graphite.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 5)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: hasDisplayedLocation ? "location.fill" : "location.slash")
                    .foregroundStyle(hasDisplayedLocation ? lime : Color.atlasMuted)
                Text(savedManifest == nil ? location.statusMessage : savedLocationMessage)
                    .font(.caption).lineLimit(2).foregroundStyle(Color.atlasMuted)
                Spacer(minLength: 0)
                Button { showDiagnostics = true } label: { Image(systemName: "info.circle").frame(width: 32, height: 32) }
                    .accessibilityLabel("Состояние камеры и геометки")
            }
            if let issue = currentCameraError {
                HStack {
                    Text(mode == .evidence ? "Повторите запуск камеры или импортируйте фото." : issue)
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    Spacer(minLength: 4)
                    Button(AVCaptureDevice.authorizationStatus(for: .video) == .denied ? "Настройки" : "Повторить") {
                        retryCamera()
                    }.font(.caption.weight(.semibold)).foregroundStyle(lime)
                }
            }
            HStack(spacing: 24) {
                Group {
                    if mode == .evidence {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Image(systemName: "photo.on.rectangle").font(.title2).frame(width: 48, height: 48)
                        }.disabled(evidence.isProcessing).accessibilityLabel("Импортировать фото")
                            .accessibilityIdentifier("evidence.import")
                    } else if mode == .lidar && [.recording, .paused, .interrupted].contains(lidar.state) {
                        Button {
                            if lidar.state == .recording { lidar.pause() } else { Task { await resumeLiDAR() } }
                        } label: { Image(systemName: lidar.state == .recording ? "pause.fill" : "play.fill").font(.title2).frame(width: 48, height: 48) }
                            .disabled(working).accessibilityLabel(lidar.state == .recording ? "Пауза" : "Продолжить")
                    } else { Color.clear.frame(width: 48, height: 48) }
                }
                Spacer(minLength: 0)
                Button { primaryAction() } label: {
                    ZStack {
                        Circle().stroke(lime, lineWidth: 2).frame(width: 74, height: 74)
                        if working { ProgressView().tint(lime) }
                        else if savedManifest != nil || mode == .room && room.state == .captured {
                            Image(systemName: primarySymbol).font(.title).foregroundStyle(lime)
                        } else if hasOpenCapture {
                            RoundedRectangle(cornerRadius: 8).fill(lime).frame(width: 30, height: 30)
                        } else { Circle().fill(lime).frame(width: 60, height: 60) }
                    }
                }.disabled(!shutterEnabled)
                    .opacity(shutterEnabled ? 1 : 0.4)
                    .accessibilityLabel(primaryTitle).accessibilityIdentifier("capture.shutter")
                Spacer(minLength: 0)
                Group {
                    if mode == .lidar && lidar.state == .recording {
                        Button {
                            let fix = location.currentFix
                            Task {
                                do { _ = try await evidence.captureCameraPhoto(from: lidar.arView, projectID: project.id,
                                    frameID: lidar.currentFrameID, outputDirectory: outputDirectory, geoFix: fix)
                                    onEvidenceSaved?()
                                }
                                catch { failure = error.localizedDescription }
                            }
                        } label: { Image(systemName: "camera").font(.title2).frame(width: 48, height: 48) }
                            .disabled(evidence.isProcessing).accessibilityLabel("Фото с камеры")
                    } else { Color.clear.frame(width: 48, height: 48) }
                }
            }
            Text(primaryTitle).font(.caption.weight(.medium)).foregroundStyle(Color.atlasMuted)
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
    }

    private var showsPhotoFallback: Bool {
        mode == .evidence && (photoCamera.state == .unavailable || photoCamera.state == .interrupted)
    }

    private var currentCameraError: String? {
        switch mode { case .lidar: lidar.errorMessage; case .room: room.errorMessage; case .evidence: photoCamera.errorMessage }
    }

    private func retryCamera() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } else {
            if mode == .lidar && [.paused, .interrupted].contains(lidar.state) {
                Task { await resumeLiDAR() }
            } else { schedulePreview() }
        }
    }

    private func resumeLiDAR() async {
        await lidar.resume()
        refreshLocationActivity()
    }

    private var captureHelp: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("Медленно, с перекрытием", systemImage: "figure.walk").font(.title2.bold())
                    Text("Двигайте телефон плавно. Держите соседние поверхности в кадре; резкие повороты и однотонные стены затрудняют трекинг.")
                    Label("Контуры — обнаруженные поверхности", systemImage: "square.dashed").font(.headline)
                    Text("Пунктир в LiDAR появляется по данным камеры. Он помогает видеть найденные плоскости, но не показывает процент полноты. В плане помещения RoomPlan рисует стены, двери и окна.")
                    Label("Свет и материал", systemImage: "sun.max").font(.headline)
                    Text("Нужен ровный свет. Зеркала, стекло, движущиеся люди и блестящие поверхности могут оставлять пробелы. Осмотрите модель после сохранения.")
                    Label("Геометка и точность", systemImage: "location").font(.headline)
                    Text("Геометка — положение телефона. Для точной привязки участка используйте контрольные точки; размеры для рабочего проекта проверяйте контрольным прибором.")
                }.padding(24).foregroundStyle(Color.atlasInk)
            }.background(Color.atlasCanvas).navigationTitle("Советы по съёмке")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { showTips = false } } }
        }.preferredColorScheme(.dark)
    }

    private var diagnostics: some View {
        NavigationStack {
            List {
                LabeledContent("Режим", value: mode.rawValue)
                LabeledContent("Камера", value: guidanceText)
                if mode != .evidence {
                    LabeledContent("Получено кадров", value: String(mode == .room ? room.cameraFrameCount : lidar.cameraFrameCount))
                }
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("LiDAR", value: CaptureCoordinator.isSupported ? "Доступен" : "Недоступен")
                Section("Геометка") { locationStatus }
                if mode == .lidar && lidar.segmentCount > 1 {
                    Text("Фрагменты имеют отдельные координаты. Для общей модели требуется совмещение.")
                }
                if let notice = room.planNotice, mode == .room { Text(notice) }
                Button("Повторить открытие камеры") { showDiagnostics = false; retryCamera() }
            }.navigationTitle("Состояние съёмки")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { showDiagnostics = false } } }
        }.preferredColorScheme(.dark)
    }

    private var locationStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: hasDisplayedLocation ? "location.fill" : "location.slash")
                    .foregroundStyle(hasDisplayedLocation ? lime : .orange)
                Text(savedManifest == nil ? location.statusMessage : savedLocationMessage)
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if savedManifest == nil && location.canOpenSettings {
                    Button("Настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.font(.caption.weight(.semibold)).foregroundStyle(lime)
                }
            }
            Text("Геометка — положение телефона, не привязка 3D. После сохранения её можно уточнить в проекте.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var hasDisplayedLocation: Bool {
        if savedManifest == nil { return location.currentFix != nil }
        return (mode == .room ? room.currentGeoTag : lidar.currentGeoTag)?.effectiveFix != nil
    }

    private var savedLocationMessage: String {
        let tag = mode == .room ? room.currentGeoTag : lidar.currentGeoTag
        guard let fix = tag?.effectiveFix else { return "Геометка не получена. Её можно добавить вручную в проекте." }
        let accuracy = fix.horizontalAccuracyMeters.map { " · ±\($0.formatted(.number.precision(.fractionLength(1)))) м" } ?? ""
        return "Геометка сохранена" + accuracy + (fix.isSimulated ? " · тестовое положение" : "")
    }

    private func savedCard(_ manifest: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Съёмка сохранена", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(lime)
            Text(mode == .room ? "RoomPlan JSON и USDZ. Обмер хранится в собственных локальных координатах."
                              : "OBJ каждого фрагмента и исходные сетки. Файлы доступны без интернета.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.65))
            ForEach(shareableAssets, id: \.self) { asset in
                ShareLink(item: asset) {
                    Label(asset.lastPathComponent, systemImage: "square.and.arrow.up").font(.subheadline).foregroundStyle(lime)
                }
            }
            ShareLink(item: manifest) { Label("Метаданные съёмки", systemImage: "doc.text").font(.caption).foregroundStyle(.white.opacity(0.6)) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(graphite.opacity(0.94), in: RoundedRectangle(cornerRadius: 22))
    }

    private var awaitingLocationPermission: Bool {
        location.isActive && location.authorizationStatus == .notDetermined && location.status != .servicesDisabled
    }
    private var shutterEnabled: Bool {
        guard supported, !working else { return false }
        if savedManifest != nil || hasOpenCapture { return true }
        if mode == .evidence { return photoCamera.isReady && !awaitingLocationPermission }
        let cameraReady = mode == .room ? room.isCameraReady : lidar.isCameraReady
        return cameraReady && !preparingPreview && !awaitingLocationPermission
    }

    private var supported: Bool { mode == .evidence || (mode == .room ? RoomCaptureAdapter.isSupported : CaptureCoordinator.isSupported) }
    private var trackingGood: Bool { mode == .room ? room.state == .captured || room.state == .saved : lidar.isTrackingNormal || lidar.state == .saved }
    private var working: Bool {
        isStarting || isSaving || evidence.isProcessing || photoCamera.state == .capturing || (mode == .room ? [.preparing, .processing, .exporting].contains(room.state) : [.preparing, .exporting].contains(lidar.state))
    }
    private var navigationLocked: Bool {
        isStarting || isSaving || [.preparing, .exporting].contains(lidar.state) || [.preparing, .exporting].contains(room.state)
    }
    private var hasOpenCapture: Bool {
        [.preparing, .recording, .paused, .interrupted, .exporting].contains(lidar.state) || [.preparing, .recording, .processing, .captured, .exporting].contains(room.state)
    }
    private var primaryTitle: String {
        if savedManifest != nil { return "Готово" }
        if mode == .evidence { return evidence.isProcessing ? "Сохраняем фото…" : photoCamera.state == .capturing ? "Снимаем…" : "Сделать фото" }
        if mode == .room {
            switch room.state {
            case .recording: return "Завершить комнату"
            case .captured: return "Сохранить обмер"
            case .processing: return "Обрабатываем…"
            case .exporting: return "Сохраняем…"
            default: return "Начать обмер"
            }
        }
        switch lidar.state {
        case .recording, .paused, .interrupted: return "Завершить фрагмент"
        case .exporting: return "Сохраняем…"
        default: return "Начать LiDAR"
        }
    }
    private var primarySymbol: String {
        if savedManifest != nil { return "checkmark" }
        if mode == .room { return room.state == .recording ? "stop.fill" : room.state == .captured ? "square.and.arrow.down" : "viewfinder" }
        return [.recording, .paused, .interrupted].contains(lidar.state) ? "stop.fill" : "viewfinder"
    }

    private func primaryAction() {
        guard !isStarting, !isSaving, !working, shutterEnabled else { return }
        if savedManifest != nil { dismiss(); return }
        if mode == .evidence { takePhoto(); return }
        if mode == .room {
            if room.state == .recording { room.stop() }
            else if room.state == .captured { Task { await saveRoom() } }
            else { beginCapture() }
        } else {
            if [.recording, .paused, .interrupted].contains(lidar.state) { Task { await saveLiDAR() } }
            else { beginCapture() }
        }
    }

    private func saveLiDAR() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do { captureSaved(try await lidar.finish()) }
        catch { failure = error.localizedDescription; exitAfterSave = false }
    }

    private func saveRoom() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let url = try await room.export()
            if let floorPlan = room.asFloorPlan(projectID: project.id, frameID: room.frameID) { onFloorPlan?(floorPlan) }
            captureSaved(url)
        } catch { failure = error.localizedDescription; exitAfterSave = false }
    }

    private func beginCapture() {
        guard !isStarting, !hasOpenCapture else { return }
        let generation = UUID()
        let selectedMode = mode
        startGeneration = generation
        isStarting = true
        lidar.updateAutomaticLocation(location.currentFix)
        room.updateAutomaticLocation(location.currentFix)
        startTask = Task {
            defer {
                if startGeneration == generation { isStarting = false; startTask = nil }
            }
            if selectedMode == .room {
                await room.start(projectID: project.id, projectName: project.name, outputDirectory: outputDirectory)
            } else {
                await lidar.start(projectID: project.id, projectName: project.name, outputDirectory: outputDirectory)
            }
            refreshLocationActivity()
        }
    }

    private func takePhoto() {
        guard photoCamera.isReady, !evidence.isProcessing else { return }
        let fix = location.currentFix
        let capturedAt = Date()
        Task {
            do {
                let data = try await photoCamera.takePhoto()
                _ = try await evidence.capturePhoto(data: data, projectID: project.id,
                    outputDirectory: outputDirectory, geoFix: fix, capturedAt: capturedAt)
                onEvidenceSaved?()
            } catch { if !(error is CancellationError) { failure = error.localizedDescription } }
        }
    }

    private func cancelPreview() {
        previewGeneration = UUID()
        previewTask?.cancel(); previewTask = nil; preparingPreview = false
        lidar.suspendPreview(); room.suspendPreview(); photoCamera.stop()
    }

    private func schedulePreview() {
        cancelPreview()
        guard savedManifest == nil, !hasOpenCapture, !isStarting else { return }
        let ticket = UUID(); previewGeneration = ticket
        preparingPreview = true
        previewTask = Task { @MainActor in
            defer {
                if previewGeneration == ticket { preparingPreview = false; previewTask = nil }
            }
            await prepareVisibleCamera()
        }
    }

    private func prepareVisibleCamera() async {
        guard !Task.isCancelled, savedManifest == nil else { return }
        switch mode {
        case .lidar:
            photoCamera.stop(); room.suspendPreview()
            await lidar.preparePreview()
        case .room:
            photoCamera.stop(); lidar.suspendPreview()
            await room.preparePreview()
        case .evidence:
            lidar.suspendPreview(); room.suspendPreview()
            await photoCamera.prepare()
        }
        guard !Task.isCancelled else { return }
        refreshLocationActivity()
    }

    private func refreshLocationActivity() {
        if scenePhase == .active && supported && savedManifest == nil && currentCameraError == nil && AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            location.start()
        } else {
            stopLocation()
        }
    }

    private func stopLocation() {
        location.stop()
        // SwiftUI may defer onChange delivery while the scene is backgrounded.
        // Clear adapter caches synchronously, preserving already recorded tags.
        lidar.updateAutomaticLocation(nil)
        room.updateAutomaticLocation(nil)
    }

    private func cancelStart() {
        startGeneration = UUID()
        startTask?.cancel(); startTask = nil; isStarting = false
        lidar.cancelPendingStart(); room.cancelPendingStart()
    }

    private func captureSaved(_ url: URL) {
        savedManifest = url
        shareableAssets = exportedAssets(from: url)
        onSaved(url)
        if exitAfterSave { dismiss() }
    }

    private func exportedAssets(from manifest: URL) -> [URL] {
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["completedAssets"] as? [String] else { return [] }
        let root = manifest.deletingLastPathComponent().standardizedFileURL
        return paths.compactMap { path in
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), ["obj", "usdz"].contains(url.pathExtension),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }
}

private struct LiDARCameraView: UIViewRepresentable {
    let coordinator: CaptureCoordinator
    func makeUIView(context: Context) -> ARView { coordinator.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

private struct NativeRoomCaptureView: UIViewRepresentable {
    let adapter: RoomCaptureAdapter
    func makeUIView(context: Context) -> RoomCaptureView { adapter.captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

@MainActor
private struct EvidenceGallerySheet: View {
    @ObservedObject var evidence: EvidenceService
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotoEvidence?

    var body: some View {
        NavigationStack {
            List {
                ForEach(evidence.photos) { photo in
                    Button {
                        evidence.select(photo)
                        selectedPhoto = photo
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: photo.source == "photoLibrary" ? "photo" : "camera")
                                .foregroundStyle(Color.atlasAccent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(photo.createdAt, format: .dateTime.day().month().year().hour().minute())
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.atlasInk)
                                Text("\(photo.pixelWidth) × \(photo.pixelHeight) · \(photo.ocr?.lines.count ?? 0) строк текста")
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                                if photo.recognitionIssue != nil {
                                    Label("Распознавание требует проверки", systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.atlasMuted)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("evidence.gallery.photo." + photo.id.uuidString)
                        .listRowBackground(Color.atlasCard)
                }
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas)
            .navigationTitle("Фото проекта · \(evidence.photos.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .sheet(item: $selectedPhoto) { photo in EvidenceDetailSheet(photo: photo, root: root) }
        }.preferredColorScheme(.dark).tint(.atlasAccent)
    }
}

@MainActor
private struct EvidenceDetailSheet: View {
    let photo: PhotoEvidence
    let root: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let image = evidenceThumbnail(at: root.appendingPathComponent(photo.relativePath)) {
                        Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Label("Оригинал сохранён", systemImage: "checkmark.shield").foregroundStyle(Color(red: 216 / 255, green: 1, blue: 62 / 255))
                    if let issue = photo.recognitionIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    Text("Распознавание — черновик").font(.headline)
                    Text("Проверьте ФИО, даты и цифры по фотографии. Приложение не связывает их с реестром автоматически.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let ocr = photo.ocr {
                        ForEach(Array(ocr.lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top) {
                                Text(line.text).textSelection(.enabled)
                                Spacer()
                                if line.confidence < 0.8 { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityLabel("Низкая уверенность распознавания") }
                            }
                        }
                        if ocr.lines.isEmpty { Text("Текст не найден").foregroundStyle(.secondary) }
                    }
                    ShareLink(item: root.appendingPathComponent(photo.relativePath)) { Label("Поделиться оригиналом", systemImage: "square.and.arrow.up") }
                }.padding(20)
            }.navigationTitle("Фото объекта").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}

/// Bounded decoding protects older devices when evidence is a 48 MP photo.
private func evidenceThumbnail(at url: URL, maximumPixelSize: Int = 1_600) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}
