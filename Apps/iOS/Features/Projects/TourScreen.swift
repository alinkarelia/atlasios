import SwiftUI
import PhotosUI
import AtlasCore

/// Ordered original-photo stations. Adding a photo never invents its GPS,
/// capture date, panorama projection or position in the LiDAR coordinate frame.
@MainActor
struct TourScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @StateObject private var photos = BurialPhotoService()
    @StateObject private var videoEvidence = EvidenceService()
    private let store = TourStore()
    private let videoImporter = VideoTourImporter()
    @State private var routes: [TourManifest] = []
    @State private var route: TourManifest?
    @State private var features: [AtlasFeature] = []
    @State private var loading = true
    @State private var saving = false
    @State private var issue: String?
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showViewer = false
    @State private var photoItem: PhotosPickerItem?
    @State private var panoramaStation: TourStation?
    @State private var contourStation: TourStation?
    @State private var selectedFeature: AtlasFeature?
    @State private var pendingFeature: AtlasFeature?
    @State private var showVideos = false
    @State private var videos:[VideoTourSource] = []
    @State private var videoIssues:[String] = []
    @State private var loadingVideos = false
    @State private var importingVideo = false
    @State private var videoProgress = (completed:0,total:0)
    @State private var videoImportTask:Task<Void,Never>?
    private var directory: URL { model.captureDirectory(for: project) }
    private var busy: Bool { loading || saving || photos.isProcessing }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                introduction
                if loading { ProgressView("Открываем маршруты") }
                else if let route {
                    routeHeader(route)
                    acquisition
                    if route.stations.isEmpty { Text("Добавьте фотографии остановок по порядку. Посетитель сможет переходить между ними и открывать связанные карточки.").foregroundStyle(Color.atlasMuted) }
                    ForEach(route.stations) { station in stationRow(station) }
                } else {
                    Button("Создать маршрут",systemImage:"point.topleft.down.to.point.bottomright.curvepath") { Task { await createRoute() } }
                        .buttonStyle(AtlasPrimaryButtonStyle()).accessibilityIdentifier("tour.create")
                }
            }.padding(20)
        }
        .background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
        .navigationTitle("Прогулка по проекту").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of:photoItem) { _, item in if let item { Task { await importPhoto(item) } } }
        .sheet(isPresented:$showPhotos) { photoPicker }
        .sheet(isPresented:$showVideos) { videoPicker }
        .onDisappear { videoImportTask?.cancel() }
        .fullScreenCover(isPresented:$showCamera) {
            TourCameraScreen { data, fix, time in
                let photo = try await photos.captureOriginal(data:data,projectID:project.id,captureDirectory:directory,operatorFix:fix,capturedAt:time)
                model.fieldMaterialsDidChange(projectID:project.id)
                try await append(photo)
            }
        }
        .fullScreenCover(isPresented:$showViewer,onDismiss:{ selectedFeature = pendingFeature; pendingFeature = nil }) {
            if let route {
                TourPhotoViewer(tour:route,service:photos,directory:directory,features:features) { pendingFeature = $0; showViewer = false }
            }
        }
        .sheet(item:$contourStation) { station in
            TourContourEditor(station:station,service:photos,directory:directory,features:features.filter { !SurveyFeatureLifecycle.isSoftRemoved($0) }) { annotations in
                try await update(station.id) { $0.annotations = annotations }
            }
        }
        .sheet(item:$selectedFeature) { feature in
            if feature.category == .grave {
                BurialCardScreen(model:model,project:project,feature:feature,cemetery:cemetery(for:feature)) {
                    Task { features = await model.features(in:project) }
                }
            } else {
                FeatureEditScreen(model:model,project:project,feature:feature,cemetery:cemetery(for:feature)) {
                    Task { features = await model.features(in:project) }
                }
            }
        }
        .confirmationDialog("Это полная панорама 360°?",isPresented:Binding(get:{panoramaStation != nil},set:{ if !$0 { panoramaStation = nil } }),titleVisibility:.visible,presenting:panoramaStation) { station in
            Button("Да, исходный файл — полная панорама 360°") {
                Task { await perform { try await update(station.id) { $0.projection = .equirectangular360; $0.projectionConfirmedAt = Date() } } }
            }
            Button("Отмена",role:.cancel) { panoramaStation = nil }
        } message: { _ in Text("Подтвердите, что изображение содержит весь обзор 360° × 180° в эквидистантной проекции. Соотношение 2:1 само по себе этого не доказывает. Приложение не сшивает обычные фотографии в панораму.") }
        .alert("Маршрут",isPresented:Binding(get:{issue != nil},set:{ if !$0 { issue = nil } })) { Button("Понятно",role:.cancel) { issue = nil } } message: { Text(issue ?? "") }
    }

    private var introduction: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Остановки, фотографии и карточки",systemImage:"figure.walk").font(.title2.bold())
            Text("Маршрут работает без сервера. Исходные фото, время съёмки и имеющиеся геометки сохраняются в проекте и входят в его ZIP.").font(.subheadline).foregroundStyle(Color.atlasMuted)
            Text("Контуры на снимках отмечает оператор: GPS объекта не задаёт его место в кадре. Для прогулки по объёмной модели откройте 3D-просмотр съёмки.").font(.caption).foregroundStyle(Color.atlasMuted)
        }
    }
    private func routeHeader(_ value: TourManifest) -> some View {
        VStack(alignment:.leading,spacing:12) {
            if routes.count > 1 {
                Picker("Маршрут",selection:Binding(get:{route?.id ?? value.id},set:{ id in Task { await perform { try await persist(); route = routes.first { $0.id == id } } } })) {
                    ForEach(routes) { Text($0.title).tag($0.id) }
                }.disabled(busy)
            }
            TextField("Название маршрута",text:Binding(get:{route?.title ?? ""},set:{route?.title = String($0.prefix(250))}))
                .font(.title3.bold()).onSubmit { Task { await saveCurrent() } }.disabled(busy).accessibilityIdentifier("tour.title")
            HStack {
                Button("Сохранить",systemImage:"checkmark.circle") { Task { await saveCurrent() } }.disabled(busy)
                Spacer()
                Button("Новый маршрут",systemImage:"plus") { Task { await createRoute() } }.disabled(busy || routes.count >= 100)
            }.font(.caption)
            Button("Начать прогулку · \(value.stations.count) точек",systemImage:"play.fill") { showViewer = true }
                .buttonStyle(AtlasPrimaryButtonStyle()).disabled(value.stations.isEmpty || busy).accessibilityIdentifier("tour.play")
        }
    }
    private var acquisition: some View {
        VStack(alignment:.leading,spacing:12) {
            Button("Снять следующую остановку",systemImage:"camera") { showCamera = true }
                .buttonStyle(AtlasSecondaryButtonStyle()).disabled(busy).accessibilityIdentifier("tour.camera")
            HStack {
                Button("Фото проекта",systemImage:"photo.on.rectangle") { showPhotos = true }.disabled(busy)
                Spacer()
                PhotosPicker(selection:$photoItem,matching:.images) { Label("Импорт",systemImage:"square.and.arrow.down") }.disabled(busy)
            }.font(.subheadline)
            Button("Маршрут из видеосъёмки",systemImage:"video.badge.waveform") { showVideos = true }
                .buttonStyle(AtlasSecondaryButtonStyle()).disabled(busy || (route?.stations.count ?? 0) >= 500).accessibilityIdentifier("tour.video.import")
        }
    }
    private func stationRow(_ station: TourStation) -> some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.top,spacing:12) {
                if let photo = photos.photos.first(where:{$0.id == station.photoID}) { BurialPhotoThumbnail(service:photos,photo:photo,directory:directory) }
                VStack(alignment:.leading,spacing:5) {
                    TextField("Название остановки",text:stationBinding(station.id,\.name,limit:250)).font(.headline).onSubmit { Task { await saveCurrent() } }.disabled(busy)
                    Text(station.capturedAt?.formatted(date:.abbreviated,time:.shortened) ?? "Время съёмки неизвестно").font(.caption).foregroundStyle(Color.atlasMuted)
                    Text(station.coordinate == nil ? "Геометка источника отсутствует" : "Геометка источника сохранена").font(.caption).foregroundStyle(Color.atlasMuted)
                    Text(station.projection == .photograph ? "Фотография" : "Полная панорама 360°").font(.caption).foregroundStyle(Color.atlasAccent)
                    if let source = station.videoFrameProvenance { Text("Кадр видео · \(source.actualVideoSeconds.formatted(.number.precision(.fractionLength(2)))) с").font(.caption).foregroundStyle(Color.atlasMuted) }
                }
            }
            TextField("Комментарий к остановке",text:stationBinding(station.id,\.comment,limit:10_000),axis:.vertical)
                .lineLimit(2...4).font(.subheadline).onSubmit { Task { await saveCurrent() } }.disabled(busy)
            HStack {
                Button("Выше",systemImage:"arrow.up") { Task { await reorder(station.id,by:-1) } }.disabled(busy || route?.stations.first?.id == station.id)
                Button("Ниже",systemImage:"arrow.down") { Task { await reorder(station.id,by:1) } }.disabled(busy || route?.stations.last?.id == station.id)
                Spacer()
                Button("Убрать",systemImage:"minus.circle") { Task { await remove(station.id) } }.disabled(busy)
            }.font(.caption)
            Button("Контуры и карточки · \(station.annotations.count)",systemImage:"square.dashed") { contourStation = station }
                .font(.subheadline).disabled(busy).accessibilityIdentifier("tour.annotate")
            if station.projection == .photograph && TourPolicy.supportsPanorama(width:station.pixelWidth,height:station.pixelHeight,explicitlyConfirmed:true) {
                Button("Указать полную панораму 360°",systemImage:"pano") { panoramaStation = station }.font(.caption).disabled(busy)
            } else if station.projection == .equirectangular360 {
                Button("Показывать как обычное фото") { Task { await perform { try await update(station.id) { $0.projection = .photograph; $0.projectionConfirmedAt = nil } } } }.font(.caption).disabled(busy)
            }
            Text("Удаление остановки не удаляет исходную фотографию. Изменённые подписи сохраните кнопкой «Сохранить».").font(.caption2).foregroundStyle(Color.atlasMuted)
        }.padding(16).background(Color.atlasCard,in:RoundedRectangle(cornerRadius:20))
    }
    private var photoPicker: some View {
        NavigationStack {
            List {
                ForEach(photos.photos) { photo in
                    Button {
                        showPhotos = false; Task { await perform { try await append(photo) } }
                    } label: {
                        HStack {
                            BurialPhotoThumbnail(service:photos,photo:photo,directory:directory)
                            VStack(alignment:.leading,spacing:6) {
                                Text(photo.capturedAt?.formatted(date:.abbreviated,time:.shortened) ?? "Время съёмки неизвестно")
                                Text("\(photo.pixelWidth) × \(photo.pixelHeight) · оригинал").font(.caption)
                            }
                        }
                    }
                }
                if photos.photos.isEmpty { Text("Сначала снимите остановку или импортируйте фотографию.") }
            }.navigationTitle("Фото для остановки")
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Закрыть") { showPhotos = false } } }
        }
    }
    private var videoPicker:some View {
        NavigationStack {
            List {
                Text("Выберите конкретный фрагмент LiDAR с записанным видео. Остановки создаются из настоящих кадров с временем и позой камеры в его локальной системе. Это фотографии, без автоматической геопривязки и превращения в 360°.").font(.footnote)
                if loadingVideos { ProgressView("Проверяем видеосъёмки") }
                else if videos.isEmpty { Text("Готовых видеофрагментов в этом проекте нет. При LiDAR-съёмке включите сохранение видео и дождитесь завершения.") }
                if importingVideo {
                    ProgressView("Извлечено \(videoProgress.completed) / \(videoProgress.total) кадров",value:Double(videoProgress.completed),total:Double(max(1,videoProgress.total)))
                    Button("Отменить извлечение",role:.cancel) { videoImportTask?.cancel() }
                    Text("Уже сохранённые исходные кадры останутся в фотографиях проекта. Маршрут изменится после успешного завершения всей выбранной серии.").font(.caption)
                }
                ForEach(videos) { source in
                    Button {
                        videoImportTask = Task { await importVideo(source) }
                    } label: {
                        VStack(alignment:.leading,spacing:7) {
                            Text(source.title).font(.headline)
                            Text("\(source.startedAt.formatted(date:.abbreviated,time:.shortened)) · \(source.durationSeconds.formatted(.number.precision(.fractionLength(1)))) с").font(.caption)
                            Text("\(source.keyframeCount) поз камеры · фрагмент \(String(source.id.uuidString.prefix(8)))").font(.caption)
                        }
                    }.disabled(importingVideo || busy)
                }
                ForEach(videoIssues,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }.navigationTitle("Видео → остановки").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Закрыть") { showVideos = false }.disabled(importingVideo) } }
                .interactiveDismissDisabled(importingVideo)
                .task { await loadVideos() }
        }
    }
    private func stationBinding(_ id: UUID,_ key: WritableKeyPath<TourStation,String>,limit:Int) -> Binding<String> {
        Binding(get:{ route?.stations.first(where:{$0.id == id})?[keyPath:key] ?? "" },set:{ value in
            if let index = route?.stations.firstIndex(where:{$0.id == id}) { route?.stations[index][keyPath:key] = String(value.prefix(limit)) }
        })
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            routes = try await store.load(projectID:project.id,directory:directory); route = routes.first
            await photos.load(projectID:project.id,captureDirectory:directory); features = await model.features(in:project)
            if let error = photos.errorMessage { issue = error }
        } catch { issue = error.localizedDescription }
    }
    private func createRoute() async {
        await perform {
            if route != nil { try await persist() }
            guard routes.count < 100 else { throw TourError.invalidManifest }
            route = TourManifest(projectID:project.id,title:String("\(project.name) · маршрут \(routes.count+1)".prefix(250)))
            try await persist()
        }
    }
    private func saveCurrent() async { await perform { try await persist() } }
    private func persist() async throws {
        guard var value = route else { throw TourError.invalidManifest }
        value.updatedAt = Date(); _ = try await store.save(value,directory:directory,projectID:project.id)
        route = value
        if let index = routes.firstIndex(where:{$0.id == value.id}) { routes[index] = value } else { routes.insert(value,at:0) }
        model.fieldMaterialsDidChange(projectID:project.id)
    }
    private func append(_ photo: PhotoEvidence) async throws {
        guard photo.projectID == project.id,let count = route?.stations.count,count < 500 else { throw TourError.invalidManifest }
        route?.stations.append(TourStation(photo:photo,number:count+1)); try await persist()
    }
    private func update(_ id: UUID,change:(inout TourStation)->Void) async throws {
        guard let index = route?.stations.firstIndex(where:{$0.id == id}) else { throw TourError.invalidManifest }
        let original = route
        change(&route!.stations[index])
        do { try await persist() } catch { route = original; throw error }
    }
    private func reorder(_ id: UUID,by delta:Int) async {
        await perform {
            guard let index = route?.stations.firstIndex(where:{$0.id == id}),let count = route?.stations.count,(0..<count).contains(index+delta) else { return }
            route?.stations.swapAt(index,index+delta); try await persist()
        }
    }
    private func remove(_ id: UUID) async { await perform { route?.stations.removeAll { $0.id == id }; try await persist() } }
    private func perform(_ operation:() async throws -> Void) async {
        guard !saving else { return }; saving = true; defer { saving = false }
        do { try await operation() } catch { issue = error.localizedDescription }
    }
    private func importPhoto(_ item:PhotosPickerItem) async {
        await perform {
            guard let data = try await item.loadTransferable(type:Data.self) else { throw TourError.sourceMissing }
            let photo = try await photos.importOriginal(data:data,projectID:project.id,captureDirectory:directory)
            model.fieldMaterialsDidChange(projectID:project.id); try await append(photo); photoItem = nil
        }
    }
    private func cemetery(for feature:AtlasFeature) -> AtlasFeature? {
        let id = (try? BurialMetadata(attributes:feature.attributes))?.cemeteryID
        return features.first { $0.id == id && $0.category == .cemetery }
    }
    private func loadVideos() async {
        guard !loadingVideos else { return }; loadingVideos = true; defer { loadingVideos = false }
        do {
            let listing = try await videoImporter.sources(projectID:project.id,directory:directory)
            videos = listing.sources; videoIssues = listing.issues
        } catch { videoIssues = [error.localizedDescription] }
    }
    private func importVideo(_ source:VideoTourSource) async {
        guard !busy,!importingVideo,let count = route?.stations.count,count < 500 else { return }
        importingVideo = true; saving = true; videoProgress = (0,0)
        defer { importingVideo = false; saving = false; videoImportTask = nil }
        do {
            let added = try await videoImporter.importStations(source:source,projectID:project.id,directory:directory,evidence:videoEvidence,
                maximumStations:min(120,500-count),intervalSeconds:3,progress:{ completed,total in videoProgress = (completed,total) })
            try Task.checkCancellation()
            guard !added.isEmpty,added.allSatisfy({$0.projectID == project.id}) else { throw TourError.sourceMissing }
            let unique = added.filter { photo in
                guard let source = photo.videoFrameProvenance else { return true }
                return route?.stations.contains(where:{ station in
                    guard let old = station.videoFrameProvenance else { return false }
                    return old.frameID == source.frameID && old.sourceVideoSHA256 == source.sourceVideoSHA256 && old.sourceMetadataSHA256 == source.sourceMetadataSHA256 && abs(old.actualVideoSeconds-source.actualVideoSeconds) < 0.001
                }) != true
            }
            let original = route
            var number = count
            for photo in unique { number += 1; route?.stations.append(TourStation(photo:photo,number:number)) }
            do { try await persist() } catch { route = original; throw error }
            await photos.load(projectID:project.id,captureDirectory:directory); showVideos = false
            if unique.isEmpty { issue = "Точки выбранного видео уже входят в маршрут. Существующая разметка и подписи сохранены." }
        } catch is CancellationError {
            await photos.load(projectID:project.id,captureDirectory:directory)
            model.fieldMaterialsDidChange(projectID:project.id)
            videoIssues.insert("Извлечение отменено. Уже сохранённые кадры доступны в фотографиях проекта; маршрут не изменён.",at:0)
        } catch {
            await photos.load(projectID:project.id,captureDirectory:directory)
            model.fieldMaterialsDidChange(projectID:project.id); issue = error.localizedDescription
        }
    }
}

