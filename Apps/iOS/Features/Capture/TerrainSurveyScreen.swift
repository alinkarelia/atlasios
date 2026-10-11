import SwiftUI
import MapKit
import AtlasCore

@MainActor
struct TerrainSurveyScreen: View {
    let project: AtlasProject
    let cemetery: AtlasFeature
    let directory: URL
    let onConfirmedFeature: (AtlasFeature) async throws -> Void
    let onSurveySaved: (() -> Void)?
    let onCaptureSaved: ((URL) -> Void)?
    private let analyzer = CemeteryTerrainAnalyzer()
    @State private var frames = [CemeteryTerrainAnalyzer.SourceFrame]()
    @State private var selectedFrame: UUID?
    @State private var survey: TerrainSurvey?
    @State private var busy = false
    @State private var showCapture = false
    @State private var showRegistration = false
    @State private var selectedCandidate: TerrainCandidate?
    @State private var error: String?
    @State private var savedURL: URL?
    @State private var selectedControl: MetricPoint2D?
    @State private var analysisTask: Task<Void,Never>?

    init(project: AtlasProject, cemetery: AtlasFeature, directory: URL, onConfirmedFeature: @escaping (AtlasFeature) async throws -> Void,
         onSurveySaved: (() -> Void)? = nil, onCaptureSaved: ((URL) -> Void)? = nil) {
        self.project = project; self.cemetery = cemetery; self.directory = directory
        self.onConfirmedFeature = onConfirmedFeature; self.onSurveySaved = onSurveySaved; self.onCaptureSaved = onCaptureSaved
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Label("Рельеф и точки для проверки", systemImage:"mountain.2").font(.title2.bold())
                Text("LiDAR показывает видимую землю и конструкции. Выступ или впадина — повод осмотреть место, а не доказательство захоронения.")
                    .font(.subheadline).foregroundStyle(Color.atlasMuted)
                Button { showCapture = true } label: { Label("Снять участок LiDAR",systemImage:"viewfinder") }
                    .buttonStyle(AtlasPrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("terrain.capture")
                if frames.isEmpty {
                    Text("Сначала медленно обойдите участок: покажите землю, соседние ровные поверхности и видимые детали. После сохранения здесь появится рельеф.")
                        .font(.subheadline).padding(18).background(Color.atlasCard,in:RoundedRectangle(cornerRadius:18))
                } else {
                    Picker("Фрагмент съёмки",selection:$selectedFrame) {
                        Text("Выберите фрагмент").tag(Optional<UUID>.none)
                        ForEach(frames) { frame in Text(frame.createdAt.formatted(date:.abbreviated,time:.shortened)+" · "+String(frame.frameID.uuidString.prefix(6))).tag(Optional(frame.frameID)) }
                    }.disabled(busy)
                    Button { analysisTask = Task { await analyzeSelected() } } label: {
                        if busy { Label("Анализируем поверхность…",systemImage:"hourglass") }
                        else { Label("Построить / обновить рельеф",systemImage:"square.stack.3d.up") }
                    }.buttonStyle(AtlasSecondaryButtonStyle()).disabled(busy).accessibilityIdentifier("terrain.analyze")
                }
                if let survey {
                    Text("\(survey.cells.count) измеренных ячеек · шаг \(survey.cellSize.formatted()) м")
                        .font(.caption).foregroundStyle(Color.atlasMuted).accessibilityIdentifier("terrain.coverage")
                    TerrainLocalPreview(survey:survey,selected:selectedControl) { selectedControl = $0 }
                        .frame(height:280).clipShape(RoundedRectangle(cornerRadius:20)).accessibilityIdentifier("terrain.local.preview")
                    HStack {
                        Text("Оранжевый — выше фона, синий — ниже. Пробелы не измерены.").font(.caption).foregroundStyle(Color.atlasMuted)
                        Spacer()
                    }
                    if let selectedControl, let cell = survey.cells.first(where: { $0.center(cellSize:survey.cellSize) == selectedControl }) {
                        Text("Выбрано X \(selectedControl.x.formatted()) · Z \(selectedControl.y.formatted()) м · высота \(cell.height.formatted(.number.precision(.fractionLength(2)))) м относительно нуля")
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                        Button("Считать выбранную поверхность нулём высоты") { Task { await setHeightReference(cell) } }
                            .font(.caption).foregroundStyle(Color.atlasAccent).disabled(busy)
                    }
                    Button { showRegistration = true } label: {
                        Label(survey.registration?.approvedAt == nil ? "Привязать рельеф к карте" : "Проверить контрольные точки",systemImage:"mappin.and.ellipse")
                    }.buttonStyle(AtlasSecondaryButtonStyle()).accessibilityIdentifier("terrain.registration")
                    if let registration = survey.registration, registration.approvedAt != nil {
                        TerrainGeographicPreview(survey:survey,cemetery:cemetery).frame(height:300)
                            .clipShape(RoundedRectangle(cornerRadius:20)).accessibilityIdentifier("terrain.geo.preview")
                        Text("Невязка контрольных точек: \(registration.rmsResidualMeters.formatted(.number.precision(.fractionLength(2)))) м. "+(registration.positionalUncertaintyMeters.map { "Оценка по точности контролей: ±\($0.formatted(.number.precision(.fractionLength(1)))) м." } ?? "Точность геопривязки неизвестна."))
                            .font(.caption).foregroundStyle(Color.atlasMuted)
                    } else {
                        Text("Пока это локальная схема в координатах данного фрагмента. Геометка телефона не совмещает её с картой.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Предложения для осмотра").font(.headline)
                    if survey.candidates.isEmpty { Text("Подходящих аномалий в измеренной поверхности нет. Это не подтверждает отсутствие захоронений.").font(.subheadline).foregroundStyle(Color.atlasMuted) }
                    ForEach(survey.candidates) { candidate in candidateRow(candidate) }
                    ForEach(survey.warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(Color.atlasMuted) }
                    if let savedURL { ShareLink(item:savedURL) { Label("Экспорт рельефа и протокола JSON",systemImage:"square.and.arrow.up") }.foregroundStyle(Color.atlasAccent) }
                }
            }.padding(20)
        }.background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
            .navigationTitle(cemetery.label).navigationBarTitleDisplayMode(.inline)
            .task { await reload() }
            .onDisappear { analysisTask?.cancel(); analysisTask = nil }
            .onChange(of:selectedFrame) { _, _ in Task { await loadSelected() } }
            .fullScreenCover(isPresented:$showCapture) {
                CaptureScreen(project:project,outputDirectory:directory,onSaved:{ manifest in
                    onCaptureSaved?(manifest); showCapture = false
                    analysisTask = Task { await analyzeSavedCapture(manifest) }
                },lidarOnly:true)
            }
            .sheet(isPresented:$showRegistration) {
                if let survey {
                    TerrainRegistrationSheet(survey:survey,selectedLocal:selectedControl) { registration in
                        Task { await acceptRegistration(registration) }
                    }
                }
            }
            .confirmationDialog("Как записать проверенную оператором точку?",isPresented:Binding(get:{selectedCandidate != nil},set:{ if !$0 { selectedCandidate = nil } }),titleVisibility:.visible,presenting:selectedCandidate) { candidate in
                if candidate.kind == .fenceLikeStructure { Button("Ограда / ограждение · проверить") { Task { await confirm(candidate,category:.fence) } } }
                else { Button("Возможное захоронение · личность неизвестна") { Task { await confirm(candidate,category:.grave) } } }
                Button("Другой объект / препятствие") { Task { await confirm(candidate,category:.other) } }
                Button("Отмена",role:.cancel) { selectedCandidate = nil }
            } message: { _ in Text("Вы подтверждаете точку для дальнейшей проверки. Форма поверхности не устанавливает, кто или что находится под землёй.") }
            .alert("Рельеф участка",isPresented:Binding(get:{error != nil},set:{ if !$0 { error = nil } })) {
                Button("Понятно",role:.cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func candidateRow(_ candidate: TerrainCandidate) -> some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(candidate.kind == .raisedSurface ? "Возвышение" : candidate.kind == .depression ? "Впадина" : candidate.kind == .fenceLikeStructure ? "Вертикальное ограждение?" : "Линейное препятствие").font(.headline)
                Spacer()
                Text(candidate.state == .proposed ? "Проверить" : candidate.state == .confirmed ? "Точка подтверждена" : "Отклонено")
                    .font(.caption).foregroundStyle(candidate.state == .rejected ? Color.atlasMuted : Color.atlasAccent)
            }
            Text(candidate.evidence).font(.caption).foregroundStyle(Color.atlasMuted)
            HStack {
                Button("Показать") { selectedControl = candidate.center }.font(.caption)
                Spacer()
                if candidate.state == .proposed {
                    Button("Отклонить") { Task { await review(candidate.id,state:.rejected) } }.font(.caption)
                    Button("Создать точку") { selectedCandidate = candidate }.font(.caption.bold())
                } else if candidate.state == .rejected {
                    Button("Вернуть на проверку") { Task { await review(candidate.id,state:.proposed) } }.font(.caption)
                } else if candidate.confirmedFeatureID == nil {
                    Button("Перенести на карту") { selectedCandidate = candidate }.font(.caption)
                }
            }.foregroundStyle(Color.atlasAccent).disabled(busy)
        }.padding(16).background(Color.atlasCard,in:RoundedRectangle(cornerRadius:18))
    }

