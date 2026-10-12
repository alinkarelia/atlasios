import SwiftUI
import Combine
import SceneKit
import UIKit
import simd

/// SceneKit owns only display buffers from the bounded worker-side USDZ reader.
/// Native RoomPlan/ModelIO object graphs never cross a concurrency boundary.
@MainActor
final class EmptyRoomSceneController: ObservableObject {
    static let maximumModelAnnotations = 500
    @Published private(set) var hasRendered = false
    let scene = SCNScene()
    let camera = SCNNode()
    private let annotations = SCNNode()
    private let radius: Float
    private weak var view: SCNView?

    init(mesh: OBJPreviewPayload, document: EmptyRoomDocument, review: EmptyRoomSurfaceReview? = nil) {
        let center = (mesh.minimum + mesh.maximum) / 2
        radius = max(1, simd_length(mesh.maximum - mesh.minimum))
        let positions = SCNGeometrySource(data: mesh.positions, semantic: .vertex, vectorCount: mesh.vertexCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let normals = SCNGeometrySource(data: mesh.normals, semantic: .normal, vectorCount: mesh.vertexCount,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(data: mesh.indices, primitiveType: .triangles, primitiveCount: mesh.triangleCount, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [positions, normals], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.69, green: 0.73, blue: 0.76, alpha: 1)
        material.lightingModel = .lambert; material.isDoubleSided = true
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = -center
        scene.rootNode.addChildNode(node)
        annotations.simdPosition = -center
        scene.rootNode.addChildNode(annotations)
        updateAnnotations(document: document, review: review)
        scene.background.contents = UIColor(Color.atlasGraphite)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 300
        scene.rootNode.addChildNode(ambient)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .directional; light.light?.intensity = 950
        light.eulerAngles = SCNVector3(-0.7, -0.6, 0); scene.rootNode.addChildNode(light)
        camera.camera = SCNCamera(); camera.camera?.fieldOfView = 55
        camera.camera?.zNear = 0.01; camera.camera?.zFar = Double(max(100, radius * 30))
        scene.rootNode.addChildNode(camera)
        reset()
    }

    func attach(_ view: SCNView) { self.view = view }
    func setDimensions(_ visible: Bool) { annotations.isHidden = !visible; view?.setNeedsDisplay() }
    func updateAnnotations(document: EmptyRoomDocument, review: EmptyRoomSurfaceReview?) {
        for child in annotations.childNodes { child.removeFromParentNode() }
        let surfaces = Dictionary(document.surfaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for dimension in EmptyRoomReviewPresentation.dimensions(document, review: review).prefix(Self.maximumModelAnnotations) {
            let matrix = surfaces[dimension.sourceID]?.transform.columns
            let normal: SIMD3<Float>
            if let matrix, matrix.count == 16 { normal = SIMD3(Float(matrix[8]), Float(matrix[9]), Float(matrix[10])) }
            else { normal = SIMD3(0, 0, 1) }
            add(dimension, surfaceNormal: normal)
        }
        view?.setNeedsDisplay()
    }
    func setActive(_ active: Bool) { view?.rendersContinuously = active && !hasRendered }
    func markRendered() { if !hasRendered { hasRendered = true } }
    func reset() {
        camera.simdPosition = SIMD3(radius * 0.55, radius * 1.3, radius * 0.85)
        camera.look(at: SCNVector3Zero)
        view?.pointOfView = camera
        view?.defaultCameraController.target = SCNVector3Zero
    }
    func snapshot() throws -> UIImage {
        guard hasRendered, let view, view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { throw EmptyRoomError.noRenderedImage }
        SCNTransaction.flush()
        return view.snapshot()
    }

    private func add(_ value: EmptyRoomDimension, surfaceNormal: SIMD3<Float>) {
        let a = SIMD3<Float>(Float(value.start.x), Float(value.start.y), Float(value.start.z))
        let b = SIMD3<Float>(Float(value.end.x), Float(value.end.y), Float(value.end.z))
        let delta = b - a, length = simd_length(delta)
        guard length > 0 else { return }
        let color = value.confidence == .low || value.confidence == .unknown ? UIColor.systemOrange : UIColor(Color.atlasAccent)
        let direction = delta / length
        let normal = simd_length(surfaceNormal) > 0.00001 ? simd_normalize(surfaceNormal) : SIMD3<Float>(0, 0, 1)
        var perpendicular = simd_cross(direction, normal)
        if simd_length(perpendicular) < 0.00001 { perpendicular = simd_cross(direction, abs(direction.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)) }
        perpendicular = simd_normalize(perpendicular)
        let displayOffset = perpendicular * max(0.025, radius * 0.009) + normal * 0.004
        let lineA = a + displayOffset, lineB = b + displayOffset
        let tick = perpendicular * max(0.01, radius * 0.003)
        let lineMaterial = SCNMaterial(); lineMaterial.diffuse.contents = color; lineMaterial.lightingModel = .constant
        func segment(_ start: SIMD3<Float>, _ end: SIMD3<Float>) {
            let delta = end - start, length = simd_length(delta)
            guard length > 0 else { return }
            let cylinder = SCNCylinder(radius: CGFloat(max(0.001, radius * 0.00065)), height: CGFloat(length))
            cylinder.radialSegmentCount = 5; cylinder.materials = [lineMaterial]
            let line = SCNNode(geometry: cylinder)
            line.simdPosition = (start + end) / 2
            line.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            annotations.addChildNode(line)
        }
        segment(lineA, lineB)
        segment(a, lineA); segment(b, lineB)
        segment(lineA - tick, lineA + tick); segment(lineB - tick, lineB + tick)
        let text = SCNText(string: "\(value.title) · \(value.valueMeters.formatted(.number.precision(.fractionLength(2)))) м", extrusionDepth: 0)
        text.font = .systemFont(ofSize: 6, weight: .semibold); text.flatness = 0.5
        let textMaterial = SCNMaterial(); textMaterial.diffuse.contents = color; textMaterial.lightingModel = .constant
        text.materials = [textMaterial]
        let label = SCNNode(geometry: text)
        let bounds = text.boundingBox
        label.pivot = SCNMatrix4MakeTranslation((bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2, 0)
        let scale = max(0.005, radius * 0.0012)
        label.simdScale = SIMD3<Float>(repeating: scale)
        label.simdPosition = (lineA + lineB) / 2 + perpendicular * max(0.02, radius * 0.007)
        let billboard = SCNBillboardConstraint(); billboard.freeAxes = .all
        label.constraints = [billboard]
        annotations.addChildNode(label)
    }
}

struct EmptyRoomSceneView: UIViewRepresentable {
    @ObservedObject var controller: EmptyRoomSceneController
    let showDimensions: Bool
    let isActive: Bool
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = controller.scene; view.pointOfView = controller.camera
        view.allowsCameraControl = true; view.defaultCameraController.target = SCNVector3Zero
        view.antialiasingMode = .multisampling4X; view.preferredFramesPerSecond = 30
        view.backgroundColor = UIColor(Color.atlasGraphite)
        controller.attach(view); controller.setDimensions(showDimensions); controller.setActive(isActive)
        view.delegate = context.coordinator; context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.controller = controller
        if view.scene !== controller.scene {
            view.scene = controller.scene; view.pointOfView = controller.camera
            view.delegate = context.coordinator; controller.attach(view)
        }
        controller.setDimensions(showDimensions); controller.setActive(isActive)
    }
    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) { view.rendersContinuously = false; view.delegate = nil; view.scene = nil }
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }
    @MainActor final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var controller: EmptyRoomSceneController
        weak var view: SCNView?
        init(controller: EmptyRoomSceneController) { self.controller = controller }
        nonisolated func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            // The mutable renderer/scene remain on their callback executor.
            Task { @MainActor [weak self] in
                guard let self, let view = self.view, view.window != nil,
                      view.bounds.width > 0, view.bounds.height > 0 else { return }
                self.controller.markRendered(); view.rendersContinuously = false; view.delegate = nil
            }
        }
    }
}

