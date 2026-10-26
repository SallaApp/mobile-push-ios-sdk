import Foundation
import SallaPushCore
@testable import SallaPushExtension
import XCTest

/// Serves scripted image answers without a network: the answer and a first burst of bytes, then the rest only if
/// the client has not cancelled within 5 s. Records how many bytes went out and whether the client cancelled.
final class StubImageProtocol: URLProtocol {
    struct Script {
        let status: Int
        let headers: [String: String]
        let firstBurst: Data
        let rest: Data
    }

    static let scripts = Locked<[String: Script]>([:])
    static let served = Locked<[String: Int]>([:])
    static let cancelled = Locked<Set<String>>([])
    static let timedOut = Locked<Set<String>>([])

    private let stop = DispatchSemaphore(value: 0)
    private let waitQueue = DispatchQueue(label: "test.image.stub")

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "img.sallapush.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let url = request.url, let script = Self.scripts.current[path],
              let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1",
                                             headerFields: script.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: script.firstBurst)
        Self.served.withLock { $0[path, default: 0] += script.firstBurst.count }
        guard !script.rest.isEmpty else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let stop = self.stop
        waitQueue.async {
            // The downloader is expected to cancel after the first burst; the rest never goes out.
            if stop.wait(timeout: .now() + 5) == .timedOut {
                Self.timedOut.withLock { _ = $0.insert(path) }
            }
        }
    }

    override func stopLoading() {
        let path = request.url?.path ?? ""
        Self.cancelled.withLock { _ = $0.insert(path) }
        stop.signal()
    }
}

final class AttachmentDownloaderTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sallapush-download-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func download(_ path: String, _ script: StubImageProtocol.Script) throws -> AttachmentDownloadResult {
        StubImageProtocol.scripts.withLock { $0[path] = script }
        let downloader = URLSessionAttachmentDownloader(temporaryDirectory: directory, protocolClasses: [StubImageProtocol.self])
        let result = Locked<AttachmentDownloadResult?>(nil)
        let done = expectation(description: "download \(path)")
        _ = downloader.download(try XCTUnwrap(URL(string: "https://img.sallapush.test" + path))) { answer in
            result.set(answer)
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        return try XCTUnwrap(result.current)
    }

    private func served(_ path: String) -> Int { StubImageProtocol.served.current[path] ?? 0 }

    func test_smallImage_isDownloaded_andMoved() throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let result = try download("/small.png", .init(status: 200, headers: ["Content-Type": "image/png"], firstBurst: png,
                                                      rest: Data()))
        guard case let .success(file) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(file.typeIdentifier, "public.png")
        XCTAssertEqual(try Data(contentsOf: file.fileURL), png)
    }

    func test_declaredOversizedImage_isCancelledAfterTheFirstBytes() throws {
        let declared = String(AttachmentRules.maximumBytes * 5)
        let result = try download("/declared.jpg", .init(status: 200, headers: ["Content-Length": declared],
                                                         firstBurst: Data(count: 64 * 1_024),
                                                         rest: Data(count: 1_024 * 1_024)))
        XCTAssertEqual(result, .failure("image larger than 10 MB"))
        XCTAssertTrue(StubImageProtocol.cancelled.current.contains("/declared.jpg"), "the download was cancelled")
        XCTAssertFalse(StubImageProtocol.timedOut.current.contains("/declared.jpg"))
        XCTAssertEqual(served("/declared.jpg"), 64 * 1_024, "only the first bytes went out")
    }

    func test_undeclaredOversizedImage_isCancelledOnceItPasses10MB() throws {
        let limit = Int(AttachmentRules.maximumBytes)
        let result = try download("/undeclared.jpg", .init(status: 200, headers: [:], firstBurst: Data(count: limit + 1_024),
                                                           rest: Data(count: 1_024 * 1_024)))
        XCTAssertEqual(result, .failure("image larger than 10 MB"))
        XCTAssertTrue(StubImageProtocol.cancelled.current.contains("/undeclared.jpg"))
        XCTAssertFalse(StubImageProtocol.timedOut.current.contains("/undeclared.jpg"))
        XCTAssertEqual(served("/undeclared.jpg"), limit + 1_024)
    }

    func test_errorStatus_isCancelledAtTheFirstBytes() throws {
        let result = try download("/missing.png", .init(status: 404, headers: [:], firstBurst: Data(count: 512),
                                                        rest: Data(count: 1_024 * 1_024)))
        XCTAssertEqual(result, .failure("HTTP 404"))
        XCTAssertTrue(StubImageProtocol.cancelled.current.contains("/missing.png"))
        XCTAssertFalse(StubImageProtocol.timedOut.current.contains("/missing.png"))
    }

    func test_earlyRejection_rules() throws {
        let url = try XCTUnwrap(URL(string: "https://img.sallapush.test/a.png"))
        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
        let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])
        let limit = AttachmentRules.maximumBytes
        let reject = URLSessionAttachmentDownloader.earlyRejection
        XCTAssertNil(reject(success, limit, limit), "exactly 10 MB is allowed")
        XCTAssertNil(reject(success, 10, -1), "an unknown length goes on")
        XCTAssertEqual(reject(success, 10, limit + 1), "image larger than 10 MB")
        XCTAssertEqual(reject(success, limit + 1, -1), "image larger than 10 MB")
        XCTAssertEqual(reject(missing, 1, 1), "HTTP 404")
    }
}
