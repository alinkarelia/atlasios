import Foundation

/// Geometry used only by the live LiDAR overlay. Capture/export geometry must
/// never be filtered with these visual limits.
enum LiDAROverlayGeometry {
    static let maximumBoundaryVertices = 32
    /// A convex input can gain one vertex at the near plane and four at the
    /// viewport planes. Keep that bounded intermediate polygon valid.
    static let maximumClippedVertices = maximumBoundaryVertices + 5
    static let maximumTriangleBudget = 32_000

    struct OverlayTriangle: Sendable, Equatable {
        let indices: SIMD3<UInt32>
        /// Index of the original ARKit face, including when faces were sampled.
        /// Classification buffers must be read with this index.
        let sourceFaceIndex: Int
    }

    /// Clip a *convex* camera-space fill against the near plane. ARKit cameras
    /// look along negative Z. Do this before perspective projection, where
    /// points behind the camera can otherwise produce enormous inverted lines.
    /// For concave outlines use `clipCameraBoundary`, which never joins pieces.
    static func clipCameraPolygon(_ points: [SIMD3<Float>], near: Float = 0.12) -> [SIMD3<Float>] {
        guard validBoundary(points), validNear(near) else { return [] }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(points.count + 1)
        var previous = points[points.count - 1]
        var previousInside = previous.z <= -near
        for current in points {
            let currentInside = current.z <= -near
            if currentInside != previousInside {
                guard let intersection = nearIntersection(previous, current, near: near) else { return [] }
                appendDistinct(intersection, to: &result)
            }
            if currentInside { appendDistinct(current, to: &result) }
            previous = current
            previousInside = currentInside
        }
        removeDuplicateClosingVertex(from: &result)
        return result.count >= 3 ? result : []
    }

