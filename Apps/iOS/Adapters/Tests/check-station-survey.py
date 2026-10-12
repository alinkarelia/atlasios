#!/usr/bin/env python3
"""Exercise actual offline station store with append-only raw history and CAS.

The production Core declarations and actor are compiled unchanged. The unrelated
floor-plan geometry overload and unavailable Linux file protection are omitted.
This tests real persistence and GPS observation policy without simulating hardware.
"""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[4]
core = ROOT / "Packages/AtlasCore/Sources/AtlasCore"
domain = (core / "Domain.swift").read_text()
types = domain[domain.index("public enum ProjectKind:"):domain.index("public struct PlanRoom:")]
geometry = (core / "Geometry.swift").read_text()
floor_start = geometry.index("    public static func validate(_ plan: AtlasFloorPlan,")
floor_end = geometry.index("    /// Stable for a small ring translated", floor_start)
geometry = geometry[:floor_start] + geometry[floor_end:]
exports = (core / "Export.swift").read_text()
artifact = exports[exports.index("public struct ExportArtifact:"):exports.index("public enum AtlasExportError:")]
journal = (core / "CemeterySurvey.swift").read_text()
stations = (core / "SurveyStations.swift").read_text()
store = (ROOT / "Apps/iOS/Adapters/StationSurveyStore.swift").read_text().replace("import AtlasCore\n", "")
if platform.system() == "Darwin":
    compiler = ["xcrun", "swiftc"]
else:
    swiftc = os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc")
    if not swiftc:
        raise SystemExit("Swift 6 compiler required; set ATLAS_SWIFTC to its path.")
    compiler = [swiftc]
    store = store.replace("[.atomic, .completeFileProtectionUnlessOpen]", "[.atomic]")

