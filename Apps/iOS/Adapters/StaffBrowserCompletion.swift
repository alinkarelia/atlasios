import Foundation

/// The browser callback, a failed start and local logout may all finish the
/// same attempt. Resolve it exactly once, without exposing its URL or code.
final class StaffBrowserCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(with:result)
    }
}
