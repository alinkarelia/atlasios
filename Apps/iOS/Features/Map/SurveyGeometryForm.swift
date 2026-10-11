import Foundation
import SwiftUI
import AtlasCore

/// Editing vertices keeps the existing geometry type, holes and local frame.
/// A point is never silently replaced by a small invented polygon.
@MainActor
struct SurveyGeometryForm: View {
    @Binding var geometry: FeatureGeometry
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary).font(.footnote).foregroundStyle(Color.atlasMuted)
            if isMetric {
                ForEach(metricPoints.indices, id: \.self) { index in
                    HStack {
                        Text(vertexLabel(index)).font(.caption).frame(width: 64, alignment: .leading)
                        TextField("X, м", value: metricValue(index: index, x: true), format: .number)
                            .keyboardType(.numbersAndPunctuation).accessibilityLabel("X, метры, \(vertexLabel(index))")
                        TextField("Y, м", value: metricValue(index: index, x: false), format: .number)
                            .keyboardType(.numbersAndPunctuation).accessibilityLabel("Y, метры, \(vertexLabel(index))")
                        if !isPoint { Button(role: .destructive) { remove(index) } label: { Image(systemName: "minus.circle") } }
                    }
                }
            } else {
                ForEach(geographicPoints.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(vertexLabel(index)).font(.caption).foregroundStyle(Color.atlasMuted)
                        TextField("Долгота", value: geographicValue(index: index, longitude: true), format: .number.precision(.fractionLength(8)))
                            .keyboardType(.numbersAndPunctuation).accessibilityLabel("Долгота, \(vertexLabel(index))")
                        TextField("Широта", value: geographicValue(index: index, longitude: false), format: .number.precision(.fractionLength(8)))
                            .keyboardType(.numbersAndPunctuation).accessibilityLabel("Широта, \(vertexLabel(index))")
                        if !isPoint { Button("Удалить вершину", role: .destructive) { remove(index) } }
                    }
                }
            }
            if !isPoint {
                Button("Добавить вершину", systemImage: "plus") {
                    if isMetric { setMetric(metricPoints + [metricPoints.last ?? MetricPoint2D(x: 0, y: 0)]) }
                    else { setGeographic(geographicPoints + [geographicPoints.last ?? GeographicCoordinate(longitude: 0, latitude: 0)]) }
                }
            }
            if holeCount > 0 { Text("Отверстий: \(holeCount). Они сохраняются при изменении внешних вершин.").font(.footnote).foregroundStyle(Color.atlasMuted) }
        }
    }
    private var isMetric: Bool { if case .localMeters = geometry.coordinateReference { true } else { false } }
    private var isPoint: Bool { switch geometry { case .metricPoint, .geographicPoint: true; default: false } }
    private var holeCount: Int {
        switch geometry { case .metricPolygon(let p): p.holes.count; case .geographicPolygon(let p): p.holes.count; default: 0 }
    }
    private var summary: String { SurveyGeometrySummary.text(geometry) }
    private func vertexLabel(_ index: Int) -> String { isPoint ? "Точка" : "Точка \(index + 1)" }
    private var metricPoints: [MetricPoint2D] {
        switch geometry { case .metricPoint(_, let p): [p]; case .metricPolyline(let p): p.vertices; case .metricPolygon(let p): p.vertices; default: [] }
    }
    private var geographicPoints: [GeographicCoordinate] {
        switch geometry { case .geographicPoint(let p): [p]; case .geographicPolyline(let p): p.vertices; case .geographicPolygon(let p): p.vertices; default: [] }
    }
    private func metricValue(index: Int, x: Bool) -> Binding<Double> {
        Binding(get: { guard metricPoints.indices.contains(index) else { return 0 }; return x ? metricPoints[index].x : metricPoints[index].y },
            set: { value in guard metricPoints.indices.contains(index) else { return }; var points = metricPoints
                if x { points[index].x = value } else { points[index].y = value }; setMetric(points) })
    }
    private func geographicValue(index: Int, longitude: Bool) -> Binding<Double> {
        Binding(get: { guard geographicPoints.indices.contains(index) else { return 0 }; return longitude ? geographicPoints[index].longitude : geographicPoints[index].latitude },
            set: { value in guard geographicPoints.indices.contains(index) else { return }; var points = geographicPoints
                if longitude { points[index].longitude = value } else { points[index].latitude = value }; setGeographic(points) })
    }
    private func remove(_ index: Int) {
        if isMetric { var points = metricPoints; guard points.indices.contains(index) else { return }; points.remove(at: index); setMetric(points) }
        else { var points = geographicPoints; guard points.indices.contains(index) else { return }; points.remove(at: index); setGeographic(points) }
    }
    private func setMetric(_ points: [MetricPoint2D]) {
        switch geometry {
        case .metricPoint(let frame, _): if let first = points.first { geometry = .metricPoint(frameID: frame, point: first) }
        case .metricPolyline(var line): line.vertices = points; geometry = .metricPolyline(line)
        case .metricPolygon(var polygon): polygon.vertices = points; geometry = .metricPolygon(polygon)
        default: break
        }
    }
    private func setGeographic(_ points: [GeographicCoordinate]) {
        switch geometry {
        case .geographicPoint: if let first = points.first { geometry = .geographicPoint(first) }
        case .geographicPolyline(var line): line.vertices = points; geometry = .geographicPolyline(line)
        case .geographicPolygon(var polygon): polygon.vertices = points; geometry = .geographicPolygon(polygon)
        default: break
        }
    }
}

