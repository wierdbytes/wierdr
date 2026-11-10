import Foundation
import Synchronization

/// The ordered outgoing byte queue of a connection. Enqueueing never blocks or
/// suspends, so UI code can send keystrokes synchronously and in order; one
/// writer task drains it into the transport.
final class Outbound: Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let stream: AsyncStream<Data>

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    /// Queues bytes; false once the connection is over.
    @discardableResult
    func send(_ bytes: Data) -> Bool {
        if case .terminated = continuation.yield(bytes) { return false }
        return true
    }

    @discardableResult
    func send(_ frame: Frame) -> Bool { send(frame.encoded()) }

    func finish() { continuation.finish() }
}

/// Receives the frames of one framed channel (an attach stream or an event subscription).
/// `receive` is only ever called from the connection's read loop, in wire order.
protocol ChannelSink: AnyObject, Sendable {
    var channel: UInt32 { get }
    /// Handles one frame. Returns false when the channel is over (the core's CLOSE).
    func receive(_ frame: Frame) -> Bool
    /// The connection ended; finish the consumer's stream.
    func connectionEnded(_ error: ConnectionError)
}

/// Batches CREDIT frames: small acknowledgements are added up and sent once
/// they reach `threshold`. The core's window is 256 KiB, so a threshold well
/// below it never stalls a stream.
struct CreditBatcher {
    static let defaultThreshold = 16 * 1024
    var threshold: Int = CreditBatcher.defaultThreshold
    private(set) var pending = 0

    /// Adds consumed bytes; returns the credit to send now, if any.
    mutating func add(_ bytes: Int) -> UInt32? {
        guard bytes > 0 else { return nil }
        pending += bytes
        guard pending >= threshold else { return nil }
        let n = UInt32(clamping: pending)
        pending -= Int(n)
        return n
    }
}

/// The event channel of a subscription: JSON lines (possibly split across
/// frames) parsed into `CoreEvent`s. Credits itself as it parses: the
/// `AsyncStream` buffers events, so the read loop never waits on the consumer.
final class EventSink: ChannelSink {
    let channel: UInt32
    let stream: AsyncStream<CoreEvent>
    private let continuation: AsyncStream<CoreEvent>.Continuation
    private let outbound: Outbound
    private let state = Mutex(State())

    private struct State {
        var partial = Data()
        var credit = CreditBatcher()
        var cancelled = false
    }

    init(channel: UInt32, outbound: Outbound) {
        self.channel = channel
        self.outbound = outbound
        (stream, continuation) = AsyncStream.makeStream(of: CoreEvent.self, bufferingPolicy: .unbounded)
    }

    func receive(_ frame: Frame) -> Bool {
        switch frame.kind {
        case .data:
            let (lines, credit) = state.withLock { s -> ([Data], UInt32?) in
                s.partial.append(frame.payload)
                var lines: [Data] = []
                var start = s.partial.startIndex
                while let nl = s.partial[start...].firstIndex(of: 0x0A) {
                    lines.append(s.partial[start..<nl])
                    start = nl + 1
                }
                if start > s.partial.startIndex { s.partial = Data(s.partial[start...]) }
                if s.partial.count > Frame.maxPayload * 2 { s.partial = Data() }  // not a line protocol
                return (lines, s.credit.add(frame.payload.count))
            }
            if let credit { outbound.send(.credit(channel, credit)) }
            for line in lines where !line.isEmpty {
                guard let message = try? JSONValue(data: line), let event = CoreEvent.parse(message) else { continue }
                continuation.yield(event)
            }
            return true
        case .close:
            continuation.finish()
            return false
        default:
            return true
        }
    }

    func connectionEnded(_ error: ConnectionError) { continuation.finish() }

    func cancel() {
        let first = state.withLock { s in
            defer { s.cancelled = true }
            return !s.cancelled
        }
        guard first else { return }
        if !outbound.send(Frame(channel: channel, kind: .close)) { continuation.finish() }
    }
}
