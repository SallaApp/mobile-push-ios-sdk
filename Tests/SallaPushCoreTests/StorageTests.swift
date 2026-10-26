import Foundation
@testable import SallaPushCore
import XCTest

final class FileStoreTests: XCTestCase {
    private var root: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-files-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_writeThenRead_roundTrips() throws {
        let store = FileStore(root: root)
        XCTAssertTrue(store.write("st_42_ios/abcd1234/state.json", data: Data("{}".utf8)))
        guard case let .data(data) = store.read("st_42_ios/abcd1234/state.json") else {
            return XCTFail("expected data")
        }
        XCTAssertEqual(data, Data("{}".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url("st_42_ios/abcd1234/state.json").path))
    }

    func test_missingFile_isNotFound() {
        guard case .notFound = FileStore(root: root).read("nope.json") else {
            return XCTFail("expected notFound")
        }
    }

    func test_folders_listsDirectoriesOnly() {
        let store = FileStore(root: root)
        store.write("a/x/identity.json", data: Data("1".utf8))
        store.write("b/y/identity.json", data: Data("1".utf8))
        store.write("file.json", data: Data("1".utf8))
        XCTAssertEqual(store.folders(in: ""), ["a", "b"])
        XCTAssertEqual(store.folders(in: "a"), ["x"])
    }

