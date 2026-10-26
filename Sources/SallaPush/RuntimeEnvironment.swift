import Foundation
import SallaPushCore

/// The dependencies of the runtime. The engine environment is created lazily on the control queue, so the first
/// public call does no I/O.
struct RuntimeEnvironment: Sendable {
    var logger: SDKLogger
    var clock: Clock
    var notificationCenter: NotificationCenterClient
    var application: ApplicationClient
    var bundle: BundleInfoSource
    var makeEngineEnvironment: @Sendable () -> EngineEnvironment

    /// The real system.
    static func live() -> RuntimeEnvironment {
        let logger = SDKLogger.shared
        let clock = SystemClock()
        let center = SystemNotificationCenterClient(logger: logger)
        let application = liveApplication()
        let bundle = MainBundleInfo()
        return RuntimeEnvironment(
            logger: logger, clock: clock, notificationCenter: center, application: application, bundle: bundle,
            makeEngineEnvironment: {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
                return EngineEnvironment(
                    clock: clock,
                    scheduler: DispatchScheduler(),
                    keychain: KeychainStore(bundleIdentifier: bundle.bundleIdentifier),
                    files: FileStore(root: support.appendingPathComponent("SallaPush", isDirectory: true)),
                    makeTransport: { queue, userAgent in URLSessionTransport(queue: queue, userAgent: userAgent) },
                    notificationCenter: center,
                    application: application,
                    lifecycle: SystemLifecycleSource(),
                    makeReachability: { SystemReachabilityMonitor() },
                    deviceFacts: SystemDeviceFacts(),
                    bundle: bundle,
                    apnsReader: APNsEnvironmentReader.mainBundle(),
                    appGroupContainer: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) },
                    logger: logger,
                    random: { Double.random(in: 0...1) })
            })
    }

    private static func liveApplication() -> ApplicationClient {
        #if canImport(UIKit) && os(iOS)
        return SystemApplicationClient()
        #else
        return InertApplicationClient()
        #endif
    }
}
