import Foundation
import SallaPushCore

/// An event the SDK saw: a notification received, displayed, opened or dismissed.
struct EventRecord: Equatable, Sendable {
    var messageId: String
    var type: EventType
    /// Seconds since 1970.
    var at: Double
    var actionId: String?
}

/// A public call handed to the engine, in call order.
enum PublicCall: Sendable {
    case pushToken(PushToken)
    case registrationFailed(String)
    /// A login of `externalId`, with its identity token.
    case login(externalId: String, token: SecretString)
    case logout
    case addTags([String: String])
    case removeTags([String])
    case setLanguage(String?)
    case optIn
    case optOut
    case events([EventRecord])
    case refreshPermission
}

/// A public call and its sequence number: the order in which the app made its calls.
struct SequencedCall: Sendable {
    let call: PublicCall
    let sequence: Int
}

/// The bounded buffer of calls made while no engine takes calls: before `initialize`, while the engine loads its
/// files, and while consent is withheld. The engine replays it in call order once it takes calls. Identity calls are
/// collapsed by the identity rules and never dropped; tag, language and opt-in calls are dropped oldest first on overflow,
/// and so are taps and notification events beyond their limits.
struct PreInitBuffer {
    static let maximumCalls = 100
    static let maximumTaps = 20
    static let maximumEvents = 50

    /// What the buffer dropped.
    struct Dropped: Equatable {
        /// Tag, language and opt-in calls.
        var calls = 0
        /// Taps and received/displayed events.
        var events = 0

        var total: Int { calls + events }

        /// The verb that agrees with `total`: "was" for one, "were" otherwise.
        var verb: String { total == 1 ? "was" : "were" }

        /// `12 tag/language/opt-in calls and 3 notification events`.
        var summary: String {
            var parts: [String] = []
            if calls > 0 { parts.append("\(calls) tag/language/opt-in call\(calls == 1 ? "" : "s")") }
            if events > 0 { parts.append("\(events) notification event\(events == 1 ? "" : "s")") }
            return parts.joined(separator: " and ")
        }
    }

    private var token: (sequence: Int, value: PushToken)?
    private var registrationError: (sequence: Int, reason: String)?
    private var taps: [(sequence: Int, event: EventRecord)] = []
    private var events: [(sequence: Int, event: EventRecord)] = []
    private var calls: [(sequence: Int, call: PublicCall)] = []
    private var others: [(sequence: Int, call: PublicCall)] = []
    private var dropped = Dropped()

    /// The sequences of the buffered login, logout, tag, language and opt-in calls.
    var callSequences: Set<Int> {
        Set(calls.map(\.sequence))
    }

    /// Adds a call made at `sequence` at its place in call order: a call the engine returned can be older than the
    /// calls buffered since. On overflow the oldest droppable entries go (see `drain()`).
    /// - Returns: the sequences of the login, logout, tag, language and opt-in calls this removed (collapsed identity
    ///   calls, this one included when a later call supersedes it, dropped droppable calls), so the getters stop
    ///   anticipating them.
    @discardableResult
    mutating func append(_ call: PublicCall, sequence: Int) -> [Int] {
        switch call {
        case let .pushToken(value):
            if (token?.sequence ?? .min) < sequence { token = (sequence, value) }
        case let .registrationFailed(reason):
            if (registrationError?.sequence ?? .min) < sequence { registrationError = (sequence, reason) }
        case let .events(records):
            appendEvents(records, sequence: sequence)
        case .login, .logout:
            return appendIdentity(call, sequence: sequence)
        case .addTags, .removeTags, .setLanguage, .optIn, .optOut:
            calls.insert((sequence, call), at: Self.position(of: sequence, in: calls) { $0.sequence })
            return trimDroppable()
        case .refreshPermission:
            guard !others.contains(where: { $0.sequence > sequence }) else { break }
            others.removeAll()
            others.append((sequence, call))
        }
        return []
    }

    /// Collapses identity calls: a call removes the earlier calls it supersedes, and is itself
    /// dropped when a later buffered call supersedes it.
    private mutating func appendIdentity(_ call: PublicCall, sequence: Int) -> [Int] {
        if calls.contains(where: { $0.sequence > sequence && Self.supersedes($0.call, call) }) { return [sequence] }
        let removed = calls.filter { $0.sequence < sequence && Self.supersedes(call, $0.call) }.map(\.sequence)
        if !removed.isEmpty { calls.removeAll { $0.sequence < sequence && Self.supersedes(call, $0.call) } }
        calls.insert((sequence, call), at: Self.position(of: sequence, in: calls) { $0.sequence })
        return removed
    }

    private mutating func appendEvents(_ records: [EventRecord], sequence: Int) {
        for record in records {
            if record.type == .opened || record.type == .dismissed {
                taps.insert((sequence, record), at: Self.position(of: sequence, in: taps) { $0.sequence })
                if taps.count > Self.maximumTaps {
                    taps.removeFirst()
                    dropped.events += 1
                }
            } else {
                events.insert((sequence, record), at: Self.position(of: sequence, in: events) { $0.sequence })
                if events.count > Self.maximumEvents {
                    events.removeFirst()
                    dropped.events += 1
                }
            }
        }
    }

    /// The index that keeps `entries` in call order: after every entry made at or before `sequence`, so the records of
    /// one call keep their order.
    private static func position<Entry>(of sequence: Int, in entries: [Entry], _ sequenceOf: (Entry) -> Int) -> Int {
        entries.lastIndex { sequenceOf($0) <= sequence }.map { $0 + 1 } ?? 0
    }

    /// Whether `later` makes `earlier` pointless: a login replaces an earlier login, and a logout an earlier login or
    /// logout.
    private static func supersedes(_ later: PublicCall, _ earlier: PublicCall) -> Bool {
        switch (later, earlier) {
        case (.login, .login), (.logout, .login), (.logout, .logout):
            return true
        default:
            return false
        }
    }

    /// Every buffered call in call order, and what was dropped to make room; the buffer is emptied.
    mutating func drain() -> (calls: [SequencedCall], dropped: Dropped) {
        var ordered = calls.map { SequencedCall(call: $0.call, sequence: $0.sequence) }
            + others.map { SequencedCall(call: $0.call, sequence: $0.sequence) }
        if let token { ordered.append(SequencedCall(call: .pushToken(token.value), sequence: token.sequence)) }
        if let registrationError {
            ordered.append(SequencedCall(call: .registrationFailed(registrationError.reason), sequence: registrationError.sequence))
        }
        for tap in taps { ordered.append(SequencedCall(call: .events([tap.event]), sequence: tap.sequence)) }
        for event in events { ordered.append(SequencedCall(call: .events([event.event]), sequence: event.sequence)) }
        // A call split into several entries (events) keeps its order: the sort is stable.
        ordered = ordered.enumerated().sorted { ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset) }.map(\.element)
        let report = dropped
        self = PreInitBuffer()
        return (ordered, report)
    }

    /// Drops the oldest droppable calls beyond the limit and returns their sequences.
    private mutating func trimDroppable() -> [Int] {
        var removed: [Int] = []
        while calls.count > Self.maximumCalls {
            guard let index = calls.firstIndex(where: { Self.isDroppable($0.call) }) else { break }
            removed.append(calls[index].sequence)
            calls.remove(at: index)
            dropped.calls += 1
        }
        return removed
    }

    private static func isDroppable(_ call: PublicCall) -> Bool {
        switch call {
        case .addTags, .removeTags, .setLanguage, .optIn, .optOut: return true
        default: return false
        }
    }
}
