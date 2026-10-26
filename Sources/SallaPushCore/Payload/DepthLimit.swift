import Foundation

/// Bounded measurement of nested payload data. The walk never recurses deeper than the limit,
/// so a hostile 2,000-level document cannot exhaust a small thread stack.
package enum DepthLimit {
    /// The largest `custom` object of the compatible payload format SallaPush accepts, in bytes of text.
    package static let maximumCompatBytes = 4_096

    /// Whether `value` nests at most `maxDepth` containers and its text weighs at most `maxBytes`.
    package static func fits(_ value: Any, maxDepth: Int, maxBytes: Int) -> Bool {
        var budget = maxBytes
        return walk(value, depth: 1, maxDepth: maxDepth, budget: &budget)
    }

    /// Whether the UTF-8 JSON text `data` nests objects and arrays at most `maxDepth` levels. `JSONSerialization`
    /// parses recursively, about 1 KB of stack a level, so a few KB of nesting would overflow a GCD thread: this
    /// string-aware scan, a plain loop, runs before any parser sees outside text. Without JSON5 the parser accepts no
    /// comments or unquoted text, so brackets outside strings are exactly its nesting. In UTF-8 no byte of a multi-byte
    /// character is ASCII. Text with a NUL byte never fits: UTF-16 and UTF-32, which the parser also detects, put one in
    /// every ASCII character, and their other bytes could hide brackets from this scan.
    package static func jsonFits(_ data: Data, maxDepth: Int) -> Bool {
        let quote = UInt8(ascii: "\"")
        let backslash = UInt8(ascii: "\\")
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if byte == 0 { return false }
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                continue
            }
            switch byte {
            case quote:
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                if depth > maxDepth { return false }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }
        return true
    }

    private static func walk(_ value: Any, depth: Int, maxDepth: Int, budget: inout Int) -> Bool {
        if let string = value as? String {
            budget -= string.utf8.count + 2
            return budget >= 0
        }
        if let dictionary = value as? [AnyHashable: Any] {
            return walk(dictionary: dictionary, depth: depth, maxDepth: maxDepth, budget: &budget)
        }
        if let array = value as? [Any] {
            return walk(array: array, depth: depth, maxDepth: maxDepth, budget: &budget)
        }
        // Numbers, null and anything else count as a short scalar.
        budget -= 8
        return budget >= 0
    }

    private static func walk(dictionary: [AnyHashable: Any], depth: Int, maxDepth: Int, budget: inout Int) -> Bool {
        guard depth <= maxDepth else { return false }
        budget -= 2
        for (key, element) in dictionary {
            if let key = key.base as? String { budget -= key.utf8.count + 3 }
            guard budget >= 0, walk(element, depth: depth + 1, maxDepth: maxDepth, budget: &budget) else {
                return false
            }
        }
        return budget >= 0
    }

    private static func walk(array: [Any], depth: Int, maxDepth: Int, budget: inout Int) -> Bool {
        guard depth <= maxDepth else { return false }
        budget -= 2
        for element in array {
            guard walk(element, depth: depth + 1, maxDepth: maxDepth, budget: &budget) else { return false }
        }
        return budget >= 0
    }
}
