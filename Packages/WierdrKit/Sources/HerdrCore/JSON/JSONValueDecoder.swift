import Foundation

/// A `Decoder` reading straight from a parsed `JSONValue`: no re-serialization,
/// and nested `JSONValue` fields keep their exact numbers and key order.
/// Keys are used as written (models declare snake_case `CodingKeys`).
struct JSONValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try T(from: JSONValueDecoder(value: value, codingPath: []))
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let o) = value else { throw mismatch([String: JSONValue].self, value, codingPath) }
        return KeyedDecodingContainer(Keyed<Key>(object: o, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let a) = value else { throw mismatch([JSONValue].self, value, codingPath) }
        return Unkeyed(array: a, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer { Single(value: value, codingPath: codingPath) }
}

private func mismatch(_ type: Any.Type, _ value: JSONValue, _ path: [CodingKey]) -> DecodingError {
    .typeMismatch(type, .init(codingPath: path, debugDescription: "expected \(type), found \(value.jsonString())"))
}

/// Primitive conversions shared by all containers.
private func primitive<T>(_ type: T.Type, _ value: JSONValue, _ path: [CodingKey]) throws -> T {
    let result: Any?
    switch type {
    case is Bool.Type: result = value.bool
    case is String.Type: result = value.string
    case is Double.Type: result = value.double
    case is Float.Type: result = value.double.map { Float($0) }
    case is Int.Type: result = value.int64.flatMap { Int(exactly: $0) }
    case is Int8.Type: result = value.int64.flatMap { Int8(exactly: $0) }
    case is Int16.Type: result = value.int64.flatMap { Int16(exactly: $0) }
    case is Int32.Type: result = value.int64.flatMap { Int32(exactly: $0) }
    case is Int64.Type: result = value.int64
    case is UInt.Type: result = value.uint64.flatMap { UInt(exactly: $0) }
    case is UInt8.Type: result = value.uint64.flatMap { UInt8(exactly: $0) }
    case is UInt16.Type: result = value.uint64.flatMap { UInt16(exactly: $0) }
    case is UInt32.Type: result = value.uint64.flatMap { UInt32(exactly: $0) }
    case is UInt64.Type: result = value.uint64
    default: result = nil
    }
    guard let typed = result as? T else { throw mismatch(type, value, path) }
    return typed
}

private func decodeAny<T: Decodable>(_ type: T.Type, _ value: JSONValue, _ path: [CodingKey]) throws -> T {
    if T.self == JSONValue.self, let v = value as? T { return v }
    return try T(from: JSONValueDecoder(value: value, codingPath: path))
}

private struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: JSONObject
    let codingPath: [CodingKey]

    var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }
    func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

    func get(_ key: Key) throws -> JSONValue {
        guard let v = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "no \"\(key.stringValue)\""))
        }
        return v
    }

    func decodeNil(forKey key: Key) throws -> Bool { try get(key).isNull }
    func decode(_ t: Bool.Type, forKey k: Key) throws -> Bool { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: String.Type, forKey k: Key) throws -> String { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: Double.Type, forKey k: Key) throws -> Double { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: Float.Type, forKey k: Key) throws -> Float { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: Int.Type, forKey k: Key) throws -> Int { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: Int8.Type, forKey k: Key) throws -> Int8 { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: Int16.Type, forKey k: Key) throws -> Int16 { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: Int32.Type, forKey k: Key) throws -> Int32 { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: Int64.Type, forKey k: Key) throws -> Int64 { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: UInt.Type, forKey k: Key) throws -> UInt { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: UInt8.Type, forKey k: Key) throws -> UInt8 { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: UInt16.Type, forKey k: Key) throws -> UInt16 { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: UInt32.Type, forKey k: Key) throws -> UInt32 { try primitive(t, get(k), codingPath + [k]) }
    func decode(_ t: UInt64.Type, forKey k: Key) throws -> UInt64 { try primitive(t, get(k), codingPath + [k]) }
    func decode<T: Decodable>(_ t: T.Type, forKey k: Key) throws -> T { try decodeAny(t, get(k), codingPath + [k]) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        try JSONValueDecoder(value: get(key), codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try JSONValueDecoder(value: get(key), codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        JSONValueDecoder(value: .object(object), codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        JSONValueDecoder(value: object[key.stringValue] ?? .null, codingPath: codingPath + [key])
    }
}

private struct Unkeyed: UnkeyedDecodingContainer {
    let array: [JSONValue]
    let codingPath: [CodingKey]
    var currentIndex = 0

    init(array: [JSONValue], codingPath: [CodingKey]) {
        self.array = array
        self.codingPath = codingPath
    }

    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }

    private var key: CodingKey { AnyCodingKey(intValue: currentIndex) ?? AnyCodingKey("\(currentIndex)") }

    mutating func next() throws -> JSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                JSONValue.self, .init(codingPath: codingPath, debugDescription: "unkeyed container is at end"))
        }
        defer { currentIndex += 1 }
        return array[currentIndex]
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd, array[currentIndex].isNull else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode(_ t: Bool.Type) throws -> Bool { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: String.Type) throws -> String { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: Double.Type) throws -> Double { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: Float.Type) throws -> Float { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: Int.Type) throws -> Int { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: Int8.Type) throws -> Int8 { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: Int16.Type) throws -> Int16 { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: Int32.Type) throws -> Int32 { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: Int64.Type) throws -> Int64 { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: UInt.Type) throws -> UInt { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: UInt8.Type) throws -> UInt8 { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: UInt16.Type) throws -> UInt16 { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: UInt32.Type) throws -> UInt32 { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode(_ t: UInt64.Type) throws -> UInt64 { let p = codingPath + [key]; return try primitive(t, next(), p) }
    mutating func decode<T: Decodable>(_ t: T.Type) throws -> T { let p = codingPath + [key]; return try decodeAny(t, next(), p) }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey>
    {
        let p = codingPath + [key]
        return try JSONValueDecoder(value: next(), codingPath: p).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let p = codingPath + [key]
        return try JSONValueDecoder(value: next(), codingPath: p).unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        let p = codingPath + [key]
        return JSONValueDecoder(value: try next(), codingPath: p)
    }
}

