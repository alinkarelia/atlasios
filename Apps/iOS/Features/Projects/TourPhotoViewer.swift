import SwiftUI
import UIKit
import SceneKit
import ImageIO
import UniformTypeIdentifiers
import AtlasCore

private actor TourPreviewReader {
    func preview(url:URL,panorama:Bool) throws -> Data {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:panorama ? 4_096 : 1_920,kCGImageSourceShouldCacheImmediately:true
              ] as CFDictionary) else { throw TourError.sourceMissing }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,UTType.jpeg.identifier as CFString,1,nil) else { throw TourError.sourceMissing }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TourError.sourceMissing }
        return output as Data
    }
}

@MainActor
struct TourPhotoViewer: View {
    let tour:TourManifest
    @ObservedObject var service:BurialPhotoService
    let directory:URL
    let features:[AtlasFeature]
    let onOpenFeature:(AtlasFeature)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var image:UIImage?
    @State private var originalURL:URL?
    @State private var issue:String?
    @State private var focusedFeature:AtlasFeature?
    @State private var flatPanorama = false
    private let reader = TourPreviewReader()
    private var station:TourStation? { tour.stations.indices.contains(index) ? tour.stations[index] : nil }
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                imageArea
                if let feature = focusedFeature { featurePreview(feature) }
                if let station { footer(station) }
            }.background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
                .navigationTitle(tour.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Закрыть") { dismiss() } } }
                .task(id:station?.id) { await loadStation() }
        }
    }
    private var imageArea:some View {
        ZStack {
            Color.black
            if let image,let station {
                if station.projection == .equirectangular360 && !flatPanorama {
                    TourPanoramaView(image:image).accessibilityLabel("Панорама 360 градусов. Поверните обзор движением пальца.")
                    VStack {
                        Label("360° · поверните обзор пальцем",systemImage:"pano").font(.caption).padding(10).background(.ultraThinMaterial,in:Capsule())
                        Spacer()
                        if !station.annotations.isEmpty { Text("Для контуров и карточек откройте исходный панорамный снимок.").font(.caption).padding(10).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12)) }
                    }.padding().allowsHitTesting(false)
                } else {
                    TourAnnotatedImage(image:image,annotations:station.annotations,selectedFeatureID:focusedFeature?.id,onSelect: { annotation in
                        focusedFeature = annotation.flatMap { value in features.first { $0.id == value.featureID } }
                    })
                }
            } else if let issue { Text(issue).foregroundStyle(.white).multilineTextAlignment(.center).padding() }
            else { ProgressView("Проверяем исходное фото").tint(.white).foregroundStyle(.white) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).accessibilityIdentifier("tour.viewer.image")
    }
    private func featurePreview(_ feature:AtlasFeature) -> some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Text(feature.label.isEmpty ? feature.category.title : feature.label).font(.headline)
                Spacer()
                Button("Карточка",systemImage:"rectangle.portrait") { onOpenFeature(feature); dismiss() }.accessibilityIdentifier("tour.feature.card")
            }
            if feature.category == .grave,let metadata = try? BurialMetadata(attributes:feature.attributes) {
                Text(metadata.identityStatus == .unknown ? "Личность неизвестна" : "Личность: \(metadata.identityStatus.rawValue)").font(.caption)
                if !metadata.people.isEmpty { Text(metadata.people.map(\.fullName).filter { !$0.isEmpty }.joined(separator:" · ")).font(.subheadline) }
                if let photo = metadata.photoIDs.compactMap({ id in service.photos.first { $0.id == id } }).first {
                    BurialPhotoThumbnail(service:service,photo:photo,directory:directory)
                }
                if !metadata.condition.isEmpty { Text(metadata.condition).font(.caption).lineLimit(2) }
                Text("Фотографии и полный комментарий — в связанной карточке.").font(.caption).foregroundStyle(Color.atlasMuted)
            } else { Text(feature.category.title).font(.caption) }
            Text("\(SurveyFeatureLifecycle.status(of:feature).rawValue) · контур в кадре отметил оператор").font(.caption2).foregroundStyle(Color.atlasMuted)
            if !feature.notes.isEmpty { Text(feature.notes).font(.caption).lineLimit(2) }
        }.padding(14).background(Color.atlasCard)
    }
    private func footer(_ value:TourStation) -> some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("\(index+1) / \(tour.stations.count) · \(value.name)").font(.headline)
                Spacer()
                if let originalURL { ShareLink(item:originalURL) { Image(systemName:"square.and.arrow.up") }.accessibilityLabel("Поделиться оригиналом остановки") }
            }
            if !value.comment.isEmpty { Text(value.comment).font(.subheadline).lineLimit(3) }
            Text(value.capturedAt?.formatted(date:.abbreviated,time:.shortened) ?? "Время съёмки неизвестно").font(.caption).foregroundStyle(Color.atlasMuted)
            if let source = value.videoFrameProvenance { Text("Исходное видео: \(source.actualVideoSeconds.formatted(.number.precision(.fractionLength(2)))) с · поза камеры привязана к локальному фрагменту").font(.caption2).foregroundStyle(Color.atlasMuted) }
            if let point = value.coordinate { Text("Геометка источника: \(point.latitude.formatted(.number.precision(.fractionLength(6)))), \(point.longitude.formatted(.number.precision(.fractionLength(6))))").font(.caption2).foregroundStyle(Color.atlasMuted) }
            if value.projection == .equirectangular360 {
                Button(flatPanorama ? "Вернуться в обзор 360°" : "Исходная панорама · контуры и карточки",systemImage:"pano") { flatPanorama.toggle(); focusedFeature = nil }.font(.caption)
            } else if !value.annotations.isEmpty { Text("Нажмите на контур или наведите центральный указатель, чтобы открыть данные объекта.").font(.caption).foregroundStyle(Color.atlasMuted) }
            HStack {
                Button("Назад",systemImage:"chevron.left") { index -= 1 }.disabled(index == 0)
                Spacer()
                Button("Вперёд",systemImage:"chevron.right") { index += 1 }.disabled(index+1 >= tour.stations.count)
            }.buttonStyle(.bordered).accessibilityIdentifier("tour.viewer.navigation")
        }.padding(16)
    }
    private func loadStation() async {
        image = nil; originalURL = nil; focusedFeature = nil; issue = nil; flatPanorama = false
        guard let station,let photo = service.photos.first(where:{$0.id == station.photoID}),photo.projectID == tour.projectID,
              photo.relativePath == station.originalRelativePath,photo.sha256 == station.originalSHA256 else { issue = TourError.sourceMissing.localizedDescription; return }
        do {
            let url = try await service.photoURL(photo,captureDirectory:directory)
            let data = try await reader.preview(url:url,panorama:station.projection == .equirectangular360)
            try Task.checkCancellation()
            guard let decoded = UIImage(data:data) else { throw TourError.sourceMissing }
            // Check oriented display dimensions too: EXIF rotation cannot turn
            // a portrait source into a valid sphere merely by its raw header.
            if station.projection == .equirectangular360,abs(decoded.size.width/decoded.size.height-2) > 0.01 { throw TourError.panoramaNeedsConfirmation }
            image = decoded; originalURL = url
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }
}

