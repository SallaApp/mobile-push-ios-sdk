import Foundation
@testable import SallaPushCore
import XCTest

/// Outside text (a server's error message, a system error's description) never
/// carries a secret into a log line. Known secrets are hidden exactly, every secret-looking run is masked by the rule
/// both SDKs share, and dotted identifiers, hosts, versions and error codes survive.
final class LogSanitizerTests: XCTestCase {
    private let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMDAxIn0.c2lnbmF0dXJlc2lnbmF0dXJl"
    private let signedToken = "v4.public." + String(repeating: "eyJzdWIiOiIxMDAxIn0", count: 6)
    private let deviceSecret = "c2VjcmV0LXNlY3JldC1zZWNyZXQ"
    private let pushToken = String(repeating: "ab", count: 32)
    private let uuid = "3f2a8c1e-6b3d-4c2a-9e1f-0123456789ab"
    private let standardBase64 = "dGhpcyBpcyBh/c2VjcmV0+dG9rZW4="

    func test_tokenLikeRuns_areMasked() {
        for token in [jwt, signedToken, deviceSecret, pushToken, uuid, standardBase64] {
            XCTAssertEqual(LogSanitizer.serverText("echo \(token) here"), "echo <redacted> here", token)
        }
        XCTAssertEqual(LogSanitizer.serverText("Authorization: Device \(deviceSecret)"), "Authorization: Device <redacted>")
        XCTAssertEqual(LogSanitizer.serverText("token=\(jwt);"), "<redacted>;", "a key glued to the token goes with it")
    }

    func test_dottedIdentifiersHostsVersionsAndCodes_survive() {
        let kept = [
            "This app id belongs to another app (expected com.salla.store42, got com.salla.dev)",
            "com.salla.store42.SallaPushExampleNSE",
            "Cannot POST https://push.example.com/devices",
            "Route /devices/{id}/login answered by push.salla.dev:443",
            "SallaPush 1.2.0-beta.1 (invalid_customer_token, identity_not_configured)",
            "Tag limit exceeded (max 100)",
            "Platform does not match the app",
        ]
        for text in kept {
            XCTAssertEqual(LogSanitizer.serverText(text), text)
        }
    }

    /// The shared rule's thresholds: a segment of 32 characters, or of 20 with a digit, is a secret.
    func test_theThresholds_ofTheRuleBothSDKsShare() {
        let words31 = String(repeating: "abcdefghij", count: 3) + "k"
        XCTAssertEqual(LogSanitizer.serverText(words31), words31)
        XCTAssertEqual(LogSanitizer.serverText(words31 + "l"), "<redacted>")
        let digits19 = "abcdefghijklmnopqr1"
        XCTAssertEqual(LogSanitizer.serverText(digits19), digits19)
        XCTAssertEqual(LogSanitizer.serverText(digits19 + "s"), "<redacted>")
        XCTAssertEqual(LogSanitizer.serverText("\(digits19).\(digits19):\(digits19)"), "\(digits19).\(digits19):\(digits19)",
                       "segments end at '.' and ':'")
        XCTAssertEqual(LogSanitizer.serverText("GET /apps/st_42_ios/devices"), "GET <redacted>",
                       "'/' does not split: a path with 20 characters and a digit is masked")
    }

    func test_aPathOrURL_withAnIdentifier_masksOnlyThatRun() {
        XCTAssertEqual(LogSanitizer.serverText("Not found: /devices/\(uuid)/login"), "Not found: <redacted>")
        XCTAssertEqual(LogSanitizer.serverText("see https://push.salla.dev/devices/\(uuid) now"), "see <redacted> now")
    }

    func test_knownSecrets_areHidden_evenWhenShort() {
        XCTAssertEqual(LogSanitizer.serverText("token abcd1234 echoed", hiding: ["abcd1234"]), "token <redacted> echoed")
        XCTAssertEqual(LogSanitizer.serverText("customer.token.a was refused", hiding: ["customer.token.a"]),
                       "<redacted> was refused")
        XCTAssertEqual(LogSanitizer.serverText("value abc", hiding: ["abc"]), "value abc",
                       "shorter than 8 characters: no issued credential, not searched")
    }

    /// Masking happens before the 200-character cap, so a secret the cap would cut never shows a fragment.
    func test_masking_beforeTheCap_leavesNoFragment() {
        let prefix = String(repeating: "word ", count: 38)
        let text = LogSanitizer.serverText(prefix + deviceSecret + deviceSecret + " end")
        XCTAssertFalse(text.contains("c2Vj"), text)
        XCTAssertTrue(text.hasSuffix("<redacted>"), text)
        XCTAssertLessThanOrEqual(text.count, LogSanitizer.maximumLength)
        let long = LogSanitizer.serverText(String(repeating: "a b ", count: 300))
        XCTAssertLessThanOrEqual(long.count, LogSanitizer.maximumLength)
    }