TESTS = r'''
@main struct StationSurveyChecks {
    static func main() async throws {
        var checks = 0
        func expect(_ result: Bool, _ message: String) {
            guard result else { fatalError("Station survey regression: \(message)") }
            checks += 1
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-station-\(UUID())",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let directory = base.appendingPathComponent("Captures/StationSurvey",isDirectory:true)
        let projectID = UUID(), epoch = Date(timeIntervalSince1970:1_790_000_000.125)
        let first = StationSurveyStore(projectID:projectID,reference:.wgs84,directory:directory)
        let second = StationSurveyStore(projectID:projectID,reference:.wgs84,directory:directory)
        expect(try await first.load() == nil,"absent journal is distinguishable from corruption")
        var document = StationSurvey(projectID:projectID,coordinateReference:.wgs84,at:epoch)
        let id = try document.addStation()
        try document.enter(stationID:id,position:.geographicPoint(.init(longitude:30,latitude:60)),reason:"Контроль",at:epoch)
        let stale = document
        document = try await first.save(document)
        let file = directory.appendingPathComponent(projectID.uuidString+".station-survey.json")
        let initial = try Data(contentsOf:file)
        expect(document.revision == 1,"atomic first commit increments persisted revision")
        expect(try await second.load() == document,"another actor independently restores journal and dates exactly")
        var conflict = false
        do { _ = try await second.save(stale) } catch StationSurveyStoreError.revisionConflict { conflict = true }
        expect(try conflict && Data(contentsOf:file) == initial,"stale concurrent writers cannot replace a newer journal")
        var wrong = StationSurvey(projectID:UUID(),coordinateReference:.wgs84,at:epoch)
        _ = try wrong.addStation()
        var rejected = false
        do { _ = try await first.save(wrong) } catch { rejected = true }
        expect(try rejected && Data(contentsOf:file) == initial,"foreign project data cannot cross project scope")

        try document.beginGPS(stationID:id,at:epoch.addingTimeInterval(20))
        for index in 0..<3 {
            let time = epoch.addingTimeInterval(21+Double(index)*3)
            try document.updateGPS(stationID:id,sample:CemeterySurveySample(coordinate:.init(longitude:30.001,latitude:60),
                capturedAt:time,horizontalAccuracyMeters:7,altitudeMeters:200),receivedAt:time)
        }
        document = try await first.save(document)
        let interrupted = try await second.load()!
        expect(interrupted.stations[0].attempts.last?.state == .collecting && interrupted.stations[0].attempts.last?.observations.count == 3,
            "in-progress raw fixes survive an independent reopen before completion")
        try document.finishGPS(stationID:id,at:epoch.addingTimeInterval(30))
        document = try await first.save(document)
        expect(document.stations[0].attempts.count == 2 && document.stations[0].current?.reportedAccuracyMeters == 7,
            "successful GPS remeasurement retains manual history without invented accuracy")
        let durable = try Data(contentsOf:file)
        var metadata = try JSONSerialization.jsonObject(with:durable) as! [String:Any]
        var stationJSON = metadata["stations"] as! [[String:Any]]
        var attempts = stationJSON[0]["attempts"] as! [[String:Any]]
        attempts[0]["reason"] = "Перезаписанная история"; stationJSON[0]["attempts"] = attempts; metadata["stations"] = stationJSON
        let tampered = try JSONDecoder().decode(StationSurvey.self,from:JSONSerialization.data(withJSONObject:metadata))
        var historyRejected = false
        do { _ = try await first.save(tampered) } catch StationSurveyError.historyChanged { historyRejected = true }
        expect(try historyRejected && Data(contentsOf:file) == durable,"completed history is immutable across saves")

        // A legal long-running project with repeat observations hits the REAL
        // production 16MiB boundary. No test-specific smaller limit is injected.
        var large = document
        var moment = epoch.addingTimeInterval(100)
        for stationIndex in 0..<18 {
            let station = stationIndex == 0 ? id : try large.addStation()
            let prior = large.stations.first { $0.id == station }!.attempts.count
            for _ in prior..<40 {
                try large.beginGPS(stationID:station,at:moment)
                for index in 0..<StationSurveyAttempt.maximumObservations {
                    let time = moment.addingTimeInterval(Double(index)*0.08)
                    try large.updateGPS(stationID:station,sample:CemeterySurveySample(coordinate:.init(longitude:30.001,latitude:60),
                        capturedAt:time,horizontalAccuracyMeters:7,altitudeMeters:200),receivedAt:time)
                }
                try large.finishGPS(stationID:station,at:moment.addingTimeInterval(10))
                moment = moment.addingTimeInterval(12)
            }
        }
        let largeBytes = try JSONEncoder().encode(large).count
        expect(largeBytes > StationSurveyStore.maximumBytes,"valid repeated raw measurements reach the exact reader byte bound")
        var tooLarge = false
        do { _ = try await first.save(large) } catch StationSurveyStoreError.tooLarge { tooLarge = true }
        expect(tooLarge,"oversized valid candidate produces precise size failure before atomic replacement")
        expect((try Data(contentsOf:file)) == durable,"size failure preserves prior checkpoint bytes")
        expect(try await second.load() == document,"failed growth remains readable through a separate store instance")

        let largeReaderID = UUID()
        try Data(repeating:32,count:StationSurveyStore.maximumBytes+1).write(to:directory.appendingPathComponent(largeReaderID.uuidString+".station-survey.json"))
        var boundedRead = false
        do { _ = try await StationSurveyStore(projectID:largeReaderID,reference:.wgs84,directory:directory).load() }
        catch StationSurveyStoreError.tooLarge { boundedRead = true }
        expect(boundedRead,"reader rejects oversized input before attempting JSON decode")

        let outside = base.appendingPathComponent("outside",isDirectory:true)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let escaped = base.appendingPathComponent("Captures/LinkedSurvey",isDirectory:true)
        try FileManager.default.createSymbolicLink(atPath:escaped.path,withDestinationPath:outside.path)
        let escapedStore = StationSurveyStore(projectID:UUID(),reference:.wgs84,directory:escaped)
        let escapedProjectID = escapedStore.projectID
        var escapedDocument = StationSurvey(projectID:escapedProjectID,coordinateReference:.wgs84,at:epoch)
        _ = try escapedDocument.addStation()
        var escapeRejected = false
        do { _ = try await escapedStore.save(escapedDocument) } catch { escapeRejected = true }
        expect(try escapeRejected && FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty,
            "directory symlink escapes cannot write any external journal")
        print("PASS: \(checks) production station persistence checks; \(largeBytes) bytes rejected, original observations preserved.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="atlas-station-checks-") as directory:
    folder = Path(directory)
    harness = folder / "StationSurveyChecks.swift"
    executable = folder / "station-survey-checks"
    harness.write_text("import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n" + types + geometry + journal + artifact + stations + store + TESTS)
    subprocess.run(compiler + ["-swift-version", "6", "-strict-concurrency=complete", "-O", "-parse-as-library",
        str(harness), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