/// Identical aspect-fit math is used for rendering, pointing and authoring.
/// The normalized coordinates refer to the EXIF-oriented original image.
@MainActor
struct TourAnnotatedImage: View {
    let image:UIImage
    let annotations:[TourAnnotation]
    var selectedFeatureID:UUID?
    var draft:[TourImagePoint] = []
    var draftKind:TourAnnotationKind = .polygon
    var onAddPoint:((TourImagePoint)->Void)?
    var onSelect:((TourAnnotation?)->Void)?
    var body:some View {
        GeometryReader { geometry in
            let rect = TourPolicy.imageRect(imageWidth:image.size.width,imageHeight:image.size.height,container:CGRect(origin:.zero,size:geometry.size))
            ZStack(alignment:.topLeading) {
                Color.black
                Image(uiImage:image).resizable().frame(width:rect.width,height:rect.height).position(x:rect.midX,y:rect.midY)
                Canvas { context,_ in
                    for annotation in annotations {
                        draw(annotation.vertices,kind:annotation.kind,rect:rect,context:&context,color:annotation.featureID == selectedFeatureID ? .white : annotation.kind == .polyline ? .green : .cyan,filled:annotation.kind == .polygon)
                    }
                    draw(draft,kind:draftKind,rect:rect,context:&context,color:.orange,filled:false)
                }.allowsHitTesting(false)
                if onAddPoint == nil {
                    Image(systemName:"plus").font(.system(size:17,weight:.light)).foregroundStyle(.white)
                        .position(x:geometry.size.width/2,y:geometry.size.height/2).allowsHitTesting(false)
                }
            }.contentShape(Rectangle())
                .onTapGesture(coordinateSpace:.local) { point in
                    guard let normalized = TourPolicy.normalized(point,imageRect:rect) else { onSelect?(nil); return }
                    if let onAddPoint { onAddPoint(normalized) }
                    else { onSelect?(annotations.reversed().first { TourPolicy.hit(normalized,annotation:$0) }) }
                }
                .task(id:geometry.size) {
                    if onAddPoint == nil,let center = TourPolicy.normalized(CGPoint(x:geometry.size.width/2,y:geometry.size.height/2),imageRect:rect) {
                        onSelect?(annotations.reversed().first { TourPolicy.hit(center,annotation:$0) })
                    }
                }
        }
    }
    private func draw(_ points:[TourImagePoint],kind:TourAnnotationKind,rect:CGRect,context:inout GraphicsContext,color:Color,filled:Bool) {
        guard let first = points.first else { return }
        let mapped = points.map { CGPoint(x:rect.minX+$0.x*rect.width,y:rect.minY+$0.y*rect.height) }
        if kind == .point {
            let center = CGPoint(x:rect.minX+first.x*rect.width,y:rect.minY+first.y*rect.height)
            context.stroke(Path(ellipseIn:CGRect(x:center.x-8,y:center.y-8,width:16,height:16)),with:.color(color),lineWidth:3)
            return
        }
        var path = Path(); path.addLines(mapped)
        if kind == .polygon && points.count >= 3 { path.closeSubpath() }
        if filled && points.count >= 3 { context.fill(path,with:.color(color.opacity(0.1))) }
        context.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:3,dash:[7,5]))
        for point in mapped { context.fill(Path(ellipseIn:CGRect(x:point.x-3,y:point.y-3,width:6,height:6)),with:.color(color)) }
    }
}

