#if ATLAS_OBJ_PREVIEW_CHECKS
import Foundation
#if canImport(SceneKit)
import SceneKit
import simd
#endif

@main struct OBJPreviewChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("obj-preview-checks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mesh.obj")
        func write(_ text: String) throws { try Data(text.utf8).write(to: url) }
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw Failure(message: message) }
        }
        func rejects(_ text: String, error expected: OBJPreviewError) throws {
            try write(text)
            do { _ = try OBJPreviewLoader.load(url) }
            catch let error as OBJPreviewError {
                try check(String(describing: error) == String(describing: expected), "Correct parser error")
                return
            }
            throw Failure(message: "Expected rejection")
        }
        try write("# Atlas ARKit mesh. metres. Y up. local frame test\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3")
        let payload = try OBJPreviewLoader.load(url)
        try check(payload.vertexCount == 3 && payload.triangleCount == 1 && payload.isAtlasCapture, "Capture metadata and actual counts")
        try check(payload.positions.count == 36 && payload.normals.count == 36 && payload.indices.count == 12, "Geometry buffer lengths")
        try check(payload.minimum == SIMD3<Float>(0, 0, 0) && payload.maximum == SIMD3<Float>(1, 1, 0), "Actual bounds")
        let zNormal = payload.normals.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Float.self) }
        try check(zNormal == 1, "Computed triangle normal")
        try write("v 0 0 0\nv 1 0 0\nv 0 1 0\nf -3/1/1 -2//1 -1/3/1\n")
        let relative = try OBJPreviewLoader.load(url)
        try check(relative.vertexCount == 3 && relative.triangleCount == 1 && !relative.isAtlasCapture, "Relative/slash OBJ indices")
        try rejects("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 0 2 3\n", error: .invalidMesh)
        try rejects("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 999\n", error: .invalidMesh)
        try rejects("v 0 0 0\nv 1 0 0\nv 0 1 0\nf -9223372036854775808 2 3\n", error: .invalidMesh)
        try rejects("v NaN 0 0\n", error: .invalidMesh)
        try rejects("v 1e30 0 0\n", error: .invalidMesh)
        try rejects("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3 1\n", error: .unsupportedFaces)
        try rejects("# empty mesh\n", error: .noGeometry)
        try rejects("#" + String(repeating: "a", count: 16_385), error: .invalidMesh)
        var chunked = ""
        for index in 0..<5_000 { chunked += "v \(index) 0.123456789 0\n" }
        chunked += "f 1 2 3\n"
        try write(chunked)
        try check(try OBJPreviewLoader.load(url).sourceVertexCount == 5_000, "Chunk boundaries preserve all vertices")
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(OBJPreviewLoader.maximumBytes + 1))
        try file.close()
        do { _ = try OBJPreviewLoader.load(url); throw Failure(message: "Expected size limit") }
        catch OBJPreviewError.limit {}
        // Two faces share an edge at a physical 90° crease. Flat display
        // normals must preserve that edge and every original triangle position.
        try write("v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 2 3\nf 1 4 2\n")
        let crease = try OBJPreviewLoader.load(url)
        try check(crease.sourceVertexCount == 4 && crease.vertexCount == 6 && crease.triangleCount == 2, "Hard edges expand only display vertices")
        func vector(in buffer: Data, at index: Int) -> SIMD3<Float> {
            buffer.withUnsafeBytes {
                SIMD3<Float>($0.loadUnaligned(fromByteOffset: index * 12, as: Float.self),
                             $0.loadUnaligned(fromByteOffset: index * 12 + 4, as: Float.self),
                             $0.loadUnaligned(fromByteOffset: index * 12 + 8, as: Float.self))
            }
        }
        try check(vector(in: crease.normals, at: 0) == SIMD3<Float>(0, 0, 1)
                  && vector(in: crease.normals, at: 3) == SIMD3<Float>(0, 1, 0), "A floor and wall retain independent normals at shared source vertices")
        let expectedTrianglePositions: [SIMD3<Float>] = [.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                                                         .zero, SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0)]
        for (index, point) in expectedTrianglePositions.enumerated() {
            try check(vector(in: crease.positions, at: index) == point, "Flat shading preserves exact source positions and triangle winding")
            let element = crease.indices.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self) }
            try check(element == UInt32(index), "Expanded index stream remains valid")
        }
        try check(crease.positions.count + crease.normals.count + crease.indices.count == 6 * 28, "Expanded buffer accounting is exact")
        try check(OBJPreviewLoader.maximumRenderVertices == 1_800_000 && OBJPreviewLoader.maximumGeometryBufferBytes == 50_400_000,
                  "Display expansion has an explicit bounded memory budget")
        try write("v 0 0 0\nv 1 0 0\nv 2 0 0\nf 1 2 3\n")
        let degenerate = try OBJPreviewLoader.load(url)
        try check(vector(in: degenerate.normals, at: 0) == SIMD3<Float>(0, 1, 0), "Degenerate geometry receives finite fallback normals")

        // Exercise the actual worst supported expansion, then exceed it by one
        // triangle. This validates allocation accounting and rejection against
        // a real input stream, rather than only repeating configuration values.
        try write("v 0 0 0\nv 1 0 0\nv 0 1 0\n" + String(repeating: "f 1 2 3\n", count: OBJPreviewLoader.maximumTriangles))
        do {
            let largest = try OBJPreviewLoader.load(url)
            try check(largest.sourceVertexCount == 3 && largest.vertexCount == OBJPreviewLoader.maximumRenderVertices,
                      "Maximum accepted triangle count expands within the vertex budget")
            try check(largest.positions.count + largest.normals.count + largest.indices.count == OBJPreviewLoader.maximumGeometryBufferBytes,
                      "Largest real input uses the advertised maximum buffer budget")
            let lastIndex = largest.indices.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: largest.indices.count - 4, as: UInt32.self)
            }
            try check(lastIndex == UInt32(OBJPreviewLoader.maximumRenderVertices - 1), "Largest expanded index is valid")
        }
        let append = try FileHandle(forWritingTo: url)
        try append.seekToEnd(); try append.write(contentsOf: Data("f 1 2 3\n".utf8)); try append.close()
        do { _ = try OBJPreviewLoader.load(url); throw Failure(message: "Expected triangle expansion limit") }
        catch OBJPreviewError.limit {}

        #if canImport(ModelIO)
        // A genuine, uncompressed/aligned USDZ fixture exercises native ModelIO
        // decoding and parent world transforms. It contains no bundled images.
        let usdzURL = directory.appendingPathComponent("room.usdz")
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
"""#, usdzURL.path]
        try fixture.run(); fixture.waitUntilExit()
        try check(fixture.terminationStatus == 0, "Native USDZ fixture creation")
        let usd = try OBJPreviewLoader.load(usdzURL)
        try check(usd.vertexCount == 3 && usd.triangleCount == 1, "USDZ actual geometry decoding")
        try check(usd.minimum == SIMD3<Float>(10, 0, 20) && usd.maximum == SIMD3<Float>(12, 3, 24), "USDZ parent transforms flatten to world geometry")
        try check(usd.positions.count == 36 && usd.normals.count == 36 && usd.indices.count == 12, "USDZ immutable buffer lengths")
        #endif

        // Walkthrough uses real model bounds and camera yaw. These checks cover
        // navigation math independently of SceneKit or a mirrored UI assertion.
        let roomBounds = MeshNavigationBounds(minimum: SIMD3<Float>(-4, 0, -3), maximum: SIMD3<Float>(4, 3, 3))
        let eye = roomBounds.initialWalkPosition
        try check(abs(eye.y - 0.1) < 0.0001, "Eye height is floor + 1.6 metres in centred scene")
        let ahead = roomBounds.moved(eye, forward: 1, sideways: 0, vertical: 0, yaw: 0, distance: 0.5)
        try check(ahead.x == eye.x && ahead.y == eye.y && abs(ahead.z - (eye.z - 0.5)) < 0.0001, "Forward follows viewing direction")
        let rotated = roomBounds.moved(.zero, forward: 1, sideways: 0, vertical: 0, yaw: .pi / 2, distance: 0.5)
        try check(abs(rotated.x + 0.5) < 0.0001 && abs(rotated.z) < 0.0001, "Quarter turn changes forward axis")
        let side = roomBounds.moved(.zero, forward: 0, sideways: 1, vertical: 0, yaw: 0, distance: 0.5)
        try check(side == SIMD3<Float>(0.5, 0, 0), "Strafe preserves eye height")
        let outside = roomBounds.clamped(SIMD3<Float>(100, -100, 100))
        try check(outside.x < 4 && outside.y > -1.5 && outside.z < 3, "Camera cannot escape model bounds")
        let flat = MeshNavigationBounds(minimum: .zero, maximum: SIMD3<Float>(1, 0, 1))
        try check(flat.initialWalkPosition.y == 0 && flat.clamped(SIMD3<Float>(0, 100, 0)).y == 0, "Flat meshes have finite zero-height navigation")
        try check(flat.diagonal.isFinite && flat.diagonal > 0, "Small/flat meshes retain usable camera scale")
        // A conservative sphere must fit both axes, not just a square canvas.
        for aspect: Float in [0.35, 0.6, 1, 2] {
            let distance = roomBounds.fittedOrbitDistance(viewportAspect: aspect)
            let sphereAngle = asin(roomBounds.diagonal * 0.5 / distance)
            let verticalHalfAngle = Float.pi / 6
            let horizontalHalfAngle = atan(tan(verticalHalfAngle) * aspect)
            try check(sphereAngle < verticalHalfAngle && sphereAngle < horizontalHalfAngle, "Portrait/landscape fit contains the complete model")
        }
        try check(roomBounds.fittedOrbitDistance(viewportAspect: 0.35) > roomBounds.fittedOrbitDistance(viewportAspect: 1), "Narrow viewports need a farther orbit camera")
        #if canImport(SceneKit)
        // Verify the native camera convention against an independent world→local
        // conversion, catching wrong front axes and Euler rotation ordering.
        let camera = SCNNode()
        camera.camera = SCNCamera()
        for angles in [SIMD2<Float>(0.35, -0.3), SIMD2<Float>(-0.8, 0.6), SIMD2<Float>(1.1, -0.9)] {
            let forward = MeshNavigationBounds.cameraForward(yaw: angles.x, pitch: angles.y)
            camera.simdPosition = -forward * 20
            camera.simdOrientation = simd_quatf(angle: angles.x, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: angles.y, axis: SIMD3<Float>(1, 0, 0))
            let localTarget = camera.simdConvertPosition(.zero, from: nil)
            try check(abs(localTarget.x) < 0.0001 && abs(localTarget.y) < 0.0001 && localTarget.z < -19.99, "Native camera aims at origin along local -Z")
        }
        #endif
        print("OBJ preview: buffer, geometry, bounds, relative index, malformed input, streaming, size-limit, bounded walkthrough, sharp crease normals and aspect-aware camera checks passed.")
    }
    struct Failure: Error { let message: String }
}
#endif
