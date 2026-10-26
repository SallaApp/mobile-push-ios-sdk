import Foundation
import SallaPushCore

/// What the engine publishes for the public getters, read in O(1) under a lock, never on the engine queue; `GetterView`
/// applies the calls the engine has not handled yet.
struct EngineSnapshot: Equatable, Sendable {
    var deviceId: String?
    var token: String?
    var permission: PermissionStatus?
    /// When the permission was read (`EngineHost.permissionReadStarted()`): a read started later wins, so an older
    /// read never replaces a fresher one.
    var permissionSequence = 0
    var userOptedOut = false
    var externalId: String?
    var isLoggedIn = false
    /// While the customer logged in has no id (a consent withdrawal forgot it), the customer of the identity token in
    /// memory: consent given again in this process names them again before the calls made meanwhile run.
    var tokenExternalId: String?
    var tags: [String: String] = [:]
    /// While the identity is unknown, the tags a `logout()` keeps: those the app set in this launch; nil once
    /// it is known. Before the first snapshot nothing is known, and a launch logout keeps the tag calls of this launch.
    var launchTags: [String: String]? = [:]
    /// The sequence of the last public call the engine handled: the runtime's pending intents up to it are reflected.
    var callSequence = 0
    /// A `logout()` now would change nothing (signed out, unlinked, no login on the way): it keeps the tags.
    var logoutIsFree = false
    /// A `logout()` now would send a request; when it would not, the logout after it is free.
    var logoutSends = false

    /// `permission && !optedOut && token`.
    var optedIn: Bool {
        (permission?.isGranted ?? false) && !userOptedOut && token != nil
    }

    /// Whether the fields that public calls read or change (login state, external id, opt-out, tags and the facts that
    /// decide what a login or a logout does) equal those of `other`.
    func hasSameCallFields(as other: EngineSnapshot) -> Bool {
        isLoggedIn == other.isLoggedIn && externalId == other.externalId && tokenExternalId == other.tokenExternalId
            && userOptedOut == other.userOptedOut && tags == other.tags && launchTags == other.launchTags
            && logoutIsFree == other.logoutIsFree && logoutSends == other.logoutSends
    }

    /// `other` with the fields that public calls read or change taken from `self`.
    func withCallFields(over other: EngineSnapshot) -> EngineSnapshot {
        var merged = other
        merged.isLoggedIn = isLoggedIn
        merged.externalId = externalId
        merged.tokenExternalId = tokenExternalId
        merged.userOptedOut = userOptedOut
        merged.tags = tags
        merged.launchTags = launchTags
        merged.logoutIsFree = logoutIsFree
        merged.logoutSends = logoutSends
        return merged
    }
}

/// A public call the getters reflect as soon as it returns, before the engine has handled it.
enum PendingIntent: Sendable {
    /// A login of the customer `externalId`.
    case login(externalId: String)
    case logout
    case optIn
    case optOut
    /// The changes of an `addTags` or `removeTags` call, normalised once, when the call is made.
    case tags([TagChange])

    /// The intent of `call`, or nil when no getter reflects it.
    init?(_ call: PublicCall) {
        switch call {
        case let .login(externalId, _): self = .login(externalId: externalId)
        case .logout: self = .logout
        case .optIn: self = .optIn
        case .optOut: self = .optOut
        case let .addTags(tags): self = .tags(TagRules.changes(adding: tags))
        case let .removeTags(keys): self = .tags(TagRules.changes(removing: keys))
        case .pushToken, .registrationFailed, .setLanguage, .events, .refreshPermission:
            return nil
        }
    }

    /// Applies the intent the way the engine will: the same login, logout and tag rules, without logging.
    func apply(to snapshot: inout EngineSnapshot, clearTagsOnLogout: Bool) {
        switch self {
        case let .login(externalId):
            // A login of another customer than the one logged in is an account switch: it drops the tags
            // (clearTagsOnLogout). So is a login while the one logged in has no id, unless it is of the customer the
            // identity token in memory names. So does a login while the identity is unknown, except the tags of this
            // launch.
            let previous = snapshot.externalId ?? snapshot.tokenExternalId
            if clearTagsOnLogout, snapshot.isLoggedIn, previous != externalId {
                snapshot.tags = [:]
            } else if clearTagsOnLogout, let launchTags = snapshot.launchTags {
                snapshot.tags = launchTags
            }
            snapshot.isLoggedIn = true
            snapshot.externalId = externalId
            snapshot.tokenExternalId = nil
            snapshot.logoutIsFree = false
            snapshot.launchTags = nil
        case .logout:
            // A free logout changes nothing and keeps the tags; any other clears them (clearTagsOnLogout),
            // except, while the identity is unknown, the tags the app set in this launch.
            guard !snapshot.logoutIsFree else { return }
            if clearTagsOnLogout { snapshot.tags = snapshot.launchTags ?? [:] }
            snapshot.launchTags = nil
            snapshot.isLoggedIn = false
            snapshot.externalId = nil
            snapshot.tokenExternalId = nil
            snapshot.logoutIsFree = !snapshot.logoutSends
        case .optIn:
            snapshot.userOptedOut = false
        case .optOut:
            snapshot.userOptedOut = true
        case let .tags(changes):
            TagRules.apply(changes, to: &snapshot.tags, recordingIn: &snapshot.launchTags)
        }
    }
}

