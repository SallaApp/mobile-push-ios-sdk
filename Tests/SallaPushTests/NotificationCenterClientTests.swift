import Foundation
@testable import SallaPush
@testable import SallaPushCore
import UserNotifications
import XCTest

/// The `Once` rule: every system completion of the notification center goes
/// through `Once`; one the system calls again is ignored, with DEBUG `api.callback_repeated` once per call site.
final class NotificationCenterClientTests: XCTestCase {
    /// A notification center that calls every completion twice, on another queue, as a misbehaving system would.
    final class TwiceCalling: UserNotificationCenterBackend, @unchecked Sendable {
        let queue = DispatchQueue(label: "test.twice")
        let removed = Locked<[[String]]>([])

        private func twice(_ body: @escaping @Sendable () -> Void) {
            queue.async {
                body()
                body()
            }
        }

        func authorizationStatus(_ completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
            twice { completion(.authorized) }
        }

        func requestAuthorization(options: UNAuthorizationOptions, _ completion: @escaping @Sendable (Bool) -> Void) {
            twice { completion(true) }
        }

        func deliveredNotifications(_ completion: @escaping @Sendable ([DeliveredNotification]) -> Void) {
            twice { completion([DeliveredNotification(identifier: "n1", userInfo: [:])]) }
        }

        func removeDeliveredNotifications(identifiers: [String]) {
            removed.withLock { $0.append(identifiers) }
        }

        func add(_ request: UNNotificationRequest, _ completion: @escaping @Sendable (Error?) -> Void) {
            twice { completion(nil) }
        }

        func setBadgeCount(_ count: Int) -> Bool { true }

        func hasDelegate(_ completion: @escaping @Sendable (Bool) -> Void) {
            completion(true)
        }
    }

    func test_systemCompletionsCalledTwice_runOnce_andAreLoggedAsRepeated_oncePerCallSite() {
        let logs = LogCapture()
        let backend = TwiceCalling()
        let client = SystemNotificationCenterClient(logger: logs.logger, backend: { backend })
        let calls = Locked<[String]>([])
        for _ in 0..<2 {
            client.authorizationStatus { status in calls.withLock { $0.append("status \(status.name)") } }
            client.requestAuthorization(provisional: false) { granted in calls.withLock { $0.append("granted \(granted)") } }
            client.deliveredNotifications { delivered in calls.withLock { $0.append("delivered \(delivered.count)") } }
            let copy = LocalNotificationRequest(identifier: "sallapush.local.msg_ab", title: "t", subtitle: nil, body: "b",
                                                sound: "default", badge: 1, threadId: nil, userInfo: ["sp_local": "1"])
            client.add(copy) { error in calls.withLock { $0.append("added \(error ?? "ok")") } }
        }
        backend.queue.sync {}
        XCTAssertEqual(calls.current.sorted(), ["added ok", "added ok", "delivered 1", "delivered 1", "granted true",
                                                "granted true", "status authorized", "status authorized"],
                       "each completion ran once per call")
        let repeated = logs.all.filter { $0.code == "api.callback_repeated" }
        XCTAssertEqual(repeated.map(\.message).sorted(), [
            "The system called the add completion more than once; extra calls ignored.",
            "The system called the getDeliveredNotifications completion more than once; extra calls ignored.",
            "The system called the getNotificationSettings completion more than once; extra calls ignored.",
            "The system called the requestAuthorization completion more than once; extra calls ignored.",
        ], "once per call site")
        XCTAssertTrue(repeated.allSatisfy { $0.level == .debug })
    }

    /// Outside an app bundle (test runners) there is no notification center: each call answers at once with its default
    /// and logs nothing.
    func test_withoutANotificationCenter_everyCallAnswersItsDefault() {
        let logs = LogCapture()
        let client = SystemNotificationCenterClient(logger: logs.logger, backend: { nil })
        let answers = Locked<[String]>([])
        client.authorizationStatus { status in answers.withLock { $0.append(status.name) } }
        client.requestAuthorization(provisional: true) { granted in answers.withLock { $0.append("\(granted)") } }
        client.deliveredNotifications { delivered in answers.withLock { $0.append("\(delivered.count)") } }
        client.add(LocalNotificationRequest(identifier: "x", title: nil, subtitle: nil, body: nil, sound: nil, badge: nil,
                                            threadId: nil, userInfo: [:])) { error in answers.withLock { $0.append(error ?? "ok") } }
        client.hasDelegate { hasDelegate in answers.withLock { $0.append("\(hasDelegate)") } }
        XCTAssertEqual(answers.current, ["notDetermined", "false", "0", "notification center unavailable", "true"])
        XCTAssertTrue(client.setBadgeCount(0))
        XCTAssertTrue(logs.all.isEmpty)
    }
}
