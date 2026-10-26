import Foundation
@testable import SallaPushCore
import XCTest

/// Test fixtures: the vendored goldens and the generated provisioning profiles.
enum Fixtures {
    enum FixtureError: Error {
        case missing(String)
        case malformed(String)
    }

    static func url(_ relativePath: String) throws -> URL {
        guard let base = Bundle.module.resourceURL else { throw FixtureError.missing("resources") }
        let url = base.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FixtureError.missing(relativePath) }
        return url
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    static func json(_ relativePath: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data(relativePath)) as? [String: Any] else {
            throw FixtureError.malformed(relativePath)
        }
        return object
    }

    /// Converts the server's iOS send request (the golden shape) to the `userInfo` APNs delivers: `aps` from
    /// title/message/subtitle/badge/sound/thread-id/mutable_content, and the `data` keys at the top level.
    static func deliveredUserInfo(fromSendRequest notification: [String: Any]) -> [AnyHashable: Any] {
        var alert: [String: Any] = [:]
        if let title = notification["title"] as? String { alert["title"] = title }
        if let message = notification["message"] as? String { alert["body"] = message }
        if let subtitle = notification["subtitle"] as? String { alert["subtitle"] = subtitle }
        var aps: [String: Any] = ["alert": alert]
        if let badge = notification["badge"] { aps["badge"] = badge }
        if let sound = notification["sound"] { aps["sound"] = sound }
        if let thread = notification["thread-id"] { aps["thread-id"] = thread }
        if (notification["mutable_content"] as? Bool) == true { aps["mutable-content"] = 1 }
        var userInfo: [AnyHashable: Any] = ["aps": aps]
        for (key, value) in (notification["data"] as? [String: Any]) ?? [:] {
            userInfo[key] = value
        }
        return userInfo
    }

    /// The four iOS goldens as delivered payloads, keyed by file name.
    static func goldenPayloads() throws -> [String: [AnyHashable: Any]] {
        let native = try json("golden/c3-ios.json")
        guard let first = (native["notifications"] as? [[String: Any]])?.first else { throw FixtureError.malformed("c3-ios") }
        let pushRef = try json("golden/compat-push-ref.json")
        guard let ios = pushRef["ios"] as? [String: Any] else { throw FixtureError.malformed("compat-push-ref") }
        return [
            "c3-ios": deliveredUserInfo(fromSendRequest: first),
            "compat-ios": deliveredUserInfo(fromSendRequest: try json("golden/compat-ios.json")),
            "compat-ios-typed-data": deliveredUserInfo(fromSendRequest: try json("golden/compat-ios-typed-data.json")),
            "compat-push-ref": deliveredUserInfo(fromSendRequest: ios),
        ]
    }
}

/// Captures every log entry of a logger.
final class LogRecorder: @unchecked Sendable {
    private let entries = Locked<[SallaPushLogEntry]>([])
    let logger: SDKLogger

    init(category: String? = nil) {
        let entries = self.entries
        logger = SDKLogger(categoryOverride: category, plistLevelReader: { nil }, consoleSink: { _, _, _ in })
        logger.setTap { entry in entries.withLock { $0.append(entry) } }
    }

    var all: [SallaPushLogEntry] { entries.current }
    var codes: [String] { all.map(\.code) }

    func count(_ code: String) -> Int {
        all.filter { $0.code == code }.count
    }
}
