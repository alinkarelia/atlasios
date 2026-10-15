import Foundation

/// A visual lease is independent of a checkpoint's durable coordinate frame.
/// Invalidating presentation must never cancel an already accepted disk write.
struct CaptureVisualAdmission: Sendable {
    struct Ticket: Equatable, Sendable {
        let epoch: UUID
        let anchorID: UUID
        let revision: UUID
    }

    private var epoch = UUID()
    private var anchors: [UUID: UUID] = [:]
    private(set) var isActive = false

    mutating func activate() { isActive = true }

    /// Retain live anchor identities across a same-origin pause, but revoke all
    /// work accepted before it. Returning to normal tracking cannot revive it.
    mutating func suspend() {
        epoch = UUID()
        isActive = false
    }

    mutating func reset() {
        suspend()
        anchors.removeAll()
    }

    mutating func observe(anchorID: UUID) {
        if anchors[anchorID] == nil { anchors[anchorID] = UUID() }
    }

    mutating func remove(anchorID: UUID) { anchors[anchorID] = nil }

    /// Revisions advance only for accepted work, not for throttled callbacks.
    /// A remove/re-add of the same identifier also receives a new revision.
    mutating func issue(anchorID: UUID) -> Ticket? {
        guard isActive, anchors[anchorID] != nil else { return nil }
        let revision = UUID()
        anchors[anchorID] = revision
        return Ticket(epoch: epoch, anchorID: anchorID, revision: revision)
    }

    func admits(_ ticket: Ticket) -> Bool {
        isActive && ticket.epoch == epoch && anchors[ticket.anchorID] == ticket.revision
    }
}

/// The real checkpoint pipeline uses this boundary after processing. A write
/// that completes after removal/pause/reset still commits, but cannot render.
/// Keeping this seam free of ARKit permits controlled async regression tests.
@MainActor
enum CaptureVisualCommit {
    static func persist(write: () async throws -> Void,
                        canPresent: () -> Bool, present: () -> Void) async throws {
        try await write()
        if canPresent() { present() }
    }
}
