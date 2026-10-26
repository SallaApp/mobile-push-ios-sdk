@testable import SallaPush
@testable import SallaPushCore
import XCTest

/// The buffer keeps call order whatever order calls reach it in: a call the engine hands back can be older than the
/// calls buffered since, and it must neither replace nor supersede a later one.
final class PreInitBufferTests: XCTestCase {
    private func token(_ hex: String) -> PushToken {
        PushToken(hex: String(repeating: hex, count: 64))
    }

    private func login(_ customer: String) -> PublicCall {
        .login(externalId: customer, token: SecretString("eyJ." + customer))
    }

    func test_anOlderCall_takesItsPlaceInCallOrder_andNeverReplacesALaterOne() throws {
        var buffer = PreInitBuffer()
        XCTAssertEqual(buffer.append(login("cust_b"), sequence: 6), [])
        XCTAssertEqual(buffer.append(login("cust_a"), sequence: 5), [5], "the later login supersedes it")
        XCTAssertEqual(buffer.append(.logout, sequence: 4), [], "a later login does not supersede a logout")
        XCTAssertEqual(buffer.append(.pushToken(token("b")), sequence: 8), [])
        XCTAssertEqual(buffer.append(.pushToken(token("a")), sequence: 2), [])
        XCTAssertEqual(buffer.append(.refreshPermission, sequence: 10), [])
        XCTAssertEqual(buffer.append(.refreshPermission, sequence: 1), [])
        let calls = buffer.drain().calls
        XCTAssertEqual(calls.map(\.sequence), [4, 6, 8, 10])
        guard case let .login(customer, identityToken) = calls[1].call else { return XCTFail("the later login is kept") }
        XCTAssertEqual(customer, "cust_b")
        XCTAssertEqual(identityToken.revealed, "eyJ.cust_b")
        guard case let .pushToken(kept) = calls[2].call else { return XCTFail("the later token is kept") }
        XCTAssertEqual(kept, token("b"))
    }

    func test_anOlderLogout_removesOnlyTheIdentityCallsMadeBeforeIt() {
        var buffer = PreInitBuffer()
        buffer.append(login("cust_a"), sequence: 1)
        buffer.append(login("cust_c"), sequence: 7)
        XCTAssertEqual(buffer.append(.logout, sequence: 5), [], "the later login replaced the first one already")
        XCTAssertEqual(buffer.drain().calls.map(\.sequence), [5, 7])

        var withEarlierLogin = PreInitBuffer()
        withEarlierLogin.append(.addTags(["k": "v"]), sequence: 1)
        withEarlierLogin.append(login("cust_a"), sequence: 2)
        withEarlierLogin.append(.logout, sequence: 3)
        withEarlierLogin.append(login("cust_c"), sequence: 9)
        XCTAssertEqual(withEarlierLogin.append(.logout, sequence: 6), [3])
        XCTAssertEqual(withEarlierLogin.drain().calls.map(\.sequence), [1, 6, 9])
    }

    /// On overflow the oldest entry in call order goes, even when it reached the buffer last.
    func test_overflow_dropsTheOldestEntryInCallOrder() {
        var buffer = PreInitBuffer()
        for sequence in 2...(PreInitBuffer.maximumCalls + 1) {
            buffer.append(.addTags(["k\(sequence)": "v"]), sequence: sequence)
        }
        XCTAssertEqual(buffer.append(.addTags(["k1": "v"]), sequence: 1), [1])
        for sequence in 2...(PreInitBuffer.maximumTaps + 1) {
            buffer.append(.events([EventRecord(messageId: "m\(sequence)", type: .opened, at: 0)]), sequence: sequence)
        }
        buffer.append(.events([EventRecord(messageId: "m1", type: .opened, at: 0)]), sequence: 1)
        let drained = buffer.drain()
        XCTAssertEqual(drained.dropped, PreInitBuffer.Dropped(calls: 1, events: 1))
        let messages = drained.calls.compactMap { entry -> String? in
            guard case let .events(records) = entry.call else { return nil }
            return records.first?.messageId
        }
        XCTAssertEqual(messages.count, PreInitBuffer.maximumTaps)
        XCTAssertFalse(messages.contains("m1"), "the oldest tap is the one dropped")
        XCTAssertEqual(drained.calls.filter { if case .addTags = $0.call { return true }; return false }.map(\.sequence),
                       Array(2...(PreInitBuffer.maximumCalls + 1)))
    }

    /// The records of one call stay in their order.
    func test_theRecordsOfOneCall_keepTheirOrder() {
        var buffer = PreInitBuffer()
        let records = (0..<3).map { EventRecord(messageId: "m\($0)", type: .received, at: Double($0)) }
        buffer.append(.events(records), sequence: 4)
        buffer.append(.events([EventRecord(messageId: "early", type: .received, at: 0)]), sequence: 2)
        let messages = buffer.drain().calls.compactMap { entry -> String? in
            guard case let .events(records) = entry.call else { return nil }
            return records.first?.messageId
        }
        XCTAssertEqual(messages, ["early", "m0", "m1", "m2"])
    }
}
