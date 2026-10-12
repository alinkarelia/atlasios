import Foundation
import SwiftUI
import MapKit
import UIKit
import AtlasCore

@MainActor
struct StationSurveyScreen: View {
    @ObservedObject var model: AtlasAppModel
    let project: AtlasProject
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var service: StationSurveyLocationService
    @State private var manual: StationManualRequest?
    @State private var history: SurveyStation?
    @State private var outline: StationSurveyOutline?
    @State private var closed = true
    @State private var issue: String?
    @State private var exporting = false
    @State private var share: StationExportRequest?
    private var directory: URL { model.captureDirectory(for: project).appendingPathComponent("StationSurvey", isDirectory: true) }

    init(model: AtlasAppModel, project: AtlasProject, onSaved: @escaping () -> Void = {}) {
        self.model = model; self.project = project; self.onSaved = onSaved
        _service = StateObject(wrappedValue: StationSurveyLocationService.shared(project: project,
            directory: model.captureDirectory(for: project).appendingPathComponent("StationSurvey", isDirectory: true)))
    }
    private var geographic: Bool { project.coordinateReference == .wgs84 }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    introduction
                    if !service.ready { ProgressView("Открываем журнал станций") }
                    ForEach(service.document.stations) { station in stationRow(station) }
                    if !service.document.stations.isEmpty {
                        Picker("Соединение станций", selection: $closed) {
                            Text("Граница").tag(true); Text("Линия").tag(false)
                        }.pickerStyle(.segmented).accessibilityIdentifier("stations.outline.kind")
                        Text(closed ? "Последняя станция соединится с первой прямой. Проверьте границу перед записью." : "Станции соединятся по номерам. Линия остаётся открытой.")
                            .font(.footnote).foregroundStyle(Color.atlasMuted)
                        Button("Проверить соединение", systemImage: "point.3.connected.trianglepath.dotted") {
                            do { outline = try StationSurveyGeometry.outline(service.document, closed: closed) }
                            catch { issue = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).foregroundStyle(Color.atlasAccentInk)
                            .disabled(service.isCollecting || service.saving || service.starting || exporting).accessibilityIdentifier("stations.preview")
                        Button("Записать точки на карте", systemImage: "mappin.and.ellipse") {
                            Task { await savePoints() }
                        }.buttonStyle(.bordered).disabled(service.isCollecting || exporting || service.saving || service.starting)
                            .accessibilityIdentifier("stations.savePoints")
                        HStack {
                            Button("Исходные точки JSON") { export(geographic: false) }.accessibilityIdentifier("stations.exportJSON")
                            Spacer()
                            Button("GeoJSON") { export(geographic: true) }.disabled(!geographic).accessibilityIdentifier("stations.exportGeoJSON")
                        }.font(.subheadline).disabled(service.isCollecting || exporting || service.saving || service.starting)
                    }
                    Text(service.storageMessage).font(.footnote).foregroundStyle(Color.atlasMuted)
                        .accessibilityIdentifier("stations.storage")
                    if service.issue != nil {
                        Button(service.ready ? "Повторить запись журнала" : "Повторить открытие журнала") {
                            Task { if service.ready { _ = await service.persist() } else { await service.restore() } }
                        }.disabled(service.saving)
                    }
                    if let message = issue ?? service.issue { Text(message).foregroundStyle(.orange).font(.subheadline).accessibilityIdentifier("stations.issue") }
                }.padding(20)
            }.background(Color.atlasCanvas).foregroundStyle(Color.atlasInk)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        if service.isCollecting { acquisition }
                        captureActions
                    }.padding(16).background(Color.atlasCanvas)
                }
                .navigationTitle("Съёмка по точкам").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { service.leave(); dismiss() }.accessibilityIdentifier("stations.close") } }
                .task { await service.restore() }
                .onChange(of: phase) { _, value in if value == .background { service.leave() } }
                .onDisappear { service.leave(); model.fieldMaterialsDidChange(projectID: project.id) }
                .sheet(item: $manual) { request in
                    StationManualEditor(station: service.document.stations.first { $0.id == request.stationID },
                        reference: project.coordinateReference) { position, reason in
                        await service.enter(stationID: request.stationID, position: position, reason: reason)
                    }.id(request.id)
                }
                .sheet(item: $history) { station in StationHistoryScreen(station: station) }
                .sheet(isPresented: Binding(get: { outline != nil }, set: { if !$0 { outline = nil } })) {
                    if let outline { preview(outline) }
                }
                .sheet(item: $share) { request in StationShareSheet(url: request.url) }
        }.preferredColorScheme(.dark)
    }
    private var captureActions: some View {
        HStack {
            Button("Точка GPS · 10 с", systemImage: "location") {
                Task { if let id = await service.addStation() { await service.start(stationID: id) } }
            }.disabled(!geographic || !service.ready || service.isCollecting || service.saving || service.starting || exporting)
                .accessibilityIdentifier("stations.addGPS")
            Spacer()
            Button("Ввести точку", systemImage: "number") {
                Task { if let id = await service.addStation() { manual = StationManualRequest(stationID: id) } }
            }.disabled(!service.ready || service.isCollecting || service.saving || service.starting || exporting)
                .accessibilityIdentifier("stations.addManual")
        }.buttonStyle(.bordered)
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.name).font(.caption).foregroundStyle(Color.atlasMuted)
            Text("Остановитесь у каждого угла участка").font(.title3.bold())
            Text("Станции A001, A002… сохраняются по порядку. Не двигайтесь 10 секунд во время GPS-наблюдения. Для контрольного измерения можно повторить станцию: предыдущие исходные данные сохранятся.")
                .font(.subheadline)
            Text(geographic ? "WGS84 · GPS телефона даёт приблизительное положение. Разброс фиксов не доказывает абсолютную точность; усреднение не уменьшает заявленную погрешность." : "Локальные метры · координатная система проекта. GPS сюда не переносится; введите X/Y по вашим обмерам.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }
    }
    private var acquisition: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Наблюдение · \(service.elapsed.formatted(.number.precision(.fractionLength(0)))) / 10 с").font(.headline)
            ProgressView(value: min(10, service.elapsed), total: 10)
            if let attempt = service.activeAttempt {
                Text("Принято свежих уникальных: \(attempt.acceptedObservations.count) / минимум 3 · исходных: \(attempt.observations.count)")
                    .accessibilityIdentifier("stations.sampleCount")
                quality(attempt)
                if let latest = attempt.observations.last, latest.rejection != nil {
                    Text("Последний фикс: \(rejectionTitle(latest.rejection)) · GPS сообщает ±\(latest.sample.horizontalAccuracyMeters.formatted(.number.precision(.fractionLength(1)))) м")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Нужны 3 свежих разных фикса за 10 секунд. Принимается заявленная погрешность до 25 м; устаревшие, повторные и имитированные фиксы остаются в журнале.")
                .font(.caption).foregroundStyle(Color.atlasMuted)
            Button("Отменить наблюдение", role: .destructive) { Task { await service.finish(cancelled: true) } }
                .buttonStyle(.bordered).accessibilityIdentifier("stations.cancelGPS")
        }.padding(14).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
    private func stationRow(_ station: SurveyStation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(station.label).font(.headline).accessibilityIdentifier("stations.label." + station.label); Spacer(); if !station.included { Text("Не соединяется").font(.caption) } }
            if let position = station.position { Text(SurveyGeometrySummary.text(position)).font(.caption) }
            else { Text("Координаты ещё не приняты").font(.subheadline).foregroundStyle(.orange) }
            if let current = station.current { quality(current) }
            else if let attempt = station.attempts.last { Text(stateTitle(attempt.state)).font(.caption).foregroundStyle(.orange) }
            if station.current != nil, let latest = station.attempts.last, latest.state != .accepted {
                Text("Повторное наблюдение: \(stateTitle(latest.state)). Прежние координаты сохранены.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Повторить GPS") { Task { await service.start(stationID: station.id) } }.disabled(!geographic)
                    .accessibilityIdentifier("stations.repeat." + station.label)
                Button("Исправить координаты") { manual = StationManualRequest(stationID: station.id) }
                    .accessibilityIdentifier("stations.edit." + station.label)
            }.buttonStyle(.bordered).disabled(service.isCollecting || service.saving || service.starting || exporting || !service.ready)
            HStack {
                Button("История · \(station.attempts.count)") { history = station }.accessibilityIdentifier("stations.history." + station.label)
                Spacer()
                Button(station.included ? "Не соединять" : "Соединять") { Task { await service.include(stationID: station.id, value: !station.included) } }
                    .disabled(service.isCollecting || service.saving || service.starting || exporting)
                    .accessibilityIdentifier("stations.include." + station.label)
            }.buttonStyle(.borderless).font(.caption)
        }.padding(14).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }
    private func quality(_ attempt: StationSurveyAttempt) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if attempt.source == .manual { Text("Ручной ввод · точность не указана").font(.caption) }
            else {
                Text(attempt.reportedAccuracyMeters.map { "GPS сообщает ±\($0.formatted(.number.precision(.fractionLength(1)))) м" } ?? "Точность GPS пока не определена").font(.caption)
                Text(attempt.spreadMeters.map { "Разброс относительно выбранного фикса: \($0.formatted(.number.precision(.fractionLength(1)))) м" } ?? "Разброс пока не определён").font(.caption)
                if let spread = attempt.spreadMeters, spread > 10 { Text("Большой разброс. Повторите наблюдение на неподвижной точке.").font(.caption).foregroundStyle(.orange) }
            }
        }.foregroundStyle(Color.atlasMuted)
    }
    private func preview(_ outline: StationSurveyOutline) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if geographic {
                        Map(initialPosition: .automatic) {
                            ForEach(service.document.stations.filter(\.included)) { station in
                                if case let .geographicPoint(point) = station.position { Marker(station.label, coordinate: SurveyMapStyle.coordinate(point)) }
                            }
                            if case let .geographicPolygon(polygon) = outline.geometry {
                                MapPolygon(SurveyMapStyle.polygon(polygon)).foregroundStyle(Color.atlasBlue.opacity(0.15)).stroke(Color.atlasBlue, lineWidth: 2)
                            } else if case let .geographicPolyline(line) = outline.geometry {
                                MapPolyline(coordinates: line.vertices.map(SurveyMapStyle.coordinate)).stroke(Color.atlasBlue, lineWidth: 3)
                            }
                        }.frame(height: 240)
                    } else {
                        MetricPlotCanvas(features: [AtlasFeature(projectID: project.id, label: "Соединение станций", category: .boundary, geometry: outline.geometry)],
                            draft: [], zoom: 1) { _, _, _ in }.frame(height: 240)
                    }
                    if let area = outline.areaSquareMeters {
                        Text("Площадь ≈ \(area.formatted(.number.precision(.fractionLength(1)))) м²").font(.headline)
                            .accessibilityIdentifier("stations.area")
                    }
                    Text("\(outline.areaSquareMeters == nil ? "Длина" : "Периметр") ≈ \(outline.perimeterMeters.formatted(.number.precision(.fractionLength(1)))) м")
                        .accessibilityIdentifier("stations.perimeter")
                    ForEach(Array(outline.segments.enumerated()), id: \.offset) { _, segment in
                        VStack(alignment: .leading) {
                            Text("\(segment.from) → \(segment.to) · \(segment.distanceMeters.formatted(.number.precision(.fractionLength(2)))) м")
                            if let bearing = segment.trueBearingDegrees { Text("Направление от истинного севера ≈ \(bearing.formatted(.number.precision(.fractionLength(1))))°").font(.caption).foregroundStyle(Color.atlasMuted) }
                        }
                    }
                    Text("Расчёты зависят от координат станций. GPS телефона не превращает эту границу в геодезический обмер.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                    Button("Записать соединение", systemImage: "checkmark") { Task { await saveOutline(outline) } }
                        .buttonStyle(.borderedProminent).foregroundStyle(Color.atlasAccentInk).disabled(exporting)
                        .accessibilityIdentifier("stations.saveOutline")
                    if let issue { Text(issue).foregroundStyle(.orange) }
                }.padding(20)
            }.background(Color.atlasCanvas).navigationTitle("Проверка участка").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { self.outline = nil } } }
        }
    }
    private func savePoints() async {
        exporting = true; defer { exporting = false }
        do {
            guard !service.isCollecting, !service.starting else { throw StationSurveyError.collecting }
            guard await service.persist() else { throw SurveyCardError.message(service.issue ?? "Исходный журнал не сохранён.") }
            try await materializePoints(service.document)
            issue = nil; onSaved()
        } catch { issue = error.localizedDescription }
    }
    private func materializePoints(_ snapshot: StationSurvey) async throws {
            guard snapshot.stations.contains(where: { $0.position != nil }) else { throw StationSurveyError.missingPosition }
            let existing = await model.features(in: project)
            for station in snapshot.stations {
                guard let position = station.position else { continue }
                var feature = existing.first { $0.id == station.id } ?? AtlasFeature(id: station.id, projectID: project.id, label: station.label, category: .other, geometry: position)
                if feature.revision > 0, feature.attributes["survey.stationSurveyID"] != snapshot.id.uuidString { throw StationSurveyError.historyChanged }
                if !SurveyFeatureLifecycle.isActive(feature) { throw SurveyCardError.message("Станция \(station.label) скрыта в реестре. Восстановите её карточку перед записью точек.") }
                if feature.geometry != position || feature.attributes["survey.stationAttemptID"] != station.current?.id.uuidString { feature.reviewStatus = .needsReview }
                feature.geometry = position
                feature.attributes["survey.stationSurveyID"] = snapshot.id.uuidString
                feature.attributes["survey.stationNumber"] = station.label
                feature.attributes["survey.includedInConnection"] = String(station.included)
                feature.attributes["survey.sourceDocument"] = "StationSurvey/\(project.id).station-survey.json"
                feature.attributes["survey.stationSource"] = station.current?.source.rawValue
                feature.attributes["survey.stationAttemptID"] = station.current?.id.uuidString
                feature.attributes["survey.sourceRevision"] = String(snapshot.revision)
                feature.attributes["survey.observedAt"] = (station.current?.chosenObservation?.sample.capturedAt ?? station.current?.startedAt)?.ISO8601Format()
                feature.attributes["accuracyBasis"] = station.current?.source == .phoneGPS ? "gpsPhone" : "operatorCoordinates"
                if let accuracy = station.current?.reportedAccuracyMeters, station.current?.source == .phoneGPS { feature.attributes["survey.reportedAccuracyMeters"] = String(accuracy) }
                else { feature.attributes.removeValue(forKey: "survey.reportedAccuracyMeters") }
                feature.attributes["survey.freshFixCount"] = station.current.map { String($0.acceptedObservations.count) }
                feature.attributes["survey.rawObservationCount"] = station.current.map { String($0.observations.count) }
                feature.attributes["survey.observedSpreadMeters"] = station.current?.spreadMeters.map { String($0) }
                guard await model.saveFeature(feature) != nil else { throw SurveyCardError.message(model.issue ?? "Не удалось записать точку на карте.") }
            }
    }
    private func saveOutline(_ outline: StationSurveyOutline) async {
        exporting = true; defer { exporting = false }
        do {
        guard !service.isCollecting, !service.starting else { throw StationSurveyError.collecting }
        guard await service.persist() else { throw SurveyCardError.message(service.issue ?? "Исходный журнал не сохранён.") }
        let snapshot = service.document
        let current = try StationSurveyGeometry.outline(snapshot, closed: outline.areaSquareMeters != nil)
        guard current.geometry == outline.geometry else { throw SurveyCardError.message("Станции изменились. Закройте проверку и проверьте соединение заново.") }
        try await materializePoints(snapshot)
        var attributes = ["survey.stationSurveyID": snapshot.id.uuidString,
            "survey.sourceRevision": String(snapshot.revision),
            "survey.sourceDocument": "StationSurvey/\(project.id).station-survey.json", "boundaryBasis": "stationCoordinates",
            "accuracyBasis": geographic ? "gpsOrManualWGS84" : "operatorLocalMeters"]
        let ids = snapshot.stations.filter(\.included).map { $0.id.uuidString }
        let attemptIDs = snapshot.stations.filter(\.included).compactMap { $0.current?.id.uuidString }
        for start in stride(from: 0, to: ids.count, by: 40) {
            attributes["survey.stationOrder.\(start / 40)"] = ids[start..<min(start + 40, ids.count)].joined(separator: ",")
            attributes["survey.stationAttempts.\(start / 40)"] = attemptIDs[start..<min(start + 40, attemptIDs.count)].joined(separator: ",")
        }
        let feature = AtlasFeature(projectID: project.id, label: outline.areaSquareMeters == nil ? "Линия по станциям" : "Участок по станциям",
            category: outline.areaSquareMeters == nil ? .path : .boundary, geometry: outline.geometry, attributes: attributes, reviewStatus: .needsReview)
        if await model.saveFeature(feature) != nil { self.outline = nil; onSaved() }
        else { throw SurveyCardError.message(model.issue ?? "Соединение не записано. Исходные станции сохранены.") }
        } catch { issue = error.localizedDescription }
    }
    private func export(geographic: Bool) {
        do {
            let artifact = try (geographic ? StationSurveyExporter.geoJSON(service.document) : StationSurveyExporter.json(service.document))
            let folder = directory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(artifact.fileName)
            try artifact.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            share = StationExportRequest(url: url)
        } catch { issue = error.localizedDescription }
    }
}

