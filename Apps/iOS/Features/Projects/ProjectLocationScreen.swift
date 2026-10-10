import SwiftUI
import MapKit
import AtlasCore

private enum GeoTagTarget: Identifiable {
    case scan(ScanRecord), photo(PhotoEvidence)
    var id: String {
        switch self { case .scan(let scan): "scan-\(scan.id)"; case .photo(let photo): "photo-\(photo.id)" }
    }
}

@MainActor
struct ProjectLocationScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    @StateObject private var evidence = EvidenceService()
    @State private var scans: [ScanRecord] = []
    @State private var editing: GeoTagTarget?
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var loading = true
    @State private var issue: String?

    var body: some View {
        List {
            Section {
                Map {
                    ForEach(scans) { scan in
                        if let fix = scan.geoTag?.effectiveFix {
                            Annotation(scanTitle(scan), coordinate: mapCoordinate(fix)) {
                                Button { editing = .scan(scan) } label: {
                                    Image(systemName: "viewfinder").padding(9).foregroundStyle(Color.atlasAccentInk)
                                        .background(Color.atlasAccent, in: Circle())
                                }.buttonStyle(.plain).accessibilityLabel("Исправить геометку съёмки")
                            }
                        }
                    }
                    ForEach(evidence.photos) { photo in
                        if let fix = photo.geoTag?.effectiveFix {
                            Annotation("Фото", coordinate: mapCoordinate(fix)) {
                                Button { editing = .photo(photo) } label: {
                                    Image(systemName: "photo").padding(9).foregroundStyle(Color.atlasAccentInk)
                                        .background(Color.orange, in: Circle())
                                }.buttonStyle(.plain).accessibilityLabel("Исправить геометку фото")
                            }
                        }
                    }
                }.mapControls { MapCompass(); MapScaleView() }.frame(height: 270)
                    .listRowInsets(EdgeInsets())
                Text("Точки показывают положение съёмок и фото. Геометрия скана сохраняет свою локальную систему координат.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }.listRowBackground(Color.atlasCard)
            Section("Съёмки") {
                if scans.isEmpty { Text("Сохраните съёмку, чтобы увидеть её геометку.").foregroundStyle(Color.atlasMuted) }
                ForEach(scans) { scan in
                    Button { editing = .scan(scan) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(scanTitle(scan)).font(.headline).foregroundStyle(Color.atlasInk)
                            Text(scan.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.atlasMuted)
                            Text(locationLabel(scan.geoTag)).font(.subheadline).foregroundStyle(Color.atlasBlue)
                        }
                    }
                }
            }.listRowBackground(Color.atlasCard)
            Section("Фотофиксация") {
                if evidence.photos.isEmpty { Text("Фото появятся после съёмки или импорта.").foregroundStyle(Color.atlasMuted) }
                ForEach(evidence.photos) { photo in
                    Button { editing = .photo(photo) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(photo.relativePath.components(separatedBy: "/").last ?? "Фото").font(.headline).foregroundStyle(Color.atlasInk)
                            Text(locationLabel(photo.geoTag)).font(.subheadline).foregroundStyle(Color.atlasBlue)
                            if photo.geoTimestampBasis == .importedAtUnknownCaptureTime {
                                Text("Время исходной съёмки неизвестно").font(.caption).foregroundStyle(Color.atlasMuted)
                            }
                        }
                    }
                }
            }.listRowBackground(Color.atlasCard)
            Section {
                Button {
                    Task { await exportLocations() }
                } label: {
                    if exporting { HStack { ProgressView(); Text("Выгружаем метки…") } }
                    else { Label("Геометки съёмок и фото · GeoJSON", systemImage: "square.and.arrow.up") }
                }.disabled(exporting || loading)
                if let exportURL { ShareLink(item: exportURL) { Label("Сохранить файл", systemImage: "square.and.arrow.up") } }
            } header: { Text("Экспорт") } footer: {
                Text("Экспортируются точки WGS84 с источником, точностью и историей. Исходные координаты не заменяются ручной поправкой.")
            }.listRowBackground(Color.atlasCard)
        }
        .scrollContentBackground(.hidden).background(Color.atlasCanvas)
        .foregroundStyle(Color.atlasInk)
        .navigationTitle("Геометки").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.atlasCanvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $editing) { target in
            switch target {
            case .scan(let scan):
                GeoTagEditorScreen(title: "Геометка съёмки", tag: scan.geoTag) { correction in
                    _ = try await model.correctGeoTag(of: scan, with: correction)
                    await reload()
                }
            case .photo(let photo):
                GeoTagEditorScreen(title: "Геометка фото", tag: photo.geoTag,
                    automaticTimeLabel: photo.geoTimestampBasis == .importedAtUnknownCaptureTime ? "Время исходного положения неизвестно; сохранено время импорта." : nil) { correction in
                    _ = try await evidence.updateGeoTag(photoID: photo.id, correction: correction,
                        expectedGeoTag: photo.geoTag, outputDirectory: model.captureDirectory(for: project))
                    await reload()
                }
            }
        }
        .alert("Геометки", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("Понятно", role: .cancel) { issue = nil }
        } message: { Text(issue ?? "") }
    }

    private func reload() async {
        guard !exporting else { return }
        loading = true
        defer { loading = false }
        scans = await model.scans(in: project)
        await evidence.loadEvidence(projectID: project.id, outputDirectory: model.captureDirectory(for: project))
        if let error = evidence.errorMessage { issue = error }
    }
    private func mapCoordinate(_ fix: GeoLocationFix) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
    }
    private func scanTitle(_ scan: ScanRecord) -> String {
        (scan.source == .roomPlan ? "Обмер RoomPlan" : "LiDAR-фрагмент") + " · " + scan.id.uuidString.prefix(6)
    }
    private func locationLabel(_ tag: GeoTag?) -> String {
        guard let fix = tag?.effectiveFix else { return "Добавить положение вручную" }
        let source = fix.isSimulated ? "Тестовое положение" : (fix.source == .operatorEntered ? "Ручная поправка" : (fix.source == .photoEXIF ? "Из фото" : "Автоматически"))
        return source + (fix.horizontalAccuracyMeters.map { " · ±\($0.formatted(.number.precision(.fractionLength(1)))) м" } ?? " · точность неизвестна")
    }
    private func exportLocations() async {
        guard !exporting, !loading else { return }
        exporting = true
        defer { exporting = false }
        guard let snapshot = await model.snapshot(of: project) else { return }
        do {
            let artifact = try AtlasExporter.exportGeotags(snapshot)
            var collection = try JSONSerialization.jsonObject(with: artifact.data) as? [String: Any] ?? [:]
            var points = collection["features"] as? [[String: Any]] ?? []
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            for photo in evidence.photos {
                guard let tag = photo.geoTag, let fix = tag.effectiveFix else { continue }
                try GeoTagPolicy.validate(tag)
                var properties: [String: Any] = ["projectID": project.id.uuidString, "kind": "photo", "sourceFile": photo.relativePath,
                    "geoTag": try JSONSerialization.jsonObject(with: encoder.encode(tag))]
                if let basis = photo.geoTimestampBasis { properties["timestampBasis"] = basis.rawValue }
                if let capturedAt = photo.capturedAt { properties["capturedAt"] = capturedAt.timeIntervalSince1970 * 1000 }
                points.append(["type": "Feature", "id": "photo-" + photo.id.uuidString,
                    "geometry": ["type": "Point", "coordinates": [fix.coordinate.longitude, fix.coordinate.latitude]],
                    "properties": properties])
            }
            collection["features"] = points
            let directory = model.directory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(artifact.fileName)
            try JSONSerialization.data(withJSONObject: collection, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            exportURL = destination
        } catch { issue = error.localizedDescription }
    }
}
