import Foundation
@testable import SallaPushCore
import XCTest

/// The badge files the app and its Notification Service Extension share: one mark per counted notification, the app's
/// settings, and the options every file and folder is written with.
final class BadgeStoreTests: XCTestCase {
    private var container: URL = FileManager.default.temporaryDirectory
    private let now: Double = 1_790_000_000

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-badge-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func store(_ bundle: String = "com.salla.test") throws -> BadgeStore {
        try XCTUnwrap(BadgeStore(container: container, appBundleIdentifier: bundle))
    }

    private func files(_ store: BadgeStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.folder.path)) ?? []).sorted()
    }

    private func writeMark(_ store: BadgeStore, _ identifier: String, body: String) throws {
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: store.folder.appendingPathComponent(BadgeStore.markName(identifier)))
    }

    // MARK: - Where the files are

    func test_theFolder_isTheAppsOwn_nextToTheInbox() throws {
        let store = try store()
        let inbox = Inbox.folder(inContainer: container)
        XCTAssertEqual(store.folder.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       inbox.deletingLastPathComponent().standardizedFileURL)
        XCTAssertEqual(store.folder.lastPathComponent, "com.salla.test")
        XCTAssertEqual(store.folder.deletingLastPathComponent().lastPathComponent, "badge")
        XCTAssertNotEqual(try self.store("com.salla.other").folder, store.folder, "one folder per app")
    }

    func test_aBundleIdThatCantNameAFolder_meansNoStore() {
        for bundle in [nil, "", ".", "..", "../x", "a/b", ".hidden", "-x", "com.salla test", "com.salla.تجربة",
                       String(repeating: "a", count: 256)] {
            XCTAssertNil(BadgeStore(container: container, appBundleIdentifier: bundle), bundle ?? "nil")
        }
        XCTAssertNotNil(BadgeStore(container: container, appBundleIdentifier: "com.Salla-Shop.app2"))
    }

    // MARK: - Counting

    func test_theSameIdTwice_countsOnce_andTwoIdsCountTwo() throws {
        let store = try store()
        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(store.add(identifier: "a", at: now), .added)
        XCTAssertEqual(store.add(identifier: "a", at: now + 1), .alreadyCounted, "a replacement or a duplicate")
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(store.add(identifier: "b", at: now), .added)
        XCTAssertEqual(store.count(), 2)
    }

    func test_remove_reset_andRemoveAll() throws {
        let store = try store()
        for identifier in ["a", "b", "c"] { XCTAssertEqual(store.add(identifier: identifier, at: now), .added) }
        XCTAssertTrue(store.writeSettings(BadgeSettings(autoUpdateBadge: true)))
        store.remove(identifier: "b")
        store.remove(identifier: "missing")
        XCTAssertEqual(store.count(), 2)
        store.reset()
        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(files(store), ["settings.json"], "a reset keeps the settings")
        XCTAssertEqual(store.add(identifier: "a", at: now), .added, "counted again after a reset")
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path))
        XCTAssertNil(store.readSettings())
        XCTAssertEqual(store.count(), 0)
    }

    func test_at999Marks_theNextAddIsFull_andTheCountStaysAt999() throws {
        let store = try store()
        for index in 0..<BadgeStore.capacity {
            XCTAssertEqual(store.add(identifier: "r\(index)", at: now), .added)
        }
        XCTAssertEqual(store.count(), 999)
        XCTAssertEqual(store.add(identifier: "one more", at: now), .full)
        XCTAssertEqual(store.add(identifier: "r7", at: now), .alreadyCounted, "a counted one is still known")
        XCTAssertEqual(store.count(), 999)
    }

    func test_addingSeveral_countsOnlyTheMissingOnes_once_upTo999() throws {
        let store = try store()
        XCTAssertEqual(store.add(identifier: "a", at: now - 3_600), .added)
        store.add(identifiers: ["a", "b", "b", "c"], at: now)
        XCTAssertEqual(store.count(), 3)
        XCTAssertEqual(store.prune(keeping: [], now: now), 2, "a keeps its time: only b and c are recent")
        store.add(identifiers: (0..<1_100).map { "r\($0)" }, at: now)
        XCTAssertEqual(files(store).count, BadgeStore.capacity)
        XCTAssertEqual(store.add(identifier: "b", at: now), .alreadyCounted)
    }

    func test_fileNames_holdNoRequestId() throws {
        let store = try store()
        let identifier = "sallapush.local.msg_ab12"
        XCTAssertEqual(store.add(identifier: identifier, at: now), .added)
        let names = files(store)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names.contains { $0.contains("msg_ab12") || $0.contains("sallapush") })
        XCTAssertEqual(names.first?.count, 37)
        let body = try String(contentsOf: store.folder.appendingPathComponent(try XCTUnwrap(names.first)), encoding: .utf8)
        XCTAssertEqual(body, #"{"at":1790000000,"v":1}"#)
        XCTAssertFalse(body.contains("msg_ab12"))
    }

    func test_aMarkThatAppearedMeanwhile_isAlreadyCounted_notAFailure() throws {
        let created = try store()
        let racing = try XCTUnwrap(BadgeStore(container: container, appBundleIdentifier: "com.salla.test",
                                              writer: { data, url, options in
                                                  // Another process creates the same mark just before this one.
                                                  try? data.write(to: url)
                                                  try BadgeStore.fileWriter(data, url, options)
                                              }))
        XCTAssertEqual(created.add(identifier: "other", at: now), .added)
        XCTAssertEqual(racing.add(identifier: "a", at: now), .alreadyCounted)
        XCTAssertEqual(created.count(), 2)
        let refusing = try XCTUnwrap(BadgeStore(container: container, appBundleIdentifier: "com.salla.test",
                                                writer: { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertEqual(refusing.add(identifier: "b", at: now), .failed)
        XCTAssertEqual(created.count(), 2)
    }

    func test_200NotificationsAtOnce_countExactly200() throws {
        let store = try store()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            _ = store.add(identifier: "request-\(index)", at: now)
            _ = store.add(identifier: "request-\(index)", at: now)
        }
        XCTAssertEqual(store.count(), 200)
    }

    // MARK: - Pruning

    func test_prune_keepsListedAndRecentMarks_andDropsTheRest() throws {
        let store = try store()
        XCTAssertEqual(store.add(identifier: "listed", at: now - 7_200), .added)
        XCTAssertEqual(store.add(identifier: "recent", at: now - 10), .added)
        XCTAssertEqual(store.add(identifier: "old", at: now - 3_600), .added)
        XCTAssertEqual(store.add(identifier: "ahead", at: now + 3_600), .added)
        XCTAssertEqual(store.add(identifier: "nearly ahead", at: now + 59), .added)
        try writeMark(store, "empty", body: "")
        try writeMark(store, "corrupt", body: "{")
        try writeMark(store, "other version", body: #"{"at":1790000000,"v":2}"#)
        XCTAssertEqual(store.count(), 8)
        XCTAssertEqual(store.prune(keeping: ["listed", "missing"], now: now), 3)
        XCTAssertEqual(store.count(), 3)
        XCTAssertEqual(store.add(identifier: "listed", at: now), .alreadyCounted)
        XCTAssertEqual(store.add(identifier: "recent", at: now), .alreadyCounted)
        XCTAssertEqual(store.add(identifier: "nearly ahead", at: now), .alreadyCounted)
        for dropped in ["old", "ahead", "empty", "corrupt", "other version"] {
            XCTAssertEqual(store.add(identifier: dropped, at: now), .added, dropped)
        }
    }

    func test_prune_keepsAnUnreadableMarkThatIsListed() throws {
        let store = try store()
        try writeMark(store, "listed", body: "")
        XCTAssertEqual(store.prune(keeping: ["listed"], now: now), 1)
        XCTAssertEqual(store.count(), 1)
    }

    // MARK: - Settings

    func test_settings_roundTrip_andAMissingCorruptOrNewerFileReadsAsNone() throws {
        let store = try store()
        XCTAssertNil(store.readSettings())
        XCTAssertTrue(store.writeSettings(BadgeSettings(autoUpdateBadge: false)))
        XCTAssertEqual(store.readSettings(), BadgeSettings(autoUpdateBadge: false))
        XCTAssertTrue(store.writeSettings(BadgeSettings(autoUpdateBadge: true)))
        XCTAssertEqual(store.readSettings(), BadgeSettings(autoUpdateBadge: true))
        let url = store.folder.appendingPathComponent("settings.json")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), #"{"auto_update_badge":true,"v":1}"#)
        for body in ["", "{", #"{"v":2,"auto_update_badge":true}"#, #"{"v":1}"#, #"{"v":1,"auto_update_badge":"yes"}"#,
                     "{\"v\":1,\"auto_update_badge\":true,\"x\":\"" + String(repeating: "x", count: 2_000) + "\"}"] {
            try Data(body.utf8).write(to: url)
            XCTAssertNil(store.readSettings(), String(body.prefix(40)))
        }
    }

    // MARK: - Protection and backup

    /// A folder the store asked the folder maker for.
    private struct MadeFolder: Equatable {
        let name: String
        let protection: FileProtectionType?
        /// Whether its parent was there already, so the call made this folder only.
        let parentExisted: Bool
    }

    /// No test run applies protection classes (macOS and the Simulator ignore them), so the options the store passes
    /// are what is checked; a device check covers the rest. A folder maker gives its attributes to every folder it
    /// creates, so only the `badge` folder and the app's folder are made without protection, each once its parent
    /// exists: the App Group's `Library`, `Application Support` and `SallaPush` folders keep the container's default,
    /// for the other files written there.
    func test_everyFile_isWrittenWithoutDataProtection_andTheFolderIsExcludedFromBackup() throws {
        let writes = Locked<[(name: String, options: Data.WritingOptions)]>([])
        let folders = Locked<[MadeFolder]>([])
        let store = try XCTUnwrap(BadgeStore(
            container: container, appBundleIdentifier: "com.salla.test",
            writer: { data, url, options in
                writes.withLock { $0.append((url.lastPathComponent, options)) }
                try BadgeStore.fileWriter(data, url, options)
            },
            makeFolder: { url, attributes in
                let parentExisted = FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
                let protection = attributes[.protectionKey] as? FileProtectionType
                let made = MadeFolder(name: url.lastPathComponent, protection: protection, parentExisted: parentExisted)
                folders.withLock { $0.append(made) }
                try BadgeStore.folderMaker(url, attributes)
            }))
        XCTAssertEqual(store.add(identifier: "a", at: now), .added)
        XCTAssertTrue(store.writeSettings(BadgeSettings(autoUpdateBadge: true)))
        XCTAssertEqual(store.add(identifier: "b", at: now), .added)
        XCTAssertEqual(writes.current.map(\.options), [[.withoutOverwriting, .noFileProtection], [.atomic, .noFileProtection],
                                                      [.withoutOverwriting, .noFileProtection]])
        XCTAssertEqual(writes.current.map(\.name)[1], "settings.json")
        XCTAssertEqual(folders.current, [
            MadeFolder(name: "SallaPush", protection: nil, parentExisted: false),
            MadeFolder(name: "badge", protection: FileProtectionType.none, parentExisted: true),
            MadeFolder(name: "com.salla.test", protection: FileProtectionType.none, parentExisted: true),
        ], "each folder is made once, and no parent of a folder without protection is made with it")
        let badge = store.folder.deletingLastPathComponent()
        XCTAssertEqual(try badge.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func test_aFolderThatCantBeCreated_failsEveryWrite() throws {
        let store = try XCTUnwrap(BadgeStore(container: container, appBundleIdentifier: "com.salla.test",
                                             makeFolder: { _, _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertEqual(store.add(identifier: "a", at: now), .failed)
        XCTAssertFalse(store.writeSettings(BadgeSettings(autoUpdateBadge: true)))
        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(store.prune(keeping: [], now: now), 0)
    }
}
