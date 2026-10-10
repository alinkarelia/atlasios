import Combine
import SceneKit
import simd
import SwiftUI
import UIKit

struct MeshPreviewScreen: View {
    let url: URL
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: MeshPreviewController?
    @State private var issue: String?
    @State private var isLoading = true
    @State private var loadAttempt = 0

    var body: some View {
        Group {
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
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("viewer.retry")
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
        .onAppear { controller?.setActive(scenePhase == .active) }
        .onDisappear { controller?.setActive(false) }
        .onChange(of: scenePhase) { _, phase in
            controller?.setActive(phase == .active)
        }
    }

    @MainActor private func load() async {
        controller?.stopMoving()
        isLoading = true; issue = nil; controller = nil
        let sourceURL = url
        let worker = Task.detached(priority: .userInitiated) { try OBJPreviewLoader.load(sourceURL) }
        await withTaskCancellationHandler {
            do {
                let payload = try await worker.value
                try Task.checkCancellation()
                // Parsing, world transforms and normal generation already ran
                // off the UI actor. SceneKit only receives three data buffers.
                await Task.yield()
                controller = MeshPreviewController(mesh: payload, isActive: scenePhase == .active)
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
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Выгрузить исходную модель")
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
                    Text(controller.isAtlasCapture ? "Измеренная LiDAR-сетка · локальные метры." : "Масштаб и единицы исходной модели.")
                    Text("Поверхность показана с чёткими гранями, без фототекстуры. Исходный файл выгружается полностью. Открытые края и пропуски могут быть частью съёмки.")
                    Text("Прогулка — ручной просмотр модели, без распознавания пола или проверки столкновений со стенами.")
                }
                .navigationTitle("О модели").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showsInfo = false } } }
            }.presentationDetents([.medium, .large])
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

    init(mesh: OBJPreviewPayload, isActive: Bool) {
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
        let meshNode = SCNNode(geometry: geometry)
        meshNode.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(meshNode)
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

    var accessibilityPose: String {
        let position = camera.position
        return String(format: "%@ %@ x:%.3f y:%.3f z:%.3f yaw:%.3f pitch:%.3f", mode == .orbit ? "orbit" : "walk", hasRendered ? "rendered" : "preparing", position.x, position.y, position.z,
                      mode == .orbit ? orbitYaw : walkYaw, mode == .orbit ? orbitPitch : walkPitch)
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
        if !active { stopMoving() }
        isActive = active
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
        // A scene installed before SwiftUI gives the SCNView a real viewport
        // can otherwise remain blank until the first gesture. Render the first
        // valid frame explicitly, then stop continuous rendering in the delegate.
        view.rendersContinuously = controller.isActive
        view.delegate = context.coordinator
        context.coordinator.view = view
        view.viewportChanged = { [weak controller] size in controller?.updateViewport(size) }
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "viewer.scene"
        view.accessibilityLabel = "Трёхмерная модель"
        view.accessibilityTraits = [.allowsDirectInteraction]
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ view: MeshRenderView, context: Context) {
        context.coordinator.controller = controller
        // Camera revisions must not reinstall an unchanged SceneKit graph.
        if view.scene !== controller.scene { view.scene = controller.scene }
        if view.pointOfView !== controller.camera { view.pointOfView = controller.camera }
        view.accessibilityValue = controller.accessibilityPose
        view.rendersContinuously = controller.isActive && !controller.hasRendered
        view.setNeedsDisplay()
    }

    static func dismantleUIView(_ view: MeshRenderView, coordinator: Coordinator) {
        coordinator.controller.stopMoving()
        view.rendersContinuously = false
        view.delegate = nil
        view.viewportChanged = nil
        view.scene = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var controller: MeshPreviewController
        weak var view: MeshRenderView?
        init(controller: MeshPreviewController) { self.controller = controller }
        nonisolated func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            // The renderer and mutable scene stay on SceneKit's callback thread.
            // Only a no-argument completion reaches MainActor.
            Task { @MainActor [weak self] in
                guard let self, let view = self.view, view.window != nil,
                      view.bounds.width > 0, view.bounds.height > 0 else { return }
                view.rendersContinuously = false
                view.delegate = nil
                self.controller.markRendered()
            }
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
    private var reportedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0, size != reportedSize else { return }
        reportedSize = size
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bounds.size == size else { return }
            self.viewportChanged?(size)
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
