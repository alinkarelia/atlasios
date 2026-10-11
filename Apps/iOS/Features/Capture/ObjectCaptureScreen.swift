import SwiftUI
import UIKit
@preconcurrency import RealityKit
import AtlasCore

/// Guided photography is an independent capture mode. The native camera
/// supplies its reticle, object bounds and scan-pass coverage without invented
/// geometry or a simulated camera feed.
@MainActor
struct ObjectCaptureScreen: View {
    let project: AtlasProject
    let directory: URL
    let onSaved: (URL) -> Void
    let captureOperator: FieldCaptureOperator?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = ObjectCaptureAdapter()
    @StateObject private var location = LocationCaptureService()
    @State private var showTips = false
    @State private var showExitChoice = false
    @State private var exitWhenSaved = false
    @State private var startingTask: Task<Void, Never>?

    init(project: AtlasProject, directory: URL, onSaved: @escaping (URL) -> Void,
         captureOperator: FieldCaptureOperator? = nil) {
        self.project = project; self.directory = directory
        self.onSaved = onSaved; self.captureOperator = captureOperator
    }

    var body: some View {
        ZStack {
            Color.atlasCanvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if capture.state == .unavailable { unavailable }
                else {
                    viewport
                    ScrollView {
                        VStack(spacing: 14) {
                            status
                            controls
                            if let error = capture.errorMessage {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.footnote).foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("objectCapture.error")
                            }
                            if let warning = capture.warningMessage {
                                Text(warning).font(.footnote).foregroundStyle(Color.atlasMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(20)
                    }.frame(maxHeight: 290)
                }
            }
        }
        .foregroundStyle(Color.atlasInk)
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(capture.hasLiveCapture || capture.state == .reconstructing)
        .onChange(of: capture.state) { _, state in
            if [.ready, .detecting, .capturing].contains(state), scenePhase == .active {
                location.start(); capture.updateLocation(location.currentFix)
            } else { location.stop() }
            if state == .failed, exitWhenSaved { exitWhenSaved = false }
        }
        .onChange(of: location.currentFix) { _, fix in capture.updateLocation(fix) }
        .onChange(of: capture.savedRevision) { _, _ in
            if let url = capture.manifestURL { onSaved(url) }
            if exitWhenSaved, capture.state != .reconstructing {
                exitWhenSaved = false; dismiss()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                capture.suspend(background: phase == .background)
                if phase == .background { location.stop() }
            } else if [.ready, .detecting, .capturing].contains(capture.state) {
                location.start()
            }
        }
        .onDisappear {
            startingTask?.cancel(); startingTask = nil
            location.stop(); capture.suspendForDismissal()
        }
        .confirmationDialog("Завершить съёмку объекта?", isPresented: $showExitChoice, titleVisibility: .visible) {
            if capture.state == .capturing {
                Button("Сохранить снимки и закрыть") { exitWhenSaved = true; capture.finishCapture() }
            } else if capture.state == .reconstructing {
                Button("Остановить обработку и закрыть") { exitWhenSaved = true; capture.cancelReconstruction() }
            }
            Button("Продолжить", role: .cancel) {}
        } message: { Text("Полученные оригиналы остаются в проекте.") }
        .sheet(isPresented: $showTips) { tips }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { showTips = true } label: { Image(systemName: "lightbulb").frame(width: 42, height: 42) }
                .buttonStyle(.plain).background(Color.atlasCard, in: Circle())
                .accessibilityLabel("Советы по съёмке объекта")
            VStack(alignment: .leading, spacing: 3) {
                Text("3D по фотографиям").font(.headline)
                Text(project.name).font(.caption).foregroundStyle(Color.atlasMuted).lineLimit(1)
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .buttonStyle(.plain).background(Color.atlasCard, in: Circle())
                .accessibilityLabel("Закрыть съёмку объекта")
                .accessibilityIdentifier("objectCapture.close")
                .disabled(capture.state == .finishing)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var unavailable: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "camera.aperture").font(.system(size: 62, weight: .light)).foregroundStyle(Color.atlasAccent)
            Text("Нужен совместимый iPhone").font(.title2.bold())
            Text("Направляемая съёмка Object Capture доступна на поддерживаемом устройстве с LiDAR. В симуляторе камера и создание объекта недоступны.")
                .font(.body).foregroundStyle(Color.atlasMuted).multilineTextAlignment(.center)
            Text("На устройстве можно снять объект со всех сторон, сохранить оригиналы и построить модель, если доступна обработка Apple.")
                .font(.footnote).foregroundStyle(Color.atlasMuted).multilineTextAlignment(.center)
            Button("Вернуться в проект") { dismiss() }.buttonStyle(AtlasPrimaryButtonStyle())
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("objectCapture.unavailable")
    }

    private var viewport: some View {
        ZStack(alignment: .top) {
            if let session = capture.session {
                ObjectCaptureView(session: session)
                    .accessibilityIdentifier("objectCapture.nativeCamera")
            } else {
                LinearGradient(colors: [Color.atlasCard, Color.atlasCanvas], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 16) {
                    Image(systemName: viewportSymbol).font(.system(size: 74, weight: .ultraLight))
                        .foregroundStyle(Color.atlasAccent)
                    Text(viewportTitle).font(.title3.bold()).multilineTextAlignment(.center)
                    Text(viewportCaption).font(.subheadline).foregroundStyle(Color.atlasMuted)
                        .multilineTextAlignment(.center)
                    if capture.state == .reconstructing {
                        ProgressView(value: capture.progress).tint(Color.atlasAccent)
                        Text(capture.processingStage).font(.caption).foregroundStyle(Color.atlasMuted)
                    }
                }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if capture.session != nil {
                Text(liveInstruction).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(16).frame(maxWidth: 430)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 12)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(capture.state == .reconstructing ? "Обработка на iPhone" : "Оригинальные снимки",
                      systemImage: capture.state == .reconstructing ? "cpu" : "photo.stack")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.atlasMuted)
                Spacer()
                if capture.state == .reconstructing {
                    Text(capture.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit()).foregroundStyle(Color.atlasAccent)
                } else {
                    Text("\(capture.imageCount)").font(.title3.monospacedDigit().bold())
                }
            }
            if capture.session != nil {
                Text(capture.feedback.first ?? (capture.isPaused ? "Съёмка на паузе" : capture.trackingMessage))
                    .font(.footnote).foregroundStyle(capture.feedback.isEmpty ? Color.atlasMuted : Color.orange)
                if capture.passCompleted {
                    Label("Обход завершён. Следующий ракурс снимите выше или ниже.", systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(Color.atlasAccent)
                }
                Text(location.statusMessage).font(.caption).foregroundStyle(Color.atlasMuted).lineLimit(2)
            } else if capture.state == .datasetReady || capture.state == .modelReady {
                Label("Снимки и паспорт съёмки сохранены в проекте", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(Color.atlasAccent)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var controls: some View {
        switch capture.state {
        case .idle, .failed:
            Button { start() } label: { Label("Открыть камеру", systemImage: "camera") }
                .buttonStyle(AtlasPrimaryButtonStyle()).accessibilityIdentifier("objectCapture.start")
        case .preparing, .finishing:
            HStack(spacing: 12) { ProgressView(); Text(capture.state == .finishing ? "Сохраняем оригиналы…" : "Подготавливаем камеру…") }
                .font(.subheadline).frame(maxWidth: .infinity, minHeight: 54)
        case .ready:
            Button { capture.detectObject() } label: { Label("Выделить объект", systemImage: "viewfinder") }
                .buttonStyle(AtlasPrimaryButtonStyle())
        case .detecting:
            Button { capture.beginCapture() } label: { Label("Начать обход", systemImage: "record.circle") }
                .buttonStyle(AtlasPrimaryButtonStyle())
            Button("Выделить заново") { capture.resetDetection() }.buttonStyle(AtlasSecondaryButtonStyle())
        case .capturing:
            HStack(spacing: 12) {
                Button { capture.togglePause() } label: {
                    Image(systemName: capture.isPaused ? "play.fill" : "pause.fill").frame(width: 44, height: 44)
                }.buttonStyle(.plain).background(Color.atlasCard, in: Circle())
                    .accessibilityLabel(capture.isPaused ? "Продолжить съёмку" : "Пауза")
                Button { capture.finishCapture() } label: { Label("Завершить", systemImage: "stop.fill") }
                    .buttonStyle(AtlasPrimaryButtonStyle()).accessibilityIdentifier("objectCapture.finish")
            }
            HStack(spacing: 12) {
                Button("Новый ракурс") { capture.nextPass() }.buttonStyle(AtlasSecondaryButtonStyle())
                Button { capture.takeExtraShot() } label: { Label("Кадр", systemImage: "camera") }
                    .buttonStyle(AtlasSecondaryButtonStyle()).disabled(!capture.canRequestShot || capture.isPaused)
            }
        case .datasetReady, .modelReady:
            if capture.canBuildModel {
                Button { capture.buildModel() } label: {
                    Label(capture.modelURL == nil ? "Построить 3D-модель" : "Перестроить модель", systemImage: "cube")
                }.buttonStyle(AtlasPrimaryButtonStyle()).accessibilityIdentifier("objectCapture.reconstruct")
            } else if !ObjectCaptureAdapter.canReconstruct {
                Text("На этом устройстве обработка Apple недоступна. Оригиналы можно выгрузить из проекта для реконструкции.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            } else if capture.imageCount < 10 {
                Text("Для модели нужно минимум 10 снимков с перекрывающимися ракурсами. Этот набор сохранён; снимите новый обход.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }
            if let model = capture.modelURL {
                ShareLink(item: model) { Label("Поделиться моделью", systemImage: "square.and.arrow.up") }
                    .buttonStyle(AtlasSecondaryButtonStyle())
            }
            HStack(spacing: 12) {
                Button("Новый объект") { start() }.buttonStyle(AtlasSecondaryButtonStyle())
                Button("В проект") { dismiss() }.buttonStyle(AtlasSecondaryButtonStyle())
            }
        case .reconstructing:
            Button("Остановить обработку") { capture.cancelReconstruction() }.buttonStyle(AtlasSecondaryButtonStyle())
        case .unavailable: EmptyView()
        }
    }

    private var liveInstruction: String {
        if capture.isPaused { return "Пауза. Нажмите продолжить, когда будете готовы." }
        switch capture.state {
        case .ready: return "Объект должен целиком помещаться в кадре. Нажмите «Выделить объект»."
        case .detecting: return "Проверьте границы объекта и начните обход."
        case .capturing: return "Медленно обойдите объект. Камера снимает автоматически."
        case .finishing: return "Сохраняем снимки. Подождите, прежде чем закрывать экран."
        default: return "Держите неподвижный объект в кадре."
        }
    }
    private var viewportSymbol: String {
        switch capture.state {
        case .reconstructing: "cube.transparent"
        case .modelReady: "cube.fill"
        case .datasetReady: "photo.stack.fill"
        default: "camera.aperture"
        }
    }
    private var viewportTitle: String {
        switch capture.state {
        case .reconstructing: "Создаём настоящую 3D-модель"
        case .modelReady: "3D-модель готова"
        case .datasetReady: "Объект снят"
        default: "Объект со всех сторон"
        }
    }
    private var viewportCaption: String {
        switch capture.state {
        case .reconstructing: "Оставьте приложение открытым. Оригиналы уже сохранены."
        case .modelReady: "Модель USDZ сохранена вместе с исходными снимками."
        case .datasetReady: "Набор снимков сохранён. Создание модели запускается отдельно."
        default: "Направляемая съёмка поможет сохранить детали и текстуру памятника, предмета или небольшого объекта."
        }
    }

    private var tips: some View {
        NavigationStack {
            List {
                Section("Подготовьте объект") {
                    Text("Выберите неподвижный объект с видимой фактурой. Стекло, зеркала и блестящие поверхности восстанавливаются хуже.")
                    Text("Используйте ровное освещение. Не двигайте объект и не допускайте людей в кадр.")
                }
                Section("Снимите перекрывающиеся ракурсы") {
                    Text("Сначала сделайте полный обход на одной высоте. Затем снимите новый ракурс выше или ниже, сохраняя перекрытие.")
                    Text("Система показывает границы и ход обхода. Жёлтые подсказки означают, что нужно поправить расстояние, свет или движение.")
                }
                Section("Сохраните и проверьте") {
                    Text("Завершение съёмки сохраняет оригинальные снимки и их метаданные. Создание модели — отдельная обработка на совместимом устройстве.")
                    Text("Перед точными измерениями проверьте масштаб на известном размере. Геометка показывает местоположение оператора; она не совмещает независимые 3D-модели.")
                }
            }.scrollContentBackground(.hidden).background(Color.atlasCanvas)
                .navigationTitle("Советы по съёмке")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showTips = false } } }
        }.preferredColorScheme(.dark)
    }
    private func start() {
        guard startingTask == nil else { return }
        startingTask = Task {
            await capture.start(project: project, directory: directory, captureOperator: captureOperator)
            startingTask = nil
        }
    }
    private func close() {
        if capture.state == .capturing || capture.state == .reconstructing { showExitChoice = true }
        else if capture.state != .finishing {
            startingTask?.cancel(); capture.cancelUnusedPreview(); dismiss()
        }
    }
}