    private func reload(selectNewest: Bool = false) async {
        do {
            frames = try await analyzer.availableFrames(directory:directory,projectID:project.id)
            if selectNewest || selectedFrame == nil { selectedFrame = frames.first?.frameID }
            await loadSelected()
        } catch { self.error = error.localizedDescription }
    }
    private func analyzeSavedCapture(_ manifest: URL) async {
        do {
            let savedFrames = try await analyzer.framesForSavedCapture(manifestURL:manifest,directory:directory,projectID:project.id)
            frames = try await analyzer.availableFrames(directory:directory,projectID:project.id)
            guard savedFrames.count == 1, let frame = savedFrames.first else {
                selectedFrame = nil; survey = nil; savedURL = nil
                error = "Съёмка содержит несколько независимых фрагментов. Выберите нужный фрагмент в списке; координаты автоматически не объединяются."
                return
            }
            selectedFrame = frame.frameID
            await loadSelected()
            await analyzeSelected()
        } catch { self.error = error.localizedDescription }
    }
    private func loadSelected() async {
        guard let selectedFrame else { survey = nil; return }
        do {
            let loaded = try await analyzer.load(cemeteryID:cemetery.id,frameID:selectedFrame,projectID:project.id,directory:directory)
            guard self.selectedFrame == selectedFrame else { return }
            survey = loaded; selectedControl = nil
            savedURL = loaded.map { directory.appendingPathComponent("TerrainSurveys/\($0.cemeteryID.uuidString)-\($0.frameID.uuidString).terrain.json") }
        } catch { self.error = error.localizedDescription }
    }
    private func analyzeSelected() async {
        guard !busy, let frame = frames.first(where: { $0.frameID == selectedFrame }) else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await analyzer.analyze(frame:frame,project:project,cemetery:cemetery,directory:directory,previous:survey)
            try await persist(result)
        } catch { self.error = error.localizedDescription }
    }
    private func persist(_ value: TerrainSurvey) async throws {
        let url = try await analyzer.save(value,directory:directory)
        survey = value; savedURL = url; onSurveySaved?()
    }
    private func setHeightReference(_ cell: TerrainCell) async {
        guard var current = survey, !busy else { return }
        busy = true; defer { busy = false }
        current.referenceHeight += cell.height
        for index in current.cells.indices { current.cells[index].height -= cell.height }
        current.updatedAt = Date()
        do { try await persist(current) } catch { self.error = error.localizedDescription }
    }
    private func review(_ id: UUID, state: TerrainCandidateState) async {
        guard !busy,var current = survey, let index = current.candidates.firstIndex(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        current.candidates[index].state = state; current.candidates[index].reviewedAt = state == .proposed ? nil : Date(); current.updatedAt = Date()
        do { try await persist(current) } catch { self.error = error.localizedDescription }
    }
    private func acceptRegistration(_ registration: TerrainRegistration) async {
        guard !busy,var current = survey, registration.frameID == current.frameID else { return }
        busy = true
        var approved = registration; approved.approvedAt = Date(); current.registration = approved; current.updatedAt = Date()
        do {
            try await persist(current); showRegistration = false; busy = false
            for candidate in current.candidates where candidate.state == .confirmed && candidate.confirmedFeatureID == nil {
                await confirm(candidate,category:candidate.confirmedCategory ?? .other)
            }
        } catch { busy = false; self.error = error.localizedDescription }
    }
    private func confirm(_ candidate: TerrainCandidate, category: FeatureCategory) async {
        selectedCandidate = nil
        guard var current = survey, let index = current.candidates.firstIndex(where: { $0.id == candidate.id }), !busy else { return }
        busy = true; defer { busy = false }
        var geometry: FeatureGeometry?
        var pendingFeature: AtlasFeature?
        do {
            if project.coordinateReference == .wgs84, let registration = current.registration, registration.approvedAt != nil {
                let geographic = try registration.coordinate(for:candidate.center,frameID:current.frameID)
                if case .geographicPolygon(let boundary) = cemetery.geometry, !terrainContains(geographic,in:boundary) {
                    self.error = "Точка находится вне границы выбранного кладбища. Проверьте привязку или границу."; return
                }
                if let line = candidate.lineVertices,line.count >= 2 {
                    let coordinates = try line.map { try registration.coordinate(for:$0,frameID:current.frameID) }
                    if case .geographicPolygon(let boundary) = cemetery.geometry, !coordinates.allSatisfy({ terrainContains($0,in:boundary) }) {
                        self.error = "Часть предложенной линии находится вне выбранного кладбища. Проверьте привязку и видимые концы ограждения."; return
                    }
                    geometry = .geographicPolyline(GeographicPolyline(vertices:coordinates))
                } else { geometry = .geographicPoint(geographic) }
            } else if project.coordinateReference == .localMeters(frameID:current.frameID) {
                if let line = candidate.lineVertices,line.count >= 2 { geometry = .metricPolyline(MetricPolyline(frameID:current.frameID,vertices:line)) }
                else { geometry = .metricPoint(frameID:current.frameID,point:candidate.center) }
            }
            if let geometry {
                // A retry after a sidecar-write failure must address the same
                // map record, rather than silently duplicating a candidate.
                let featureID = candidate.confirmedFeatureID ?? candidate.id
                var attributes = ["cemeteryID":cemetery.id.uuidString,"terrainCandidateID":candidate.id.uuidString,"surveyID":current.id.uuidString,
                    "sourceFrameID":current.frameID.uuidString,"survey.sourceCandidateID":candidate.id.uuidString,"survey.status":"confirmed","grave.identityStatus":"unknown","grave.evidenceType":"surfaceAnomaly",
                    "positionalUncertaintyMeters":current.registration?.positionalUncertaintyMeters.map { String($0) } ?? "unknown"]
                if category != .grave { attributes.removeValue(forKey:"grave.identityStatus"); attributes.removeValue(forKey:"grave.evidenceType") }
                let feature = AtlasFeature(id:featureID,projectID:project.id,label:category == .grave ? "Возможное захоронение · проверить" : category == .fence ? "Ограждение · проверить" : "Объект рельефа · проверить",category:category,geometry:geometry,attributes:attributes,
                    notes:candidate.evidence+"\nОператор подтвердил точку осмотра; наличие захоронения и личность не установлены.",reviewStatus:.needsReview)
                pendingFeature = feature
            }
            if let pendingFeature {
                try await onConfirmedFeature(pendingFeature)
                current.candidates[index].confirmedFeatureID = pendingFeature.id
            }
            current.candidates[index].state = .confirmed; current.candidates[index].reviewedAt = Date(); current.updatedAt = Date()
            current.candidates[index].confirmedCategory = category
            try await persist(current)
            if geometry == nil { self.error = "Точка подтверждена в локальном протоколе. Для переноса на карту сначала привяжите этот фрагмент по контрольным точкам." }
        } catch { self.error = error.localizedDescription }
    }
}

