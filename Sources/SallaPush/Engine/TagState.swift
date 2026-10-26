import Foundation

// `state.json` → `tags`, a frozen schema.

/// A pending tag value and the identity epoch of the call that set it (its order within this process).
struct PendingTagAdd: Codable, Equatable, Sendable {
    var v: String
    var epoch: Int

    init(v: String, epoch: Int) {
        self.v = v
        self.epoch = epoch
    }

    private enum CodingKeys: String, CodingKey {
        case v, epoch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(String.self, forKey: .v)
        epoch = try container.decode(Int.self, forKey: .epoch)
        try PersistedInteger.checkTagEpoch(epoch, key: .epoch, in: container)
    }
}

/// `state.json` → `tags`.
struct TagState: Codable, Equatable, Sendable {
    /// What the server last returned.
    var mirror: [String: String] = [:]
    var pendingAdd: [String: PendingTagAdd] = [:]
    /// Key → identity epoch of the removing call.
    var pendingRemove: [String: Int] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mirror
        case pendingAdd = "pending_add"
        case pendingRemove = "pending_remove"
    }

    /// An earlier (pre-release) version marked the changes made before a login that could switch customers with a
    /// negative epoch, until the server answered that login. Such a change may be the previous customer's, or the same
    /// customer's when that login only refreshed the token, and that login is never sent again (it has no external id),
    /// so the change is dropped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mirror = try container.decodeIfPresent([String: String].self, forKey: .mirror) ?? [:]
        let adds = try container.decodeIfPresent([String: PendingTagAdd].self, forKey: .pendingAdd) ?? [:]
        let removes = try container.decodeIfPresent([String: Int].self, forKey: .pendingRemove) ?? [:]
        for epoch in removes.values {
            try PersistedInteger.checkTagEpoch(epoch, key: .pendingRemove, in: container)
        }
        pendingAdd = adds.filter { $0.value.epoch >= 0 }
        pendingRemove = removes.filter { $0.value >= 0 }
    }

    var hasPendingChanges: Bool { !pendingAdd.isEmpty || !pendingRemove.isEmpty }

    /// The tags as the app sees them: the mirror with pending changes applied.
    var effective: [String: String] {
        var tags = mirror
        for key in pendingRemove.keys { tags.removeValue(forKey: key) }
        for (key, value) in pendingAdd { tags[key] = value.v }
        return tags
    }

    /// The largest epoch of a pending change (0 without changes).
    var largestEpoch: Int {
        (pendingAdd.values.map(\.epoch) + Array(pendingRemove.values)).max().map { max($0, 0) } ?? 0
    }

    /// Every key SallaPush holds: the server's last answer and the pending changes. A tag clearing removes them all.
    var heldKeys: [String] {
        Set(mirror.keys).union(pendingAdd.keys).union(pendingRemove.keys).sorted()
    }
}
