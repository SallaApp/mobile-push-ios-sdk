import Foundation
@testable import SallaPushCore
import XCTest

final class LoggerTests: XCTestCase {
    private struct ConsoleLine {
        let level: SallaPushLogLevel
        let category: String
        let text: String
    }

    private final class Console: @unchecked Sendable {
        let lines = Locked<[ConsoleLine]>([])
    }

    private func makeLogger(plist: String? = nil, console: Console, queue: DispatchQueue? = nil) -> SDKLogger {
        SDKLogger(plistLevelReader: { plist.map(ConfiguredLogLevel.text) },
                  consoleSink: { level, category, line in
                      console.lines.withLock { $0.append(ConsoleLine(level: level, category: category, text: line)) }
                  },
                  handlerQueue: queue ?? DispatchQueue(label: "test.log"))
    }

    func test_sinkRule() {
        XCTAssertTrue(SallaPushLogLevel.warn.admits(.error))
        XCTAssertTrue(SallaPushLogLevel.warn.admits(.warn))
        XCTAssertFalse(SallaPushLogLevel.warn.admits(.info))
        XCTAssertFalse(SallaPushLogLevel.off.admits(.error))
        XCTAssertFalse(SallaPushLogLevel.verbose.admits(.off))
        XCTAssertTrue(SallaPushLogLevel.verbose.admits(.verbose))
    }