private struct TerrainLocalPreview: View {
    let survey: TerrainSurvey
    let selected: MetricPoint2D?
    let onSelect: (MetricPoint2D) -> Void
    private var observedCoordinates:[MetricPoint2D] {
        var points = survey.cells.map { $0.center(cellSize:survey.cellSize) }
        for candidate in survey.candidates where candidate.state != .rejected {
            points.append(candidate.center); points.append(contentsOf:candidate.lineVertices ?? candidate.boundary)
        }
        return points.isEmpty ? [.init(x:0,y:0)] : points
    }
    var body: some View {
        GeometryReader { geometry in
            let observed = observedCoordinates
            let minX = (observed.map(\.x).min() ?? 0)-survey.cellSize/2
            let minZ = (observed.map(\.y).min() ?? 0)-survey.cellSize/2
            let extentX = (observed.map(\.x).max() ?? 0)-minX+survey.cellSize/2
            let extentZ = (observed.map(\.y).max() ?? 0)-minZ+survey.cellSize/2
            let scale = min(geometry.size.width/max(1,extentX),geometry.size.height/max(1,extentZ))
            Canvas { context,_ in
                for cell in survey.cells {
                    let rect = CGRect(x:(Double(cell.column)*survey.cellSize-minX)*scale,y:(Double(cell.row)*survey.cellSize-minZ)*scale,width:survey.cellSize*scale,height:survey.cellSize*scale)
                    context.fill(Path(rect),with:.color(terrainColor(cell.residual)))
                }
                for candidate in survey.candidates where candidate.state != .rejected {
                    var path = Path(); path.addLines((candidate.lineVertices ?? candidate.boundary).map { CGPoint(x:($0.x-minX)*scale,y:($0.y-minZ)*scale) }); if candidate.lineVertices == nil { path.closeSubpath() }
                    context.stroke(path,with:.color(.white),style:StrokeStyle(lineWidth:2,dash:[5,4]))
                }
                if let selected {
                    let center = CGPoint(x:(selected.x-minX)*scale,y:(selected.y-minZ)*scale)
                    context.stroke(Path(ellipseIn:CGRect(x:center.x-6,y:center.y-6,width:12,height:12)),with:.color(.white),lineWidth:3)
                }
            }.background(Color.atlasCard)
                .onTapGesture(coordinateSpace:.local) { point in
                    let local = MetricPoint2D(x:minX+point.x/scale,y:minZ+point.y/scale)
                    let column = Int(floor(local.x/survey.cellSize)), row = Int(floor(local.y/survey.cellSize))
                    if let cell = survey.cells.first(where:{ $0.column == column && $0.row == row }) { onSelect(cell.center(cellSize:survey.cellSize)) }
                }
        }
    }
}

