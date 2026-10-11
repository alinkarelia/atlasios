import Foundation
import SwiftUI
import UIKit
import AtlasCore

@MainActor
struct BurialPhotoThumbnail: View {
    @ObservedObject var service: BurialPhotoService
    let photo: PhotoEvidence
    let directory: URL
    @State private var image: UIImage?
    @State private var issue: String?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.atlasCard)
            if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: 96, height: 96).clipped() }
            else if issue != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.atlasMuted) }
            else { ProgressView() }
        }
        .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(issue ?? "Фотография \(photo.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "с неизвестным временем съёмки")")
        .task(id: photo.id) {
            do { let data = try await service.thumbnail(photo, captureDirectory: directory); try Task.checkCancellation(); image = UIImage(data: data) }
            catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
    }
}

@MainActor
struct BurialProjectPhotoPicker: View {
    @ObservedObject var service: BurialPhotoService
    let directory: URL
    let attachedIDs: [UUID]
    let onSelect: (PhotoEvidence) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("Фотографии остаются в проекте, даже если вы отменили заполнение карточки.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
                if service.photos.isEmpty { Text("В проекте пока нет фотографий.") }
                ForEach(service.photos) { photo in
                    Button {
                        onSelect(photo); dismiss()
                    } label: {
                        HStack {
                            BurialPhotoThumbnail(service: service, photo: photo, directory: directory)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(photo.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Время съёмки неизвестно")
                                Text("\(photo.pixelWidth) × \(photo.pixelHeight) · оригинал").font(.caption).foregroundStyle(Color.atlasMuted)
                                if attachedIDs.contains(photo.id) { Text("Уже в карточке").font(.caption) }
                            }
                        }
                    }.disabled(attachedIDs.contains(photo.id))
                }
            }
            .navigationTitle("Фотографии проекта")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}

@MainActor
struct BurialPhotoDetailScreen: View {
    @ObservedObject var service: BurialPhotoService
    let photo: PhotoEvidence
    let directory: URL
    var onUseOCR: ((String, UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var originalURL: URL?
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
                    else if issue == nil { ProgressView("Проверяем оригинал") }
                    if let issue { Text(issue).foregroundStyle(.red) }
                    Text("Время съёмки: \(photo.capturedAt?.formatted(date: .abbreviated, time: .standard) ?? "неизвестно")")
                    Text("Добавлено в проект: \(photo.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(Color.atlasMuted)
                    if let source = photo.sourceGeoMetadata, let coordinate = source.coordinate {
                        Text("GPS из файла: \(coordinate.latitude.formatted(.number.precision(.fractionLength(7)))), \(coordinate.longitude.formatted(.number.precision(.fractionLength(7))))")
                        Text("Время наблюдения из файла: \(source.capturedAt?.formatted(date: .abbreviated, time: .standard) ?? "неизвестно")").font(.caption)
                    } else { Text("GPS в исходном файле не указан.").font(.caption).foregroundStyle(Color.atlasMuted) }
                    if let fix = photo.geoTag?.effectiveFix {
                        Text("Геометка наблюдения: \(fix.coordinate.latitude.formatted(.number.precision(.fractionLength(6)))), \(fix.coordinate.longitude.formatted(.number.precision(.fractionLength(6))))")
                        Text("\(fix.observedAt.formatted(date: .abbreviated, time: .standard)) · \(fix.horizontalAccuracyMeters.map { "±\($0.formatted(.number.precision(.fractionLength(1)))) м" } ?? "точность неизвестна")")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                        Text("Положение телефона при съёмке не задаёт точную точку могилы.").font(.footnote).foregroundStyle(Color.atlasMuted)
                    }
                    Divider()
                    Text("Надпись · черновик OCR").font(.headline)
                    if let ocr = photo.ocr, !ocr.lines.isEmpty {
                        ForEach(Array(ocr.lines.enumerated()), id: \.offset) { _, line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.text).textSelection(.enabled)
                                Text("Уверенность распознавания \(Int((max(0, min(1, line.confidence)) * 100).rounded())) %")
                                    .font(.caption).foregroundStyle(Color.atlasMuted)
                            }
                        }
                        if let onUseOCR {
                            Button("Взять текст в черновик надписи", systemImage: "text.badge.plus") {
                                onUseOCR(ocr.text, photo.id); dismiss()
                            }.buttonStyle(.borderedProminent).disabled(originalURL == nil)
                        }
                        Text("Сверьте буквы и даты с оригиналом. Распознавание не подтверждает личность и не заполняет людей автоматически.")
                            .font(.footnote).foregroundStyle(Color.atlasMuted)
                    } else { Text(photo.recognitionIssue ?? "Читаемый текст не найден. Надпись можно вписать вручную.").foregroundStyle(Color.atlasMuted) }
                    if let originalURL { ShareLink(item: originalURL) { Label("Поделиться оригиналом", systemImage: "square.and.arrow.up") } }
                }.padding()
            }
            .navigationTitle("Оригинальная фотография")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task {
                do {
                    originalURL = try await service.photoURL(photo, captureDirectory: directory)
                    let data = try await service.thumbnail(photo, captureDirectory: directory, maxPixelSize: 1_200)
                    try Task.checkCancellation(); image = UIImage(data: data)
                } catch is CancellationError { }
                catch { issue = error.localizedDescription; originalURL = nil }
            }
        }
    }
}

@MainActor
struct BurialPhotoCameraScreen: View {
    let onCapture: (Data, GeoLocationFix?, Date) async throws -> Void
    @StateObject private var camera = PhotoCameraController()
    @StateObject private var location = LocationCaptureService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var saving = false
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                PhotoCameraPreview(controller: camera).ignoresSafeArea(edges: .bottom)
                VStack {
                    Text("Снимите памятник и надпись крупно. Оригинал сохранится без пересжатия.")
                        .font(.callout).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    Spacer()
                    if let message = issue ?? camera.errorMessage {
                        Text(message).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        Button("Повторить запуск камеры") { Task { await camera.prepare() } }.buttonStyle(.bordered)
                    }
                    Text(location.statusMessage).font(.caption).padding(8).background(.ultraThinMaterial, in: Capsule())
                    Button { Task { await capture() } } label: {
                        if saving { ProgressView().tint(.black) }
                        else { Image(systemName: "camera.fill").font(.title) }
                    }
                    .frame(width: 76, height: 76).background(.white, in: Circle()).foregroundStyle(.black)
                    .disabled(saving || !camera.isReady).accessibilityLabel("Снять и сохранить оригинал")
                    .accessibilityIdentifier("burial.camera.shutter")
                }.padding()
            }
            .navigationTitle("Фото захоронения").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(saving) } }
            .interactiveDismissDisabled(saving)
            .task { location.start(); await camera.prepare() }
            .onDisappear { camera.stop(); location.stop() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { location.start(); Task { await camera.prepare() } }
                else { camera.stop(); location.stop() }
            }
        }
    }
    private func capture() async {
        guard !saving else { return }
        saving = true; issue = nil; defer { saving = false }
        let time = Date(); let fix = location.currentFix
        do { let data = try await camera.takePhoto(); camera.stop(); try await onCapture(data, fix, time); dismiss() }
        catch { issue = error.localizedDescription; await camera.prepare() }
    }
}
