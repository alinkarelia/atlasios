import SwiftUI
import MapKit
import AtlasCore

@MainActor
struct SurveyMapSurface: View {
    @Binding var position: MapCameraPosition
    let features: [AtlasFeature]
    let prominentIDs: Set<UUID>
    let draft: [GeographicCoordinate]
    @ObservedObject var location: SurveyLocationService
    let isDrawing: Bool
    let onTap: (GeographicCoordinate) -> Void
    let onSelect: (AtlasFeature) -> Void
    let onRegion: (MKCoordinateRegion) -> Void

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                ForEach(features) { feature in
                    featureContent(feature)
                }
                if draft.count > 1 {
                    MapPolyline(coordinates: draft.map(SurveyMapStyle.coordinate))
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                }
                ForEach(draft.indices, id: \.self) { index in
                    Annotation("Точка \(index + 1)", coordinate: SurveyMapStyle.coordinate(draft[index])) {
                        Circle().fill(Color.orange).frame(width: 10, height: 10)
                    }.annotationTitles(.hidden)
                }
                ForEach(location.segments) { segment in
                    if segment.samples.count > 1 {
                        MapPolyline(coordinates: segment.samples.map { SurveyMapStyle.coordinate($0.coordinate) })
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, dash: [5, 4]))
                    }
                }
                if let fix = location.fix, let accuracy = fix.horizontalAccuracyMeters {
                    MapCircle(center: SurveyMapStyle.coordinate(fix.coordinate), radius: accuracy)
                        .foregroundStyle(Color.blue.opacity(0.12)).stroke(Color.blue.opacity(0.6), lineWidth: 1)
                    Annotation("Положение оператора", coordinate: SurveyMapStyle.coordinate(fix.coordinate)) {
                        Circle().fill(Color.blue).frame(width: 13, height: 13)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }.annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { onRegion($0.region) }
            .onTapGesture(coordinateSpace: .local) { point in
                if isDrawing {
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    onTap(GeographicCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude))
                } else if let feature = SurveyMapHitTest.selectGeographic(point, features: features, project: { coordinate in
                    proxy.convert(SurveyMapStyle.coordinate(coordinate), to: .local)
                }) {
                    onSelect(feature)
                }
            }
            .accessibilityIdentifier("map.geographicCanvas")
        }
    }

    @MapContentBuilder
    private func featureContent(_ feature: AtlasFeature) -> some MapContent {
        if case let .geographicPolygon(polygon) = feature.geometry {
            MapPolygon(SurveyMapStyle.polygon(polygon))
                .foregroundStyle(SurveyMapStyle.color(feature.category).opacity(0.16))
                .stroke(SurveyMapStyle.color(feature.category), lineWidth: feature.category == .cemetery ? 3 : 2)
            if prominentIDs.contains(feature.id), let first = polygon.vertices.first { annotation(feature, at: first) }
        } else if case let .geographicPolyline(line) = feature.geometry {
            MapPolyline(coordinates: line.vertices.map(SurveyMapStyle.coordinate))
                .stroke(SurveyMapStyle.color(feature.category), lineWidth: 4)
            if prominentIDs.contains(feature.id), let first = line.vertices.first { annotation(feature, at: first) }
        } else if case let .geographicPoint(point) = feature.geometry {
            annotation(feature, at: point)
        }
    }

    @MapContentBuilder
    private func annotation(_ feature: AtlasFeature, at coordinate: GeographicCoordinate) -> some MapContent {
        Annotation(feature.label, coordinate: SurveyMapStyle.coordinate(coordinate)) {
            if prominentIDs.contains(feature.id) {
                Button { onSelect(feature) } label: {
                    Image(systemName: SurveyMapStyle.symbol(feature.category)).font(.caption.bold())
                        .foregroundStyle(Color.atlasCanvas).padding(9)
                        .background(SurveyMapStyle.color(feature.category), in: Circle())
                        .overlay(Circle().stroke(Color.atlasCanvas.opacity(0.7), lineWidth: 2))
                }
                .buttonStyle(.plain).disabled(isDrawing)
                .accessibilityLabel(feature.label + ", " + feature.category.title)
                .accessibilityIdentifier("map.feature." + feature.id.uuidString)
            } else {
                // Dense point layers retain a small symbol; the same projected
                // hit test selects them without hundreds of labelled buttons.
                Circle().fill(SurveyMapStyle.color(feature.category)).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color.atlasCanvas, lineWidth: 1))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }.annotationTitles(.hidden)
    }
}