    /// The exact hiding and the masking run on the whole text, before any cap. A known
    /// secret straddling the 400th character (where an earlier pre-cap cut the text) is hidden in full, so no fragment
    /// of it can land inside the 200-character result once earlier runs were masked.
    func test_aSecretStraddlingTheOldPreCap_neverShowsAFragment() {
        let secret = "Ab3dEf5hIj7lMn9pQr1tUv3xYz5bCd7fGh9jKl1nOp3"
        let prefix = "echo " + String(repeating: "a1", count: 150) + " "
        let fillerCount = 381 - prefix.count
        let filler = String(repeating: "w ", count: (fillerCount - 1) / 2) + ((fillerCount - 1) % 2 == 1 ? "w" : "") + "!"
        let raw = prefix + filler + secret + " tail"
        XCTAssertGreaterThan(raw.count, 400, "the secret straddles the old 400-character pre-cap")
        let text = LogSanitizer.serverText(raw, hiding: [secret])
        XCTAssertFalse(text.contains(String(secret.prefix(19))), text)
        XCTAssertFalse(text.contains("Ab3dEf"), text)
        XCTAssertLessThanOrEqual(text.count, LogSanitizer.maximumLength)
        // Without the exact hiding, a fragment shorter than the masking thresholds would show: the whole-text rule
        // masks the full run instead.
        let masked = LogSanitizer.serverText(raw)
        XCTAssertFalse(masked.contains("Ab3dEf"), masked)
    }

    // MARK: - Bounded work

    /// The largest answer, 256 KB: an error message of ordinary words filling the API client's cap. The
    /// result is the one a pass over the whole text gives, with or without the carried secrets.
    func test_theLargestAnswer_givesWhatAPassOverTheWholeTextGives() {
        let message = Self.words(bytes: 250 * 1_024)
        let carried = [jwt, String(repeating: "x", count: 43)]
        XCTAssertEqual(LogSanitizer.serverText(message), Self.wholeTextReference(message, hiding: []))
        XCTAssertEqual(LogSanitizer.serverText(message, hiding: carried), Self.wholeTextReference(message, hiding: carried))
        XCTAssertLessThanOrEqual(LogSanitizer.serverText(message).count, LogSanitizer.maximumLength)
        let echoing = "Rejected \(jwt) for Device \(deviceSecret) (installation \(uuid), token abcd1234): "
            + Self.words(bytes: 256 * 1_024 - 300)
        XCTAssertEqual(LogSanitizer.serverText(echoing, hiding: ["abcd1234", jwt]),
                       Self.wholeTextReference(echoing, hiding: ["abcd1234", jwt]))
        XCTAssertTrue(LogSanitizer.serverText(echoing, hiding: ["abcd1234"]).hasPrefix(
            "Rejected <redacted> for Device <redacted> (installation <redacted>, token <redacted>): the device"))
    }

    /// Outside text of every kind (identifiers, tokens, carried secrets, control characters, whitespace runs, Arabic,
    /// emoji, punctuation), read within the window: the same result as a pass over the whole text, character for
    /// character.
    func test_anyTextWithinTheWindow_givesWhatAPassOverTheWholeTextGives() {
        var random = TextRandom(seed: 0x5A11_5A17)
        let secrets = ["abcd1234", "customer.token.a", deviceSecret, "Ab3dEf5h.Ij7l"]
        let pieces = ["the", "device", "42", "com.salla.store42", "1.2.0-beta.1", jwt, signedToken, deviceSecret, pushToken,
                      uuid, standardBase64, "abcd1234", "customer.token.a", "Ab3dEf5h.Ij7l", "xabcd1234y",
                      "abcd1234abcd1234", " ", "  ", "\n\t", "\u{0}", "\u{200B}", ",", ":", "<", ">", ".", "=", "/",
                      "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", "\u{1F600}", "\u{00E9}"]
        for _ in 0..<400 {
            var text = ""
            while text.unicodeScalars.count < 1_200 {
                text += pieces[Int(random.next() % UInt64(pieces.count))]
                if random.next() % 3 == 0 { text += " " }
            }
            let hidden = secrets.filter { _ in random.next() % 2 == 0 }
            XCTAssertEqual(LogSanitizer.serverText(text, hiding: hidden), Self.wholeTextReference(text, hiding: hidden),
                           text)
        }
    }

    /// The work per answer is bounded by the window, not by the answer: the largest one costs a small fraction of a pass
    /// over its whole text (which took 40-60 ms on the engine queue before the work was bounded).
    func test_theWorkStaysBounded_forTheLargestAnswer() {
        let message = Self.words(bytes: 256 * 1_024)
        let carried = [jwt, String(repeating: "x", count: 43)]
        func milliseconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        let whole = milliseconds { _ = Self.wholeTextReference(message, hiding: carried) }
        let bounded = (0..<5).map { _ in milliseconds { _ = LogSanitizer.serverText(message, hiding: carried) } }.min() ?? 0
        XCTAssertLessThan(bounded * 10, whole, "bounded \(bounded) ms, whole text \(whole) ms")
    }

