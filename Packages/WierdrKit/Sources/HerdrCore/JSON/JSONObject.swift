/// A JSON object that remembers key order. Setting an existing key keeps its
/// place; a new key goes last. Equality ignores order (as JSON does).
public struct JSONObject: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    /// Keys in order.
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    /// From ordered pairs; a repeated key keeps its first place and last value.
    public init<S: Sequence>(_ pairs: S) where S.Element == (String, JSONValue) {
        for (k, v) in pairs { self[k] = v }
    }

    /// From a dictionary (unordered), keys sorted for a deterministic order.
    public init(_ dictionary: [String: JSONValue]) {
        keys = dictionary.keys.sorted()
        storage = dictionary
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// Values in key order.
    public var values: [JSONValue] { keys.compactMap { storage[$0] } }

    /// The members as an (unordered) dictionary.
    public var dictionary: [String: JSONValue] { storage }

    /// Member value; assigning nil removes the key.
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let old = storage.removeValue(forKey: key) else { return nil }
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) }
        return old
    }

    public func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var i = keys.makeIterator()
        let storage = storage
        return AnyIterator {
            while let k = i.next() {
                if let v = storage[k] { return (k, v) }
            }
            return nil
        }
    }

    public static func == (a: JSONObject, b: JSONObject) -> Bool { a.storage == b.storage }
    public func hash(into h: inout Hasher) { h.combine(storage) }
}
