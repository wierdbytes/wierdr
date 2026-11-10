/// A value JSON cannot express (a non-finite double).
public struct JSONWriteError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

/// Serializes `JSONValue`s: object keys in order, numbers as their kind.
struct JSONWriter {
    let pretty: Bool
    var bytes: [UInt8] = []
    private var indent = 0

    init(pretty: Bool) { self.pretty = pretty }

    mutating func write(_ value: JSONValue) throws {
        switch value {
        case .null: append("null")
        case .bool(let b): append(b ? "true" : "false")
        case .int(let i): append(String(i))
        case .uint(let u): append(String(u))
        case .double(let d):
            guard d.isFinite else { throw JSONWriteError(description: "non-finite number \(d)") }
            // Swift prints the shortest representation that round-trips ("4.0", "1e-05").
            append(d.description)
        case .string(let s): writeString(s)
        case .array(let a):
            guard !a.isEmpty else { return append("[]") }
            bytes.append(UInt8(ascii: "["))
            indent += 1
            for (i, v) in a.enumerated() {
                if i > 0 { bytes.append(UInt8(ascii: ",")) }
                newline()
                try write(v)
            }
            indent -= 1
            newline()
            bytes.append(UInt8(ascii: "]"))
        case .object(let o):
            guard !o.isEmpty else { return append("{}") }
            bytes.append(UInt8(ascii: "{"))
            indent += 1
            var first = true
            for (k, v) in o {
                if !first { bytes.append(UInt8(ascii: ",")) }
                first = false
                newline()
                writeString(k)
                bytes.append(UInt8(ascii: ":"))
                if pretty { bytes.append(UInt8(ascii: " ")) }
                try write(v)
            }
            indent -= 1
            newline()
            bytes.append(UInt8(ascii: "}"))
        }
    }

    private mutating func append(_ s: String) { bytes.append(contentsOf: s.utf8) }

    private mutating func newline() {
        guard pretty else { return }
        bytes.append(0x0A)
        bytes.append(contentsOf: repeatElement(UInt8(ascii: " "), count: indent * 2))
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    mutating func writeString(_ s: String) {
        bytes.append(UInt8(ascii: "\""))
        for c in s.utf8 {
            switch c {
            case 0x22: bytes.append(contentsOf: [0x5C, 0x22])
            case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: bytes.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: bytes.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: bytes.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x08: bytes.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: bytes.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0..<0x20:
                bytes.append(contentsOf: Array("\\u00".utf8))
                bytes.append(Self.hex[Int(c >> 4)])
                bytes.append(Self.hex[Int(c & 0xF)])
            default: bytes.append(c)
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }
}
