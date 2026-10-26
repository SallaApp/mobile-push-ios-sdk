import Foundation

/// The outcome of reading a stored file.
package enum FileReadResult: Sendable {
    case data(Data)
    case notFound
    /// The file exists but cannot be read before the first unlock. Never treated as a fresh install.
    case protectedDataUnavailable
    case failed(String)
}

/// Small JSON files under one root (`<Application Support>/SallaPush`). Writes are atomic, protected until the
/// first unlock and excluded from backups. No file-timestamp APIs are used.
package final class FileStore: Sendable {
    /// Reads the contents of a file URL.
    package typealias Reader = @Sendable (_ url: URL) throws -> Data
    /// Writes `data` to a file URL.
    package typealias Writer = @Sendable (_ data: Data, _ url: URL) throws -> Void
    /// Deletes the item at a file URL.
    package typealias Remover = @Sendable (_ url: URL) throws -> Void

    /// The root folder.
    package let root: URL
    private let reader: Reader
    private let writer: Writer
    private let remover: Remover

    /// - Parameters:
    ///   - reader: performs each read; the default reads the whole file.
    ///   - writer: performs each write; the default is an atomic, protected write.
    ///   - remover: deletes a file; the default uses `FileManager`.
    package init(root: URL, reader: @escaping Reader = FileStore.fileReader, writer: @escaping Writer = FileStore.atomicWriter,
                 remover: @escaping Remover = FileStore.itemRemover) {
        self.root = root
        self.reader = reader
        self.writer = writer
        self.remover = remover
    }

    /// `Data(contentsOf:)`.
    package static let fileReader: Reader = { url in
        try Data(contentsOf: url)
    }

    /// An atomic write, protected until the first unlock on iOS.
    package static let atomicWriter: Writer = { data, url in
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    /// `FileManager.removeItem(at:)`.
    package static let itemRemover: Remover = { url in
        try FileManager.default.removeItem(at: url)
    }

    /// The URL of a path relative to the root.
    package func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// Reads a file. Only the data-protection denial (EPERM) counts as protected data being unavailable; any other
    /// failure, a plain permission error (EACCES) included, is `.failed`.
    package func read(_ relativePath: String) -> FileReadResult {
        let fileURL = url(relativePath)
        do {
            return .data(try reader(fileURL))
        } catch {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .notFound }
            return Self.isProtectedDataDenial(error) ? .protectedDataUnavailable : .failed(LogSanitizer.describe(error))
        }
    }

    /// Whether a read failed because the file is protected until the first unlock: iOS answers EPERM, under the
    /// Cocoa "no permission" error, for a protected file while the device is locked.
    package static func isProtectedDataDenial(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return nsError.code == Int(EPERM) }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying.domain == NSPOSIXErrorDomain else { return false }
        return underlying.code == Int(EPERM)
    }

    /// Writes a file atomically, creating its folders. Returns false on failure.
    @discardableResult
    package func write(_ relativePath: String, data: Data) -> Bool {
        let fileURL = url(relativePath)
        guard prepareFolder(fileURL.deletingLastPathComponent()) else { return false }
        do {
            try writer(data, fileURL)
            return true
        } catch {
            return false
        }
    }

    /// Renames a file, replacing the destination.
    @discardableResult
    package func move(_ relativePath: String, to destination: String) -> Bool {
        let source = url(relativePath)
        let target = url(destination)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: source, to: target)
            return true
        } catch {
            return false
        }
    }

    /// Deletes a file. Returns true when it is gone afterwards (a missing file counts as removed).
    @discardableResult
    package func remove(_ relativePath: String) -> Bool {
        let fileURL = url(relativePath)
        do {
            try remover(fileURL)
            return true
        } catch {
            return !FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    /// The names of the folders directly inside `relativePath` (the root when empty).
    package func folders(in relativePath: String) -> [String] {
        let folder = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { name in
            var isDirectory: ObjCBool = false
            let path = folder.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted()
    }

    private func prepareFolder(_ folder: URL) -> Bool {
        if FileManager.default.fileExists(atPath: folder.path) { return true }
        do {
            #if os(iOS)
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            #else
            let attributes: [FileAttributeKey: Any] = [:]
            #endif
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
            excludeRootFromBackup()
            return true
        } catch {
            return false
        }
    }

    private func excludeRootFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
    }
}
