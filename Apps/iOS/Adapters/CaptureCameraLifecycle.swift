import Foundation

/// Admission for transient camera rendering, independent of durable mesh work.
/// A stopped run may still finish writing its source checkpoint, but it cannot
/// paint a later preview, resumed segment, or newly presented capture screen.
struct CaptureCameraLifecycle: Sendable {
    enum Mode: Equatable, Sendable {
        case preview
        case recording(segmentID: UUID)
    }

    private struct Run: Sendable {
        var id: UUID
        var mode: Mode
        var startedAt: TimeInterval
        var lastFrameTimestamp: TimeInterval?
    }
    private var run: Run?
    // Only outstanding visualization work needs a permit. Completed source
    // anchors and removed-anchor tombstones are never accumulated here.
    private var surfacePermits: [UUID: UUID] = [:]
    static let maximumPendingSurfaces = 4

    var currentRunID: UUID? { run?.id }

    mutating func begin(_ mode: Mode, at timestamp: TimeInterval) -> UUID {
        surfacePermits.removeAll(keepingCapacity: true)
        let id = UUID()
        run = timestamp.isFinite ? Run(id: id, mode: mode, startedAt: timestamp) : nil
        return id
    }

    mutating func stop() {
        run = nil; surfacePermits.removeAll(keepingCapacity: true)
    }

    func acceptsCallback(runID: UUID) -> Bool { run?.id == runID }

    /// ARKit timestamps and system uptime share the same monotonic clock.
    /// An old but recently queued frame must not revive a newly reset camera.
    mutating func acceptFrame(runID: UUID, timestamp: TimeInterval, now: TimeInterval) -> Bool {
        guard var current = run, current.id == runID,
              timestamp.isFinite, now.isFinite, timestamp >= current.startedAt,
              timestamp <= now + 0.1, now - timestamp < 1.5,
              current.lastFrameTimestamp.map({ timestamp > $0 }) ?? true else { return false }
        current.lastFrameTimestamp = timestamp
        run = current
        return true
    }

    func acceptsAnchors(runID: UUID) -> Bool {
        guard let run, run.id == runID else { return false }
        return run.lastFrameTimestamp != nil
    }

    func acceptsRecordedSurface(runID: UUID, segmentID: UUID) -> Bool {
        guard let run, run.id == runID, run.lastFrameTimestamp != nil else { return false }
        return run.mode == .recording(segmentID: segmentID)
    }

    func acceptsEvidenceFrame(runID: UUID, segmentID: UUID, timestamp: TimeInterval, now: TimeInterval) -> Bool {
        guard acceptsRecordedSurface(runID: runID, segmentID: segmentID), let run,
              let lastFrame = run.lastFrameTimestamp,
              timestamp.isFinite, now.isFinite, timestamp >= run.startedAt,
              timestamp >= lastFrame, timestamp <= now + 0.1, now - timestamp < 1.5 else { return false }
        return true
    }

    mutating func beginSurface(runID: UUID, segmentID: UUID, anchorID: UUID) -> UUID? {
        guard acceptsRecordedSurface(runID: runID, segmentID: segmentID),
              surfacePermits[anchorID] == nil,
              surfacePermits.count < Self.maximumPendingSurfaces else { return nil }
        let permit = UUID(); surfacePermits[anchorID] = permit
        return permit
    }

    func acceptsSurface(runID: UUID, segmentID: UUID, anchorID: UUID, permit: UUID) -> Bool {
        acceptsRecordedSurface(runID: runID, segmentID: segmentID) && surfacePermits[anchorID] == permit
    }

    mutating func removeAnchor(_ anchorID: UUID) { surfacePermits[anchorID] = nil }

    mutating func finishSurface(anchorID: UUID, permit: UUID) {
        // A completion from an invalidated run/anchor must not revoke a new
        // legitimate update that happens to use that same AR anchor ID.
        if surfacePermits[anchorID] == permit { surfacePermits[anchorID] = nil }
    }
}
