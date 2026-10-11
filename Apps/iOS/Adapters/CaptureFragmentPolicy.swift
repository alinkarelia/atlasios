import Foundation

/// A proposal for the operator; this policy neither stops capture nor writes
/// files. The coordinator's independent hard resource reserve still applies.
enum CaptureFragmentPolicy {
    enum Recommendation: String, Equatable, Sendable { case duration, lowStorage }

    static let durationThresholdSeconds: TimeInterval = 600
    static let lowStorageThresholdBytes: Int64 = 2_000_000_000
    static let recommendationDeferralSeconds: TimeInterval = 300

    static func recommendation(activeSeconds: TimeInterval,
                               availableDiskBytes: Int64) -> Recommendation? {
        if availableDiskBytes >= 0 && availableDiskBytes < lowStorageThresholdBytes { return .lowStorage }
        if activeSeconds.isFinite && activeSeconds >= durationThresholdSeconds { return .duration }
        return nil
    }

    /// Approximate compressed video only. Meshes, sidecars, movie overhead and
    /// encoder bitrate variation require additional storage; this is no cap.
    static func estimatedVideoBytes(activeSeconds: TimeInterval) -> Int64? {
        guard activeSeconds.isFinite, activeSeconds >= 0 else { return nil }
        let bytes = ceil(activeSeconds * Double(CaptureVideoDocument.targetVideoBitrateBitsPerSecond) / 8)
        guard bytes.isFinite, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }
}

/// Elapsed time comes from observed AR monotonic timestamps. Pausing discards
/// the timestamp bridge, so a lunch break, locked phone or overnight gap adds
/// no recording duration. A fresh origin resets the fragment's active clock.
struct CaptureFragmentActiveClock: Sendable {
    private(set) var elapsedSeconds: TimeInterval = 0
    private var previousTimestamp: TimeInterval?
    private var deferredUntilActiveSeconds: TimeInterval?

    mutating func observe(arTimestamp: TimeInterval) {
        guard arTimestamp.isFinite, arTimestamp >= 0 else { return }
        if let previousTimestamp {
            guard arTimestamp > previousTimestamp else { return }
            let interval = arTimestamp - previousTimestamp
            guard interval.isFinite, (elapsedSeconds + interval).isFinite else { return }
            elapsedSeconds += interval
        }
        previousTimestamp = arTimestamp
    }

    mutating func pause() { previousTimestamp = nil }
    mutating func reset() { self = Self() }

    mutating func deferRecommendation(for activeSeconds: TimeInterval = CaptureFragmentPolicy.recommendationDeferralSeconds) {
        guard activeSeconds.isFinite, activeSeconds >= 0, (elapsedSeconds + activeSeconds).isFinite else { return }
        deferredUntilActiveSeconds = elapsedSeconds + activeSeconds
    }

    func recommendation(availableDiskBytes: Int64) -> CaptureFragmentPolicy.Recommendation? {
        if let deferredUntilActiveSeconds, elapsedSeconds < deferredUntilActiveSeconds { return nil }
        return CaptureFragmentPolicy.recommendation(activeSeconds: elapsedSeconds, availableDiskBytes: availableDiskBytes)
    }
}
