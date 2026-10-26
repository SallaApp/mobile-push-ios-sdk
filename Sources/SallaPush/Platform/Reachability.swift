import Foundation
import Network
import SallaPushCore

/// Tells the engine when the network comes back. Started only while an operation has failed with a network error.
protocol ReachabilityMonitor: AnyObject, Sendable {
    /// Starts watching; `onRestored` runs on `queue` each time the path goes from unusable to usable.
    func start(on queue: DispatchQueue, onRestored: @escaping @Sendable () -> Void)
    func cancel()
}

/// `NWPathMonitor`. A cancelled monitor is never restarted; the engine creates a new one.
final class SystemReachabilityMonitor: ReachabilityMonitor, @unchecked Sendable {
    private let monitor = NWPathMonitor()

    func start(on queue: DispatchQueue, onRestored: @escaping @Sendable () -> Void) {
        // The first update reports the current path; only a later change from unusable to usable counts.
        let wasOffline = Locked(false)
        monitor.pathUpdateHandler = { path in
            let restored = wasOffline.withLock { offline -> Bool in
                if path.status == .satisfied {
                    defer { offline = false }
                    return offline
                }
                offline = true
                return false
            }
            if restored { onRestored() }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}
