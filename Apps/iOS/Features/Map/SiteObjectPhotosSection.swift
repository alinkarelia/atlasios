import Foundation
import SwiftUI
import PhotosUI
import AtlasCore

/// Attachments for site facilities use the same original evidence pipeline as
/// grave cards. Detaching changes an association, never the original file.
@MainActor
struct SiteObjectPhotosSection: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @Binding var photoIDs: [UUID]
    @Binding var busy: Bool
    @StateObject private var photos = BurialPhotoService()
    @State private var loading = true
    @State private var item: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showProjectPhotos = false
    @State private var selected: PhotoEvidence?
    @State private var issue: String?
    private var directory: URL { model.captureDirectory(for: project) }
    private var attached: [PhotoEvidence] { photoIDs.compactMap { id in photos.photos.first { $0.id == id } } }

    var body: some View {
        Section {
            if loading { ProgressView("Читаем фотографии проекта") }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(attached) { photo in
                        VStack {
                            Button { selected = photo } label: { BurialPhotoThumbnail(service: photos, photo: photo, directory: directory) }.buttonStyle(.plain)
                            Button("Отвязать", role: .destructive) { photoIDs.removeAll { $0 == photo.id } }.buttonStyle(.borderless).font(.caption).disabled(busy)
                        }
                    }
                }
            }
            if !loading && attached.count < photoIDs.count {
                Text("Часть связанных оригиналов не найдена. Ссылки сохранены для восстановления.").font(.footnote).foregroundStyle(.orange)
            }
            Button("Снять оригинал", systemImage: "camera") { showCamera = true }
                .disabled(busy || loading || photoIDs.count >= 48).accessibilityIdentifier("site.photo.camera")
            PhotosPicker(selection: $item, matching: .images, preferredItemEncoding: .current) {
                Label("Добавить из Фото", systemImage: "photo.on.rectangle")
            }.disabled(busy || loading || photoIDs.count >= 48)
            Button("Выбрать из проекта", systemImage: "folder") { showProjectPhotos = true }
                .disabled(busy || loading || photoIDs.count >= 48)
            if busy && !loading { ProgressView("Сохраняем оригинальный файл") }
            if let message = issue ?? photos.errorMessage { Text(message).font(.footnote).foregroundStyle(.red) }
        } header: { Text("Фотографии объекта") } footer: {
            Text("Снимите состояние входа, дороги, ограды или свалки. Оригиналы и метаданные сохраняются; снятые фото доступны в проекте даже после отмены карточки.")
        }
        .task {
            busy = true
            await photos.load(projectID: project.id, captureDirectory: directory)
            loading = false; busy = false
        }
        .onChange(of: item) { _, selected in if let selected { Task { await importOriginal(selected) } } }
        .sheet(isPresented: $showCamera) {
            BurialPhotoCameraScreen { data, fix, time in
                busy = true; defer { busy = false }
                let photo = try await photos.captureOriginal(data: data, projectID: project.id,
                    captureDirectory: directory, operatorFix: fix, capturedAt: time)
                attach(photo); model.fieldMaterialsDidChange(projectID: project.id)
            }
        }
        .sheet(isPresented: $showProjectPhotos) {
            BurialProjectPhotoPicker(service: photos, directory: directory, attachedIDs: photoIDs, onSelect: attach)
        }
        .sheet(item: $selected) { photo in
            BurialPhotoDetailScreen(service: photos, photo: photo, directory: directory)
        }
    }
    private func attach(_ photo: PhotoEvidence) {
        guard photo.projectID == project.id, !photoIDs.contains(photo.id) else { return }
        guard photoIDs.count < 48 else { issue = "В карточке уже 48 фотографий. Новый оригинал сохранён в проекте."; return }
        photoIDs.append(photo.id)
    }
    private func importOriginal(_ item: PhotosPickerItem) async {
        guard !busy else { return }
        busy = true; issue = nil; defer { busy = false; self.item = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw SurveyCardError.message("Не удалось прочитать исходный файл фотографии.") }
            let photo = try await photos.importOriginal(data: data, projectID: project.id, captureDirectory: directory)
            attach(photo); model.fieldMaterialsDidChange(projectID: project.id)
        } catch { issue = error.localizedDescription }
    }
}