    /// A run the window cuts may be the start of a secret, so it is hidden whole, as Android hides a run its own input cap
    /// cuts: a carried secret straddling the window, and a run longer than the window, never show a fragment.
    func test_aRunTheWindowCuts_isHiddenWhole() {
        let secret = "Ab3dEf5hIj7lMn9pQr1tUv3xYz5bCd7fGh9jKl1nOp3"
        let window = LogSanitizer.scanWindow + secret.count
        let controls = String(repeating: "\u{1}", count: window - 6)
        let straddling = LogSanitizer.serverText(controls + secret + " tail", hiding: [secret])
        XCTAssertEqual(straddling, "<redacted>")
        let dotted = String(repeating: "ab.", count: 100_000)
        XCTAssertEqual(LogSanitizer.serverText("Bad " + dotted), "Bad <redacted>",
                       "a run too long to judge in the window is hidden, not cut")
        let short = String(repeating: "ab.", count: 50)
        XCTAssertEqual(LogSanitizer.serverText("Bad " + short), Self.wholeTextReference("Bad " + short, hiding: []))
    }

    /// A carried secret is matched character for character inside its run, so a combining mark after it (which defeats
    /// a canonical-equivalence search) never lets it show.
    func test_aCarriedSecretFollowedByACombiningMark_isHidden() {
        XCTAssertEqual(LogSanitizer.serverText("token abcd1234\u{301} echoed", hiding: ["abcd1234"]),
                       "token <redacted>\u{301} echoed")
    }

    /// Occurrences of a carried secret are found left to right without overlap, as a pass over the whole text finds
    /// them, also in text built to nearly match it.
    func test_nearMatchesOfACarriedSecret_areResolvedAsAPassOverTheWholeText() {
        let cases: [(String, String)] = [
            ("ababab1234", "abab1234"),
            ("aaaa.aaaa.aaab.x1 end", "aaaa.aaab.x1"),
            ("abcd1234abcd1234abcd123", "abcd1234abcd1234"),
            (String(repeating: "a", count: 1_000) + "b", String(repeating: "a", count: 40) + "b"),
        ]
        for (text, secret) in cases {
            XCTAssertEqual(LogSanitizer.serverText(text, hiding: [secret]), Self.wholeTextReference(text, hiding: [secret]),
                           secret)
        }
        XCTAssertEqual(LogSanitizer.serverText("ababab1234", hiding: ["abab1234"]), "ab<redacted>")
    }

    /// A carried secret with a character no run holds (none of a request's secrets has one) can straddle runs, so the
    /// whole text is read for it: it is still hidden, wherever it is.
    func test_aCarriedSecretThatIsNotARun_isStillHidden() {
        let secret = "open sesame 42"
        let text = String(repeating: "word ", count: 30) + secret + " twice: " + secret + String(repeating: " tail", count: 99)
        XCTAssertFalse(LogSanitizer.serverText(text, hiding: [secret]).contains("sesame"))
        XCTAssertEqual(LogSanitizer.serverText("then " + secret + " end", hiding: [secret]), "then <redacted> end")
        XCTAssertEqual(LogSanitizer.serverText(text, hiding: [secret]), Self.wholeTextReference(text, hiding: [secret]))
    }

    /// Ordinary words, `bytes` long.
    private static func words(bytes: Int) -> String {
        let words = ["the", "device", "secret", "is", "invalid", "request", "failed", "with", "code", "42"]
        var message = ""
        var index = 0
        while message.utf8.count < bytes {
            message += words[index % words.count] + " "
            index += 1
        }
        return message
    }

    /// The rule as a pass over the whole text applies it (`serverText` before its work was bounded), for
    /// comparison.
    private static func wholeTextReference(_ raw: String, hiding secrets: [String]) -> String {
        var text = ""
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace && !text.isEmpty { text.unicodeScalars.append(" ") }
                lastWasSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                continue
            default:
                text.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        for secret in secrets where secret.count >= LogSanitizer.minimumHiddenSecretLength {
            text = text.replacingOccurrences(of: secret, with: LogSanitizer.redacted)
        }
        let masked = LogSanitizer.maskingTokens(text)
        guard masked.unicodeScalars.count > LogSanitizer.maximumLength else { return masked }
        var result = ""
        result.unicodeScalars.append(contentsOf: masked.unicodeScalars.prefix(LogSanitizer.maximumLength))
        return result.trimmingCharacters(in: .whitespaces)
    }

    func test_controlCharacters_andWhitespace_areCleaned() {
        XCTAssertEqual(LogSanitizer.serverText("Bad\n\nthing\u{0} \t here"), "Bad thing here")
        XCTAssertEqual(LogSanitizer.clean("a\nb\u{0}c"), "a bc")
    }

    func test_describe_masksTheErrorDescription() {
        let error = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed for Device \(deviceSecret)"])
        XCTAssertEqual(LogSanitizer.describe(error), "Test 7, Failed for Device <redacted>")
    }

    func test_printableASCII_replacesTheRest_andCaps() {
        XCTAssertEqual(LogSanitizer.printableASCII("v\u{E9}\u{1}rbose", maximum: 5), "v??rb")
        XCTAssertEqual(LogSanitizer.printableASCII("warn", maximum: 32), "warn")
    }
}

/// A small deterministic random generator (SplitMix64) for the text model tests.
private struct TextRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
