import Foundation
import SallaPushCore

/// This device's push subscription.
@objc public final class SallaPushSubscription: NSObject {
    // Stateless, so one instance serves every thread.
    private static let instance = UncheckedSendable(SallaPushSubscription())
    static var shared: SallaPushSubscription { instance.value }

    override init() {
        super.init()
    }

    /// The SallaPush device id; nil until the device is registered.
    @objc public var id: String? { Runtime.shared.snapshot.deviceId }

    /// The APNs token in lowercase hex; nil until the app forwards one. Do not share it with third parties.
    @objc public var token: String? { Runtime.shared.snapshot.token }

    /// Permission granted, not opted out, and a token present; it reflects `optIn()` and `optOut()` as soon as they
    /// return.
    @objc public var optedIn: Bool { Runtime.shared.snapshot.optedIn }

    /// Clears an earlier `optOut()`; prompts for permission when it was never asked.
    @objc public func optIn() {
        Runtime.shared.submit(.optIn)
    }

    /// Stops SallaPush notifications on this device; the device stays registered.
    @objc public func optOut() {
        Runtime.shared.submit(.optOut)
    }

    /// Adds a subscription observer (held weakly). Added while registered, it gets one replay with
    /// `previous == current == <the state when the replay is delivered>`, on main, after this call returns.
    @objc public func addObserver(_ observer: SallaPushSubscriptionObserver) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(observer, of: "pushSubscription.addObserver", "observer") else { return }
        runtime.observers.addSubscriptionObserver(observer, replay: replay(for: runtime))
    }

    /// Removes a subscription observer.
    @objc public func removeObserver(_ observer: SallaPushSubscriptionObserver) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(observer, of: "pushSubscription.removeObserver", "observer") else { return }
        runtime.observers.removeSubscriptionObserver(observer)
    }

    /// Observes subscription changes with a closure on main (same replay rule); keep the returned observation.
    public func addObserver(_ handler: @escaping @MainActor @Sendable (SallaPushSubscriptionChangedState) -> Void) -> SallaPushObservation {
        let runtime = Runtime.shared
        return runtime.observers.addSubscriptionHandler(handler, replay: replay(for: runtime))
    }

    /// The replay of an observer added now: decided now (only while registered), built when it is delivered, so a
    /// change published in between can never be followed by an older state.
    private func replay(for runtime: Runtime) -> ObserverHub.Replay? {
        guard runtime.snapshot.deviceId != nil else { return nil }
        return { [weak runtime] in
            guard let snapshot = runtime?.snapshot, snapshot.deviceId != nil else { return nil }
            let state = SallaPushSubscriptionState(id: snapshot.deviceId, token: snapshot.token, optedIn: snapshot.optedIn)
            return SallaPushSubscriptionChangedState(previous: state, current: state)
        }
    }
}
