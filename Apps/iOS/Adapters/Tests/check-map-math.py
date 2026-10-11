#!/usr/bin/env python3
"""Run actual native map math with no MapKit or hardware simulation.

Only Foundation-only declarations are extracted from production MapPresentation
and AtlasCore Domain. This checks screen-space selection, open lines/holes,
viewport culling and render budgets; Apple SDK integration is checked by the
native Xcode build separately. No production algorithm is copied into the tests.
"""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
source = (ROOT / "Apps/iOS/Features/Map/MapPresentation.swift").read_text()
domain = (ROOT / "Packages/AtlasCore/Sources/AtlasCore/Domain.swift").read_text()
types = domain[domain.index("public enum ProjectKind:"):domain.index("public struct PlanRoom:")]
helpers = source[source.index("enum SurveyMapHitTest {"):source.index("struct MetricPlotCanvas: View {")]
transform = source[source.index("struct PlotTransform {"):]
if platform.system() == "Darwin":
    compiler = ["xcrun", "swiftc"]
else:
    swiftc = os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc")
    if not swiftc:
        raise SystemExit("Swift 6 compiler required; set ATLAS_SWIFTC to its path.")
    compiler = [swiftc]

TESTS = r'''
@main struct MapMathChecks {
    static func main() {
        let projectID = UUID()
        func point(_ x: Double, _ y: Double) -> GeographicCoordinate { GeographicCoordinate(longitude: x, latitude: y) }
        func feature(_ geometry: FeatureGeometry, _ category: FeatureCategory = .grave) -> AtlasFeature {
            AtlasFeature(projectID: projectID, label: "Math check", category: category, geometry: geometry)
        }
        func projection(_ coordinate: GeographicCoordinate) -> CGPoint? { CGPoint(x: coordinate.longitude, y: coordinate.latitude) }
        var checked = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checked += 1
        }
        let polygon = feature(.geographicPolygon(GeographicPolygon(vertices: [point(0, 0), point(100, 0), point(100, 100), point(0, 100)], holes: [[point(40, 40), point(60, 40), point(60, 60), point(40, 60)]])))
        check(SurveyMapHitTest.geographic(CGPoint(x: 20, y: 20), feature: polygon, project: projection), "polygon body must select")
        check(!SurveyMapHitTest.geographic(CGPoint(x: 50, y: 50), feature: polygon, project: projection), "hole interior must not select")
        let tinyHole = feature(.geographicPolygon(GeographicPolygon(vertices: [point(0, 0), point(100, 0), point(100, 100), point(0, 100)], holes: [[point(49, 49), point(51, 49), point(51, 51), point(49, 51)]])))
        check(!SurveyMapHitTest.geographic(CGPoint(x: 50, y: 50), feature: tinyHole, project: projection), "small hole must stay empty despite touch tolerance")
        let line = feature(.geographicPolyline(GeographicPolyline(vertices: [point(0, 0), point(100, 0), point(100, 100)])), .road)
        check(SurveyMapHitTest.geographic(CGPoint(x: 50, y: 10), feature: line, project: projection), "line body within fixed touch target must select")
        check(!SurveyMapHitTest.geographic(CGPoint(x: 50, y: 50), feature: line, project: projection), "open line must not create a closing diagonal")
        let territory = feature(polygon.geometry, .cemetery)
        check(SurveyMapHitTest.drawingOrder([polygon, territory]).last?.id == polygon.id, "grave must take priority over enclosing territory")
        check(SurveyMapHitTest.selectGeographic(CGPoint(x: 20, y: 20), features: [polygon, territory], project: projection)?.id == polygon.id,
              "tapping a grave body must open its card rather than the enclosing cemetery")
        let nearestMarker = feature(.geographicPoint(point(20, 20))), adjacentMarker = feature(.geographicPoint(point(35, 20)))
        check(SurveyMapHitTest.selectGeographic(CGPoint(x: 21, y: 20), features: [nearestMarker, adjacentMarker], project: projection)?.id == nearestMarker.id,
              "dense grave markers select the nearest position rather than the last saved neighbour")
        let localFeature = feature(.metricPoint(frameID: UUID(), point: MetricPoint2D(x: 20, y: 20)))
        check(!SurveyMapHitTest.geographic(CGPoint(x: 20, y: 20), feature: localFeature, project: projection),
              "local metric coordinates must never be interpreted as WGS84 positions")
        let fixtures = (0..<3000).map { index in feature(.geographicPoint(point(30 + Double(index % 30) * 0.00003, 60 + Double(index / 30) * 0.00003))) }
        let index = SurveyGeographicIndex(features: fixtures)
        check(SurveyGeographicIndex(features: [localFeature]).plan(in: nil).features.isEmpty,
              "a geographic render index cannot include local metric objects")
        let overview = index.plan(in: nil)
        check(overview.features.count == 400 && overview.matchingCount == 3000 && overview.isLimited, "overview must bound rendered features without dropping the count")
        check(overview.prominentIDs.count == 80, "overview must bound labelled buttons")
        let near = index.plan(in: SurveyGeographicViewport(center: point(30.00015, 60.00015), latitudeSpan: 0.0003, longitudeSpan: 0.0003))
        check(near.matchingCount > 0 && near.matchingCount < 400 && !near.isLimited, "zoomed viewport must reveal all local records")
        check(index.plan(in: SurveyGeographicViewport(center: point(0, 0), latitudeSpan: 0.001, longitudeSpan: 0.001)).features.isEmpty, "offscreen records must be culled")
        let seam = SurveyGeographicIndex(features: [feature(.geographicPoint(point(179.9, 0))), feature(.geographicPoint(point(-179.9, 0))), feature(.geographicPoint(point(0, 0)))])
        check(seam.plan(in: SurveyGeographicViewport(center: point(180, 0), latitudeSpan: 1, longitudeSpan: 0.5)).matchingCount == 2, "viewport crossing antimeridian must include both sides")
        let enclosing = feature(.geographicPolygon(GeographicPolygon(vertices: [point(10, 10), point(20, 10), point(20, 20), point(10, 20)])), .cemetery)
        check(SurveyGeographicIndex(features: [enclosing]).plan(in: SurveyGeographicViewport(center: point(15, 15), latitudeSpan: 0.01, longitudeSpan: 0.01)).matchingCount == 1, "enclosing area must remain visible when every vertex is outside viewport")
        let transform = PlotTransform(points: [MetricPoint2D(x: 0, y: 0), MetricPoint2D(x: 100, y: 100)], size: CGSize(width: 300, height: 400), zoom: 4, pan: CGSize(width: -120, height: 80))
        let metric = MetricPoint2D(x: 12.5, y: 42.75), restored = transform.metric(transform.screen(metric))
        check(abs(restored.x - metric.x) < 1e-10 && abs(restored.y - metric.y) < 1e-10, "pan/zoom conversion must round trip")
        print("PASS: \(checked) production map math checks; 3000-feature overview bounded to \(overview.features.count), close viewport \(near.matchingCount).")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="atlas-map-math-") as directory:
    folder = Path(directory)
    harness = folder / "MapMathChecks.swift"
    executable = folder / "map-math-checks"
    harness.write_text("import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n" + types + helpers + transform + TESTS)
    subprocess.run(compiler + ["-swift-version", "6", "-strict-concurrency=complete",
        "-parse-as-library", str(harness), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
