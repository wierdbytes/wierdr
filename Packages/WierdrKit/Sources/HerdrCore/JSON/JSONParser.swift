import Foundation

/// A JSON text that could not be parsed.
public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    /// Byte offset where parsing failed.
    public let offset: Int
    public var description: String { "invalid JSON at byte \(offset): \(message)" }
}

/// Strict RFC 8259 parser producing order-preserving, number-faithful `JSONValue`s.
enum JSONParser {
    /// Like serde_json's limit; keeps recursion far from small thread stacks.
    static let maxDepth = 128

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            var p = Cursor(bytes: raw.bindMemory(to: UInt8.self))
            p.skipWhitespace()
            let value = try p.value(depth: 0)
            p.skipWhitespace()
            guard p.at == p.bytes.count else { throw p.error("trailing characters") }
            return value
        }
    }

    struct Cursor {
        let bytes: UnsafeBufferPointer<UInt8>
        var at = 0

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: at) }

        var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

        mutating func skipWhitespace() {
            while at < bytes.count {
                switch bytes[at] {
                case 0x20, 0x09, 0x0A, 0x0D: at += 1
                default: return
                }
            }
        }

        mutating func expect(_ literal: StaticString, _ value: JSONValue) throws -> JSONValue {
            let n = literal.utf8CodeUnitCount
            guard at + n <= bytes.count else { throw error("unexpected end") }
            let lit = literal.utf8Start
            for i in 0..<n where bytes[at + i] != lit[i] { throw error("invalid literal") }
            at += n
            return value
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < JSONParser.maxDepth else { throw error("nested too deeply") }
            guard let c = peek else { throw error("unexpected end") }
            switch c {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try expect("true", .bool(true))
            case UInt8(ascii: "f"): return try expect("false", .bool(false))
            case UInt8(ascii: "n"): return try expect("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
            default: throw error("unexpected character")
            }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            at += 1
            var o = JSONObject()
            skipWhitespace()
            if peek == UInt8(ascii: "}") {
                at += 1
                return .object(o)
            }
            while true {
                skipWhitespace()
                guard peek == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                skipWhitespace()
                guard peek == UInt8(ascii: ":") else { throw error("expected ':'") }
                at += 1
                skipWhitespace()
                o[key] = try value(depth: depth + 1)
                skipWhitespace()
                switch peek {
                case UInt8(ascii: ","): at += 1
                case UInt8(ascii: "}"):
                    at += 1
                    return .object(o)
                default: throw error("expected ',' or '}'")
                }
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            at += 1
            var a: [JSONValue] = []
            skipWhitespace()
            if peek == UInt8(ascii: "]") {
                at += 1
                return .array(a)
            }
            while true {
                skipWhitespace()
                a.append(try value(depth: depth + 1))
                skipWhitespace()
                switch peek {
                case UInt8(ascii: ","): at += 1
                case UInt8(ascii: "]"):
                    at += 1
                    return .array(a)
                default: throw error("expected ',' or ']'")
                }
            }
        }

        mutating func number() throws -> JSONValue {
            let start = at
            var integral = true
            if peek == UInt8(ascii: "-") { at += 1 }
            guard let first = peek, isDigit(first) else { throw error("invalid number") }
            if first == UInt8(ascii: "0") {
                at += 1
            } else {
                while let c = peek, isDigit(c) { at += 1 }
            }
            if peek == UInt8(ascii: ".") {
                integral = false
                at += 1
                guard let c = peek, isDigit(c) else { throw error("invalid fraction") }
                while let c = peek, isDigit(c) { at += 1 }
            }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                integral = false
                at += 1
                if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { at += 1 }
                guard let c = peek, isDigit(c) else { throw error("invalid exponent") }
                while let c = peek, isDigit(c) { at += 1 }
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
            if integral {
                if let i = Int64(text) { return .int(i) }
                if let u = UInt64(text) { return .uint(u) }
            }
            guard let d = Double(text), d.isFinite else { throw JSONParseError(message: "number out of range", offset: start) }
            return .double(d)
        }

        func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

        mutating func string() throws -> String {
            at += 1  // opening quote
            let start = at
            // Fast path: no escapes.
            while at < bytes.count {
                let c = bytes[at]
                if c == UInt8(ascii: "\"") {
                    let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self)
                    at += 1
                    return s
                }
                if c == UInt8(ascii: "\\") { break }
                if c < 0x20 { throw error("control character in string") }
                at += 1
            }
            var out = [UInt8](UnsafeBufferPointer(rebasing: bytes[start..<at]))
            while at < bytes.count {
                let c = bytes[at]
                switch c {
                case UInt8(ascii: "\""):
                    at += 1
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    at += 1
                    guard let e = peek else { throw error("unexpected end") }
                    at += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"): appendScalar(try unicodeEscape(), to: &out)
                    default: throw error("invalid escape")
                    }
                default:
                    if c < 0x20 { throw error("control character in string") }
                    out.append(c)
                    at += 1
                }
            }
            throw error("unterminated string")
        }

        /// After `\u`: a scalar, joining surrogate pairs; lone surrogates become U+FFFD.
        mutating func unicodeEscape() throws -> Unicode.Scalar {
            let high = try hex4()
            if (0xD800...0xDBFF).contains(high) {
                if at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
                    let save = at
                    at += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        let value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                        return Unicode.Scalar(value) ?? "\u{FFFD}"
                    }
                    at = save
                }
                return "\u{FFFD}"
            }
            return Unicode.Scalar(high) ?? "\u{FFFD}"
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= bytes.count else { throw error("unexpected end") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[at]
                let d: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A") + 10)
                default: throw error("invalid \\u escape")
                }
                v = v << 4 | d
                at += 1
            }
            return v
        }

        func appendScalar(_ s: Unicode.Scalar, to out: inout [UInt8]) {
            out.append(contentsOf: UTF8.encode(s).map { Array($0) } ?? [0xEF, 0xBF, 0xBD])
        }
    }
}