@MainActor
struct TourContourEditor:View {
    let station:TourStation
    @ObservedObject var service:BurialPhotoService
    let directory:URL
    let features:[AtlasFeature]
    let onSave:([TourAnnotation]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image:UIImage?
    @State private var annotations:[TourAnnotation]
    @State private var selectedID:UUID?
    @State private var kind:TourAnnotationKind = .polygon
    @State private var draft:[TourImagePoint] = []
    @State private var editingID:UUID?
    @State private var saving = false
    @State private var issue:String?
    private let reader = TourPreviewReader()
    init(station:TourStation,service:BurialPhotoService,directory:URL,features:[AtlasFeature],onSave:@escaping([TourAnnotation]) async throws -> Void) {
        self.station = station; self.service = service; self.directory = directory; self.features = features; self.onSave = onSave
        _annotations = State(initialValue:station.annotations)
    }
    private var draftAnnotation:TourAnnotation? {
        guard let selectedID else { return nil }
        if let editingID,var existing = annotations.first(where:{$0.id == editingID}) {
            existing.featureID = selectedID; existing.vertices = draft; existing.kind = kind; return existing
        }
        return TourAnnotation(featureID:selectedID,vertices:draft,kind:kind)
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    Text("Выберите объект проекта и отметьте его видимый контур на этом снимке. Это связь с карточкой, а не новая географическая граница.").font(.subheadline).foregroundStyle(Color.atlasMuted)
                    Picker("Объект",selection:Binding(get:{selectedID},set:{ selectedID = $0; draft = []; editingID = nil })) {
                        Text("Выберите объект").tag(Optional<UUID>.none)
                        ForEach(features) { Text($0.label.isEmpty ? $0.category.title : $0.label).tag(Optional($0.id)) }
                    }.disabled(saving)
                    Picker("Разметка",selection:Binding(get:{kind},set:{ kind = $0; draft = []; editingID = nil })) {
                        Text("Контур").tag(TourAnnotationKind.polygon)
                        Text("Линия").tag(TourAnnotationKind.polyline)
                        Text("Точка").tag(TourAnnotationKind.point)
                    }.pickerStyle(.segmented).disabled(saving)
                    if let image {
                        TourAnnotatedImage(image:image,annotations:annotations,draft:draft,draftKind:kind,onAddPoint:{ point in
                            guard selectedID != nil,!saving else { return }
                            if kind == .point { draft = [point] } else if draft.count < 64 { draft.append(point) }
                        }).frame(height:360).clipShape(RoundedRectangle(cornerRadius:16)).accessibilityIdentifier("tour.contour.image")
                    } else if issue == nil { ProgressView("Проверяем оригинал") }
                    Text(kind == .polygon ? "Нажмите на углы по порядку: минимум 3 точки, без пересечений." : kind == .polyline ? "Нажмите вдоль дорожки или ограды: минимум 2 точки. Линия остаётся открытой." : "Нажмите на видимый объект, чтобы поставить точку.").font(.caption)
                    HStack {
                        Button("Отменить точку",systemImage:"arrow.uturn.backward") { if !draft.isEmpty { draft.removeLast() } }.disabled(draft.isEmpty || saving)
                        Spacer()
                        Button(editingID == nil ? "Добавить" : "Применить",systemImage:"plus.circle") {
                            if let value = draftAnnotation,TourPolicy.validAnnotation(value) {
                                if let index = annotations.firstIndex(where:{$0.id == value.id}) { annotations[index] = value } else { annotations.append(value) }
                                draft = []; editingID = nil
                            }
                        }.disabled(saving || (annotations.count >= 200 && editingID == nil) || draftAnnotation.map { !TourPolicy.validAnnotation($0) } != false)
                    }.font(.caption)
                    if !draft.isEmpty || editingID != nil { Button("Отменить черновик") { draft = []; editingID = nil }.font(.caption).disabled(saving) }
                    if features.isEmpty { Text("Сначала создайте объект или карточку в проекте. Маршрут использует те же записи и UUID.").font(.subheadline) }
                    ForEach(annotations) { annotation in
                        HStack {
                            Text(features.first(where:{$0.id == annotation.featureID})?.label ?? "Объект недоступен").font(.subheadline)
                            Spacer()
                            Button("Изменить") { selectedID = annotation.featureID; kind = annotation.kind; draft = annotation.vertices; editingID = annotation.id }.font(.caption).disabled(saving)
                            Button("Убрать",systemImage:"minus.circle") { annotations.removeAll { $0.id == annotation.id }; if editingID == annotation.id { draft = []; editingID = nil } }.font(.caption).disabled(saving)
                        }
                    }
                    if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
                    if station.projection == .equirectangular360 { Text("Разметка этой панорамы доступна на исходном снимке. Сферический обзор открывается отдельно.").font(.caption).foregroundStyle(Color.atlasMuted) }
                }.padding(20)
            }.background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
                .navigationTitle("Объекты в кадре").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement:.confirmationAction) { Button("Сохранить") { Task { await save() } }.disabled(saving || image == nil || !draft.isEmpty) }
                }.interactiveDismissDisabled(saving)
                .task { await load() }
        }
    }
    private func load() async {
        guard let photo = service.photos.first(where:{$0.id == station.photoID}),photo.relativePath == station.originalRelativePath,photo.sha256 == station.originalSHA256 else { issue = TourError.sourceMissing.localizedDescription; return }
        do {
            let url = try await service.photoURL(photo,captureDirectory:directory)
            let data = try await reader.preview(url:url,panorama:false); try Task.checkCancellation()
            image = UIImage(data:data)
        } catch is CancellationError { } catch { issue = error.localizedDescription }
    }
    private func save() async {
        guard !saving,draft.isEmpty else { return }; saving = true; defer { saving = false }
        do { try await onSave(annotations); dismiss() } catch { issue = error.localizedDescription }
    }
}

