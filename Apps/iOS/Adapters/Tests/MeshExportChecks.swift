#if TERRAVIEW_MESH_EXPORT_CHECKS
import Foundation

@main struct MeshExportChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure("Expected output fixture directory") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        let source = directory.appendingPathComponent("source.obj")
        let frameID = UUID(uuidString: "A7100000-1234-4000-8000-000000000101")!
        // A two-metre edge, physical creases, reversed/slash/relative indices,
        // and an unused vertex expose scaling, winding and accessor-bounds bugs.
        let original = Data("""
        # Atlas ARKit mesh. metres. Y up. local frame \(frameID.uuidString)
        v 1.25 -2 0.5
        v 3.25 -2 0.5
        v 1.25 1 0.5
        v 1.25 -2 4.5
        v -90 90 90
        f 1 2 3
        f 1/1/1 4//1 2/3/1
        f 2 4 3
        f -5 -3 -2

        """.utf8)
        try original.write(to: source)
        var files: [String: String] = [:]
        for format in MeshExportFormat.allCases {
            let url = try MeshExportService.export(source: source, format: format, outputDirectory: output)
            try check(url.pathExtension == format.fileExtension, "Actual output extension")
            files[format.rawValue] = url.path
        }
        try check(try Data(contentsOf: source) == original, "Conversion preserves the source bytes")
        let second = try MeshExportService.export(source: source, format: .glb, outputDirectory: output)
        try check(second.path != files["glb"], "Repeated export creates a separate file")
        try check(try Data(contentsOf: second) == Data(contentsOf: URL(fileURLWithPath: files["glb"]!)),
                  "Repeated exports have identical geometry bytes")

        // A registered derivative declares a metric anchor without becoming
        // an acquisition original. Header-only changes must not rescale its
        // actual GLB positions, bounds or wire-format units.
        let derivative = directory.appendingPathComponent("aligned-derivative.obj")
        let derivativeBytes = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "# Atlas ARKit mesh. metres. Y up. local frame ",
                                  with: "# TerraView aligned fragment derivative. metres. Y up. local frame ").utf8)
        try derivativeBytes.write(to: derivative)
        let derivativeMesh = try OBJPreviewLoader.load(derivative)
        try check(!derivativeMesh.isAtlasCapture && derivativeMesh.declaredMetricFrame?.frameID == frameID,
                  "Derivative metres/frame do not relabel original provenance")
        let derivativeGLB = try MeshExportService.export(source: derivative, format: .glb, outputDirectory: output)
        let derivativeGLBBytes = try Data(contentsOf: derivativeGLB)
        try check(derivativeGLBBytes == Data(contentsOf: second), "Automatic derivative GLB retains actual metric geometry and bounds")
        let jsonSize = Int(derivativeGLBBytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
        let derivativeDocument = try JSONSerialization.jsonObject(with: derivativeGLBBytes.subdata(in: 20..<(20 + jsonSize))) as? [String: Any]
        let derivativeAsset = derivativeDocument?["asset"] as? [String: Any]
        let derivativeExtras = derivativeAsset?["extras"] as? [String: Any]
        try check(derivativeExtras?["units"] as? String == "metres", "Actual derivative GLB declares metre units")
        try check(try Data(contentsOf: derivative) == derivativeBytes, "Derivative GLB export retains source bytes")

        // A plausible spelling without a real frame UUID is still unknown;
        // GLB must refuse it, while PLY must explicitly preserve unknown units.
        let malformedDerivative = directory.appendingPathComponent("malformed-derivative.obj")
        let malformedBytes = Data(String(decoding: derivativeBytes, as: UTF8.self)
            .replacingOccurrences(of: frameID.uuidString, with: "invalid").utf8)
        try malformedBytes.write(to: malformedDerivative)
        let malformedMesh = try OBJPreviewLoader.load(malformedDerivative)
        try check(!malformedMesh.isAtlasCapture && malformedMesh.declaredMetricFrame == nil, "Invalid derivative frame cannot certify units")
        let beforeMalformed = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        do {
            _ = try MeshExportService.export(source: malformedDerivative, format: .glb, outputDirectory: output)
            throw CheckFailure("Malformed derivative units must not become GLB metres")
        } catch MeshExportError.unknownUnitForGLB {}
        try check(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == beforeMalformed,
                  "Unknown derivative units create no GLB or partial output")
        let malformedPLY = try MeshExportService.export(source: malformedDerivative, format: .ply, outputDirectory: output)
        let malformedPLYBytes = try Data(contentsOf: malformedPLY)
        let malformedPLYHeader = String(decoding: malformedPLYBytes.prefix(512), as: UTF8.self)
        try check(malformedPLYHeader.contains("units=unknown (source units)"), "Actual PLY preserves unknown derivative units")
        try check(try Data(contentsOf: malformedDerivative) == malformedBytes, "Unknown-unit rejection and PLY export retain source bytes")

        let degenerate = directory.appendingPathComponent("degenerate.obj")
        try Data("# Atlas ARKit mesh. metres. Y up. local frame \(frameID.uuidString)\nv 0 0 0\nv 1 0 0\nv 2 0 0\nf 1 2 3\n".utf8).write(to: degenerate)
        var degenerateFiles: [String: String] = [:]
        for format in MeshExportFormat.allCases {
            degenerateFiles[format.rawValue] = try MeshExportService.export(source: degenerate, format: format, outputDirectory: output).path
        }

        let before = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MeshExportService.export(source: source, format: .stl, outputDirectory: output)
        }
        do { _ = try await cancelled.value; throw CheckFailure("Cancelled export must fail") }
        catch is CancellationError {}
        try check(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == before,
                  "Cancelled export creates no partial file")

        let invalid = directory.appendingPathComponent("invalid.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 99\n".utf8).write(to: invalid)
        do {
            _ = try MeshExportService.export(source: invalid, format: .glb, outputDirectory: output)
            throw CheckFailure("Invalid source must fail")
        } catch OBJPreviewError.invalidMesh {}
        try check(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == before,
                  "Failed decoding creates no partial output")
        do {
            _ = try MeshExportService.export(source: source, format: .ply, outputDirectory: URL(string: "https://example.invalid/export")!)
            throw CheckFailure("Remote output directory must fail")
        } catch MeshExportError.invalidDestination {}

        let oversized = directory.appendingPathComponent("oversized.obj")
        try check(FileManager.default.createFile(atPath: oversized.path, contents: nil), "Create sparse size-limit fixture")
        let oversizedFile = try FileHandle(forWritingTo: oversized)
        try oversizedFile.truncate(atOffset: UInt64(OBJPreviewLoader.maximumBytes + 1))
        try oversizedFile.close()
        do {
            _ = try MeshExportService.export(source: oversized, format: .stl, outputDirectory: output)
            throw CheckFailure("Input size limit must fail")
        } catch OBJPreviewError.limit {}
        try FileManager.default.removeItem(at: oversized)
        try check(try FileManager.default.contentsOfDirectory(atPath: output.path).allSatisfy { !$0.hasSuffix(".tmp") },
                  "No temporary artifacts remain")

        // A real multi-chunk export crosses the streaming buffer boundary.
        let streamed = directory.appendingPathComponent("streamed.obj")
        try Data(("# Atlas ARKit mesh. metres. Y up. local frame \(frameID.uuidString)\nv 0 0 0\nv 2 0 0\nv 0 3 0\n" + String(repeating: "f 1 2 3\n", count: 10_000)).utf8).write(to: streamed)
        var streamedFiles: [String: String] = [:]
        for format in MeshExportFormat.allCases {
            streamedFiles[format.rawValue] = try MeshExportService.export(source: streamed, format: format, outputDirectory: output).path
        }
        let unknown = directory.appendingPathComponent("unknown-units.obj")
        try Data(String(decoding: original, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n").utf8).write(to: unknown)
        var unknownFiles: [String: String] = [:]
        for format in [MeshExportFormat.stl, .ply] {
            unknownFiles[format.rawValue] = try MeshExportService.export(source: unknown, format: format, outputDirectory: output).path
        }
        do {
            _ = try MeshExportService.export(source: unknown, format: .glb, outputDirectory: output)
            throw CheckFailure("GLB must not mislabel unknown units as metres")
        } catch MeshExportError.unknownUnitForGLB {}
        let explicit = try MeshExportService.export(source: unknown, format: .glb, outputDirectory: output, sourceUnit: .meters)
        var manifest: [String: Any] = ["regular": files, "degenerate": degenerateFiles, "streamed": streamedFiles,
                                       "unknown": unknownFiles, "explicit-metres": ["glb": explicit.path]]
        #if canImport(ModelIO)
        // A genuine aligned USDZ with a native metre declaration exercises the
        // same source path as RoomPlan instead of disguising OBJ as USDZ.
        let usdz = directory.appendingPathComponent("room.usdz")
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        fixture.arguments = ["python3", "-c", #"""
import struct, sys, zipfile
source = b'''#usda 1.0
(
    defaultPrim = "Room"
    metersPerUnit = 1
    upAxis = "Y"
)
def Xform "Room" {
    double3 xformOp:translate = (10, 0, 20)
    uniform token[] xformOpOrder = ["xformOp:translate"]
    def Mesh "Walls" {
        point3f[] points = [(0, 0, 0), (2, 0, 0), (0, 3, 4)]
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        uniform token subdivisionScheme = "none"
    }
}
'''
name = "room.usda"
entry = zipfile.ZipInfo(name)
entry.compress_type = zipfile.ZIP_STORED
padding = (-(30 + len(name.encode("utf-8")) + 4)) % 64
entry.extra = struct.pack("<HH", 0xCAFE, padding) + bytes(padding)
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr(entry, source)
"""#, usdz.path]
        try fixture.run(); fixture.waitUntilExit()
        try check(fixture.terminationStatus == 0, "Native USDZ fixture creation")
        var nativeFiles: [String: String] = [:]
        for format in MeshExportFormat.allCases {
            nativeFiles[format.rawValue] = try MeshExportService.export(source: usdz, format: format, outputDirectory: output).path
        }
        manifest["native-usdz"] = nativeFiles
        #endif
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: directory.appendingPathComponent("files.json"))
        print("Swift mesh exports: STL/PLY/GLB, valid original/derivative metric frames, unknown-unit refusal, source retention, cancellation, limits and streaming passed")
    }

    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw CheckFailure(message) }
    }
    private struct CheckFailure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
