#!/usr/bin/env python3
"""Exercise production atomic GPS checkpoints and byte limits without hardware.

Actual CemeterySurvey journal/geometry and SurveyCheckpointStore declarations
are extracted. The unrelated floor-plan overload and Apple's unavailable Linux
file-protection option are omitted; journal and atomic-write algorithms are used
unchanged. This verifies persistence, not CLLocationManager or device accuracy.
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
journal = (core / "CemeterySurvey.swift").read_text()
adapter = (ROOT / "Apps/iOS/Adapters/SurveyLocationService.swift").read_text()
checkpoint = adapter[adapter.index("private struct SurveyCheckpoint:"):adapter.index("@MainActor\nprivate final class SurveyWeakReference")]
store = adapter[adapter.index("private actor SurveyCheckpointStore {"):adapter.index("/// Only foreground WGS84 observations.")]
if platform.system() == "Darwin":
    compiler = ["xcrun", "swiftc"]
else:
    swiftc = os.environ.get("ATLAS_SWIFTC") or shutil.which("swiftc")
    if not swiftc:
        raise SystemExit("Swift 6 compiler required; set ATLAS_SWIFTC to its path.")
    compiler = [swiftc]
    store = store.replace("[.atomic, .completeFileProtectionUnlessOpen]", "[.atomic]")

TESTS = r'''
@main struct SurveyCheckpointChecks {
    static func main() async throws {
        var checks = 0
        func expect(_ result: Bool, _ message: String) {
            guard result else { fatalError("Survey checkpoint regression: \(message)") }
            checks += 1
        }
        let projectID = UUID(), start = Date(timeIntervalSince1970: 1_790_000_000)
        var session = try CemeterySurveySession(startedAt:start)
        let oldSnapshot = session
        // Thousands of valid stationary observations are legal raw data. Only
        // consecutive duplicates collapse when deriving a ring, never in storage.
        for index in 0..<8_500 {
            let time = start.addingTimeInterval(Double(index)*3)
            try session.record(CemeterySurveySample(coordinate:.init(longitude:0,latitude:0),
                capturedAt:time,horizontalAccuracyMeters:0.5),receivedAt:time)
        }
        let corners:[GeographicCoordinate] = [
            .init(longitude:0.00002,latitude:0),.init(longitude:0.00002,latitude:0.00002),
            .init(longitude:0,latitude:0.00002),.init(longitude:0,latitude:0)]
        for (index, coordinate) in corners.enumerated() {
            let time = start.addingTimeInterval(Double(8_500+index)*3)
            try session.record(CemeterySurveySample(coordinate:coordinate,capturedAt:time,
                horizontalAccuracyMeters:0.5),receivedAt:time)
        }
        let pausedAt = start.addingTimeInterval(25_512)
        try session.pause(at:pausedAt)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-survey-checkpoint-\(UUID())",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let storage = SurveyCheckpointStore(projectID:projectID,directory:directory)
        try await storage.save(session,generation:1)
        let active = directory.appendingPathComponent(projectID.uuidString+".json")
        let durableBytes = try Data(contentsOf:active)
        expect(durableBytes.count <= SurveyCheckpointStore.maximumCheckpointBytes,"a committed raw journal fits the reader's byte bound")
        let restored = try await SurveyCheckpointStore(projectID:projectID,directory:directory).load()
        expect(restored == session && restored?.observations.count == 8_504,"a new store restores every raw stationary and moving observation")
        try await storage.save(oldSnapshot,generation:0)
        expect(try Data(contentsOf:active) == durableBytes,"a delayed shorter checkpoint cannot truncate the durable raw journal")

        var oversized = session
        let segmentID = session.segments[0].id
        var confirmationCount = 0
        while try JSONEncoder().encode(SurveyCheckpoint(version:1,projectID:projectID,session:oversized)).count <= SurveyCheckpointStore.maximumCheckpointBytes {
            confirmationCount += 1
            try oversized.confirmBoundary(segmentID:segmentID,at:pausedAt.addingTimeInterval(Double(confirmationCount)))
        }
        expect(oversized.observations == session.observations,"repeated confirmations retain the actual original observations")
        var preciseFailure = false
        do { try await storage.save(oversized,generation:2) }
        catch SurveyCheckpointError.tooLarge { preciseFailure = true }
        expect(preciseFailure,"an oversized journal gets a precise error before replacement")
        expect(try Data(contentsOf:active) == durableBytes,"an oversized update preserves the prior durable bytes exactly")
        let cached = try await storage.load()
        expect(cached == session,"a rejected write cannot advance the store's cached confirmation state")
        let reopened = try await SurveyCheckpointStore(projectID:projectID,directory:directory).load()
        expect(reopened == session && reopened?.observations.count == 8_504,"the prior raw journal remains independently readable after failed growth")
        var archiveFailure = false
        do { try await storage.archive(oversized) }
        catch SurveyCheckpointError.tooLarge { archiveFailure = true }
        let archive = directory.appendingPathComponent(projectID.uuidString+"-"+session.id.uuidString+".json")
        expect(archiveFailure && !FileManager.default.fileExists(atPath:archive.path),"oversized archives cannot be reported as saved or create unreadable files")
        print("PASS: \(checks) production survey checkpoint checks; \(confirmationCount) confirmations hit the byte limit, 8504 raw samples preserved.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="atlas-survey-checkpoint-math-") as directory:
    folder = Path(directory)
    harness = folder / "SurveyCheckpointChecks.swift"
    executable = folder / "survey-checkpoint-checks"
    harness.write_text("import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n" + types + geometry + journal + checkpoint + store + TESTS)
    subprocess.run(compiler + ["-swift-version", "6", "-strict-concurrency=complete", "-O",
        "-parse-as-library", str(harness), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
