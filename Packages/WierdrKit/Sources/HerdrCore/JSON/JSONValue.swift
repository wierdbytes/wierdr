import Foundation

/// Any JSON value, kept faithfully:
/// - integers stay integers (`.int`, or `.uint` above `Int64.max`) and doubles
///   stay doubles, so `4.0` and `4` survive a round trip as written;
/// - objects keep their key order (`JSONObject`), so a read-modify-write of a
///   document owned by another app changes only what you changed.
///
/// Parse with `JSONValue(data:)`, serialize with `data()`. `Codable` too
/// (inside HerdrCore models it is decoded straight from the parsed value, so
/// order and number kinds are kept there as well).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// An integer that fits `Int64`.
    case int(Int64)
    /// An integer above `Int64.max` (only those; smaller ones are `.int`).
    case uint(UInt64)
    /// A number written with a fraction or an exponent (or too big for `UInt64`).
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - Reading

extension JSONValue {
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }

    public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    public var object: JSONObject? { if case .object(let o) = self { return o } else { return nil } }

    /// An integer value as `Int64`: integers that fit, and integral doubles that fit.
    public var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .uint(let u): return Int64(exactly: u)
        case .double(let d): return Int64(exactly: d)
        default: return nil
        }
    }

    /// An integer value as `Int` (see `int64`).
    public var int: Int? { int64.flatMap { Int(exactly: $0) } }

    /// A non-negative integer value as `UInt64`.
    public var uint64: UInt64? {
        switch self {
        case .int(let i): return UInt64(exactly: i)
        case .uint(let u): return u
        case .double(let d): return UInt64(exactly: d)
        default: return nil
        }
    }

    /// Any number as `Double` (large integers may lose precision).
    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Object member, or nil when this is not an object or lacks the key.
    /// Setting on a non-object turns it into an object; setting nil removes the key.
    public subscript(key: String) -> JSONValue? {
        get { object?[key] }
        set {
            var o = object ?? JSONObject()
            o[key] = newValue
            self = .object(o)
        }
    }

    /// Array element, or nil when out of range or not an array.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }
}

// MARK: - Bytes

extension JSONValue {
    /// Parses one JSON document (surrounding whitespace allowed).
    public init(data: Data) throws {
        self = try JSONParser.parse(data)
    }

    /// Parses one JSON document from a string.
    public init(parsing text: String) throws {
        self = try JSONParser.parse(Data(text.utf8))
    }

    /// Serializes compactly (or indented with `pretty`), keys in object order.
    /// Throws for non-finite doubles, which JSON cannot express.
    public func data(pretty: Bool = false) throws -> Data {
        var w = JSONWriter(pretty: pretty)
        try w.write(self)
        return Data(w.bytes)
    }

    /// The serialized text (`data()` as UTF-8), or `"null"` if it cannot be serialized.
    public func jsonString(pretty: Bool = false) -> String {
        (try? data(pretty: pretty)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Encodes any `Encodable` into a `JSONValue` (via `JSONEncoder`).
    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONValue(data: JSONEncoder().encode(value))
    }

    /// Decodes a `Decodable` from this value without going through bytes.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONValueDecoder.decode(type, from: self)
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString() }
}

// MARK: - Literals

// Deliberately not ExpressibleByNilLiteral: `nil` must always mean "absent"
// (Optional.none), never JSON null. Write `.null` for null.
extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        // Fast and faithful path: decoding from an already parsed value.
        if let d = decoder as? JSONValueDecoder {
            self = d.value
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let u = try? c.decode(UInt64.self) {
            self = .uint(u)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(JSONObject(o))
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .int(let i):
            var c = encoder.singleValueContainer()
            try c.encode(i)
        case .uint(let u):
            var c = encoder.singleValueContainer()
            try c.encode(u)
        case .double(let d):
            var c = encoder.singleValueContainer()
            try c.encode(d)
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .object(let o):
            var c = encoder.container(keyedBy: AnyCodingKey.self)
            for (k, v) in o { try c.encode(v, forKey: AnyCodingKey(k)) }
        }
    }
}

/// A coding key for arbitrary strings.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