private struct StationManualRequest: Identifiable { let id = UUID(); let stationID: UUID }
private struct StationExportRequest: Identifiable { let id = UUID(); let url: URL }
private struct StationShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
private func stateTitle(_ state: StationAttemptState) -> String {
    switch state { case .collecting: "Наблюдение"; case .accepted: "Принято"; case .insufficient: "Недостаточно свежих фиксов"; case .cancelled: "Отменено, исходные фиксы сохранены" }
}
private func rejectionTitle(_ value: String?) -> String {
    switch value {
    case nil: "Принят"
    case "duplicateFix": "Повторное время или ID фикса"
    case "beforeStart": "Получен до начала наблюдения"
    case "future": "Время фикса в будущем"
    case "stale": "Фикс старше 3 секунд"
    case "outsideWindow": "Получен после 10 секунд наблюдения"
    case "simulated": "Имитированная геолокация"
    case "invalidCoordinate": "Некорректные координаты"
    case "invalidAccuracy": "Некорректная оценка точности"
    case "poorAccuracy": "Погрешность больше 25 м"
    case "outOfOrder": "Время раньше предыдущего принятого фикса"
    case "invalidTime": "Некорректное время"
    default: "Фикс не принят"
    }
}

@MainActor
private struct StationManualEditor: View {
    let station: SurveyStation?
    let reference: CoordinateReference
    let save: (FeatureGeometry, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var reason = "Ручной ввод координат"
    @State private var busy = false
    @State private var issue: String?
    private var geographic: Bool { reference == .wgs84 }
    var body: some View {
        NavigationStack {
            Form {
                Text(station?.label ?? "Станция").font(.headline)
                Text(geographic ? "WGS84 · ручные координаты. Точность не известна." : "Локальные метры · GPS не применяется.")
                    .font(.footnote)
                TextField(geographic ? "Долгота, °" : "X, м", text: $first).keyboardType(.numbersAndPunctuation)
                    .accessibilityIdentifier("stations.manual.first")
                TextField(geographic ? "Широта, °" : "Y, м", text: $second).keyboardType(.numbersAndPunctuation)
                    .accessibilityIdentifier("stations.manual.second")
                TextField("Основание ввода или исправления", text: $reason, axis: .vertical)
                    .accessibilityIdentifier("stations.manual.reason")
                Text("Исправление добавляет новую запись. Предыдущие координаты и исходные GPS-фиксы остаются в истории.").font(.footnote)
                if let issue { Text(issue).foregroundStyle(.orange) }
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Координаты станции").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") { Task { await commit() } }.disabled(busy || first.isEmpty || second.isEmpty || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("stations.manual.save")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer(); Button("Готово") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                            .accessibilityIdentifier("stations.manual.keyboardDone")
                    }
                }
                .task {
                    if case let .geographicPoint(point) = station?.position { first = String(point.longitude); second = String(point.latitude) }
                    if case let .metricPoint(_, point) = station?.position { first = String(point.x); second = String(point.y) }
                }
        }
    }
    private func commit() async {
        guard let x = Double(first.replacingOccurrences(of: ",", with: ".")), let y = Double(second.replacingOccurrences(of: ",", with: ".")) else {
            issue = "Введите два числовых значения."; return
        }
        let geometry: FeatureGeometry
        switch reference { case .wgs84: geometry = .geographicPoint(.init(longitude: x, latitude: y))
        case let .localMeters(frame): geometry = .metricPoint(frameID: frame, point: .init(x: x, y: y)) }
        do { try PolygonGeometry.validate(geometry, in: reference) }
        catch { issue = error.localizedDescription; return }
        busy = true; defer { busy = false }
        if await save(geometry, reason) { dismiss() } else { issue = "Координаты не записаны. Проверьте сообщение хранилища." }
    }
}

@MainActor
private struct StationHistoryScreen: View {
    let station: SurveyStation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(station.attempts.reversed()) { attempt in
                    DisclosureGroup("\(attempt.source == .phoneGPS ? "GPS" : "Ручной ввод") · \(stateTitle(attempt.state))") {
                        Text(attempt.startedAt.ISO8601Format()).font(.caption)
                        if let position = attempt.position { Text(SurveyGeometrySummary.text(position)) }
                        if !attempt.reason.isEmpty { Text(attempt.reason) }
                        Text("Исходных: \(attempt.observations.count) · принято: \(attempt.acceptedObservations.count)")
                        ForEach(Array(attempt.observations.enumerated()), id: \.offset) { _, raw in
                            Text("\(raw.sample.capturedAt.ISO8601Format()) · \(raw.sample.coordinate.latitude), \(raw.sample.coordinate.longitude) · GPS ±\(raw.sample.horizontalAccuracyMeters) м · \(rejectionTitle(raw.rejection))").font(.caption)
                        }
                    }
                }
            }.navigationTitle(station.label + " · история").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}
