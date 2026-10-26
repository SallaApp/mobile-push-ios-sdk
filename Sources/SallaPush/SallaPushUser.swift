import Foundation
import SallaPushCore

/// The user of this device: the customer link, tags, language and the push subscription.
@objc public final class SallaPushUser: NSObject {
    // Stateless, so one instance serves every thread.
    private static let instance = UncheckedSendable(SallaPushUser())
    static var shared: SallaPushUser { instance.value }

    override init() {
        super.init()
    }

    /// The external id the app logged in with (`login(externalId:identityToken:)`) while it is logged in; nil for guests,
    /// and nil as soon as `logout()` returns. It reflects each call as soon as it returns.
    @objc public var externalId: String? { Runtime.shared.snapshot.externalId }

    /// Whether `login(externalId:identityToken:)` was called and no `logout()` since; it reflects each call as soon as it
    /// returns.
    @objc public var isLoggedIn: Bool { Runtime.shared.snapshot.isLoggedIn }

    /// The push subscription of this device.
    @objc public var pushSubscription: SallaPushSubscription { SallaPushSubscription.shared }

    /// Sets a tag. Keys are trimmed and lowercased (`a-z`, `0-9`, `_`, at most 64); values longer than 255
    /// characters are truncated; an empty value removes the tag. At most 100 tags.
    @objc(addTagWithKey:value:) public func addTag(key: String, value: String) {
        Runtime.shared.addTags([key: value])
    }

    /// Sets several tags (see `addTag(key:value:)`).
    @nonobjc public func addTags(_ tags: [String: String]) {
        Runtime.shared.addTags(tags)
    }

    /// Sets several tags: the Objective-C form of `addTags(_:)`. A tag whose key or value is not a string, which bridge
    /// code can pass and Swift's bridging to `[String: String]` would crash on, is skipped, and the skipped count is
    /// logged (WARN `api.invalid_argument`).
    @available(swift, obsoleted: 1)
    @objc(addTags:) public func objcAddTags(_ tags: [AnyHashable: Any]) {
        let runtime = Runtime.shared
        var usable: [String: String] = [:]
        var skipped = 0
        for (key, value) in tags {
            guard let key = key.base as? String, let value = value as? String else {
                skipped += 1
                continue
            }
            usable[key] = value
        }
        if skipped > 0 {
            let skippedTags = skipped == 1 ? "1 tag was" : "\(skipped) tags were"
            runtime.logger.log(.apiInvalidArgument,
                               "addTags: \(skippedTags) skipped; a tag's key and value must be strings.",
                               metadata: [LogMetadataKey.count: String(skipped)])
        }
        runtime.addTags(usable)
    }

    /// Removes a tag.
    @objc public func removeTag(_ key: String) {
        Runtime.shared.removeTags([key])
    }

    /// Removes several tags.
    @nonobjc public func removeTags(_ keys: [String]) {
        Runtime.shared.removeTags(keys)
    }

    /// Removes several tags: the Objective-C form of `removeTags(_:)`. A key that is not a string, which bridge code
    /// can pass and Swift's bridging to `[String]` would crash on, is skipped, and the skipped count is logged (WARN
    /// `api.invalid_argument`).
    @available(swift, obsoleted: 1)
    @objc(removeTags:) public func objcRemoveTags(_ keys: [Any]) {
        let runtime = Runtime.shared
        let usable = keys.compactMap { $0 as? String }
        let skipped = keys.count - usable.count
        if skipped > 0 {
            let skippedKeys = skipped == 1 ? "1 key was" : "\(skipped) keys were"
            runtime.logger.log(.apiInvalidArgument, "removeTags: \(skippedKeys) skipped; a tag key must be a string.",
                               metadata: [LogMetadataKey.count: String(skipped)])
        }
        runtime.removeTags(usable)
    }

    /// The device's tags, with every tag call applied as soon as it returns.
    @objc public func getTags() -> [String: String] {
        Runtime.shared.snapshot.tags
    }

    /// Sets the app's language (for example `ar`); nil uses the device language. Unchanged values are ignored.
    @objc public func setLanguage(_ language: String?) {
        Runtime.shared.submit(.setLanguage(language))
    }

    /// Adds a user observer (held weakly).
    @objc public func addObserver(_ observer: SallaPushUserObserver) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(observer, of: "User.addObserver", "observer") else { return }
        runtime.observers.addUserObserver(observer)
    }

    /// Removes a user observer.
    @objc public func removeObserver(_ observer: SallaPushUserObserver) {
        let runtime = Runtime.shared
        guard !runtime.isNilArgument(observer, of: "User.removeObserver", "observer") else { return }
        runtime.observers.removeUserObserver(observer)
    }

    /// Observes user changes with a closure on main; keep the returned observation.
    public func addObserver(_ handler: @escaping @MainActor @Sendable (SallaPushUserChangedState) -> Void) -> SallaPushObservation {
        Runtime.shared.observers.addUserHandler(handler)
    }

    /// Observes login failures with a closure on main; keep the returned observation.
    public func addLoginFailureHandler(_ handler: @escaping @MainActor @Sendable (SallaPushLoginFailure) -> Void) -> SallaPushObservation {
        Runtime.shared.observers.addLoginFailureHandler(handler)
    }
}