/// What the public getters read: the snapshot the current engine published, then every call it has not handled yet,
/// applied in call order. So a getter read right after a call reflects it, also before `initialize` and while consent
/// is pending (memory only, nothing is written). The engine's own rules decide in the end; a published snapshot
/// replaces the anticipation of every call it covers.
///
/// Bounded, and cheap to read. An intent is kept only for a call the engine has not handled: while no engine takes calls
/// they wait in the runtime's bounded pre-init buffer, and an intent leaves this view exactly when the buffer drops or
/// collapses its call, so the getters show what the engine will apply. The resolved snapshot is kept up to date as
/// intents come and settle; only after a drop is it rebuilt, once, at the next read, from at most the buffer's calls.
struct GetterView: Sendable {
    /// A pending intent and the sequence of its call.
    struct Entry: Sendable {
        let sequence: Int
        let intent: PendingIntent
    }

    /// The last snapshot of the current engine, with the freshest permission read.
    private(set) var engine = EngineSnapshot()
    /// `engine` with every pending intent applied, unless `isStale`.
    private var cached = EngineSnapshot()
    /// A drop removed an intent from the middle: `cached` is rebuilt at the next read.
    private var isStale = false
    /// The pending intents in call order; those before `head` are settled.
    private var entries: [Entry] = []
    private var head = 0
    /// Whether the process received the first engine snapshot: the state an earlier launch left.
    var hasBaseline = false
    /// `clearTagsOnLogout` of the configuration in effect.
    private(set) var clearTagsOnLogout = true

    /// How many calls the getters anticipate.
    var pendingCount: Int { entries.count - head }

    /// What the getters return: `engine` with every pending intent applied.
    mutating func resolved() -> EngineSnapshot {
        if isStale { rebuild() }
        return cached
    }

    /// Sets `clearTagsOnLogout` of the configuration in effect.
    mutating func setClearTagsOnLogout(_ value: Bool) {
        guard value != clearTagsOnLogout else { return }
        clearTagsOnLogout = value
        isStale = true
    }

    /// Records the intent of a call that was just made: O(changes of the call).
    mutating func append(sequence: Int, intent: PendingIntent) {
        entries.append(Entry(sequence: sequence, intent: intent))
        if !isStale {
            intent.apply(to: &cached, clearTagsOnLogout: clearTagsOnLogout)
        }
    }

    /// Forgets the intents of `sequences`: calls the buffer dropped or collapsed, which the engine never applies.
    mutating func remove(sequences: [Int]) {
        guard !sequences.isEmpty else { return }
        let removed = Set(sequences)
        compact()
        let before = entries.count
        entries.removeAll { removed.contains($0.sequence) }
        if entries.count != before { isStale = true }
    }

    /// Forgets the intents of the calls up to `sequence` except `kept`: calls handed to an engine that is no longer
    /// the current one, which applies them to its own app id.
    mutating func remove(through sequence: Int, keeping kept: Set<Int>) {
        compact()
        let before = entries.count
        entries.removeAll { $0.sequence <= sequence && !kept.contains($0.sequence) }
        if entries.count != before { isStale = true }
    }

    /// A snapshot the current engine published: the intents of the calls it handled settle. When the engine did exactly
    /// what they anticipated (the usual case), the later intents still apply on top unchanged and nothing is rebuilt;
    /// otherwise (a server answer changed the tags, say) the view is rebuilt from the new snapshot.
    mutating func publish(_ snapshot: EngineSnapshot) {
        var predicted = engine
        var settled = head
        while settled < entries.count, entries[settled].sequence <= snapshot.callSequence {
            entries[settled].intent.apply(to: &predicted, clearTagsOnLogout: clearTagsOnLogout)
            settled += 1
        }
        head = settled
        if head * 2 >= entries.count { compact() }
        engine = snapshot
        if isStale { return }
        if predicted.hasSameCallFields(as: snapshot) {
            cached = cached.withCallFields(over: snapshot)
        } else {
            rebuild()
        }
    }

    /// A permission read published outside an engine snapshot.
    mutating func setPermission(_ status: PermissionStatus, sequence: Int) {
        engine.permission = status
        engine.permissionSequence = sequence
        cached.permission = status
        cached.permissionSequence = sequence
    }

    /// Drops the settled entries, so `entries` holds pending intents only.
    private mutating func compact() {
        guard head > 0 else { return }
        entries.removeFirst(head)
        head = 0
    }

    private mutating func rebuild() {
        var snapshot = engine
        for index in head..<entries.count {
            entries[index].intent.apply(to: &snapshot, clearTagsOnLogout: clearTagsOnLogout)
        }
        cached = snapshot
        isStale = false
    }
}
