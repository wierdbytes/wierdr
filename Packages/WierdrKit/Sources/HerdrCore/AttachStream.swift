import Foundation
import Synchronization

/// What an attach stream delivers, in wire order.
public enum AttachEvent: Sendable, Equatable {
    /// Terminal output: first the paint of the current screen, then the program's raw bytes.
    /// Feed it to the terminal emulator, then call `AttachStream.consumed(_:)` with its count.
    case data(Data)
    /// The terminal's grid changed (observers with confirmed `resizeNotifications`).
    /// Apply it before the data that follows (an authoritative repaint).
    case resize(cols: Int, rows: Int)
    /// The stream is over; the last event. `reason` is the core's JSON, e.g.
    /// `{"reason":"exited","exit_code":0,"signal":null,"finished_ms":...}`; nil when
    /// we detached (`close()`); `{"reason":"disconnected","message":...}` when the connection dropped.
    case closed(reason: JSONValue?)
}

/// One viewer of a terminal on a framed channel (`terminal.attach`).
///
/// All methods are synchronous, cheap and safe from any thread: they queue
/// frames in order on the connection. After the stream is closed they do nothing.
///
/// Flow control: the core sends at most 256 KiB ahead of what you acknowledge.
/// Call `consumed(_:)` after feeding each `.data` chunk to the emulator; small
/// acknowledgements are batched into CREDIT frames. A viewer more than 4 MiB
/// behind gets a fresh repaint instead of the backlog.
public final class AttachStream: ChannelSink, Sendable {
    public let channel: UInt32
    /// The terminal as it was when attached.
    public let terminal: Terminal
    /// Whether `sendAutomatic` uses AUTOMATIC_INPUT frames (both the core's
    /// hello and this attach confirmed it); otherwise it falls back to DATA.
    public let automaticInput: Bool
    /// Whether the core will send `.resize` before replacement paints (observers only).
    public let resizeNotifications: Bool
    /// Whether this is a watch-only viewer (input and resizes are ignored by the core).
    public let observe: Bool
    /// Output in order. Single consumer.
    public let output: AsyncStream<AttachEvent>

    private let continuation: AsyncStream<AttachEvent>.Continuation
    private let outbound: Outbound
    private let state: Mutex<State>

    private struct State {
        var credit: CreditBatcher
        var closing = false
        var finished = false
    }

    init(channel: UInt32, terminal: Terminal, automaticInput: Bool, resizeNotifications: Bool, observe: Bool,
         outbound: Outbound, creditThreshold: Int = CreditBatcher.defaultThreshold) {
        self.channel = channel
        self.terminal = terminal
        self.automaticInput = automaticInput
        self.resizeNotifications = resizeNotifications
        self.observe = observe
        self.outbound = outbound
        state = Mutex(State(credit: CreditBatcher(threshold: creditThreshold)))
        (output, continuation) = AsyncStream.makeStream(of: AttachEvent.self, bufferingPolicy: .unbounded)
    }

    /// True once `close()` was called or the stream ended.
    public var isClosed: Bool { state.withLock { $0.closing || $0.finished } }

    // MARK: Viewer → core

    /// Keyboard input (or pasted text), as bytes for the program. Takes size ownership.
    public func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        for chunk in bytes.chunked(Frame.maxPayload) { enqueue(Frame(channel: channel, kind: .data, payload: chunk)) }
    }

    /// Replies the terminal emulator generated itself (answers to queries such as
    /// DA, DSR, mode 2048 reports): not human activity, no size ownership.
    /// Falls back to DATA when the path did not negotiate `automatic_input`.
    public func sendAutomatic(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let kind: FrameKind = automaticInput ? .automaticInput : .data
        for chunk in bytes.chunked(Frame.maxPayload) { enqueue(Frame(channel: channel, kind: kind, payload: chunk)) }
    }

    /// The viewer's grid changed.
    public func resize(cols: Int, rows: Int) {
        enqueue(.resize(channel, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows)))
    }

    /// The viewer gained (true) or lost focus. Gaining focus makes it the active viewer.
    public func focus(_ focused: Bool) {
        enqueue(Frame(channel: channel, kind: .focus, payload: Data([focused ? 1 : 0])))
    }

    /// The viewer's colors or cell size changed.
    public func facts(_ display: Display) {
        guard let payload = try? JSONEncoder().encode(display) else { return }
        enqueue(Frame(channel: channel, kind: .facts, payload: payload))
    }

    /// Acknowledges output fed to the emulator (sum of `.data` byte counts).
    /// Cheap; batches into CREDIT frames.
    public func consumed(_ byteCount: Int) {
        let credit = state.withLock { s -> UInt32? in
            s.closing || s.finished ? nil : s.credit.add(byteCount)
        }
        if let credit { outbound.send(.credit(channel, credit)) }
    }

    /// Detaches (CLOSE). `output` ends with `.closed(reason: nil)` once the core confirms.
    public func close() {
        let first = state.withLock { s in
            defer { s.closing = true }
            return !s.closing && !s.finished
        }
        guard first else { return }
        if !outbound.send(Frame(channel: channel, kind: .close)) {
            finish(reason: nil)
        }
    }

    private func enqueue(_ frame: Frame) {
        guard !isClosed else { return }
        outbound.send(frame)
    }

    // MARK: Core → viewer (read loop)

    func receive(_ frame: Frame) -> Bool {
        switch frame.kind {
        case .data:
            if !frame.payload.isEmpty, !state.withLock({ $0.finished }) { continuation.yield(.data(frame.payload)) }
            return true
        case .resize:
            if let size = frame.resizeSize { continuation.yield(.resize(cols: Int(size.cols), rows: Int(size.rows))) }
            return true
        case .close:
            var reason: JSONValue?
            if !frame.payload.isEmpty {
                reason = (try? JSONValue(data: frame.payload)) ?? .string(String(decoding: frame.payload, as: UTF8.self))
            }
            finish(reason: reason)
            return false
        default:
            return true
        }
    }

    func connectionEnded(_ error: ConnectionError) {
        finish(reason: ["reason": "disconnected", "message": .string(error.description)])
    }

    private func finish(reason: JSONValue?) {
        let first = state.withLock { s in
            defer { s.finished = true }
            return !s.finished
        }
        guard first else { return }
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }
}

extension Data {
    /// Splits into pieces of at most `size` bytes (one piece when it fits).
    func chunked(_ size: Int) -> [Data] {
        guard count > size else { return [self] }
        return stride(from: startIndex, to: endIndex, by: size).map { self[$0..<Swift.min($0 + size, endIndex)] }
    }
}
