import Foundation
@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// A runtime wired to fakes: fake time, a stateful fake push-service, an in-memory Keychain, a temporary folder and
/// recording platform clients. `settle()` drains every queue; `advance(_:)` moves time and fires due timers.
final class Harness {
    let clock: FakeClock
    let scheduler: ManualScheduler
    let server: FakeServer
    let keychainAccess: InMemoryKeychain
    let root: URL
    let center: FakeNotificationCenter
    let application: FakeApplication
    let lifecycle: FakeLifecycle
    let reachability: FakeReachability
    let bundle: FakeBundle
    let device: FakeDeviceFacts
    let logs: LogCapture
    let transports = Locked<[FakeTransport]>([])
    let random = Locked<Double>(1)
    let appGroupContainer = Locked<URL?>(nil)
    let simulatorProfile = Locked<Bool>(true)
    /// File names (`identity.json`, `consent.json`, …) whose writes fail in this launch, standing in for a full disk.
    let failingWrites = Locked<Set<String>>([])
    /// File names whose reads fail with EPERM in this launch, as iOS answers for a protected file before the first unlock.
    let protectedFiles = Locked<Set<String>>([])
    /// Whether deleting a file fails in this launch.
    let failingRemoves = Locked(false)
    let runtime: Runtime

    init(sharing previous: Harness? = nil, logCapture: LogCapture? = nil) {
        clock = previous?.clock ?? FakeClock()
        scheduler = ManualScheduler(clock: clock)
        server = previous?.server ?? FakeServer()
        keychainAccess = previous?.keychainAccess ?? InMemoryKeychain()
        root = previous?.root ?? FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-tests-\(UUID().uuidString)")
        center = previous?.center ?? FakeNotificationCenter()
        application = previous?.application ?? FakeApplication()
        lifecycle = FakeLifecycle()
        reachability = FakeReachability()
        bundle = previous?.bundle ?? FakeBundle()
        device = previous?.device ?? FakeDeviceFacts()
        logs = previous?.logs ?? logCapture ?? LogCapture()
        if let previous {
            appGroupContainer.set(previous.appGroupContainer.current)
            simulatorProfile.set(previous.simulatorProfile.current)
        }
        runtime = Self.makeRuntime(Wiring(
            clock: clock, scheduler: scheduler, keychainAccess: keychainAccess, root: root, server: server,
            transports: transports, center: center, application: application, lifecycle: lifecycle,
            reachability: reachability, device: device, bundle: bundle, logger: logs.logger, random: random,
            container: appGroupContainer, simulator: simulatorProfile, failingWrites: failingWrites,
            failingRemoves: failingRemoves, protectedFiles: protectedFiles))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// The fakes a runtime is built from.
    private struct Wiring {
        let clock: FakeClock
        let scheduler: ManualScheduler
        let keychainAccess: InMemoryKeychain
        let root: URL
        let server: FakeServer
        let transports: Locked<[FakeTransport]>
        let center: FakeNotificationCenter
        let application: FakeApplication
        let lifecycle: FakeLifecycle
        let reachability: FakeReachability
        let device: FakeDeviceFacts
        let bundle: FakeBundle
        let logger: SDKLogger
        let random: Locked<Double>
        let container: Locked<URL?>
        let simulator: Locked<Bool>
        let failingWrites: Locked<Set<String>>
        let failingRemoves: Locked<Bool>
        let protectedFiles: Locked<Set<String>>
    }

    /// A refused file operation.
    struct InjectedFailure: Error {}

    private static func makeRuntime(_ wiring: Wiring) -> Runtime {
        let keychain = KeychainStore(bundleIdentifier: "com.salla.test", access: wiring.keychainAccess)
        let failingWrites = wiring.failingWrites
        let failingRemoves = wiring.failingRemoves
        let protectedFiles = wiring.protectedFiles
        let files = FileStore(root: wiring.root,
                              reader: { url in
                                  if protectedFiles.current.contains(url.lastPathComponent) {
                                      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
                                  }
                                  return try FileStore.fileReader(url)
                              },
                              writer: { data, url in
                                  if failingWrites.current.contains(url.lastPathComponent) { throw InjectedFailure() }
                                  try FileStore.atomicWriter(data, url)
                              },
                              remover: { url in
                                  if failingRemoves.current { throw InjectedFailure() }
                                  try FileStore.itemRemover(url)
                              })
        let environment = RuntimeEnvironment(
            logger: wiring.logger, clock: wiring.clock, notificationCenter: wiring.center, application: wiring.application,
            bundle: wiring.bundle,
            makeEngineEnvironment: {
                EngineEnvironment(
                    clock: wiring.clock, scheduler: wiring.scheduler, keychain: keychain, files: files,
                    makeTransport: { queue, _ in
                        let transport = FakeTransport(server: wiring.server, queue: queue)
                        wiring.transports.withLock { $0.append(transport) }
                        return transport
                    },
                    notificationCenter: wiring.center, application: wiring.application, lifecycle: wiring.lifecycle,
                    makeReachability: { wiring.reachability.make() },
                    deviceFacts: wiring.device, bundle: wiring.bundle,
                    apnsReader: APNsEnvironmentReader(profileURL: nil, isSimulator: wiring.simulator.current),
                    appGroupContainer: { _ in wiring.container.current },
                    logger: wiring.logger, random: { wiring.random.current })
            })
        return Runtime(environment: environment)
    }

    // MARK: - Driving

    /// Puts this runtime behind the public facade (`SallaPush.*`).
    func installAsShared() {
        Runtime.install(runtime)
    }

    var engine: Engine? { runtime.currentEngine }
    var engines: [Engine] { (runtime.currentEngine.map { [$0] } ?? []) + runtime.drainingEngines }
    var snapshot: EngineSnapshot { runtime.snapshot }

    func initialize(_ appId: String = "st_42_ios", configure: ((SallaPushConfiguration) -> Void)? = nil) {
        let configuration = SallaPushConfiguration()
        configure?(configuration)
        runtime.initialize(appId: appId, configuration: configuration)
        settle()
    }

    static func token(_ seed: UInt8 = 1) -> Data {
        Data(repeating: seed, count: 32)
    }

    static func tokenHex(_ seed: UInt8 = 1) -> String {
        Hex.lowercase(token(seed))
    }

    func sendToken(_ seed: UInt8 = 1) {
        runtime.submit(.pushToken(PushToken(hex: Self.tokenHex(seed))))
        settle()
    }

    /// The app logs in the customer that `token` proves (the fake server's `customers`), with that token.
    func login(_ token: String) {
        login(externalId: server.customer(of: token), token: token)
    }

    func login(externalId: String, token: String) {
        runtime.login(externalId: externalId, identityToken: token)
        settle()
    }

    /// The app logs in `customer` with a valid identity token of theirs.
    func login(customer: String) {
        login(externalId: customer, token: FakeServer.token(for: customer))
    }

    func logout() {
        runtime.logout()
        settle()
    }

    func submit(_ call: PublicCall) {
        runtime.submit(call)
        settle()
    }

    func send(_ event: LifecycleEvent) {
        lifecycle.send(event)
        settle()
    }

    /// Initializes, delivers a token and lets the registration go out.
    func registered(_ appId: String = "st_42_ios", configure: ((SallaPushConfiguration) -> Void)? = nil) {
        initialize(appId, configure: configure)
        sendToken()
        advance(2)
    }

    /// Drains the control and engine queues and the main run loop until nothing changes.
    func settle(maxRounds: Int = 500) {
        var stableRounds = 0
        var last = signature()
        for _ in 0..<maxRounds {
            drainOnce()
            let current = signature()
            if current == last && server.pendingDeliveries == 0 {
                stableRounds += 1
                if stableRounds >= 3 { return }
            } else {
                stableRounds = 0
                last = current
            }
        }
    }

    private func drainOnce() {
        runtime.controlQueue.sync {}
        for engine in engines { engine.queue.sync {} }
        runtime.badge.queue.sync {}
        center.callbackQueue.current?.sync {}
        while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
        for engine in engines { engine.queue.sync {} }
        runtime.badge.queue.sync {}
    }

    /// Delivers system callbacks the way the system does: the notification center's on `queue`, UIKit's on main.
    func useAsynchronousSystemCallbacks(on queue: DispatchQueue = DispatchQueue(label: "test.system.callbacks")) {
        center.callbackQueue.set(queue)
        application.callbacksOnMain.set(true)
    }

    private func signature() -> [Int] {
        [server.requests.count, logs.all.count, center.readCount, application.calls.count, engines.count,
         transports.current.count, server.heldCount, center.badgeCounts.count]
    }

    /// Moves time forward by `seconds`, firing every timer that falls due on the way, in order.
    func advance(_ seconds: Double) {
        settle()
        let target = clock.now() + seconds
        var guardCount = 0
        while let due = scheduler.nextDue, due <= target, guardCount < 10_000 {
            guardCount += 1
            clock.set(max(clock.now(), due))
            scheduler.fireDue()
            settle()
        }
        clock.set(target)
        scheduler.fireDue()
        settle()
    }

    /// A new process: the old engines die without writing anything, and a fresh runtime starts on the same
    /// Keychain, files and server.
    func relaunch() -> Harness {
        settle()
        for engine in engines {
            engine.queue.sync { engine.stop(persistState: false) }
        }
        return Harness(sharing: self)
    }

    // MARK: - Inspection

    var hostTag: String { APIBase.production.hostTag }

    func file(_ name: String, appId: String = "st_42_ios") -> [String: Any] {
        let url = root.appendingPathComponent("\(appId)/\(hostTag)/\(name)")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    func identityOps(appId: String = "st_42_ios") -> [[String: Any]] {
        file("identity.json", appId: appId)["ops"] as? [[String: Any]] ?? []
    }

    var deviceId: String? { snapshot.deviceId }
}