    func test_defaultLevel_isWarn_andLineFormat() {
        let console = Console()
        let logger = makeLogger(console: console)
        XCTAssertEqual(logger.consoleLevel, .warn)
        logger.log(.registerOk, "registered")
        logger.log(.tokenMissing, "no token")
        let lines = console.lines.current
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "[SallaPush] WARN token.missing: no token")
        XCTAssertEqual(lines.first?.category, "registration")
    }

    func test_precedence_runtimeThenConfigurationThenPlist() {
        let logger = makeLogger(plist: "debug", console: Console())
        XCTAssertEqual(logger.consoleLevel, .debug)
        logger.setConfigurationLevel(.error)
        XCTAssertEqual(logger.consoleLevel, .error)
        logger.setRuntimeLevel(.verbose)
        XCTAssertEqual(logger.consoleLevel, .verbose)
        logger.setConfigurationLevel(nil)
        XCTAssertEqual(logger.consoleLevel, .verbose)
        XCTAssertEqual(SallaPushLogLevel(name: " Verbose "), .verbose)
        XCTAssertNil(SallaPushLogLevel(name: "loud"))
    }

    func test_messageIsNotBuilt_whenNoSinkAccepts() {
        let logger = makeLogger(console: Console())
        logger.setRuntimeLevel(.off)
        var built = false
        logger.log(.registerOk, { built = true; return "x" }())
        XCTAssertFalse(built)
    }

    func test_consoleOff_doesNotSilenceTheHandler() {
        let console = Console()
        let queue = DispatchQueue(label: "test.handler")
        let logger = makeLogger(console: console, queue: queue)
        logger.setRuntimeLevel(.off)
        let received = Locked<[String]>([])
        logger.setHandler(level: .info) { entry in received.withLock { $0.append(entry.code) } }
        logger.log(.registerOk, "ok")
        logger.log(.updateSent, "debug entry")
        queue.sync {}
        XCTAssertEqual(received.current, ["register.ok"])
        XCTAssertTrue(console.lines.current.isEmpty)
        logger.setHandler(level: .info, nil)
        logger.log(.registerOk, "ok")
        queue.sync {}
        XCTAssertEqual(received.current, ["register.ok"])
    }

    func test_metadata_isLimitedToTheAllowedKeys() {
        let queue = DispatchQueue(label: "test.meta")
        let logger = makeLogger(console: Console(), queue: queue)
        let received = Locked<[SallaPushLogEntry]>([])
        logger.setHandler(level: .verbose) { entry in received.withLock { $0.append(entry) } }
        logger.log(.netRetry, "retry", metadata: ["http_status": "503", "token": "secret", "request_id": "r1"])
        queue.sync {}
        XCTAssertEqual(received.current.first?.metadata, ["http_status": "503", "request_id": "r1"])
    }

    func test_handlerQueue_isBounded_andReportsDrops() {
        let queue = DispatchQueue(label: "test.bounded")
        let logger = makeLogger(console: Console(), queue: queue)
        let gate = DispatchSemaphore(value: 0)
        let received = Locked<[SallaPushLogEntry]>([])
        logger.setHandler(level: .verbose) { entry in
            if entry.message == "first" { gate.wait() }
            received.withLock { $0.append(entry) }
        }
        logger.log(.registerOk, "first")
        // Wait until the handler holds the first entry, so the rest pile up behind it.
        while received.current.isEmpty && !queueIsBlocked(queue) {}
        for index in 0..<(SDKLogger.handlerCapacity + 37) {
            logger.log(.registerOk, "entry \(index)")
        }
        gate.signal()
        queue.sync {}
        let entries = received.current
        let dropped = entries.filter { $0.code == "log.dropped" }
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first?.metadata["count"], "37")
        XCTAssertEqual(entries.filter { $0.code == "register.ok" }.count, SDKLogger.handlerCapacity + 1)
    }

    /// The sink rule holds for `log.dropped` too. A handler set to `.error` never receives
    /// the WARN notice, though the errors it admits overflow; one drop is worded in the singular.
    func test_droppedNotice_followsTheSinkRule_andCountsInTheSingular() {
        func overflow(handlerLevel: SallaPushLogLevel, code: LogCode, by extra: Int) -> [SallaPushLogEntry] {
            let queue = DispatchQueue(label: "test.dropped.\(handlerLevel.name)")
            let logger = makeLogger(console: Console(), queue: queue)
            logger.setRuntimeLevel(.off)
            let gate = DispatchSemaphore(value: 0)
            let received = Locked<[SallaPushLogEntry]>([])
            logger.setHandler(level: handlerLevel) { entry in
                if entry.message == "first" { gate.wait() }
                received.withLock { $0.append(entry) }
            }
            logger.log(code, "first")
            while received.current.isEmpty && !queueIsBlocked(queue) {}
            for index in 0..<(SDKLogger.handlerCapacity + extra) {
                logger.log(code, "entry \(index)")
            }
            gate.signal()
            queue.sync {}
            return received.current
        }
        let errorsOnly = overflow(handlerLevel: .error, code: .storageFailed, by: 5)
        XCTAssertFalse(errorsOnly.contains { $0.code == "log.dropped" })
        XCTAssertEqual(errorsOnly.count, SDKLogger.handlerCapacity + 1)
        let single = overflow(handlerLevel: .verbose, code: .registerOk, by: 1)
        let notice = single.filter { $0.code == "log.dropped" }
        XCTAssertEqual(notice.map(\.message), ["The log handler fell behind; 1 entry was dropped."])
    }

    func test_firstHandler_receivesTheEntriesLoggedBeforeIt() {
        let queue = DispatchQueue(label: "test.early")
        let logger = SDKLogger(plistLevelReader: { nil }, consoleSink: { _, _, _ in }, handlerQueue: queue,
                               keepsEarlyEntries: true)
        logger.log(.initInvalidAppId, "bad id")
        logger.log(.updateSent, "debug entry")
        logger.log(.storageFailed, "store failed")
        let received = Locked<[String]>([])
        logger.setHandler(level: .warn) { entry in received.withLock { $0.append(entry.code) } }
        logger.log(.tokenMissing, "after")
        queue.sync {}
        XCTAssertEqual(received.current, ["init.invalid_app_id", "storage.failed", "token.missing"])
        let second = Locked<[String]>([])
        logger.setHandler(level: .verbose) { entry in second.withLock { $0.append(entry.code) } }
        queue.sync {}
        XCTAssertTrue(second.current.isEmpty, "only the first handler gets the early entries")
    }

    func test_earlyEntries_areBounded_andOffByDefault() {
        let queue = DispatchQueue(label: "test.early.bounded")
        let keeping = SDKLogger(plistLevelReader: { nil }, consoleSink: { _, _, _ in }, handlerQueue: queue,
                                keepsEarlyEntries: true)
        for index in 0..<(SDKLogger.earlyEntryCapacity + 20) {
            keeping.log(.tokenMissing, "entry \(index)")
        }
        let received = Locked<[String]>([])
        keeping.setHandler(level: .warn) { entry in received.withLock { $0.append(entry.message) } }
        queue.sync {}
        XCTAssertEqual(received.current.count, SDKLogger.earlyEntryCapacity)
        XCTAssertEqual(received.current.first, "entry 0")

        let plain = makeLogger(console: Console(), queue: queue)
        plain.log(.tokenMissing, "before")
        let none = Locked<[String]>([])
        plain.setHandler(level: .warn) { entry in none.withLock { $0.append(entry.message) } }
        queue.sync {}
        XCTAssertTrue(none.current.isEmpty)
    }

    /// The first handler's early entries are warnings and errors only, so a debug or verbose message is
    /// never built while no sink accepts it.
    func test_earlyEntries_keepOnlyWarningsAndErrors_andNeverBuildDebugMessages() {
        let queue = DispatchQueue(label: "test.early.levels")
        let logger = SDKLogger(plistLevelReader: { nil }, consoleSink: { _, _, _ in }, handlerQueue: queue,
                               keepsEarlyEntries: true)
        var built = false
        logger.log(.updateSent, { built = true; return "debug" }())
        logger.log(.notifForeign, { built = true; return "verbose" }())
        XCTAssertFalse(built, "no sink accepted them, and early entries keep no debug or verbose entry")
        logger.log(.registerOk, "info")
        logger.log(.tokenMissing, "warning")
        logger.log(.storageFailed, "error")
        let received = Locked<[String]>([])
        logger.setHandler(level: .verbose) { entry in received.withLock { $0.append(entry.code) } }
        queue.sync {}
        XCTAssertEqual(received.current, ["token.missing", "storage.failed"])
    }

    /// Replacing a handler releases the old closure after the logger's lock, so an object it owns can
    /// log from its deinit.
    func test_replacingTheHandler_releasesTheOldOneOutsideTheLock() {
        final class LogsOnDeinit: @unchecked Sendable {
            let logger: SDKLogger
            init(logger: SDKLogger) { self.logger = logger }
            deinit { logger.log(.tokenMissing, "deinit") }
        }
        let logger = makeLogger(console: Console(), queue: DispatchQueue(label: "test.reentrant"))
        do {
            let owner = LogsOnDeinit(logger: logger)
            logger.setHandler(level: .warn) { _ in _ = owner }
        }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            logger.setHandler(level: .warn, nil)
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the old handler's deinit re-entered the logger's lock")
    }

    func test_invalidLevelValues_haveNames_andNeverTrap() {
        let invalid = unsafeBitCast(9, to: SallaPushLogLevel.self)
        XCTAssertNil(invalid.validated)
        XCTAssertEqual(invalid.name, "invalid(9)")
        XCTAssertEqual(SallaPushLogLevel.debug.validated, .debug)
        XCTAssertFalse(SallaPushLogLevel.off.admits(invalid))
        let reader = APNsEnvironmentReader(profileURL: nil, isSimulator: true)
        XCTAssertEqual(reader.environment(override: unsafeBitCast(7, to: SallaPushAPNsEnvironment.self)), .sandbox,
                       "an undeclared override counts as automatic")
    }

    func test_earlyEntries_keepTheirOrder_whileOtherThreadsLog() {
        for _ in 0..<50 {
            let queue = DispatchQueue(label: "test.early.race")
            let logger = SDKLogger(plistLevelReader: { nil }, consoleSink: { _, _, _ in }, handlerQueue: queue,
                                   keepsEarlyEntries: true)
            logger.log(.tokenMissing, "early")
            let received = Locked<[String]>([])
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                if lane == 0 {
                    logger.setHandler(level: .warn) { entry in received.withLock { $0.append(entry.message) } }
                } else {
                    logger.log(.tokenMissing, "racing")
                }
            }
            logger.log(.tokenMissing, "late")
            queue.sync {}
            XCTAssertEqual(received.current, ["early", "racing", "late"])
        }
    }

    /// True once `queue` is busy running a block (the handler is blocked inside it).
    private func queueIsBlocked(_ queue: DispatchQueue) -> Bool {
        let probe = DispatchSemaphore(value: 0)
        queue.async { probe.signal() }
        return probe.wait(timeout: .now() + .milliseconds(5)) == .timedOut
    }

    func test_logOnce_logsOnlyOnce() {
        let console = Console()
        let logger = makeLogger(console: console)
        logger.logOnce(.tokenMissing, key: "k", "once")
        logger.logOnce(.tokenMissing, key: "k", "once")
        XCTAssertEqual(console.lines.current.count, 1)
    }

    func test_categoryOverride() {
        let recorder = LogRecorder(category: "extension")
        recorder.logger.log(.notifForeign, "foreign")
        XCTAssertEqual(recorder.all.first?.category, "extension")
    }

    func test_everyCodeHasALevelAndACategory() {
        let categories: Set<String> = ["lifecycle", "registration", "identity", "notifications", "events", "tags",
                                       "network", "storage", "consent", "extension"]
        for code in LogCode.allCases {
            XCTAssertNotEqual(code.level, .off, code.rawValue)
            XCTAssertTrue(categories.contains(code.category), code.rawValue)
        }
    }
}