/// Sphere viewing is enabled only after explicit source-projection confirmation.
/// Camera rotation is confined to the sphere's center; no simulated translation.
@MainActor
private struct TourPanoramaView:UIViewRepresentable {
    let image:UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context:Context) -> SCNView {
        let view = SCNView(); view.backgroundColor = .black; view.scene = SCNScene()
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.fieldOfView = 80; camera.camera?.zNear = 0.01; camera.camera?.zFar = 20
        view.scene?.rootNode.addChildNode(camera); view.pointOfView = camera
        let sphere = SCNSphere(radius:10); sphere.segmentCount = 96
        let material = SCNMaterial(); material.lightingModel = .constant; material.isDoubleSided = true; material.cullMode = .front
        material.diffuse.contents = image; material.diffuse.wrapS = .repeat
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(-1,1,1)
        sphere.firstMaterial = material
        let surface = SCNNode(geometry:sphere); view.scene?.rootNode.addChildNode(surface)
        context.coordinator.camera = camera; context.coordinator.material = material; context.coordinator.image = image
        view.addGestureRecognizer(UIPanGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.pan(_:))))
        view.isPlaying = false; view.rendersContinuously = false; view.antialiasingMode = .multisampling2X
        return view
    }
    func updateUIView(_ view:SCNView,context:Context) {
        if context.coordinator.image !== image { context.coordinator.material?.diffuse.contents = image; context.coordinator.image = image }
    }
    @MainActor final class Coordinator:NSObject {
        var camera:SCNNode?
        var material:SCNMaterial?
        var image:UIImage?
        @objc func pan(_ gesture:UIPanGestureRecognizer) {
            guard let camera,let view = gesture.view else { return }
            let delta = gesture.translation(in:view); gesture.setTranslation(.zero,in:view)
            camera.eulerAngles.y -= Float(delta.x)*0.005
            camera.eulerAngles.x = min(1.45,max(-1.45,camera.eulerAngles.x-Float(delta.y)*0.005))
        }
    }
}
