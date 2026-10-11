#if TERRAVIEW_MESH_EXPORT_CHECKS
import Foundation

@main struct MeshExportChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure("Expected output fixture directory") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        let source = directory.appendingPathComponent("source.obj")
        // A two-metre edge, physical creases, reversed/slash/relative indices,
        // and an unused vertex expose scaling, winding and accessor-bounds bugs.
        let original = Data("""
        # Atlas ARKit mesh. metres. Y up. local frame fixture
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

        let degenerate = directory.appendingPathComponent("degenerate.obj")
        try Data("# Atlas ARKit mesh. metres. Y up. local frame degenerate\nv 0 0 0\nv 1 0 0\nv 2 0 0\nf 1 2 3\n".utf8).write(to: degenerate)
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
        try Data(("# Atlas ARKit mesh. metres. Y up. local frame streamed\nv 0 0 0\nv 2 0 0\nv 0 3 0\n" + String(repeating: "f 1 2 3\n", count: 10_000)).utf8).write(to: streamed)
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
        print("Swift mesh exports: STL/PLY/GLB, source retention, cancellation, limits and streaming passed")
    }

    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw CheckFailure(message) }
    }
    private struct CheckFailure: Error { let message: String; init(_ message: String) { self.message = message } }
}
#endif