private struct Single: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [CodingKey]

    func decodeNil() -> Bool { value.isNull }
    func decode(_ t: Bool.Type) throws -> Bool { try primitive(t, value, codingPath) }
    func decode(_ t: String.Type) throws -> String { try primitive(t, value, codingPath) }
    func decode(_ t: Double.Type) throws -> Double { try primitive(t, value, codingPath) }
    func decode(_ t: Float.Type) throws -> Float { try primitive(t, value, codingPath) }
    func decode(_ t: Int.Type) throws -> Int { try primitive(t, value, codingPath) }
    func decode(_ t: Int8.Type) throws -> Int8 { try primitive(t, value, codingPath) }
    func decode(_ t: Int16.Type) throws -> Int16 { try primitive(t, value, codingPath) }
    func decode(_ t: Int32.Type) throws -> Int32 { try primitive(t, value, codingPath) }
    func decode(_ t: Int64.Type) throws -> Int64 { try primitive(t, value, codingPath) }
    func decode(_ t: UInt.Type) throws -> UInt { try primitive(t, value, codingPath) }
    func decode(_ t: UInt8.Type) throws -> UInt8 { try primitive(t, value, codingPath) }
    func decode(_ t: UInt16.Type) throws -> UInt16 { try primitive(t, value, codingPath) }
    func decode(_ t: UInt32.Type) throws -> UInt32 { try primitive(t, value, codingPath) }
    func decode(_ t: UInt64.Type) throws -> UInt64 { try primitive(t, value, codingPath) }
    func decode<T: Decodable>(_ t: T.Type) throws -> T { try decodeAny(t, value, codingPath) }
}