    /// Clip original boundary edges independently. This preserves disconnected
    /// pieces of a concave ceiling/wall boundary without inventing near-plane
    /// closure lines. Draw returned segments individually, never as one path.
    static func clipCameraBoundary(_ points: [SIMD3<Float>], near: Float = 0.12)
        -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard validBoundary(points), validNear(near) else { return [] }
        var result: [(SIMD3<Float>, SIMD3<Float>)] = []
        result.reserveCapacity(points.count)
        for index in points.indices {
            let first = points[index]
            let second = points[(index + 1) % points.count]
            let firstInside = first.z <= -near
            let secondInside = second.z <= -near
            guard firstInside || secondInside else { continue }
            var from = first, to = second
            if firstInside != secondInside {
                guard let intersection = nearIntersection(first, second, near: near) else { return [] }
                if firstInside { to = intersection } else { from = intersection }
            }
            if squaredDistance(from, to) > 1e-12 { result.append((from, to)) }
        }
        return result
    }

    /// Screen clipping for a convex fill. Viewport and points share the same
    /// coordinate unit (UIKit points, or pixels); the origin is the top left.
    static func clipScreenPolygon(_ points: [SIMD2<Float>], viewport: SIMD2<Float>) -> [SIMD2<Float>] {
        guard points.count >= 3, points.count <= maximumClippedVertices,
              points.allSatisfy(isFinite), validViewport(viewport) else { return [] }
        var result = points.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let limits: [(axis: Int, limit: Double, keepGreater: Bool)] = [
            (0, 0, true), (0, Double(viewport.x), false),
            (1, 0, true), (1, Double(viewport.y), false)
        ]
        for boundary in limits {
            guard result.count >= 3 else { return [] }
            let input = result
            result.removeAll(keepingCapacity: true)
            var previous = input[input.count - 1]
            var previousInside = boundary.keepGreater
                ? previous[boundary.axis] >= boundary.limit : previous[boundary.axis] <= boundary.limit
            for current in input {
                let currentInside = boundary.keepGreater
                    ? current[boundary.axis] >= boundary.limit : current[boundary.axis] <= boundary.limit
                if previousInside != currentInside {
                    let delta = current - previous
                    let denominator = delta[boundary.axis]
                    guard denominator.isFinite, denominator != 0 else { return [] }
                    let fraction = (boundary.limit - previous[boundary.axis]) / denominator
                    var intersection = previous + delta * fraction
                    intersection[boundary.axis] = boundary.limit
                    guard intersection.x.isFinite, intersection.y.isFinite else { return [] }
                    appendDistinct(intersection, to: &result)
                }
                if currentInside { appendDistinct(current, to: &result) }
                previous = current
                previousInside = currentInside
            }
            removeDuplicateClosingVertex(from: &result)
        }
        guard result.count >= 3, abs(signedArea(result)) > 0.0001 else { return [] }
        return result.map {
            // Roundoff at a clip plane must never escape the viewport.
            SIMD2(Float(min(max($0.x, 0), Double(viewport.x))),
                  Float(min(max($0.y, 0), Double(viewport.y))))
        }
    }

    /// Clip one screen-space segment without creating a new boundary edge.
    /// Double intermediates tolerate extreme but finite projected coordinates.
    static func clipScreenLine(from: SIMD2<Float>, to: SIMD2<Float>, viewport: SIMD2<Float>)
        -> (SIMD2<Float>, SIMD2<Float>)? {
        guard isFinite(from), isFinite(to), validViewport(viewport) else { return nil }
        let start = SIMD2<Double>(Double(from.x), Double(from.y))
        let end = SIMD2<Double>(Double(to.x), Double(to.y))
        let delta = end - start
        guard delta.x * delta.x + delta.y * delta.y > 1e-12 else { return nil }
        var lower = 0.0, upper = 1.0
        let constraints = [(-delta.x, start.x), (delta.x, Double(viewport.x) - start.x),
                           (-delta.y, start.y), (delta.y, Double(viewport.y) - start.y)]
        for (direction, distance) in constraints {
            if direction == 0 {
                if distance < 0 { return nil }
            } else {
                let fraction = distance / direction
                if direction < 0 { lower = max(lower, fraction) }
                else { upper = min(upper, fraction) }
                if lower > upper { return nil }
            }
        }
        func point(_ fraction: Double) -> SIMD2<Float> {
            let value = start + delta * fraction
            return SIMD2(Float(min(max(value.x, 0), Double(viewport.x))),
                         Float(min(max(value.y, 0), Double(viewport.y))))
        }
        let first = point(lower), second = point(upper)
        guard isFinite(first), isFinite(second), squaredDistance(first, second) > 1e-8 else { return nil }
        return (first, second)
    }

    /// Uniformly sample whole source triangles, keeping each original face ID.
    /// Never subsample individual indices: doing so invents unrelated ceiling
    /// edges. Long, zero-area, invalid and nonfinite faces are visual outliers.
    static func filteredTriangles(vertices: [SIMD3<Float>], indices: [UInt32],
                                  triangleBudget: Int = maximumTriangleBudget,
                                  maxEdgeLength: Float = 0.75) -> [OverlayTriangle] {
        guard vertices.count >= 3, indices.count >= 3, indices.count % 3 == 0,
              triangleBudget > 0, maxEdgeLength.isFinite, maxEdgeLength > 0 else { return [] }
        let faceCount = indices.count / 3
        let candidateCount = min(faceCount, min(triangleBudget, maximumTriangleBudget))
        // Vertex coordinates are float32; tolerate one small relative rounding
        // step when a physical edge is exactly on the requested limit.
        let edgeLimitSquared = Double(maxEdgeLength) * Double(maxEdgeLength) * (1 + 1e-6)
        var result: [OverlayTriangle] = []
        result.reserveCapacity(candidateCount)
        for sample in 0..<candidateCount {
            let face = candidateCount == 1 ? faceCount / 2
                : Int((Double(sample) * Double(faceCount - 1) / Double(candidateCount - 1)).rounded(.down))
            let offset = face * 3
            let corners = SIMD3(indices[offset], indices[offset + 1], indices[offset + 2])
            guard Int(corners.x) < vertices.count, Int(corners.y) < vertices.count,
                  Int(corners.z) < vertices.count,
                  corners.x != corners.y, corners.y != corners.z, corners.x != corners.z else { continue }
            let first = vertices[Int(corners.x)]
            let second = vertices[Int(corners.y)]
            let third = vertices[Int(corners.z)]
            guard isFinite(first), isFinite(second), isFinite(third),
                  squaredDistance(first, second) <= edgeLimitSquared,
                  squaredDistance(second, third) <= edgeLimitSquared,
                  squaredDistance(third, first) <= edgeLimitSquared else { continue }
            let a = SIMD3<Double>(Double(second.x) - Double(first.x), Double(second.y) - Double(first.y),
                                  Double(second.z) - Double(first.z))
            let b = SIMD3<Double>(Double(third.x) - Double(first.x), Double(third.y) - Double(first.y),
                                  Double(third.z) - Double(first.z))
            let cross = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
            let normalSquared = cross.x * cross.x + cross.y * cross.y + cross.z * cross.z
            guard normalSquared.isFinite, normalSquared > 1e-12 else { continue }
            result.append(OverlayTriangle(indices: corners, sourceFaceIndex: face))
        }
        return result
    }

    private static func validNear(_ value: Float) -> Bool { value.isFinite && value > 0 }
    private static func validViewport(_ value: SIMD2<Float>) -> Bool {
        isFinite(value) && value.x > 0 && value.y > 0 && value.x <= 32_768 && value.y <= 32_768
    }
    private static func validBoundary(_ points: [SIMD3<Float>]) -> Bool {
        points.count >= 3 && points.count <= maximumBoundaryVertices && points.allSatisfy(isFinite)
    }
    private static func isFinite(_ value: SIMD3<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
    private static func isFinite(_ value: SIMD2<Float>) -> Bool { value.x.isFinite && value.y.isFinite }

    private static func nearIntersection(_ first: SIMD3<Float>, _ second: SIMD3<Float>, near: Float)
        -> SIMD3<Float>? {
        let denominator = Double(second.z) - Double(first.z)
        guard denominator.isFinite, denominator != 0 else { return nil }
        let fraction = min(max((-Double(near) - Double(first.z)) / denominator, 0), 1)
        let x = Double(first.x) + (Double(second.x) - Double(first.x)) * fraction
        let y = Double(first.y) + (Double(second.y) - Double(first.y)) * fraction
        let result = SIMD3(Float(x), Float(y), -near)
        return isFinite(result) ? result : nil
    }
    private static func squaredDistance(_ first: SIMD3<Float>, _ second: SIMD3<Float>) -> Double {
        let x = Double(first.x) - Double(second.x), y = Double(first.y) - Double(second.y)
        let z = Double(first.z) - Double(second.z)
        return x * x + y * y + z * z
    }
    private static func squaredDistance(_ first: SIMD2<Float>, _ second: SIMD2<Float>) -> Double {
        let x = Double(first.x) - Double(second.x), y = Double(first.y) - Double(second.y)
        return x * x + y * y
    }
    private static func appendDistinct(_ point: SIMD3<Float>, to result: inout [SIMD3<Float>]) {
        if let previous = result.last, squaredDistance(previous, point) < 1e-12 { return }
        result.append(point)
    }
    private static func removeDuplicateClosingVertex(from result: inout [SIMD3<Float>]) {
        if result.count > 1, let first = result.first, let last = result.last,
           squaredDistance(first, last) < 1e-12 { result.removeLast() }
    }
    private static func appendDistinct(_ point: SIMD2<Double>, to result: inout [SIMD2<Double>]) {
        if let previous = result.last {
            let delta = previous - point
            if delta.x * delta.x + delta.y * delta.y < 1e-12 { return }
        }
        result.append(point)
    }
    private static func removeDuplicateClosingVertex(from result: inout [SIMD2<Double>]) {
        if result.count > 1, let first = result.first, let last = result.last {
            let delta = first - last
            if delta.x * delta.x + delta.y * delta.y < 1e-12 { result.removeLast() }
        }
    }
    private static func signedArea(_ polygon: [SIMD2<Double>]) -> Double {
        polygon.indices.reduce(0) { area, index in
            let current = polygon[index], next = polygon[(index + 1) % polygon.count]
            return area + current.x * next.y - current.y * next.x
        } * 0.5
    }
}
