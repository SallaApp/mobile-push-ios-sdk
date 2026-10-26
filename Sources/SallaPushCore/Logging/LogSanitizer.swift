import Foundation

/// Makes text that came from outside the SDK safe to put in a log line.
package enum LogSanitizer {
    /// The longest piece of outside text that reaches a log line.
    package static let maximumLength = 200

    /// What replaces a secret or a token-like run in outside text.
    package static let redacted = "<redacted>"

    /// A segment this long is a secret whatever it holds: device secrets, push tokens and the signatures of customer
    /// tokens all have one.
    package static let secretSegmentLength = 32

    /// A segment this long with a digit in it is a secret too: the header and payload segments of a JWT.
    package static let secretSegmentLengthWithDigit = 20

    /// Known secrets shorter than this are not searched for: no issued credential is that short, and replacing a few
    /// characters everywhere would garble the text.
    package static let minimumHiddenSecretLength = 8

    /// Removes control and format characters, collapses whitespace runs and caps the result at 200 characters. For text
    /// that SallaPush itself controls or that cannot carry a secret (codes, request ids, keys the app passed).
    package static func clean(_ raw: String) -> String {
        collapsed(raw, maximum: maximumLength)
    }

    /// Text a server or the system wrote (an error message, an error description): cleaned like `clean(_:)`, with
    /// every occurrence of `secrets` and every secret-looking run replaced by `<redacted>`, then capped at 200
    /// characters. A run is hidden or judged whole before the cap applies, so no cap ever cuts a secret before it is
    /// hidden: a fragment of one never shows.
    ///
    /// The rule of both SDKs: a run is a maximal sequence of `A-Z a-z 0-9 . _ ~ + / = : -`; it looks like a secret when
    /// one of its segments (split at `.` and `:`, the separators of JWTs and push tokens) has at least 32
    /// characters, or at least 20 with a digit. So `com.salla.store42`, `push.example.com`, error codes and
    /// `1.2.0-beta.1` survive, while a JWT, a device secret, a push token and a UUID do not. The secrets
    /// a request carried are hidden exactly as well, whatever their shape.
    ///
    /// The work is bounded (`scanWindow`): the text is read one run at a time and only until the 200 characters shown
    /// are settled, so a long answer (up to the API client's 256 KB) costs no more than a short one. Within that window
    /// the result is the one a pass over the whole text gives; a run the window cuts is hidden whole, since a cut secret
    /// is a fragment the rule cannot judge (Android's rule at its own input cap).
    package static func serverText(_ raw: String, hiding secrets: [String] = []) -> String {
        let hidden = secrets.filter { $0.count >= minimumHiddenSecretLength }
        // A request's secrets are tokens, made of run characters only, so each lies inside one run. Anything else could
        // straddle runs: the whole text is then read.
        guard hidden.allSatisfy({ $0.unicodeScalars.allSatisfy(isRunScalar) }) else {
            return wholeServerText(raw, hiding: hidden)
        }
        let longest = hidden.map(\.unicodeScalars.count).max() ?? 0
        var reader = BoundedReader(hiding: hidden.map { Array($0.unicodeScalars) },
                                   window: scanWindow + longest, wanted: maximumLength + 1)
        reader.read(raw)
        return capped(reader.text, maximum: maximumLength)
    }

    /// How many characters of outside text are read at most, besides the longest secret the request carried: enough
    /// for 200 characters after control characters, echoed identifiers and tokens.
    package static let scanWindow = maximumLength * 8

    /// A short, safe description of a system error: its domain, code and its description treated as outside text.
    package static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let text = serverText(nsError.localizedDescription)
        return "\(nsError.domain) \(nsError.code)" + (text.isEmpty ? "" : ", \(text)")
    }

    /// Printable ASCII only (anything else becomes `?`), at most `maximum` characters: for echoing a value the app
    /// configured, such as an Info.plist entry.
    package static func printableASCII(_ raw: String, maximum: Int) -> String {
        var result = ""
        for scalar in raw.unicodeScalars.prefix(maximum) {
            result.unicodeScalars.append((0x20...0x7E).contains(scalar.value) ? scalar : "?")
        }
        return result
    }

    // MARK: - Steps

    /// Removes control and format characters and collapses whitespace runs, keeping at most `maximum` characters (all of
    /// them when nil).
    private static func collapsed(_ raw: String, maximum: Int?) -> String {
        var result = ""
        var lastWasSpace = false
        var count = 0
        for scalar in raw.unicodeScalars {
            if let maximum, count >= maximum { break }
            if isSpace(scalar) {
                if !lastWasSpace && !result.isEmpty {
                    result.unicodeScalars.append(" ")
                    count += 1
                }
                lastWasSpace = true
                continue
            }
            if isRemoved(scalar) { continue }
            result.unicodeScalars.append(scalar)
            count += 1
            lastWasSpace = false
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Control, format and other characters that never reach a log line.
    private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// `serverText` over the whole text, for secrets that are not made of run characters only.
    private static func wholeServerText(_ raw: String, hiding secrets: [String]) -> String {
        var text = collapsed(raw, maximum: nil)
        for secret in secrets {
            text = text.replacingOccurrences(of: secret, with: redacted, options: .literal)
        }
        return capped(maskingTokens(text), maximum: maximumLength)
    }

    /// Reads outside text the way `serverText` treats it, one run at a time: control characters removed, whitespace
    /// collapsed, then each run with the carried secrets hidden in it and its token-like pieces masked. It stops once
    /// `wanted` characters are settled (a run still open can only follow them), or after `window` characters, where a
    /// run the window cuts is hidden whole.
    private struct BoundedReader {
        let secrets: [[Unicode.Scalar]]
        let window: Int
        let wanted: Int
        /// What is shown so far.
        private(set) var text = ""
        private var count = 0
        private var run: [Unicode.Scalar] = []
        /// A space waits for the next character: none is shown first or last, as `collapsed(_:maximum:)` trims.
        private var spacePending = false

        init(hiding secrets: [[Unicode.Scalar]], window: Int, wanted: Int) {
            self.secrets = secrets
            self.window = window
            self.wanted = wanted
        }

        mutating func read(_ raw: String) {
            var examined = 0
            for scalar in raw.unicodeScalars {
                if count >= wanted { return }
                examined += 1
                if examined > window {
                    // A run the window cuts may be a secret's start: it is hidden whole.
                    if !run.isEmpty { show(LogSanitizer.redacted.unicodeScalars) }
                    return
                }
                if LogSanitizer.isSpace(scalar) {
                    endRun()
                    spacePending = count > 0
                    continue
                }
                if LogSanitizer.isRemoved(scalar) { continue }
                if spacePending {
                    spacePending = false
                    show(CollectionOfOne(" "))
                }
                if LogSanitizer.isRunScalar(scalar) {
                    run.append(scalar)
                } else {
                    endRun()
                    show(CollectionOfOne(scalar))
                }
            }
            endRun()
        }

        /// Shows the run that just ended: the carried secrets hidden in it, one after the other as a pass over the whole
        /// text hides them, then each run left between them masked when token-like.
        private mutating func endRun() {
            guard !run.isEmpty else { return }
            var scalars = run
            run = []
            for secret in secrets {
                scalars = Self.replacing(secret, in: scalars)
            }
            var piece = ""
            for scalar in scalars {
                if LogSanitizer.isRunScalar(scalar) {
                    piece.unicodeScalars.append(scalar)
                    continue
                }
                showMasked(&piece)
                show(CollectionOfOne(scalar))
            }
            showMasked(&piece)
        }

        private mutating func showMasked(_ piece: inout String) {
            guard !piece.isEmpty else { return }
            show(LogSanitizer.isTokenLike(piece) ? LogSanitizer.redacted.unicodeScalars : piece.unicodeScalars)
            piece = ""
        }

        private mutating func show<Scalars: Collection>(_ scalars: Scalars) where Scalars.Element == Unicode.Scalar {
            text.unicodeScalars.append(contentsOf: scalars)
            count += scalars.count
        }

        /// Every occurrence of `secret` in `scalars`, left to right and not overlapping, replaced by `<redacted>`. A
        /// Knuth-Morris-Pratt search, so text built to nearly match a long secret costs no more than any other.
        private static func replacing(_ secret: [Unicode.Scalar], in scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
            guard !secret.isEmpty, scalars.count >= secret.count else { return scalars }
            var fallback = [Int](repeating: 0, count: secret.count)
            var length = 0
            for index in secret.indices.dropFirst() {
                while length > 0, secret[index] != secret[length] { length = fallback[length - 1] }
                if secret[index] == secret[length] { length += 1 }
                fallback[index] = length
            }
            var result: [Unicode.Scalar] = []
            result.reserveCapacity(scalars.count)
            var copied = 0
            var matched = 0
            for (index, scalar) in scalars.enumerated() {
                while matched > 0, scalar != secret[matched] { matched = fallback[matched - 1] }
                if scalar == secret[matched] { matched += 1 }
                guard matched == secret.count else { continue }
                result.append(contentsOf: scalars[copied..<(index + 1 - secret.count)])
                result.append(contentsOf: LogSanitizer.redacted.unicodeScalars)
                copied = index + 1
                matched = 0
            }
            result.append(contentsOf: scalars[copied...])
            return result
        }
    }

    /// At most `maximum` Unicode scalars, then trimmed.
    private static func capped(_ text: String, maximum: Int) -> String {
        guard text.unicodeScalars.count > maximum else { return text }
        var result = ""
        result.unicodeScalars.append(contentsOf: text.unicodeScalars.prefix(maximum))
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces every secret-looking run (see `serverText(_:hiding:)`) with `<redacted>`.
    package static func maskingTokens(_ text: String) -> String {
        var result = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            result += isTokenLike(run) ? redacted : run
            run = ""
        }
        for scalar in text.unicodeScalars {
            if isRunScalar(scalar) {
                run.unicodeScalars.append(scalar)
            } else {
                flush()
                result.unicodeScalars.append(scalar)
            }
        }
        flush()
        return result
    }

    private static func isRunScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "~", "+", "/", "=", ":", "-": return true
        default: return false
        }
    }

    private static func isTokenLike(_ run: String) -> Bool {
        var segmentLength = 0
        var segmentHasDigit = false
        for scalar in run.unicodeScalars {
            if scalar == "." || scalar == ":" {
                segmentLength = 0
                segmentHasDigit = false
                continue
            }
            segmentLength += 1
            if ("0"..."9").contains(scalar) { segmentHasDigit = true }
            if segmentLength >= secretSegmentLength || (segmentLength >= secretSegmentLengthWithDigit && segmentHasDigit) {
                return true
            }
        }
        return false
    }
}
