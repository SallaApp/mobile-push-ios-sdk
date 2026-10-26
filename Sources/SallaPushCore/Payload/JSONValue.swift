import Foundation

/// Converts payload values to plain JSON types, keeping their types and dropping anything deeper than 32 levels.
package enum JSONValue {
    /// Containers nested deeper than this are dropped.
    package static let maximumDepth = 32

    /// The JSON form of `value`: `String`, `NSNumber`, `NSNull`, `[String: Any]` or `[Any]`.
    /// - Parameters:
    ///   - depth: the nesting level of `value` itself (a top-level container is 1).
    ///   - truncated: set to true when a subtree was dropped for depth.
    /// - Returns: nil for values that are not JSON (dates, data, custom objects) or containers past the limit.
    package static func sanitize(_ value: Any, depth: Int, truncated: inout Bool) -> Any? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number }
        if value is NSNull { return NSNull() }
        if let dictionary = value as? [AnyHashable: Any] {
            guard depth <= maximumDepth else {
                truncated = true
                return nil
            }
            return sanitizeDictionary(dictionary, depth: depth, truncated: &truncated)
        }
        if let array = value as? [Any] {
            guard depth <= maximumDepth else {
                truncated = true
                return nil
            }
            var result: [Any] = []
            result.reserveCapacity(array.count)
            for element in array {
                if let converted = sanitize(element, depth: depth + 1, truncated: &truncated) {
                    result.append(converted)
                }
            }
            return result
        }
        return nil
    }

    /// Converts a dictionary whose own level is `depth`; keys that are not strings are dropped.
    package static func sanitizeDictionary(_ dictionary: [AnyHashable: Any], depth: Int,
                                           truncated: inout Bool) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, element) in dictionary {
            guard let key = key.base as? String else { continue }
            if let converted = sanitize(element, depth: depth + 1, truncated: &truncated) {
                result[key] = converted
            }
        }
        return result
    }
}
