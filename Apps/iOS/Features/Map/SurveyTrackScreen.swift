import SwiftUI
import MapKit
import AtlasCore

@MainActor
struct SurveyTrackScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let cemetery: AtlasFeature?
    @ObservedObject var service: SurveyLocationService
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var category: FeatureCategory = .path
    @State private var label = ""
    @State private var issue: String?
    @State private var editor: MapFeatureEditorRequest?
    @State private var confirming = false
    @State private var manualSegment: CemeterySurveySegment?
    @State private var previewPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    explanation
                    statusCard
                    recordingControls
                    if !service.segments.isEmpty { preview }
                    reviewControls
                    ForEach(Array(service.segments.enumerated()), id: \.element.id) { index, segment in
                        segmentCard(segment, ordinal: index + 1)
                    }
                    Text(service.storageMessage).font(.footnote).foregroundStyle(Color.atlasMuted)
                        .accessibilityIdentifier("map.track.storage")
                    if let issue = issue ?? service.issue {
                        Text(issue).font(.subheadline).foregroundStyle(Color.orange)
                            .accessibilityIdentifier("map.track.issue")
                    }
                }.padding(20)
            }
            .background(Color.atlasCanvas)
            .navigationTitle("GPS-съёмка").navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { service.leaveScreen(); dismiss() }.accessibilityIdentifier("map.track.close")
                }
            }
            .task { await service.restoreDraft() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { service.leaveScreen() } }
            .onDisappear { service.leaveScreen() }
            .sheet(item: $editor) { request in
                FeatureEditScreen(model: model, project: project, feature: request.feature,
                    cemetery: cemetery, initialGeoTag: request.geoTag, isNew: true, onSaved: onSaved)
            }
            .confirmationDialog("Создать ручную границу из отрезка?", isPresented: Binding(
                get: { manualSegment != nil }, set: { if !$0 { manualSegment = nil } })) {
                    Button("Открыть ручную границу") {
                        if let segment = manualSegment { createManualBoundary(segment) }
                        manualSegment = nil
                    }
                    Button("Отмена", role: .cancel) { manualSegment = nil }
                } message: {
                    Text("Последняя точка соединится с первой прямой. Проверьте и исправьте вершины в карточке. Замыкание и точность GPS этим не подтверждаются; исходный журнал сохранится.")
                }
        }.preferredColorScheme(.dark)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            AtlasSectionLabel(title: cemetery?.label ?? "\(project.name) · WGS84")
            Text("Обойдите границу или пройдите вдоль дорожки")
                .font(.title3.weight(.semibold)).foregroundStyle(Color.atlasInk)
            Text("GPS телефона не заменяет геодезическую съёмку. Точки хуже ±10 м не входят в линию. Пауза, потеря сигнала и отклонённая точка создают отдельные отрезки.")
                .font(.subheadline).foregroundStyle(Color.atlasMuted)
            Text("Съёмка работает при открытом приложении. При сворачивании включается пауза; черновик можно продолжить вручную.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: service.isRecording ? "record.circle" : "location")
                    .foregroundStyle(service.isRecording ? Color.orange : Color.atlasBlue)
                Text(stateTitle).font(.headline).accessibilityIdentifier("map.track.state")
                Spacer()
                Text(duration).font(.headline.monospacedDigit()).accessibilityIdentifier("map.track.elapsed")
            }
            Text(service.statusMessage).font(.subheadline).foregroundStyle(Color.atlasMuted)
                .accessibilityIdentifier("map.track.accuracy")
            HStack {
                Text("Принято: \(service.acceptedCount)").foregroundStyle(Color.atlasBlue)
                Spacer()
                Text("Отклонено: \(service.rejectedCount)").foregroundStyle(Color.atlasMuted)
            }.font(.caption).accessibilityIdentifier("map.track.counts")
            if let rejection = service.lastRejection {
                Text("Последняя точка: \(rejection)").font(.caption).foregroundStyle(Color.orange)
            }
            if service.canOpenSettings {
                Button("Настройки геолокации") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.font(.subheadline)
            }
        }.padding(16).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var stateTitle: String {
        switch service.session?.state {
        case .recording: "Запись маршрута"
        case .paused: "Пауза"
        case .stopped: "Съёмка завершена"
        case nil: "Готово к съёмке"
        }
    }
    private var duration: String {
        let seconds = max(0, Int(service.elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var recordingControls: some View {
        HStack(spacing: 12) {
            if service.session == nil || service.session?.state == .stopped {
                Button {
                    issue = nil
                    Task { await service.start() }
                } label: { Label(service.session == nil ? "Начать" : "Новый трек", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent).foregroundStyle(Color.atlasAccentInk).disabled(!service.canStart)
                    .accessibilityIdentifier("map.track.start")
            } else if service.isRecording {
                Button("Пауза", systemImage: "pause.fill") { service.pause() }
                    .buttonStyle(.borderedProminent).foregroundStyle(Color.atlasAccentInk).accessibilityIdentifier("map.track.pause")
            } else {
                Button("Продолжить", systemImage: "play.fill") { service.resume() }
                    .buttonStyle(.borderedProminent).foregroundStyle(Color.atlasAccentInk).accessibilityIdentifier("map.track.resume")
            }
            if service.session != nil && service.session?.state != .stopped {
                Button("Завершить", systemImage: "stop.fill") { service.stop() }
                    .buttonStyle(.bordered).accessibilityIdentifier("map.track.stop")
            }
        }.disabled(service.confirmingBoundary)
    }

    private var preview: some View {
        Map(position: $previewPosition) {
            ForEach(service.segments) { segment in
                if segment.samples.count > 1 {
                    MapPolyline(coordinates: segment.samples.map { SurveyMapStyle.coordinate($0.coordinate) })
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, dash: [5, 4]))
                }
                if let first = segment.samples.first {
                    Annotation("Начало отрезка", coordinate: SurveyMapStyle.coordinate(first.coordinate)) {
                        Circle().fill(Color.atlasBlue).frame(width: 9, height: 9)
                    }.annotationTitles(.hidden)
                }
            }
        }
        .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Отрезки GPS-маршрута показаны отдельно")
    }

    private var reviewControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            AtlasSectionLabel(title: "Проверка и сохранение")
            TextField("Название линии или территории", text: $label).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("map.track.name")
            Picker("Тип линии", selection: $category) {
                Text("Дорожка").tag(FeatureCategory.path)
                Text("Дорога").tag(FeatureCategory.road)
                Text("Ограда").tag(FeatureCategory.fence)
            }.pickerStyle(.segmented).accessibilityIdentifier("map.track.category")
            Text("Завершите запись или включите паузу, затем проверьте каждый отрезок отдельно. Приложение не соединяет их через пропуски.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
            Text("Для GPS-контура вернитесь к началу: точность обеих крайних точек должна быть не хуже ±3 м, расстояние замыкания — в допустимом диапазоне до 5 м. Проверка может отклонить контур.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }
    }

    private func segmentCard(_ segment: CemeterySurveySegment, ordinal: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Отрезок \(ordinal)").font(.headline)
                Spacer()
                Text("\(segment.samples.count) точек").font(.caption).foregroundStyle(Color.atlasMuted)
            }
            Text(segmentReason(segment.startReason)).font(.caption).foregroundStyle(Color.atlasMuted)
            if let line = try? service.makeLine(segmentID: segment.id),
               let length = try? GeographicMetricGeometry.length(of: line) {
                Text("Длина ≈ \(length.formatted(.number.precision(.fractionLength(1)))) м")
                    .font(.subheadline).foregroundStyle(Color.atlasMuted)
            }
            Button("Проверить и сохранить линию", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                createLine(segment)
            }.disabled(service.isRecording || confirming || segment.samples.count < 2)
                .accessibilityIdentifier("map.track.line." + segment.id.uuidString)
            Button("Проверить GPS-замыкание", systemImage: "square.dashed") {
                Task { await createBoundary(segment) }
            }.disabled(service.isRecording || confirming || segment.samples.count < 4)
                .accessibilityIdentifier("map.track.boundary." + segment.id.uuidString)
            Button("Перейти к ручной границе", systemImage: "pencil.tip") { manualSegment = segment }
                .disabled(service.isRecording || confirming || segment.samples.count < 3)
                .font(.subheadline).accessibilityIdentifier("map.track.manualBoundary." + segment.id.uuidString)
        }.padding(16).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private func segmentReason(_ reason: CemeterySurveyBreak) -> String {
        switch reason {
        case .started: "Начало съёмки"
        case .resumed: "После паузы"
        case .timeGap: "После разрыва GPS-сигнала"
        case .rejectedObservation: "После отклонённой GPS-точки"
        }
    }

    private func attributes(_ segment: CemeterySurveySegment) -> [String: String] {
        var result = ["boundaryBasis": "walkedGPS", "accuracyBasis": "gpsPhone",
            "surveySegmentID": segment.id.uuidString, "survey.sampleCount": String(segment.samples.count),
            "survey.maximumHorizontalAccuracyMeters": String(segment.samples.map(\.horizontalAccuracyMeters).max() ?? 0)]
        if let session = service.session { result["surveySessionID"] = session.id.uuidString }
        if let cemetery { result["cemeteryID"] = cemetery.id.uuidString }
        if let first = segment.samples.first { result["survey.firstObservedAtUTC"] = first.capturedAt.ISO8601Format() }
        if let last = segment.samples.last { result["survey.lastObservedAtUTC"] = last.capturedAt.ISO8601Format() }
        return result
    }

    private func geoTag(_ segment: CemeterySurveySegment) -> GeoTag? {
        guard let sample = segment.samples.first else { return nil }
        return GeoTag(automaticFix: GeoLocationFix(coordinate: sample.coordinate, altitudeMeters: sample.altitudeMeters,
            horizontalAccuracyMeters: sample.horizontalAccuracyMeters, observedAt: sample.capturedAt,
            source: .deviceLocation, isSimulated: sample.isSimulated))
    }

    private func featureName(_ fallback: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func createLine(_ segment: CemeterySurveySegment) {
        do {
            let line = try service.makeLine(segmentID: segment.id)
            editor = MapFeatureEditorRequest(feature: AtlasFeature(projectID: project.id,
                label: featureName(category.title), category: category, geometry: .geographicPolyline(line),
                attributes: attributes(segment), reviewStatus: .needsReview), isNew: true, geoTag: geoTag(segment))
        } catch { issue = error.localizedDescription }
    }

    private func createBoundary(_ segment: CemeterySurveySegment) async {
        confirming = true
        defer { confirming = false }
        do {
            let boundary = try await service.confirmBoundary(segmentID: segment.id)
            var provenance = attributes(segment)
            provenance["survey.closureDistanceMeters"] = String(boundary.closureDistanceMeters)
            provenance["survey.closureToleranceMeters"] = String(boundary.closureToleranceMeters)
            provenance["survey.boundaryConfirmedAtUTC"] = boundary.confirmedAt.ISO8601Format()
            editor = MapFeatureEditorRequest(feature: AtlasFeature(projectID: project.id,
                label: featureName("Кладбище"), category: .cemetery, geometry: .geographicPolygon(boundary.polygon),
                attributes: provenance.filter { $0.key != "cemeteryID" }, reviewStatus: .needsReview),
                isNew: true, geoTag: geoTag(segment))
        } catch { issue = error.localizedDescription }
    }

    private func createManualBoundary(_ segment: CemeterySurveySegment) {
        do {
            var vertices = try service.makeLine(segmentID: segment.id).vertices
            if vertices.first == vertices.last { vertices.removeLast() }
            guard (3...2_048).contains(vertices.count) else { throw CemeterySurveyError.tooManyBoundaryVertices }
            var provenance = attributes(segment)
            provenance["boundaryBasis"] = "digitized"; provenance["survey.manualClosure"] = "true"
            provenance.removeValue(forKey: "cemeteryID")
            editor = MapFeatureEditorRequest(feature: AtlasFeature(projectID: project.id,
                label: featureName("Кладбище"), category: .cemetery,
                geometry: .geographicPolygon(GeographicPolygon(vertices: vertices)),
                attributes: provenance, reviewStatus: .needsReview), isNew: true, geoTag: geoTag(segment))
        } catch { issue = error.localizedDescription }
    }
}