@MainActor
private struct TourCameraScreen: View {
    let onCapture:(Data,GeoLocationFix?,Date) async throws -> Void
    @StateObject private var camera = PhotoCameraController()
    @StateObject private var location = LocationCaptureService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var saving = false
    @State private var issue:String?
    var body:some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea(); PhotoCameraPreview(controller:camera).ignoresSafeArea(edges:.bottom)
                VStack(spacing:16) {
                    Text("Остановитесь, наведите камеру и снимите точку маршрута. Для следующей точки перейдите вперёд и повторите.")
                        .padding().background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16))
                    Spacer()
                    if let issue = issue ?? camera.errorMessage {
                        Text(issue).padding().background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12))
                        Button("Перезапустить камеру") { Task { await camera.prepare() } }
                    }
                    Text(location.statusMessage).font(.caption).padding(8).background(.ultraThinMaterial,in:Capsule())
                    Button { Task { await capture() } } label: {
                        if saving { ProgressView().tint(.black) } else { Image(systemName:"camera.fill").font(.title) }
                    }.frame(width:80,height:80).background(.white,in:Circle()).foregroundStyle(.black)
                        .disabled(saving || !camera.isReady).accessibilityLabel("Снять остановку маршрута").accessibilityIdentifier("tour.camera.shutter")
                }.padding()
            }.navigationTitle("Остановка маршрута").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Закрыть") { dismiss() }.disabled(saving) } }
                .interactiveDismissDisabled(saving)
                .task { location.start(); await camera.prepare() }
                .onDisappear { camera.stop(); location.stop() }
                .onChange(of:phase) { _, value in if value == .active { location.start(); Task { await camera.prepare() } } else { camera.stop(); location.stop() } }
        }
    }
    private func capture() async {
        guard !saving else { return }; saving = true; issue = nil; defer { saving = false }
        let time = Date(),fix = location.currentFix
        do { let data = try await camera.takePhoto(); camera.stop(); try await onCapture(data,fix,time); dismiss() }
        catch { issue = error.localizedDescription; await camera.prepare() }
    }
}
