import Foundation
import SallaPushCore
@testable import SallaPushExtension
import XCTest

/// The receipts' live environment, with the system's own objects: the bundle id of the extension's app, the thread
/// check, the semaphore wait and the transport. Every other receipt test injects them.
final class ReceiptEnvironmentTests: XCTestCase {
    func test_containingAppURL_isTwoFoldersUpFromTheAppex() {
        let appex = URL(fileURLWithPath: "/var/containers/Bundle/Application/A1/Store.app/PlugIns/Service.appex",
                        isDirectory: true)
        XCTAssertEqual(ReceiptEnvironment.containingAppURL(ofExtensionAt: appex)?.path,
                       "/var/containers/Bundle/Application/A1/Store.app")
        XCTAssertNil(ReceiptEnvironment.containingAppURL(ofExtensionAt: URL(fileURLWithPath: "/Applications/Store.app")))
        XCTAssertNil(ReceiptEnvironment.containingAppURL(ofExtensionAt: URL(fileURLWithPath: "/tmp/Service.framework")))
    }

    /// The bundle id is the one in the Info.plist of the app two folders up, as an iOS app lays it out.
    func test_appBundleIdentifier_isTheContainingApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-app-\(UUID().uuidString)",
                                                                                isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Store.app", isDirectory: true)
        let appex = app.appendingPathComponent("PlugIns/Service.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.salla.store"],
                                                      format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertEqual(ReceiptEnvironment.appBundleIdentifier(ofExtensionAt: appex), "com.salla.store")
        XCTAssertNil(ReceiptEnvironment.appBundleIdentifier(ofExtensionAt: app), "not an .appex")
    }

    /// The live handler sends receipts, waits on a semaphore until signalled or out of time, and never on the main
    /// thread. The test runner is no `.appex`, so it has no containing app.
    func test_theLiveEnvironment_sendsReceipts() {
        let live = ReceiptEnvironment.live
        XCTAssertNotNil(ExtensionEnvironment.live.receipts)
        XCTAssertTrue(live.isMainThread(), "XCTest runs tests on the main thread")
        let onAQueue = Locked<Bool?>(nil)
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            onAQueue.set(live.isMainThread())
            answered.signal()
        }
        XCTAssertEqual(answered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(onAQueue.current, false, "the thread of a didReceive")
        XCTAssertNil(live.appBundleIdentifier())
        XCTAssertTrue((0..<1).contains(live.random()))
        let semaphore = DispatchSemaphore(value: 0)
        XCTAssertFalse(live.block(semaphore, 0), "out of time")
        semaphore.signal()
        XCTAssertTrue(live.block(semaphore, 5), "signalled")
        let transport = live.makeTransport(DispatchQueue(label: "test.receipt"))
        XCTAssertTrue(transport is URLSessionTransport)
        transport.invalidate()
    }
}