private struct TerrainGeographicPreview: View {
    let survey: TerrainSurvey
    let cemetery: AtlasFeature
    private var sampled: [TerrainCell] {
        let step = max(1,Int(ceil(Double(survey.cells.count)/1_200)))
        return survey.cells.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }
    private var visibleCandidates:[TerrainCandidate] { Array(survey.candidates.filter { $0.state != .rejected }.prefix(200)) }
    var body: some View {
        VStack(spacing:4) {
            Map {
                if case .geographicPolygon(let polygon) = cemetery.geometry {
                    MapPolygon(coordinates:polygon.vertices.map { .init(latitude:$0.latitude,longitude:$0.longitude) }).stroke(.white,lineWidth:2)
                }
                ForEach(sampled) { cell in
                    if let coordinates = coordinates(cell) { MapPolygon(coordinates:coordinates).foregroundStyle(terrainColor(cell.residual).opacity(0.75)) }
                }
                ForEach(visibleCandidates) { candidate in
                    if let registration = survey.registration, let point = try? registration.coordinate(for:candidate.center,frameID:survey.frameID),insideCemetery(point) {
                        Annotation("Проверить",coordinate:.init(latitude:point.latitude,longitude:point.longitude)) { Image(systemName:"questionmark.circle.fill").foregroundStyle(.orange).font(.title3) }
                        if let line = candidate.lineVertices {
                            let coordinates = line.compactMap { try? registration.coordinate(for:$0,frameID:survey.frameID) }
                            if coordinates.count == line.count,coordinates.allSatisfy(insideCemetery) { MapPolyline(coordinates:coordinates.map { .init(latitude:$0.latitude,longitude:$0.longitude) }).stroke(.orange,lineWidth:3) }
                        }
                    }
                }
            }.mapStyle(.imagery)
            if sampled.count < survey.cells.count { Text("Карта: \(sampled.count) из \(survey.cells.count) измеренных ячеек; полный рельеф сохранён в протоколе.").font(.system(size:10)).foregroundStyle(Color.atlasMuted) }
            if survey.candidates.filter({$0.state != .rejected}).count > visibleCandidates.count { Text("Карта показывает первые \(visibleCandidates.count) предложений. Все решения доступны в списке и протоколе.").font(.system(size:10)).foregroundStyle(Color.atlasMuted) }
        }
    }
    private func insideCemetery(_ coordinate:GeographicCoordinate) -> Bool {
        if case .geographicPolygon(let polygon) = cemetery.geometry { return terrainContains(coordinate,in:polygon) }
        return true
    }
    private func coordinates(_ cell: TerrainCell) -> [CLLocationCoordinate2D]? {
        guard let registration = survey.registration, registration.approvedAt != nil else { return nil }
        let center = cell.center(cellSize:survey.cellSize)
        guard let location = try? registration.coordinate(for:center,frameID:survey.frameID) else { return nil }
        if case .geographicPolygon(let polygon) = cemetery.geometry, !terrainContains(location,in:polygon) { return nil }
        let x = Double(cell.column)*survey.cellSize,z = Double(cell.row)*survey.cellSize,size = survey.cellSize
        let corners = [(x,z),(x+size,z),(x+size,z+size),(x,z+size)].compactMap { px,pz -> GeographicCoordinate? in
            guard let point = try? registration.coordinate(for:.init(x:px,y:pz),frameID:survey.frameID) else { return nil }
            return point
        }
        guard corners.count == 4 else { return nil }
        if case .geographicPolygon(let polygon) = cemetery.geometry, !corners.allSatisfy({ terrainContains($0,in:polygon) }) { return nil }
        return corners.map { CLLocationCoordinate2D(latitude:$0.latitude,longitude:$0.longitude) }
    }
}

