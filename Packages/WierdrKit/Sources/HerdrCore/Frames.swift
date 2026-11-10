import Foundation

/// Frame kind byte. A struct (not an enum) so unknown kinds stay representable.
public struct FrameKind: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Channel 0: one JSON-RPC message. Other channels: stream bytes.
    public static let data = FrameKind(rawValue: 0)
    /// u32 LE: bytes the receiver consumed.
    public static let credit = FrameKind(rawValue: 1)
    /// The channel is over; from the core, a JSON reason (empty when acknowledging ours).
    public static let close = FrameKind(rawValue: 2)
    /// u16 LE cols, u16 LE rows.
    public static let resize = FrameKind(rawValue: 3)
    /// Viewer → core: 1 gained focus, 0 lost it.
    public static let focus = FrameKind(rawValue: 4)
    /// Viewer → core: JSON display facts (`Display`).
    public static let facts = FrameKind(rawValue: 5)
    /// Viewer → core: terminal-generated reply bytes, not human activity.
    public static let automaticInput = FrameKind(rawValue: 6)

    public var description: String {
        switch rawValue {
        case 0: "DATA"
        case 1: "CREDIT"
        case 2: "CLOSE"
        case 3: "RESIZE"
        case 4: "FOCUS"
        case 5: "FACTS"
        case 6: "AUTOMATIC_INPUT"
        default: "KIND(\(rawValue))"
        }
    }
}

/// One framed-mode frame: `[channel u32 LE][kind u8][len u32 LE][payload]`.
public struct Frame: Hashable, Sendable {
    public static let headerSize = 9
    public static let maxPayload = 16 << 20

    public var channel: UInt32
    public var kind: FrameKind
    public var payload: Data

    public init(channel: UInt32, kind: FrameKind, payload: Data = Data()) {
        self.channel = channel
        self.kind = kind
        self.payload = payload
    }

    /// The frame's wire bytes.
    public func encoded() -> Data {
        var out = Data(capacity: Frame.headerSize + payload.count)
        out.appendLE(channel)
        out.append(kind.rawValue)
        out.appendLE(UInt32(payload.count))
        out.append(payload)
        return out
    }

    // Constructors for control payloads.

    public static func credit(_ channel: UInt32, _ bytes: UInt32) -> Frame {
        var p = Data(capacity: 4)
        p.appendLE(bytes)
        return Frame(channel: channel, kind: .credit, payload: p)
    }

    public static func resize(_ channel: UInt32, cols: UInt16, rows: UInt16) -> Frame {
        var p = Data(capacity: 4)
        p.appendLE(cols)
        p.appendLE(rows)
        return Frame(channel: channel, kind: .resize, payload: p)
    }

    /// RESIZE payload as (cols, rows), nil when malformed.
    public var resizeSize: (cols: UInt16, rows: UInt16)? {
        guard kind == .resize, payload.count == 4 else { return nil }
        let b = [UInt8](payload)
        return (UInt16(b[0]) | UInt16(b[1]) << 8, UInt16(b[2]) | UInt16(b[3]) << 8)
    }

    /// CREDIT payload, nil when malformed.
    public var creditBytes: UInt32? {
        guard kind == .credit, payload.count == 4 else { return nil }
        return [UInt8](payload).readLE32(at: 0)
    }
}

/// A frame stream that cannot be decoded (the connection must be dropped).
public struct FrameError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
}

/// Incremental frame decoder: feed any chunking of the byte stream, get whole frames.
public struct FrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var head = 0

    public init() {}

    /// Bytes buffered but not yet forming a whole frame.
    public var bufferedCount: Int { buffer.count - head }

    /// Appends bytes and returns every frame completed by them, in order.
    public mutating func push(_ chunk: Data) throws -> [Frame] {
        buffer.append(contentsOf: chunk)
        var frames: [Frame] = []
        while buffer.count - head >= Frame.headerSize {
            let channel = buffer.readLE32(at: head)
            let kind = FrameKind(rawValue: buffer[head + 4])
            let length = Int(buffer.readLE32(at: head + 5))
            guard length <= Frame.maxPayload else {
                throw FrameError(description: "frame of \(length) bytes exceeds \(Frame.maxPayload)")
            }
            let start = head + Frame.headerSize
            guard buffer.count - start >= length else { break }
            frames.append(Frame(channel: channel, kind: kind, payload: Data(buffer[start..<start + length])))
            head = start + length
        }
        compact()
        return frames
    }

    private mutating func compact() {
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.capacity <= 1 << 20)
            head = 0
        } else if head > 64 * 1024 && head * 2 > buffer.count {
            buffer.removeSubrange(0..<head)
            head = 0
        }
    }
}

extension Data {
    mutating func appendLE(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)])
    }

    mutating func appendLE(_ v: UInt16) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)])
    }
}

extension Array where Element == UInt8 {
    func readLE32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