    func test_move_replacesTheDestination() {
        let store = FileStore(root: root)
        store.write("s.json", data: Data("new".utf8))
        store.write("s.corrupt.json", data: Data("old".utf8))
        XCTAssertTrue(store.move("s.json", to: "s.corrupt.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url("s.json").path))
        guard case let .data(data) = store.read("s.corrupt.json") else { return XCTFail("expected data") }
        XCTAssertEqual(data, Data("new".utf8))
    }

    func test_failedWrite_returnsFalse_andRemoveReportsWhetherTheFileIsGone() throws {
        struct Refused: Error {}
        let refusing = FileStore(root: root, writer: { _, _ in throw Refused() }, remover: { _ in throw Refused() })
        XCTAssertFalse(refusing.write("a/b.json", data: Data("1".utf8)))
        XCTAssertTrue(refusing.remove("missing.json"), "a missing file counts as removed")
        let store = FileStore(root: root)
        XCTAssertTrue(store.write("kept.json", data: Data("1".utf8)))
        XCTAssertFalse(refusing.remove("kept.json"), "the file is still there")
        XCTAssertTrue(store.remove("kept.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url("kept.json").path))
    }

    func test_onlyADataProtectionDenial_isProtectedDataUnavailable() {
        let protected = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        let permission = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                                 userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        XCTAssertTrue(FileStore.isProtectedDataDenial(protected))
        XCTAssertTrue(FileStore.isProtectedDataDenial(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertFalse(FileStore.isProtectedDataDenial(permission))
        XCTAssertFalse(FileStore.isProtectedDataDenial(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        XCTAssertFalse(FileStore.isProtectedDataDenial(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)))
    }

    func test_unreadableFile_isAFailure_notProtectedData() throws {
        try XCTSkipIf(geteuid() == 0, "file modes do not stop root")
        let store = FileStore(root: root)
        XCTAssertTrue(store.write("locked.json", data: Data("{}".utf8)))
        let path = store.url("locked.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        guard case .failed = store.read("locked.json") else {
            return XCTFail("a plain permission error must not look like protected data")
        }
    }

    func test_rootIsExcludedFromBackup() throws {
        let store = FileStore(root: root)
        store.write("a/b.json", data: Data("1".utf8))
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    /// What SallaPush reads back from its files and the Keychain is decoded only when it is UTF-8
    /// and nested at most 32 levels, so a corrupt or tampered file never reaches the recursive parser. On a 512 KB
    /// thread, the engine queue's stack size.
    func test_storedJSON_decodesOnlyShallowUTF8() throws {
        struct Probe: Decodable, Equatable { let v: Int }
        let deep = Data(("{\"v\":1,\"x\":" + String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000) + "}").utf8)
        let decoded = Locked<[Probe?]>([])
        let done = expectation(description: "decoded")
        let thread = Thread {
            for data in [Data(#"{"v":1}"#.utf8), deep, APIClientTests.utf16HidingItsBrackets(levels: 10_000),
                         #"{"v":1}"#.data(using: .utf16LittleEndian) ?? Data()] {
                decoded.withLock { $0.append(StoredJSON.decode(Probe.self, from: data)) }
            }
            done.fulfill()
        }
        thread.stackSize = 512 * 1_024
        thread.start()
        wait(for: [done], timeout: 30)
        XCTAssertEqual(decoded.current, [Probe(v: 1), nil, nil, nil])
    }
}

final class HostTagTests: XCTestCase {
    func test_tag_isEightHexOfTheLowercasedOrigin() throws {
        let upper = try XCTUnwrap(URL(string: "HTTPS://Push.Salla.dev/prefix"))
        let lower = try XCTUnwrap(URL(string: "https://push.salla.dev"))
        XCTAssertEqual(HostTag.make(for: upper), HostTag.make(for: lower))
        XCTAssertEqual(HostTag.make(for: lower), String(Fingerprint.sha256Hex(Data("https://push.salla.dev".utf8)).prefix(8)))
        let other = try XCTUnwrap(URL(string: "https://push.example.com"))
        XCTAssertNotEqual(HostTag.make(for: other), HostTag.make(for: lower))
        let port = try XCTUnwrap(URL(string: "http://localhost:8787"))
        XCTAssertEqual(HostTag.origin(of: port), "http://localhost:8787")
    }

    func test_apiBase_validation() {
        XCTAssertNotNil(APIBase.validated(URL(string: "https://push.salla.dev/")))
        XCTAssertEqual(APIBase.validated(URL(string: "https://push.salla.dev/"))?.string, "https://push.salla.dev")
        XCTAssertNotNil(APIBase.validated(URL(string: "http://localhost:8787")))
        XCTAssertNotNil(APIBase.validated(URL(string: "http://127.0.0.1:8787")))
        XCTAssertNil(APIBase.validated(URL(string: "http://push.salla.dev")))
        XCTAssertNil(APIBase.validated(URL(string: "ftp://push.salla.dev")))
        XCTAssertNil(APIBase.validated(URL(string: "https://user:pass@push.salla.dev")))
        XCTAssertNil(APIBase.validated(URL(string: "https://push.salla.dev?x=1")))
        XCTAssertNil(APIBase.validated(nil))
        XCTAssertEqual(APIBase.production.string, "https://api.salla.dev/notifications/v1/sallapush")
    }

    /// A base with a path (the default's `/notifications/sallapush`, where push-service serves `/v1`) keeps it in every
    /// route's URL; its stored state is partitioned by the host alone, as for any base.
    func test_apiBase_withAPath() throws {
        let local = try XCTUnwrap(APIBase.validated(URL(string: "http://localhost:8787/notifications/sallapush/")))
        XCTAssertEqual(local.string, "http://localhost:8787/notifications/sallapush")
        XCTAssertEqual(local.url(for: .events(deviceId: "x"))?.absoluteString,
                       "http://localhost:8787/notifications/sallapush/devices/x/events")
        XCTAssertEqual(APIBase.production.url(for: .register(appId: "st_42_ios"))?.absoluteString,
                       "https://api.salla.dev/notifications/v1/sallapush/apps/st_42_ios/devices")
        let host = try XCTUnwrap(URL(string: "https://api.salla.dev"))
        XCTAssertEqual(APIBase.production.hostTag, HostTag.make(for: host))
        XCTAssertNil(APIBase.validated(URL(string: "https://api.salla.dev/notifications/v1/sallapush?x=1")))
        XCTAssertNil(APIBase.validated(URL(string: "https://api.salla.dev/notifications/v1/sallapush#v1")))
    }
}

final class InboxTests: XCTestCase {
    private var folder: URL = FileManager.default.temporaryDirectory
    private let now: Double = 1_790_000_000

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-inbox-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func test_folder_isUnderTheContainersApplicationSupport() {
        let container = URL(fileURLWithPath: "/group")
        XCTAssertEqual(Inbox.folder(inContainer: container).path, "/group/Library/Application Support/SallaPush/inbox")
    }

    func test_write_isAtomic_andIngestDeletes() throws {
        let inbox = Inbox(folder: folder)
        XCTAssertEqual(inbox.writeReceived(messageId: "msg_ab", at: now), .written)
        XCTAssertEqual(names.count, 1)
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(name.hasPrefix("1790000000000-"))
        XCTAssertTrue(name.hasSuffix(".json"))
        let ingestion = inbox.ingest(now: now)
        XCTAssertEqual(ingestion.records, [InboxRecord(messageId: "msg_ab", at: now)])
        XCTAssertTrue(names.isEmpty)
    }

    /// The extension writes `at` in UTC with milliseconds, the form push-service needs; a file an earlier version's
    /// extension wrote, without a fraction, is read all the same.
    func test_at_isWrittenWithMilliseconds_andTheOldFormIsRead() throws {
        let inbox = Inbox(folder: folder)
        XCTAssertEqual(inbox.writeReceived(messageId: "msg_ab", at: now + 0.123), .written)
        let name = try XCTUnwrap(names.first)
        XCTAssertTrue(name.hasPrefix("1790000000123-"), name)
        let data = try Data(contentsOf: folder.appendingPathComponent(name))
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(written["at"] as? String, "2026-09-21T14:13:20.123Z")
        try Data(#"{"v":1,"type":"received","message_id":"msg_cd","at":"2026-09-21T14:13:19Z"}"#.utf8)
            .write(to: folder.appendingPathComponent("1789999999000-old.json"))
        let ingestion = inbox.ingest(now: now)
        XCTAssertEqual(ingestion.records.map(\.messageId), ["msg_cd", "msg_ab"])
        XCTAssertEqual(ingestion.records.first?.at, now - 1)
        XCTAssertEqual(try XCTUnwrap(ingestion.records.last?.at), now + 0.123, accuracy: 0.000_5)
        XCTAssertEqual(ingestion.invalidRemoved, 0)
        XCTAssertTrue(names.isEmpty)
    }

    func test_temporaryFiles_areIgnored_untilAnHourOld() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fresh = folder.appendingPathComponent("1790000000000-a.json.tmp")
        let stale = folder.appendingPathComponent("1789990000000-b.json.tmp")
        try Data("{}".utf8).write(to: fresh)
        try Data("{}".utf8).write(to: stale)
        let ingestion = Inbox(folder: folder).ingest(now: now)
        XCTAssertTrue(ingestion.records.isEmpty)
        XCTAssertEqual(names, ["1790000000000-a.json.tmp"])
    }

    func test_invalidFile_isKeptUntilAnHourOld() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("1790000000000-a.json"))
        try Data(#"{"v":1,"type":"received","message_id":"bad","at":"2026-09-21T14:13:20Z"}"#.utf8)
            .write(to: folder.appendingPathComponent("1789990000000-b.json"))
        let ingestion = Inbox(folder: folder).ingest(now: now)
        XCTAssertTrue(ingestion.records.isEmpty)
        XCTAssertEqual(ingestion.invalidRemoved, 1)
        XCTAssertEqual(names, ["1790000000000-a.json"])
    }

    /// App Group files are read bounded and gated before the recursive JSON parser, so a deeply
    /// nested, huge or UTF-16 file is an invalid file, never a crash or an unbounded read. Run on a 512 KB thread.
    func test_deepOrHugeFiles_areInvalid_onASmallStack() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let deep = "{\"v\":" + String(repeating: "{\"a\":", count: 10_000) + "1" + String(repeating: "}", count: 10_000) + "}"
        try Data(deep.utf8).write(to: folder.appendingPathComponent("1789990000000-deep.json"))
        try Data(repeating: 0x20, count: 2_000_000).write(to: folder.appendingPathComponent("1789990000001-huge.json"))
        try APIClientTests.utf16HidingItsBrackets(levels: 1_000).write(to: folder.appendingPathComponent("1789990000003-utf16.json"))
        let valid = #"{"v":1,"type":"received","message_id":"msg_ab","at":"2026-09-21T14:13:20Z"}"#
        try Data(valid.utf8).write(to: folder.appendingPathComponent("1789990000002-ok.json"))
        let result = Locked<Inbox.Ingestion?>(nil)
        let done = expectation(description: "ingested")
        let inbox = Inbox(folder: folder)
        let now = self.now
        let thread = Thread {
            result.set(inbox.ingest(now: now))
            done.fulfill()
        }
        thread.stackSize = 512 * 1_024
        thread.start()
        wait(for: [done], timeout: 30)
        let ingestion = try XCTUnwrap(result.current)
        XCTAssertEqual(ingestion.records.map(\.messageId), ["msg_ab"])
        XCTAssertEqual(ingestion.invalidRemoved, 3)
        XCTAssertTrue(names.isEmpty)
        XCTAssertNil(Inbox.decode(Data(repeating: 0x20, count: Inbox.maximumFileBytes + 1)))
    }

    func test_capacity_stopsWriting() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<Inbox.capacity {
            try Data().write(to: folder.appendingPathComponent("1-\(index).json"))
        }
        XCTAssertEqual(Inbox(folder: folder).writeReceived(messageId: "msg_ab", at: now), .full)
    }

    func test_missingFolder_ingestsNothing() {
        XCTAssertTrue(Inbox(folder: folder).ingest(now: now).records.isEmpty)
    }
}
