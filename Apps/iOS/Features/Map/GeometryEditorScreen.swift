import SwiftUI
import MapKit
import AtlasCore

@MainActor
struct GeometryEditorScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var location: SurveyLocationService
    @StateObject private var search = MapSearchService()
    @State private var features: [AtlasFeature] = []
    @State private var visibleFeatures: [AtlasFeature] = []
    @State private var geographicIndex = SurveyGeographicIndex()
    @State private var geographicPlan = SurveyMapRenderPlan()
    @State private var positionedGeographicMap = false
    @State private var editor: MapFeatureEditorRequest?
    @State private var position: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var showSearch = false
    @State private var showLayers = false
    @State private var showTrack = false
    @State private var showGeographicProject = false
    @State private var geographicName = ""
    @State private var createdProject: AtlasProject?
    @State private var creatingProject = false
    @State private var selectedCemeteryID: UUID?
    @State private var layers = Set(FeatureCategory.allCases)
    @State private var showUnassigned = true
    @State private var showInactive = false
    @State private var draftKind: MapDraftKind?
    @State private var draftCategory: FeatureCategory = .grave
    @State private var metricDraft: [MetricPoint2D] = []
    @State private var geographicDraft: [GeographicCoordinate] = []
    @State private var newLabel = ""
    @State private var zoom = 1.0
    @State private var localIssue: String?

    init(model: AtlasAppModel, project: AtlasProject, cemeteryID: UUID? = nil) {
        self.model = model; self.project = project
        _selectedCemeteryID = State(initialValue: cemeteryID)
        _location = StateObject(wrappedValue: SurveyLocationService.shared(projectID: project.id,
            draftDirectory: model.captureDirectory(for: project).appendingPathComponent("SurveyDrafts", isDirectory: true)))
    }

    private var isGeographic: Bool { project.coordinateReference == .wgs84 }
    private var selectedCemetery: AtlasFeature? { features.first { $0.id == selectedCemeteryID && $0.category == .cemetery } }
    private var cemeteries: [AtlasFeature] { features.filter { $0.category == .cemetery } }
    private func updateVisibleFeatures() {
        visibleFeatures = features.filter { feature in
            guard showInactive || SurveyFeatureLifecycle.isActive(feature) else { return false }
            guard layers.contains(feature.category) else { return false }
            guard let selectedCemeteryID, feature.category != .cemetery else { return true }
            let parent = SurveyMapStyle.cemeteryID(feature)
            return parent == selectedCemeteryID || (parent == nil && showUnassigned)
        }
        geographicIndex = SurveyGeographicIndex(features: visibleFeatures)
        if isGeographic, !positionedGeographicMap, let viewport = geographicIndex.fittedViewport {
            positionedGeographicMap = true
            let region = MKCoordinateRegion(center: SurveyMapStyle.coordinate(viewport.center),
                span: MKCoordinateSpan(latitudeDelta: viewport.latitudeSpan, longitudeDelta: viewport.longitudeSpan))
            visibleRegion = region
            position = .region(region)
        }
        updateGeographicPlan()
    }
    private func updateGeographicPlan() {
        let viewport = visibleRegion.map {
            SurveyGeographicViewport(center: GeographicCoordinate(longitude: $0.center.longitude, latitude: $0.center.latitude),
                latitudeSpan: $0.span.latitudeDelta, longitudeSpan: $0.span.longitudeDelta)
        }
        geographicPlan = geographicIndex.plan(in: viewport)
    }
    private var draftCount: Int { metricDraft.count + geographicDraft.count }

    var body: some View {
        VStack(spacing: 0) {
            mapArea
            controls
        }
        .background(Color.atlasCanvas)
        .navigationTitle(project.name).navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .task {
            await refresh()
            if isGeographic { await location.restoreDraft() }
        }
        .onChange(of: location.fix) { _, fix in
            guard location.recenterRequested, let fix else { return }
            recenter(fix.coordinate, span: max(0.002, (fix.horizontalAccuracyMeters ?? 10) / 20_000))
            location.didRecenter()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { location.leaveScreen(); search.cancel() }
        }
        .onChange(of: selectedCemeteryID) { _, _ in updateVisibleFeatures() }
        .onChange(of: layers) { _, _ in updateVisibleFeatures() }
        .onChange(of: showUnassigned) { _, _ in updateVisibleFeatures() }
        .onChange(of: showInactive) { _, _ in updateVisibleFeatures() }
        .onDisappear { location.leaveScreen(); search.cancel() }
        .sheet(item: $editor) { request in
            FeatureEditScreen(model: model, project: project, feature: request.feature,
                cemetery: selectedCemetery, initialGeoTag: request.geoTag, isNew: request.isNew) {
                    resetDraft()
                    Task { await refresh() }
                }
                // A new opening owns a new draft. Keep this presentation's
                // identity stable while typing, rather than reusing card State.
                .id(request.id)
        }
        .sheet(isPresented: $showSearch, onDismiss: { search.cancel() }) {
            MapPlaceSearchScreen(search: search, region: visibleRegion) { place in
                recenter(place.coordinate, span: 0.006)
                showSearch = false
            }
        }
        .sheet(isPresented: $showLayers) { layerSheet }
        .sheet(isPresented: $showTrack) {
            SurveyTrackScreen(model: model, project: project, cemetery: selectedCemetery, service: location) {
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $showGeographicProject) { geographicProjectSheet }
        .navigationDestination(item: $createdProject) { project in
            GeometryEditorScreen(model: model, project: project)
        }
    }

    private var mapArea: some View {
        ZStack(alignment: .topLeading) {
            if isGeographic {
                SurveyMapSurface(position: $position, features: geographicPlan.features, prominentIDs: geographicPlan.prominentIDs, draft: geographicDraft,
                    location: location, isDrawing: draftKind != nil,
                    onTap: appendGeographic, onSelect: openExisting, onRegion: {
                        visibleRegion = $0; updateGeographicPlan()
                    })
            } else {
                MetricPlotCanvas(features: visibleFeatures, draft: metricDraft, zoom: zoom) { point, tolerance, rendered in
                    if draftKind != nil {
                        metricDraft.append(point)
                        if draftKind == .point { reviewDraft() }
                    } else if let feature = rendered.reversed().first(where: {
                        SurveyMapStyle.metricHit(point, feature: $0, tolerance: tolerance)
                    }) { openExisting(feature) }
                }
            }
            HStack(alignment: .top) {
                Text(draftKind?.instruction ?? (isGeographic ? "WGS84 · карта местности" : "Локальный план · метры"))
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.atlasInk)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.atlasCanvas.opacity(0.92), in: Capsule())
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    mapButton("Моё положение", symbol: "location.north.fill", id: "map.locate") {
                        if isGeographic { location.locate() } else { offerGeographicProject() }
                    }
                    mapButton("Найти населённый пункт или адрес", symbol: "magnifyingglass", id: "map.search") {
                        if isGeographic { showSearch = true } else { offerGeographicProject() }
                    }
                    mapButton("Слои и кладбище", symbol: "square.3.layers.3d", id: "map.layers") { showLayers = true }
                }
            }.padding(12)
            if isGeographic, geographicPlan.isLimited {
                VStack {
                    Spacer()
                    Text("В окне \(geographicPlan.matchingCount) объектов · показано \(geographicPlan.features.count). Приблизьте карту; все карточки доступны ниже.")
                        .font(.caption).foregroundStyle(Color.orange).padding(10)
                        .background(Color.atlasCanvas.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("map.renderLimit")
                }.padding(12).allowsHitTesting(false)
            }
        }
        .frame(minHeight: 220, maxHeight: .infinity)
    }

    private func mapButton(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44).foregroundStyle(Color.atlasInk)
                .background(Color.atlasCanvas.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let draftKind { draftControls(draftKind) }
            else {
                HStack(spacing: 12) {
                    Button { begin(.point, category: .grave) } label: { Label("Могила", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).foregroundStyle(Color.atlasAccentInk).accessibilityIdentifier("map.addgrave")
                    Menu {
                        Button("Граница кладбища", systemImage: "square.dashed") { begin(.polygon, category: .cemetery) }
                        Button("Участок могилы", systemImage: "rectangle") { begin(.polygon, category: .grave) }
                        Button("Вход", systemImage: "door.left.hand.open") { begin(.point, category: .entrance) }
                        Button("Урна", systemImage: "trash") { begin(.point, category: .wasteBin) }
                        Button("Дерево", systemImage: "tree") { begin(.point, category: .tree) }
                        Button("Кустарник", systemImage: "leaf") { begin(.point, category: .shrub) }
                        Button("Свалка — точка", systemImage: "exclamationmark.triangle") { begin(.point, category: .wasteDump) }
                        Button("Граница свалки", systemImage: "square.dashed") { begin(.polygon, category: .wasteDump) }
                        Button("Дорога", systemImage: "road.lanes") { begin(.polyline, category: .road) }
                        Button("Дорожка", systemImage: "figure.walk") { begin(.polyline, category: .path) }
                        Button("Ограда", systemImage: "line.3.horizontal") { begin(.polyline, category: .fence) }
                        Button("Координаты вручную", systemImage: "number") {
                            editor = MapFeatureEditorRequest(feature: nil, isNew: true)
                        }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Добавить другой объект").accessibilityIdentifier("map.add")
                    Spacer(minLength: 0)
                    Button {
                        if isGeographic { showTrack = true } else { offerGeographicProject() }
                    } label: { Label("GPS-трек", systemImage: "figure.walk") }
                    .buttonStyle(.bordered).accessibilityIdentifier("map.track")
                }
                HStack {
                    Button { showLayers = true } label: {
                        Text(selectedCemetery?.label ?? "Все кладбища").font(.subheadline.weight(.semibold))
                    }.accessibilityIdentifier("map.cemeteryContext")
                    Spacer()
                    Text("Объектов: \(visibleFeatures.count)").font(.caption).foregroundStyle(Color.atlasMuted)
                }
                if !visibleFeatures.isEmpty { featureStrip }
            }
            if let issue = localIssue ?? location.issue {
                Text(issue).font(.caption).foregroundStyle(Color.orange).accessibilityIdentifier("map.issue")
            }
            if isGeographic {
                if location.hasLocationActivity || location.fix != nil || location.session != nil || location.issue != nil {
                    HStack(alignment: .top) {
                        Text(location.statusMessage).font(.caption).foregroundStyle(Color.atlasMuted)
                            .accessibilityIdentifier("map.locationStatus")
                        Spacer(minLength: 8)
                        if location.canOpenSettings {
                            Button("Настройки") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }.font(.caption)
                        }
                    }
                } else {
                    Text("Границы проверяет специалист. GPS телефона — ориентир, точность указана в метрах.")
                        .font(.caption).foregroundStyle(Color.atlasMuted)
                }
            } else {
                HStack {
                    Text("GPS требует карты WGS84").font(.caption).foregroundStyle(Color.atlasMuted)
                    Spacer()
                    Slider(value: $zoom, in: 1...4).frame(maxWidth: 140)
                        .accessibilityLabel("Масштаб локального плана")
                }
            }
        }
        .padding(16).background(Color.atlasCanvas)
    }

    private func draftControls(_ kind: MapDraftKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(draftCategory.title + " · точек: \(draftCount)").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Убрать последнюю точку", systemImage: "arrow.uturn.backward") {
                    if !metricDraft.isEmpty { metricDraft.removeLast() }
                    if !geographicDraft.isEmpty { geographicDraft.removeLast() }
                }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(draftCount == 0)
            }
            TextField("Номер или название", text: $newLabel).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("map.draft.name")
            HStack {
                Button("Отмена") { resetDraft() }
                Spacer()
                Button("Проверить геометрию") { reviewDraft() }.buttonStyle(.borderedProminent).foregroundStyle(Color.atlasAccentInk)
                    .disabled(draftCount < kind.minimum).accessibilityIdentifier("map.draft.review")
            }
        }
    }

    private var featureStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(visibleFeatures) { feature in
                    Button { openExisting(feature) } label: {
                        Label(feature.label, systemImage: SurveyMapStyle.symbol(feature.category))
                            .font(.caption.weight(.semibold)).lineLimit(1).padding(10)
                            .background(SurveyMapStyle.color(feature.category).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityIdentifier("map.card." + feature.id.uuidString)
                }
            }
        }.scrollIndicators(.hidden).accessibilityIdentifier("map.featureStrip")
    }

    private var layerSheet: some View {
        NavigationStack {
            Form {
                Section("Кладбище") {
                    Picker("Рабочая территория", selection: $selectedCemeteryID) {
                        Text("Все кладбища").tag(Optional<UUID>.none)
                        ForEach(cemeteries) { Text($0.label).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("map.cemetery")
                    Toggle("Показывать объекты без привязки", isOn: $showUnassigned)
                    Toggle("Отклонённые и удалённые записи", isOn: $showInactive)
                        .accessibilityIdentifier("map.showInactive")
                    Text("Новые карточки получают выбранное кладбище. Старые объекты без привязки остаются доступными.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
                Section("Слои") {
                    ForEach(FeatureCategory.allCases, id: \.self) { category in
                        Toggle(isOn: Binding(get: { layers.contains(category) }, set: { enabled in
                            if enabled { layers.insert(category) } else { layers.remove(category) }
                        })) {
                            Label(category.title, systemImage: SurveyMapStyle.symbol(category))
                                .foregroundStyle(SurveyMapStyle.color(category))
                        }.accessibilityIdentifier("map.layer." + category.rawValue)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas)
            .navigationTitle("Слои карты").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showLayers = false } } }
        }.preferredColorScheme(.dark)
    }

    private var geographicProjectSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Этот проект хранит координаты в локальных метрах. GPS и адресный поиск работают на отдельной карте WGS84.")
                    Text("Создайте географический проект для кладбища или маршрута. Геометрия текущего плана сохранится в своей системе координат.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                    TextField("Название карты", text: $geographicName)
                } header: { Text("Карта местности") }
                Button {
                    Task {
                        creatingProject = true
                        let result = await model.createProject(name: geographicName, kind: project.kind, geographic: true)
                        creatingProject = false
                        if let result { showGeographicProject = false; createdProject = result }
                    }
                } label: {
                    if creatingProject { ProgressView() } else { Text("Создать карту WGS84") }
                }.disabled(creatingProject || geographicName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("map.createGeographicProject")
            }
            .scrollContentBackground(.hidden).background(Color.atlasCanvas)
            .navigationTitle("GPS на карте").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showGeographicProject = false } } }
        }.preferredColorScheme(.dark)
    }

    private func offerGeographicProject() {
        geographicName = project.name + " · карта"
        showGeographicProject = true
    }
    private func begin(_ kind: MapDraftKind, category: FeatureCategory) {
        resetDraft(); draftKind = kind; draftCategory = category
    }
    private func resetDraft() {
        draftKind = nil; metricDraft = []; geographicDraft = []; newLabel = ""; localIssue = nil
    }
    private func appendGeographic(_ point: GeographicCoordinate) {
        geographicDraft.append(point)
        if draftKind == .point { reviewDraft() }
    }
    private func openExisting(_ feature: AtlasFeature) {
        // Lazy map/card views may retain an older button capture. Resolve the
        // selected identity against the current saved snapshot before editing.
        guard let current = features.first(where: { $0.id == feature.id }) else {
            localIssue = "Карточка больше не доступна. Обновите данные проекта."
            return
        }
        editor = MapFeatureEditorRequest(feature: current, isNew: false)
    }
    private func recenter(_ point: GeographicCoordinate, span: Double) {
        position = .region(MKCoordinateRegion(center: SurveyMapStyle.coordinate(point),
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }
    private func refresh() async {
        features = await model.features(in: project)
        updateVisibleFeatures()
    }
    private func reviewDraft() {
        guard let kind = draftKind, draftCount >= kind.minimum else { return }
        let geometry: FeatureGeometry
        switch project.coordinateReference {
        case let .localMeters(frame):
            switch kind {
            case .point: geometry = .metricPoint(frameID: frame, point: metricDraft[0])
            case .polyline: geometry = .metricPolyline(MetricPolyline(frameID: frame, vertices: metricDraft))
            case .polygon: geometry = .metricPolygon(MetricPolygon(frameID: frame, vertices: metricDraft))
            }
        case .wgs84:
            switch kind {
            case .point: geometry = .geographicPoint(geographicDraft[0])
            case .polyline: geometry = .geographicPolyline(GeographicPolyline(vertices: geographicDraft))
            case .polygon: geometry = .geographicPolygon(GeographicPolygon(vertices: geographicDraft))
            }
        }
        do { try PolygonGeometry.validate(geometry, in: project.coordinateReference) }
        catch { localIssue = error.localizedDescription; return }
        var attributes = ["boundaryBasis": "digitized", "accuracyBasis": "unknown"]
        if let selectedCemeteryID, draftCategory != .cemetery { attributes["cemeteryID"] = selectedCemeteryID.uuidString }
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        editor = MapFeatureEditorRequest(feature: AtlasFeature(projectID: project.id,
            label: label.isEmpty ? draftCategory.title : label, category: draftCategory,
            geometry: geometry, attributes: attributes), isNew: true)
    }
}