@MainActor
private struct TerrainRegistrationSheet: View {
    let survey: TerrainSurvey
    let selectedLocal: MetricPoint2D?
    let onAccept: (TerrainRegistration) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var controls = [TerrainControlPoint]()
    @State private var x = ""
    @State private var z = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var accuracy = ""
    @State private var preview: TerrainRegistration?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Выберите узнаваемые контрольные места в локальной схеме и укажите их известные координаты. Нужны минимум две точки дальше 3 м друг от друга; третья точка в стороне проверяет привязку.")
                        .font(.caption)
                    Text("GPS телефона при съёмке не используется как контрольная точка.").font(.caption).foregroundStyle(.orange)
                }
                Section("Новая пара координат") {
                    TextField("Локальный X, м",text:$x).keyboardType(.numbersAndPunctuation)
                    TextField("Локальный Z, м",text:$z).keyboardType(.numbersAndPunctuation)
                    TextField("Широта",text:$latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Долгота",text:$longitude).keyboardType(.numbersAndPunctuation)
                    TextField("Точность известных координат, м (если известна)",text:$accuracy).keyboardType(.decimalPad)
                    Button("Добавить контрольную пару") { addControl() }
                }
                Section("Контрольные точки: \(controls.count)") {
                    ForEach(controls) { point in
                        HStack {
                            Text("X \(point.local.x.formatted()) · Z \(point.local.y.formatted())").font(.caption)
                            Spacer()
                            Button("Удалить") { controls.removeAll { $0.id == point.id }; preview = nil }.font(.caption)
                        }
                    }
                    Button("Рассчитать привязку") {
                        do { preview = try TerrainRegistration.fit(frameID:survey.frameID,controls:controls); failure = nil }
                        catch { failure = error.localizedDescription }
                    }.disabled(controls.count < 2)
                }
                if let preview {
                    Section("Проверка перед применением") {
                        LabeledContent("Средняя невязка",value:preview.rmsResidualMeters.formatted(.number.precision(.fractionLength(2)))+" м")
                        ForEach(preview.warnings,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        Button("Принять привязку и показать на карте") { onAccept(preview) }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.orange) }
            }.navigationTitle("Привязка по контролям")
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Закрыть") { dismiss() } } }
                .onAppear {
                    controls = survey.registration?.controls ?? []
                    if let selectedLocal { x = String(selectedLocal.x); z = String(selectedLocal.y) }
                }
        }.preferredColorScheme(.dark).tint(Color.atlasAccent)
    }
    private func addControl() {
        func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of:",",with:".")) }
        guard let px = number(x), let pz = number(z), let lat = number(latitude), let lon = number(longitude),
              px.isFinite,pz.isFinite,lat.isFinite,lon.isFinite,abs(lat)<85,abs(lon)<=180,
              accuracy.isEmpty || (number(accuracy).map { $0.isFinite && $0 > 0 } ?? false) else { failure = "Проверьте числовые координаты и точность."; return }
        controls.append(.init(frameID:survey.frameID,local:.init(x:px,y:pz),geographic:.init(longitude:lon,latitude:lat),accuracyMeters:number(accuracy)))
        preview = nil; failure = nil; latitude = ""; longitude = ""
    }
}

private func terrainColor(_ residual: Double) -> Color {
    if residual >= 0.12 { return .orange }
    if residual <= -0.12 { return .blue }
    return Color.atlasAccent.opacity(0.6)
}

private func terrainContains(_ point: GeographicCoordinate, in polygon: GeographicPolygon) -> Bool {
    func contains(_ ring:[GeographicCoordinate]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        for index in ring.indices {
            let a = ring[index],b = ring[(index+1)%ring.count]
            if (a.latitude>point.latitude) != (b.latitude>point.latitude),
               point.longitude < (b.longitude-a.longitude)*(point.latitude-a.latitude)/(b.latitude-a.latitude)+a.longitude { inside.toggle() }
        }
        return inside
    }
    return contains(polygon.vertices) && !polygon.holes.contains(where:contains)
}