@MainActor
enum EmptyRoomPNGExporter {
    static func render(image: UIImage, document: EmptyRoomDocument, showDimensions: Bool, review: EmptyRoomSurfaceReview? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale
        let quantities = EmptyRoomQuantities.summary(document, review: review)
        let text = "TerraView · RoomPlan · Семантический черновик\nРазмеры \(showDimensions ? "включены (до 500 подписей)" : "выключены") · Габариты, не световой проход\nПол по контурам: \(EmptyRoomReviewPresentation.number(quantities.floorGrossSquareMeters)) м² · отверстия не обследованы\nСтены до вычета, известная часть: \(EmptyRoomReviewPresentation.number(quantities.wallGrossSquareMeters)) м² · после вычета: \(EmptyRoomReviewPresentation.number(quantities.wallNetSquareMeters))\nПотолок неизвестен · Локальные метры · \(document.frameID.uuidString.prefix(8))\n? — тип не проверен · Hₛ вдоль поверхности · Уверенность не точность"
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping; style.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: UIColor(Color.atlasInk), .paragraphStyle: style]
        let width = max(1, image.size.width - 24)
        let textHeight = ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height)
        let size = CGSize(width: image.size.width, height: image.size.height + textHeight + 22)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(Color.atlasGraphite).setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(at: .zero)
            (text as NSString).draw(in: CGRect(x: 12, y: image.size.height + 10, width: width, height: textHeight + 2), withAttributes: attributes)
        }
    }
}

