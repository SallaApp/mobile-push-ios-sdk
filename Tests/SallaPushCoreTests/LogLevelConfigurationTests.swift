import Foundation
@testable import SallaPushCore
import XCTest

/// An Info.plist `SallaPushLogLevel` that is not a level is reported once (WARN `api.invalid_argument`, naming the
/// cleaned value and the accepted names) and ignored, in the app and in the extension, with the names Android accepts
/// (`warning` for `warn`; `none` is not a level on either SDK). A failure's console line names the status, code and
/// request id its message lacks.
final class LogLevelConfigurationTests: XCTestCase {
    private final class Console: @unchecked Sendable {
        let lines = Locked<[(category: String, text: String)]>([])
        var texts: [String] { lines.current.map(\.text) }
    }

    private func makeLogger(_ configured: ConfiguredLogLevel?, console: Console, category: String? = nil) -> SDKLogger {
        SDKLogger(categoryOverride: category,
                  plistLevelReader: { configured },
                  consoleSink: { _, category, line in console.lines.withLock { $0.append((category, line)) } },
                  handlerQueue: DispatchQueue(label: "test.log.level"))
    }

    private let accepted = "(accepted: off, error, warn, info, debug, verbose)"

    func test_aValueThatIsNotALevel_isReportedOnce_withTheAcceptedNames_andIgnored() {
        let console = Console()
        let logger = makeLogger(.text("verbos"), console: console)
        logger.log(.registerOk, "registered")
        logger.log(.tokenMissing, "no token")
        logger.log(.tokenMissing, "no token")
        XCTAssertEqual(logger.consoleLevel, .warn, "the default applies")
        XCTAssertEqual(console.texts, [
            "[SallaPush] WARN api.invalid_argument: The SallaPushLogLevel Info.plist value \"verbos\" is not a log level "
                + "\(accepted); it is ignored.",
            "[SallaPush] WARN token.missing: no token",
            "[SallaPush] WARN token.missing: no token",
        ])
    }

    func test_theReportedValue_isPrintableASCII_andCut() {
        let console = Console()
        let logger = makeLogger(.text("ver\u{1}b\u{E9}se" + String(repeating: "x", count: 50)), console: console)
        logger.log(.tokenMissing, "no token")
        let shown = "ver?b?se" + String(repeating: "x", count: 24)
        XCTAssertEqual(console.texts.first,
                       "[SallaPush] WARN api.invalid_argument: The SallaPushLogLevel Info.plist value \"\(shown)\" is not a "
                           + "log level \(accepted); it is ignored.")
    }

    func test_aValueThatIsNotAString_isReported() {
        let console = Console()
        let logger = makeLogger(.notText("a number (5)"), console: console)
        logger.log(.tokenMissing, "no token")
        XCTAssertEqual(console.texts.first,
                       "[SallaPush] WARN api.invalid_argument: The SallaPushLogLevel Info.plist value is a number (5), not the "
                           + "name of a log level \(accepted); it is ignored.")
    }

    func test_configuredLevel_describesEveryPlistType() {
        XCTAssertNil(SDKLogger.configuredLevel(nil))
        XCTAssertEqual(SDKLogger.configuredLevel("debug"), .text("debug"))
        XCTAssertEqual(SDKLogger.configuredLevel(NSNumber(value: 5)), .notText("a number (5)"))
        XCTAssertEqual(SDKLogger.configuredLevel(NSNumber(value: true)), .notText("a boolean"))
        XCTAssertEqual(SDKLogger.configuredLevel(["debug"]), .notText("an array"))
        XCTAssertEqual(SDKLogger.configuredLevel(["level": "debug"]), .notText("a dictionary"))
        XCTAssertEqual(SDKLogger.configuredLevel(Date()), .notText("a date"))
        XCTAssertEqual(SDKLogger.configuredLevel(Data()), .notText("data"))
    }

    func test_validValues_theAndroidAlias_andAnEmptyValue_areNotReported() {
        XCTAssertEqual(SallaPushLogLevel(name: "WARNING"), .warn)
        let cases: [(String, SallaPushLogLevel)] = [(" OFF ", .off), ("off", .off), (" debug ", .debug), ("Warning", .warn),
                                                    ("  ", .warn)]
        for (value, level) in cases {
            let console = Console()
            let logger = makeLogger(.text(value), console: console)
            logger.log(.registerDormant, "dormant")
            XCTAssertEqual(logger.consoleLevel, level, value)
            XCTAssertFalse(console.texts.contains { $0.contains("api.invalid_argument") }, value)
        }
    }

    /// `none` is not a level on either SDK (the silent level is `off`). It is reported once, like any other value that
    /// is not a level, and the console keeps the default `warn`, as on the Android SDK.
    func test_none_isNotALevel_reportedOnce_andTheConsoleKeepsWarn() {
        XCTAssertNil(SallaPushLogLevel(name: "none"))
        XCTAssertNil(SallaPushLogLevel(name: " None "))
        let console = Console()
        let logger = makeLogger(.text("none"), console: console)
        logger.log(.tokenMissing, "no token")
        logger.log(.tokenMissing, "no token")
        XCTAssertEqual(logger.consoleLevel, .warn)
        XCTAssertEqual(console.texts, [
            "[SallaPush] WARN api.invalid_argument: The SallaPushLogLevel Info.plist value \"none\" is not a log level "
                + "\(accepted); it is ignored.",
            "[SallaPush] WARN token.missing: no token",
            "[SallaPush] WARN token.missing: no token",
        ])
    }

    /// The extension's logger reads the extension's own Info.plist and reports there, in its category.
    func test_theExtensionLogger_reportsInItsCategory() {
        let console = Console()
        let logger = makeLogger(.text("loud"), console: console, category: "extension")
        logger.log(.nseExpired, "expired")
        XCTAssertEqual(console.lines.current.first?.category, "extension")
        XCTAssertTrue(console.lines.current.first?.text.contains("api.invalid_argument") ?? false)
    }

    func test_theReport_isMadeOnce_whenManyThreadsLogFirst() {
        let console = Console()
        let logger = makeLogger(.text("loud"), console: console)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            logger.log(.tokenMissing, "no token")
        }
        XCTAssertEqual(console.texts.filter { $0.contains("api.invalid_argument") }.count, 1)
        XCTAssertEqual(console.texts.filter { $0.contains("token.missing") }.count, 64)
    }

    // MARK: - Console lines of failures

    func test_consoleLine_addsTheStatusCodeAndRequestId_thatTheMessageLacks() {
        func line(_ message: String, _ metadata: [String: String]) -> String {
            SDKLogger.line(for: SallaPushLogEntry(level: .warn, category: "network", code: "net.rate_limited",
                                                  message: message, metadata: metadata, date: Date()))
        }
        let failure = ["http_status": "429", "error_code": "rate_limited", "request_id": "req-1", "app_id": "st_42_ios"]
        XCTAssertEqual(line("Rate limited (429); retry in 60 s.", failure),
                       "[SallaPush] WARN net.rate_limited: Rate limited (429); retry in 60 s. [rate_limited, request req-1]")
        XCTAssertEqual(line("Busy.", failure), "[SallaPush] WARN net.rate_limited: Busy. [HTTP 429, rate_limited, request req-1]")
        XCTAssertEqual(line("Rejected (429 rate_limited, request req-1).", failure),
                       "[SallaPush] WARN net.rate_limited: Rejected (429 rate_limited, request req-1).")
        XCTAssertEqual(line("Done.", ["count": "3"]), "[SallaPush] WARN net.rate_limited: Done.")
    }
}
