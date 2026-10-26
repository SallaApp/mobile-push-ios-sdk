import Foundation

/// JSON text read back from storage (SallaPush's files and Keychain items). It is decoded only once the byte scan has
/// shown that it is UTF-8 and nested at most `JSONValue.maximumDepth` levels (SallaPush writes at most 4), so a corrupt
/// or tampered file never reaches a recursive parser that could overflow the stack of the thread decoding it.
package enum StoredJSON {
    /// The decoded value, or nil when the text is unreadable, too deep or not a valid `Value`.
    package static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) -> Value? {
        guard DepthLimit.jsonFits(data, maxDepth: JSONValue.maximumDepth) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
