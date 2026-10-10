import SwiftUI
import MapKit
import AtlasCore

@MainActor
struct GeoTagEditorScreen: View {
    let title: String
    let tag: GeoTag?
    let automaticTimeLabel: String?
    let onSave: @MainActor (GeoTagCorrection) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var latitude: String
    @State private var longitude: String
    @State private var altitude: String
    @State private var accuracy: String
    @State private var note = ""
    @State private var position: MapCameraPosition
    @State private var saving = false
    @State private var issue: String?

    init(title: String, tag: GeoTag?, automaticTimeLabel: String? = nil,
         onSave: @escaping @MainActor (GeoTagCorrection) async throws -> Void) {
        self.title = title; self.tag = tag; self.automaticTimeLabel = automaticTimeLabel; self.onSave = onSave
        let fix = tag?.effectiveFix
        _latitude = State(initialValue: fix.map { String($0.coordinate.latitude) } ?? "")
        _longitude = State(initialValue: fix.map { String($0.coordinate.longitude) } ?? "")
        _altitude = State(initialValue: fix?.altitudeMeters.map { String($0) } ?? "")
        // A new manual position starts with unknown accuracy. GPS uncertainty
        // belongs to the original observation, not to a moved marker.
        _accuracy = State(initialValue: "")
        if let fix {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002))))
        } else { _position = State(initialValue: .automatic) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if saving { Section { ProgressView("Сохраняем исправление…") } }
                Section {
                    MapReader { proxy in
                        Map(position: $position) {
                            if let coordinate = draftCoordinate {
                                Marker("Ручная метка", coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                                    .tint(Color.atlasBlue)
                            }
                        }
                        .mapControls { MapCompass(); MapScaleView() }
                        .onTapGesture(coordinateSpace: .local) { point in
                            guard let coordinate = proxy.convert(point, from: .local) else { return }
                            latitude = String(coordinate.latitude); longitude = String(coordinate.longitude)
                            // A tap cannot determine altitude or positional accuracy.
                            altitude = ""; accuracy = ""
                        }
                    }.frame(height: 230)
                    Text("Нажмите нужную точку на карте или введите координаты. Изменения сохраняются кнопкой сверху.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
                Section("Ручное положение · WGS84") {
                    field("Широта, °", value: $latitude)
                    field("Долгота, °", value: $longitude)
                    field("Высота над уровнем моря, м", value: $altitude)
                    field("Оценка точности, м · если известна", value: $accuracy)
                    if let coordinate = draftCoordinate {
                        Button("Показать введённую точку") {
                            position = .region(MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)))
                        }
                    }
                    TextField("Основание изменения: карта, контрольная точка…", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("Исходное измерение") {
                    GeoTagSummaryView(tag: GeoTag(automaticFix: tag?.automaticFix), automaticTimeLabel: automaticTimeLabel)
                    Text("Исходное измерение сохраняется. Ручная точка не переносит автоматически всю 3D-модель и границы участков на карту.")
                        .font(.footnote).foregroundStyle(Color.atlasMuted)
                }
                if let tag, !tag.corrections.isEmpty {
                    Section("История исправлений") {
                        ForEach(tag.corrections.reversed()) { correction in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(correction.coordinate == nil ? "Возврат к оригиналу" : "Ручное исправление").font(.subheadline.weight(.semibold))
                                Text(correction.changedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.atlasMuted)
                                if !correction.note.isEmpty { Text(correction.note).font(.caption) }
                            }
                        }
                        if tag.corrections.last?.coordinate != nil {
                            Button("Вернуться к исходной геометке") {
                                Task { await save(GeoTagCorrection(coordinate: nil, note: "Возврат к исходной геометке")) }
                            }.disabled(saving)
                        }
                    }
                }
            }.disabled(saving)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await saveDraft() } }.disabled(saving || draftCoordinate == nil)
                }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: latitude) { _, _ in altitude = ""; accuracy = "" }
            .onChange(of: longitude) { _, _ in altitude = ""; accuracy = "" }
            .alert("Проверьте геометку", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("Понятно", role: .cancel) { issue = nil }
            } message: { Text(issue ?? "") }
        }
    }

    private func field(_ label: String, value: Binding<String>) -> some View {
        TextField(label, text: value).keyboardType(.numbersAndPunctuation).accessibilityLabel(label)
    }
    private var draftCoordinate: GeographicCoordinate? {
        guard let lat = number(latitude), let lon = number(longitude), lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return GeographicCoordinate(longitude: lon, latitude: lat)
    }
    private func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
    private func optionalNumber(_ text: String, error: GeoTagError) throws -> Double? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let value = number(text), value.isFinite else { throw error }
        return value
    }
    private func saveDraft() async {
        guard let coordinate = draftCoordinate else { issue = GeoTagError.invalidCoordinate.localizedDescription; return }
        do {
            let correction = GeoTagCorrection(coordinate: coordinate, altitudeMeters: try optionalNumber(altitude, error: .invalidAltitude),
                estimatedAccuracyMeters: try optionalNumber(accuracy, error: .invalidAccuracy), note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            await save(correction)
        } catch { issue = error.localizedDescription }
    }
    private func save(_ correction: GeoTagCorrection) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            var next = tag ?? GeoTag(); next.corrections.append(correction)
            try GeoTagPolicy.validate(next)
            try await onSave(correction)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

struct GeoTagSummaryView: View {
    let tag: GeoTag?
    var automaticTimeLabel: String? = nil
    var body: some View {
        if let fix = tag?.effectiveFix {
            LabeledContent("Координаты", value: "\(fix.coordinate.latitude.formatted(.number.precision(.fractionLength(7)))), \(fix.coordinate.longitude.formatted(.number.precision(.fractionLength(7))))")
            LabeledContent("Источник", value: sourceTitle(fix))
            LabeledContent(fix.source == .operatorEntered ? "Оценка точности" : "Точность положения",
                value: fix.horizontalAccuracyMeters.map { "±\($0.formatted(.number.precision(.fractionLength(1)))) м" } ?? "Неизвестна")
            if let altitude = fix.altitudeMeters { LabeledContent("Высота", value: altitude.formatted(.number.precision(.fractionLength(1))) + " м") }
            if fix.source != .operatorEntered, let automaticTimeLabel { Text(automaticTimeLabel).font(.caption).foregroundStyle(Color.atlasMuted) }
            else { LabeledContent(fix.source == .operatorEntered ? "Изменено" : "Измерено", value: fix.observedAt.formatted(date: .abbreviated, time: .shortened)) }
        } else { Text("Автоматическая геометка отсутствует. Положение можно указать вручную.").font(.subheadline).foregroundStyle(Color.atlasMuted) }
    }
    private func sourceTitle(_ fix: GeoLocationFix) -> String {
        if fix.isSimulated { return "Тестовое положение устройства" }
        switch fix.source {
        case .deviceLocation: return "Положение устройства"
        case .photoEXIF: return "Исходное фото · EXIF"
        case .operatorEntered: return "Исправлено оператором"
        }
    }
}