@MainActor
enum EmptyRoomPDFExporter {
    static func render(image: UIImage, document: EmptyRoomDocument, showDimensions: Bool, review: EmptyRoomSurfaceReview? = nil) throws -> Data {
        if showDimensions && document.dimensions.count > 10_000 { throw EmptyRoomError.presentationLimit }
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { pdf in
            var y: CGFloat = 0
            var pageIndex = 0
            func text(_ string: String, _ rect: CGRect, size: CGFloat = 11, weight: UIFont.Weight = .regular, color: UIColor = .black) {
                let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
                (string as NSString).draw(in: rect, withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
            }
            func begin(_ title: String) {
                pdf.beginPage(); pageIndex += 1
                text(title, CGRect(x: 40, y: 35, width: 515, height: 44), size: 21, weight: .bold)
                text("TerraView · Семантический черновик RoomPlan · Метры", CGRect(x: 40, y: 82, width: 515, height: 24), size: 10)
                text("Локальная система \(document.frameID.uuidString)\nНе заявлены геопривязка, печатный масштаб и сантиметровая точность. · \(pageIndex)", CGRect(x: 40, y: 785, width: 515, height: 40), size: 8, color: .gray)
                y = 122
            }
            begin("Чистое помещение")
            let imageRect = CGRect(x: 40, y: 122, width: 515, height: 355)
            let ratio = min(imageRect.width / max(1, image.size.width), imageRect.height / max(1, image.size.height))
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: imageRect.midX - size.width / 2, y: imageRect.midY - size.height / 2, width: size.width, height: size.height))
            text("Размеры на модели: \(showDimensions ? "включены (до 500 подписей)" : "выключены") · Этаж \(document.story)\nПоверхностей: \(document.surfaces.count) · Шкафов storage: \(document.storage.count) · Удалено объектов: \(document.removedObjectCount)", CGRect(x: 40, y: 492, width: 515, height: 52), size: 11, weight: .medium)
            text("Потолок не наблюдён и не построен. Высота каждой стены не определяет общую высоту помещения.\n\nЗакрытые мебелью поверхности могут быть восстановлены RoomPlan. Проверьте геометрию контрольным обмером. Уверенность относится к классификации, а не к точности.\n\nОригиналы room.json и room-data.json сохраняются без изменений. Ручная правка плана не меняет эту 3D-модель.", CGRect(x: 40, y: 556, width: 515, height: 160), size: 10, color: .darkGray)
            text("SHA-256 исходного room.json: \(document.sourceRoomJSONSHA256)", CGRect(x: 40, y: 726, width: 515, height: 40), size: 8, color: .gray)
            begin("Площади и полнота обмера")
            let quantities = EmptyRoomQuantities.summary(document, review: review)
            text("Пол по наблюдённым контурам до отверстий: \(EmptyRoomReviewPresentation.number(quantities.floorGrossSquareMeters)) м²\nПол после вычета отверстий: неизвестно — отверстия отдельно не обследованы\nСтены до вычета, известная часть: \(EmptyRoomReviewPresentation.number(quantities.wallGrossSquareMeters)) м²\nСтены после вычета: \(EmptyRoomReviewPresentation.number(quantities.wallNetSquareMeters))\nНеизвестна площадь до вычета у \(quantities.unknownWallCount) стен; после вычета у \(quantities.unknownNetWallCount).", CGRect(x: 40, y: y, width: 515, height: 120), size: 11, weight: .medium)
            y += 135
            text("Площади семантического черновика, не гарантия полного обследования. Пол — горизонтальная проекция, без объединения пересекающихся контуров. Стена — одна сторона; прямоугольный габарит L×H не описывает все неровности, наклонный верх и откосы. Площадь после вычета доступна только после подтверждения полноты обследования и проверки привязанных плоских контуров проёмов. W×H вместо неизвестного арочного контура не вычитается.", CGRect(x: 40, y: y, width: 515, height: 95), size: 10, color: .darkGray)
            y += 108
            for (index, wall) in quantities.walls.enumerated() {
                if y + 70 > 765 { begin("Площади стен — продолжение") }
                text("Стена \(index + 1) · \(wall.id.uuidString.prefix(8))\nДо вычета: \(EmptyRoomReviewPresentation.number(wall.grossSquareMeters)) м² · После вычета: \(EmptyRoomReviewPresentation.number(wall.netSquareMeters))\(wall.usesRectangularEnvelope ? " · прямоугольный габарит" : " · полигон поверхности")", CGRect(x: 40, y: y, width: 515, height: 35), size: 10, weight: .medium)
                if let issue = wall.issue { text(issue, CGRect(x: 40, y: y + 37, width: 515, height: 28), size: 8, color: .gray) }
                y += 70
            }
            guard showDimensions else { return }
            begin("Ведомость размеров RoomPlan")
            text("L — длина · W — ширина · H — вертикаль · Hₛ — вдоль поверхности. D/W/P/K — тип объекта; ? — классификация не проверена. Исходные габариты не становятся размером светового прохода или полотна после исправления типа.", CGRect(x: 40, y: y, width: 515, height: 42), size: 9, color: .gray)
            y += 55
            if document.dimensions.isEmpty { text("Нет пригодных размеров поверхностей.", CGRect(x: 40, y: y, width: 515, height: 28)) }
            for dimension in EmptyRoomReviewPresentation.dimensions(document, review: review) {
                if y + 57 > 765 { begin("Размеры — продолжение") }
                text(dimension.label, CGRect(x: 40, y: y, width: 515, height: 22), size: 11, weight: .medium)
                text("Поверхность \(dimension.sourceID.uuidString.prefix(8)) · Уверенность классификации: \(dimension.confidence.title)", CGRect(x: 40, y: y + 24, width: 515, height: 21), size: 9, color: .gray)
                y += 54
            }
            if let review, !review.events.isEmpty {
                begin("Контрольные обмеры специалиста")
                var targets = Set<UUID>()
                for event in review.events.reversed() where targets.insert(event.targetID).inserted {
                    let controls = review.controls(for: event.targetID)
                    if y + 56 > 765 { begin("Контрольные обмеры — продолжение") }
                    text("\(event.role.symbol) · \(event.label) · \(event.semanticVerified ? "Тип проверен" : "Не проверено")\n\(event.dimensionMeaning.title) · координаты не совмещаются автоматически", CGRect(x: 40, y: y, width: 515, height: 40), size: 10, weight: .medium)
                    y += 48
                    for range in EmptyRoomReviewPresentation.ranges(controls) {
                        if y + 26 > 765 { begin("Контрольные обмеры — продолжение") }
                        text(range, CGRect(x: 40, y: y, width: 515, height: 24), size: 10); y += 27
                    }
                    for control in controls {
                        if y + 54 > 765 { begin("Контрольные обмеры — продолжение") }
                        text("\(EmptyRoomReviewPresentation.notation(control.role)) \(EmptyRoomReviewPresentation.number(control.effectiveMeters)) м · \(EmptyRoomReviewPresentation.position(control.position))\(control.positionNote.isEmpty ? "" : " · \(control.positionNote)")\n\(EmptyRoomReviewPresentation.definition(control.definition)) · Обмер \(control.measurementID.uuidString.prefix(8)), рев. \(control.measurementRevision)\(control.frameID.map { " · AR-система \($0.uuidString.prefix(8))" } ?? " · без AR-координат")", CGRect(x: 40, y: y, width: 515, height: 49), size: 9)
                        y += 55
                    }
                }
            }
        }
    }
}