enum SurveyGeometrySummary {
    static func text(_ geometry: FeatureGeometry) -> String {
        switch geometry {
        case .metricPoint(_, let p): "Точка · X \(number(p.x)), Y \(number(p.y)) м"
        case .geographicPoint(let p): "Точка · \(p.latitude.formatted(.number.precision(.fractionLength(7)))), \(p.longitude.formatted(.number.precision(.fractionLength(7))))"
        case .metricPolyline(let p): "Линия · \(p.vertices.count) точек · локальные метры"
        case .geographicPolyline(let p): "Линия · \(p.vertices.count) точек · WGS84"
        case .metricPolygon(let p):
            if let area = try? PolygonGeometry.area(of: p) { "Полигон · \(number(area)) м² · \(p.vertices.count) вершин" }
            else { "Полигон · \(p.vertices.count) вершин · локальные метры" }
        case .geographicPolygon(let p): "Полигон · \(p.vertices.count) вершин · WGS84"
        }
    }
    private static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
}

@MainActor
struct SurveyPositionSummary: View {
    let feature: AtlasFeature
    var initialGeoTag: GeoTag? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(SurveyGeometrySummary.text(feature.geometry)).font(.subheadline)
            if let fix = operatorGeoTag?.effectiveFix {
                Text("Позиция оператора: \(fix.coordinate.latitude.formatted(.number.precision(.fractionLength(6)))), \(fix.coordinate.longitude.formatted(.number.precision(.fractionLength(6))))")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
                if fix.isSimulated { Text("Тестовое положение, не полевая GPS-точка").font(.caption).foregroundStyle(.orange) }
                Text("\(fix.observedAt.formatted(date: .abbreviated, time: .standard)) · \(accuracy(fix.horizontalAccuracyMeters))")
                    .font(.caption).foregroundStyle(Color.atlasMuted)
            } else {
                Text("Источник: \(sourceText) · \(accuracyText)").font(.caption).foregroundStyle(Color.atlasMuted)
                if let time = feature.attributes["survey.observedAt"] ?? feature.attributes["positionObservedAt"] {
                    Text(time).font(.caption).foregroundStyle(Color.atlasMuted)
                }
            }
            if feature.attributes["survey.positionCorrectedAt"] != nil {
                Text("Точка исправлена вручную. Исходная точность GPS не задаёт точность исправленной точки.")
                    .font(.footnote).foregroundStyle(Color.atlasMuted)
            }
            Text("GPS телефона показывает положение с погрешностью. Проверьте точку на карте; она не гарантирует точное положение отдельной могилы.")
                .font(.footnote).foregroundStyle(Color.atlasMuted)
        }
    }
    private var operatorGeoTag: GeoTag? {
        if let initialGeoTag { return initialGeoTag }
        guard let raw = feature.attributes["survey.operatorGeoTag"] else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GeoTag.self, from: Data(raw.utf8))
    }
    private var sourceText: String {
        switch feature.attributes["survey.positionSource"] ?? feature.attributes["accuracyBasis"] {
        case "phoneGPS", "deviceLocation", "gpsTrack", "gpsPhone", "walkedGPS": "GPS телефона"
        case "photoEXIF": "GPS исходного фото"
        case "operatorEntered": "введено оператором"
        case "document": "документ"
        case "controlPoints", "registered": "контрольные точки"
        default: "разметка специалистом"
        }
    }
    private var accuracyText: String {
        let value = feature.attributes["survey.horizontalAccuracyMeters"] ?? feature.attributes["horizontalAccuracyMeters"]
        return accuracy(value.flatMap(Double.init))
    }
    private func accuracy(_ value: Double?) -> String {
        if let value, value.isFinite, value >= 0 { "погрешность ±\(value.formatted(.number.precision(.fractionLength(1)))) м" }
        else { "точность не указана" }
    }
}

enum SurveyCardMetadata {
    static func retainingPosition(in original: AtlasFeature, changedGeometry: FeatureGeometry, initialGeoTag: GeoTag?) throws -> [String: String] {
        var attributes = original.attributes
        if let initialGeoTag, attributes["survey.operatorGeoTag"] == nil {
            try GeoTagPolicy.validate(initialGeoTag)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            attributes["survey.operatorGeoTag"] = String(data: try encoder.encode(initialGeoTag), encoding: .utf8)
            if let fix = initialGeoTag.effectiveFix {
                attributes["survey.positionSource"] = fix.source.rawValue
                attributes["survey.observedAt"] = ISO8601DateFormatter().string(from: fix.observedAt)
                if let accuracy = fix.horizontalAccuracyMeters { attributes["survey.horizontalAccuracyMeters"] = String(accuracy) }
            }
        }
        if original.geometry != changedGeometry {
            attributes["survey.positionCorrectedAt"] = ISO8601DateFormatter().string(from: Date())
            attributes["survey.positionCorrectionBasis"] = "manualCoordinates"
        }
        return attributes
    }
}
