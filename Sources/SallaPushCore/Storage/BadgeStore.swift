import Foundation

/// The badge settings the app shares with its Notification Service Extension.
package struct BadgeSettings: Sendable, Equatable {
    /// `autoUpdateBadge`: the extension counts SallaPush notifications and puts the count on each one.
    package var autoUpdateBadge: Bool

    package init(autoUpdateBadge: Bool) {
        self.autoUpdateBadge = autoUpdateBadge
    }
}

/// SallaPush's count of its notifications on the app icon badge, in the App Group the app shares with its Notification
/// Service Extension: `<App Group>/Library/Application Support/SallaPush/badge/<app bundle id>/`, one folder per app,
/// because several apps can share one App Group.
///
/// - `settings.json`: `{"auto_update_badge":true,"v":1}`. Only the app writes it, atomically.
/// - `<32 hex>.mark`: one per counted notification, named after the first 32 hex characters of the SHA-256 of its
///   request id, so no id is stored as text. It holds `{"at":<seconds>,"v":1}`.
///
/// Each operation is one file-system call, or one listing and one call per file, with no lock: a mark is created only
/// when it doesn't exist yet (an exclusive create), so two notifications, or the app and the extension, never count one
/// notification twice. The files have no data protection, because the extension runs before the first unlock too and a
/// count it couldn't write would be lost; they hold no personal data (a boolean, times and hashes). The `badge` folder
/// is excluded from backups.
package final class BadgeStore: Sendable {
    /// The outcome of counting a notification.
    package enum AddResult: Sendable, Equatable {
        case added
        /// Its mark exists: a replacement (the same collapse id) or a duplicate.
        case alreadyCounted
        /// `capacity` notifications are counted.
        case full
        case failed
    }

    /// Writes `data` to a file URL with `options`.
    package typealias Writer = @Sendable (_ data: Data, _ url: URL, _ options: Data.WritingOptions) throws -> Void
    /// Creates a folder, and its missing parents, with `attributes`.
    package typealias FolderMaker = @Sendable (_ url: URL, _ attributes: [FileAttributeKey: Any]) throws -> Void

    /// The most notifications counted.
    package static let capacity = 999
    /// A mark dated within this many seconds of now, either side, may belong to a notification the extension still
    /// holds: `prune(keeping:now:)` keeps it. The inbox's `claimLifetime`.
    package static let pendingWindow: Double = Inbox.claimLifetime
    /// The most bytes read from one file; a mark takes about 30.
    static let maximumFileBytes = 1_024

    /// The folder of the app's files.
    package let folder: URL
    private let writer: Writer
    private let makeFolder: FolderMaker

    private struct Settings: Codable {
        let v: Int
        let autoUpdateBadge: Bool

        enum CodingKeys: String, CodingKey {
            case v
            case autoUpdateBadge = "auto_update_badge"
        }
    }

    private struct Mark: Codable {
        let v: Int
        let at: Double
    }

    /// The store of the app `appBundleIdentifier` in the App Group `container`. nil when the bundle id is missing or
    /// holds anything but letters, digits, `.` and `-`, or doesn't start with a letter or a digit: it names a folder.
    package init?(container: URL, appBundleIdentifier: String?, writer: @escaping Writer = BadgeStore.fileWriter,
                  makeFolder: @escaping FolderMaker = BadgeStore.folderMaker) {
        guard let bundle = appBundleIdentifier, Self.isFolderName(bundle) else { return nil }
        folder = Self.folder(inContainer: container).appendingPathComponent(bundle, isDirectory: true)
        self.writer = writer
        self.makeFolder = makeFolder
    }

    /// `<App Group container>/Library/Application Support/SallaPush/badge`, next to the inbox.
    package static func folder(inContainer container: URL) -> URL {
        Inbox.folder(inContainer: container).deletingLastPathComponent().appendingPathComponent("badge", isDirectory: true)
    }

    /// The live writer. The protection options apply on iOS only.
    package static let fileWriter: Writer = { data, url, options in
        #if os(iOS)
        try data.write(to: url, options: options)
        #else
        try data.write(to: url, options: options.subtracting(.fileProtectionMask))
        #endif
    }

    /// The live folder maker. The protection attribute applies on iOS only.
    package static let folderMaker: FolderMaker = { url, attributes in
        #if os(iOS)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: attributes.filter { $0.key != .protectionKey })
        #endif
    }

    // MARK: - Counting

    /// Counts the notification of request id `identifier`, received at `seconds`.
    package func add(identifier: String, at seconds: Double) -> AddResult {
        create(Self.markName(identifier), at: seconds, listed: Set(markNames()))
    }

    /// Counts the notifications of request ids `identifiers` that no mark counts yet, received at `seconds`: one
    /// listing for all of them.
    package func add(identifiers: [String], at seconds: Double) {
        var names = Set(markNames())
        for identifier in identifiers {
            let name = Self.markName(identifier)
            let result = create(name, at: seconds, listed: names)
            if result == .added || result == .alreadyCounted { names.insert(name) }
        }
    }

    /// Creates the mark `name`, unless `names`, the marks listed, holds it or holds `capacity` marks.
    private func create(_ name: String, at seconds: Double, listed names: Set<String>) -> AddResult {
        if names.contains(name) { return .alreadyCounted }
        if names.count >= Self.capacity { return .full }
        guard prepareFolder(), let body = Self.encode(Mark(v: 1, at: seconds)) else { return .failed }
        let url = folder.appendingPathComponent(name)
        do {
            try writer(body, url, [.withoutOverwriting, .noFileProtection])
            return .added
        } catch {
            // The exclusive create fails when the mark exists: another notification or process counted it meanwhile.
            return FileManager.default.fileExists(atPath: url.path) ? .alreadyCounted : .failed
        }
    }

    /// How many notifications are counted: the marks of one listing, at most `capacity`.
    package func count() -> Int {
        min(markNames().count, Self.capacity)
    }

    /// Stops counting the notification of request id `identifier`.
    package func remove(identifier: String) {
        unlink(Self.markName(identifier))
    }

    /// Stops counting every notification: the marks of one listing. A mark created after the listing stays: its
    /// notification arrived after the reset.
    package func reset() {
        for name in markNames() { unlink(name) }
    }

    /// Deletes the settings, the marks and the folder.
    package func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Keeps the marks of `identifiers`, the request ids of the notifications still in Notification Center, and of
    /// the notifications counted within `pendingWindow` of `now`, either side (the clock is wall time), which may still
    /// be in the extension. Unlinks every other mark, an unreadable one too: an extension stopped between the create
    /// and the write leaves an empty mark. Returns the count left.
    package func prune(keeping identifiers: Set<String>, now: Double) -> Int {
        let kept = Set(identifiers.map(Self.markName))
        var left = 0
        for name in markNames() {
            if kept.contains(name) {
                left += 1
            } else if let at = markTime(name), now - Self.pendingWindow < at, at < now + Self.pendingWindow {
                left += 1
            } else {
                unlink(name)
            }
        }
        return min(left, Self.capacity)
    }

    // MARK: - Settings

    /// The app's settings; nil when the file is missing, unreadable or of another version.
    package func readSettings() -> BadgeSettings? {
        guard let data = Self.readBounded(folder.appendingPathComponent("settings.json")),
              let settings = StoredJSON.decode(Settings.self, from: data), settings.v == 1
        else { return nil }
        return BadgeSettings(autoUpdateBadge: settings.autoUpdateBadge)
    }

    /// Writes the app's settings atomically; false when the write failed.
    @discardableResult
    package func writeSettings(_ settings: BadgeSettings) -> Bool {
        guard prepareFolder(), let body = Self.encode(Settings(v: 1, autoUpdateBadge: settings.autoUpdateBadge)) else {
            return false
        }
        do {
            try writer(body, folder.appendingPathComponent("settings.json"), [.atomic, .noFileProtection])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Files

    /// `<first 32 hex characters of SHA-256(identifier)>.mark`.
    static func markName(_ identifier: String) -> String {
        String(Fingerprint.sha256Hex(Data(identifier.utf8)).prefix(32)) + ".mark"
    }

    private static func isMarkName(_ name: String) -> Bool {
        name.count == 37 && name.hasSuffix(".mark") && Validation.isLowerHex(String(name.prefix(32)))
    }

    private static func isFolderName(_ bundle: String) -> Bool {
        guard let first = bundle.unicodeScalars.first, bundle.utf8.count <= 255 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return allowed.contains(first)
            && bundle.unicodeScalars.allSatisfy { allowed.contains($0) || $0 == "." || $0 == "-" }
    }

    /// The marks of one listing; none when the folder doesn't exist.
    private func markNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter(Self.isMarkName)
    }

    /// When the notification of mark `name` was counted; nil when the mark can't be read.
    private func markTime(_ name: String) -> Double? {
        guard let data = Self.readBounded(folder.appendingPathComponent(name)),
              let mark = StoredJSON.decode(Mark.self, from: data), mark.v == 1, mark.at.isFinite
        else { return nil }
        return mark.at
    }

    private func unlink(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }

    /// Creates the folder and the `badge` folder without data protection, and excludes the `badge` folder from backups.
    /// The folders above them are created first, without attributes, as the inbox creates them: a folder maker gives
    /// its attributes to every folder it creates, and a file written without a protection class takes its folder's.
    private func prepareFolder() -> Bool {
        if FileManager.default.fileExists(atPath: folder.path) { return true }
        var badgeFolder = folder.deletingLastPathComponent()
        do {
            try makeFolder(badgeFolder.deletingLastPathComponent(), [:])
            try makeFolder(badgeFolder, [.protectionKey: FileProtectionType.none])
            try makeFolder(folder, [.protectionKey: FileProtectionType.none])
        } catch {
            return false
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? badgeFolder.setResourceValues(values)
        return true
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    /// At most `maximumFileBytes` bytes of the file; nil when it can't be read or is larger.
    private static func readBounded(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileBytes + 1), data.count <= maximumFileBytes else {
            return nil
        }
        return data
    }
}
