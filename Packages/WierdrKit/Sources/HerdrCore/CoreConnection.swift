import Foundation
import Synchronization

/// Where a connection is in its life.
public enum ConnectionState: Sendable, Equatable {
    /// Created, `start()` not called yet.
    case idle
    /// `start()` is handshaking.
    case connecting
    /// Handshake done; calls, subscriptions and attaches work.
    case open(HelloResult)
    /// Over for good: `.closed` after `close()`, otherwise why it dropped.
    /// Build a new `CoreConnection` (on a new transport) to reconnect.
    case closed(ConnectionError)

    public var isOpen: Bool { if case .open = self { return true } else { return false } }
    public var isClosed: Bool { if case .closed = self { return true } else { return false } }
}

/// A client connection to herdr-core over any `CoreTransport`.
///
/// Thread-safe: use it from the main actor and background tasks alike.
/// `start()` handshakes and switches to framed mode; then JSON-RPC calls run
/// side by side on channel 0, and each subscription and attach gets its own
/// channel. The read loop never waits for a slow consumer: every stream buffers.
///
/// The connection keeps itself alive while its transport is open; call
/// `close()` when done with it.
public final class CoreConnection: Sendable {
    /// Features this client advertises in `hello`.
    public static let clientFeatures = ["framed", "attach", "events", "resize_notifications", "automatic_input"]

    public let transport: CoreTransport
    let outbound = Outbound()
    let shared = Mutex(Shared())

    struct Shared {
        var phase: ConnectionState = .idle
        var nextID = 0
        var pending: [Int: Pending] = [:]
        var cancelledIDs: Set<Int> = []
        var sinks: [UInt32: any ChannelSink] = [:]
        /// Frames for channels whose reply is not in yet (event channels start unpaused).
        var orphans: [UInt32: [Frame]] = [:]
        var orphanBytes = 0
        /// Channels that ended; late frames for them are dropped.
        var retired: Set<UInt32> = []
        var watchers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    }

    struct Pending {
        let method: String
        let continuation: CheckedContinuation<Reply, Error>
        /// Builds the channel's sink from the result, inside the read loop, so
        /// no frame of the new channel can slip past unrouted.
        let opener: Opener?
    }

    typealias Opener = @Sendable (JSONValue) throws -> any ChannelSink

    struct Reply: Sendable {
        let result: JSONValue
        let sink: (any ChannelSink)?
    }

    static let maxOrphanBytes = 8 << 20

    public init(transport: CoreTransport) {
        self.transport = transport
    }

    // MARK: Lifecycle

    /// Current state.
    public var state: ConnectionState { shared.withLock { $0.phase } }

    /// The handshake reply, once open.
    public var hello: HelloResult? {
        if case .open(let h) = state { return h }
        return nil
    }

    /// Whether the core advertised `feature` in `hello`.
    public func supports(_ feature: String) -> Bool { hello?.features.contains(feature) ?? false }

    /// The current state, then every change; finishes after `.closed`.
    public func states() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        let id = UUID()
        let current = shared.withLock { s -> ConnectionState in
            if !s.phase.isClosed { s.watchers[id] = continuation }
            return s.phase
        }
        continuation.yield(current)
        if current.isClosed { continuation.finish() }
        continuation.onTermination = { [weak self] _ in
            _ = self?.shared.withLock { $0.watchers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Suspends until the connection is closed; returns why.
    public func waitUntilClosed() async -> ConnectionError {
        for await state in states() {
            if case .closed(let error) = state { return error }
        }
        if case .closed(let error) = state { return error }
        return .closed
    }

    /// Handshakes: `hello {framed: true}` in plain mode (one JSON line), then
    /// framed mode for everything after. Throws `CoreError` if the core refuses
    /// (e.g. `unsupported_generation`); the connection is closed then.
    @discardableResult
    public func start(features: [String] = CoreConnection.clientFeatures) async throws -> HelloResult {
        try shared.withLock { s in
            guard case .idle = s.phase else { throw ConnectionError.alreadyStarted }
            s.phase = .connecting
        }
        publish(.connecting)
        startLoops()
        let params: JSONValue = [
            "framed": true,
            "generation": .int(Int64(HerdrCoreInfo.protocolGeneration)),
            "features": .array(features.map(JSONValue.string)),
        ]
        do {
            let reply = try await request("hello", params: params.data(), opener: nil, plain: true)
            let hello: HelloResult
            do { hello = try reply.result.decode() } catch {
                throw ConnectionError.decoding(method: "hello", message: "\(error)")
            }
            guard hello.framed else { throw ConnectionError.protocolViolation("the core did not switch to framed mode") }
            let opened = shared.withLock { s -> Bool in
                guard case .connecting = s.phase else { return false }
                s.phase = .open(hello)
                return true
            }
            guard opened else { throw closedError() }
            publish(.open(hello))
            return hello
        } catch {
            fail(error as? ConnectionError ?? .disconnected("handshake failed: \(error)"))
            await transport.close()
            throw error
        }
    }

    /// Closes the connection: pending calls fail with `ConnectionError.closed`,
    /// streams end, the transport closes. Idempotent.
    public func close() async {
        fail(.closed)
        await transport.close()
    }

    private func startLoops() {
        let outbound = outbound
        let transport = transport
        Task { [self] in
            for await bytes in outbound.stream {
                do {
                    try await transport.write(bytes)
                } catch {
                    fail(.disconnected("write failed: \(error)"))
                    break
                }
            }
        }
        Task { [self] in await readLoop() }
    }

    private func publish(_ state: ConnectionState) {
        let watchers = shared.withLock { s -> [AsyncStream<ConnectionState>.Continuation] in
            let w = Array(s.watchers.values)
            if state.isClosed { s.watchers.removeAll() }
            return w
        }
        for w in watchers {
            w.yield(state)
            if state.isClosed { w.finish() }
        }
    }

    func closedError() -> ConnectionError {
        if case .closed(let e) = state { return e }
        return .notStarted
    }

    /// Ends everything once: phase, pending calls, channel sinks, writer.
    func fail(_ error: ConnectionError) {
        let taken = shared.withLock { s -> ([Pending], [any ChannelSink])? in
            if case .closed = s.phase { return nil }
            s.phase = .closed(error)
            let pending = Array(s.pending.values)
            let sinks = Array(s.sinks.values)
            s.pending.removeAll()
            s.sinks.removeAll()
            s.orphans.removeAll()
            s.orphanBytes = 0
            return (pending, sinks)
        }
        guard let (pending, sinks) = taken else { return }
        outbound.finish()
        for p in pending { p.continuation.resume(throwing: error) }
        for sink in sinks { sink.connectionEnded(error) }
        publish(.closed(error))
        if error != .closed {
            let transport = transport
            Task { await transport.close() }
        }
    }

    // MARK: Read loop

    private func readLoop() async {
        var parser = InboundParser()
        do {
            for try await chunk in transport.inbound {
                for item in try parser.push(chunk) {
                    switch item {
                    case .line(let line): handleMessage(line)
                    case .frame(let frame): route(frame)
                    }
                }
            }
            fail(.disconnected("the core closed the connection"))
        } catch let error as FrameError {
            fail(.protocolViolation(error.description))
        } catch {
            fail(.disconnected("\(error)"))
        }
    }

    private func route(_ frame: Frame) {
        if frame.channel == 0 {
            if frame.kind == .data { handleMessage(frame.payload) }
            return
        }
        let sink = shared.withLock { s -> (any ChannelSink)? in
            if let sink = s.sinks[frame.channel] { return sink }
            guard !s.retired.contains(frame.channel), !s.phase.isClosed else { return nil }
            s.orphans[frame.channel, default: []].append(frame)
            s.orphanBytes += frame.payload.count
            if s.orphanBytes > Self.maxOrphanBytes {
                s.orphans.removeAll()
                s.orphanBytes = 0
            }
            return nil
        }
        if let sink, !sink.receive(frame) { retire(frame.channel) }
    }

    private func retire(_ channel: UInt32) {
        shared.withLock { s in
            s.sinks[channel] = nil
            s.retired.insert(channel)
        }
    }

    private func handleMessage(_ bytes: Data) {
        guard let message = try? JSONValue(data: bytes) else { return }
        // Replies only: the core sends us no requests, and notifications travel on event channels.
        guard let id = message["id"]?.int, message["method"] == nil else { return }
        let pending = shared.withLock { $0.pending.removeValue(forKey: id) }
        let channel = message["result"]?["channel"]?.uint64.flatMap { UInt32(exactly: $0) }
        guard let pending else {
            // A cancelled call that opened a channel: give it back.
            if let channel {
                outbound.send(Frame(channel: channel, kind: .close))
                retire(channel)
            }
            return
        }
        if let error = message["error"] {
            pending.continuation.resume(throwing: CoreError(json: error))
            return
        }
        let result = message["result"] ?? .null
        guard let opener = pending.opener else {
            pending.continuation.resume(returning: Reply(result: result, sink: nil))
            return
        }
        let sink: any ChannelSink
        do { sink = try opener(result) } catch {
            if let channel {
                outbound.send(Frame(channel: channel, kind: .close))
                retire(channel)
            }
            pending.continuation.resume(throwing: ConnectionError.decoding(method: pending.method, message: "\(error)"))
            return
        }
        let registered = shared.withLock { s -> (ok: Bool, orphans: [Frame]) in
            guard !s.phase.isClosed else { return (false, []) }
            s.sinks[sink.channel] = sink
            let orphans = s.orphans.removeValue(forKey: sink.channel) ?? []
            s.orphanBytes -= orphans.reduce(0) { $0 + $1.payload.count }
            return (true, orphans)
        }
        guard registered.ok else {
            sink.connectionEnded(closedError())
            pending.continuation.resume(throwing: closedError())
            return
        }
        pending.continuation.resume(returning: Reply(result: result, sink: sink))
        for frame in registered.orphans where !sink.receive(frame) {
            retire(sink.channel)
            break
        }
    }

    // MARK: Requests

    /// Sends one request and waits for its reply. `params` are JSON bytes.
    func request(_ method: String, params: Data, opener: Opener?, plain: Bool = false) async throws -> Reply {
        let id = try shared.withLock { s -> Int in
            switch s.phase {
            case .open: break
            case .connecting where plain: break
            case .idle, .connecting: throw ConnectionError.notStarted
            case .closed(let e): throw e
            }
            s.nextID += 1
            return s.nextID
        }
        let message = Self.requestBytes(id: id, method: method, params: params)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, Error>) in
                let refusal = shared.withLock { s -> Error? in
                    if s.cancelledIDs.remove(id) != nil { return CancellationError() }
                    if case .closed(let e) = s.phase { return e }
                    s.pending[id] = Pending(method: method, continuation: continuation, opener: opener)
                    return nil
                }
                if let refusal {
                    continuation.resume(throwing: refusal)
                    return
                }
                let sent = plain
                    ? outbound.send(message + Data([0x0A]))
                    : outbound.send(Frame(channel: 0, kind: .data, payload: message))
                if !sent, let p = shared.withLock({ $0.pending.removeValue(forKey: id) }) {
                    p.continuation.resume(throwing: closedError())
                }
            }
        } onCancel: {
            let p = shared.withLock { s -> Pending? in
                guard let p = s.pending.removeValue(forKey: id) else {
                    s.cancelledIDs.insert(id)
                    return nil
                }
                return p
            }
            guard let p else { return }
            p.continuation.resume(throwing: CancellationError())
            let cancel: JSONValue = ["jsonrpc": "2.0", "method": "$/cancelRequest", "params": ["id": .int(Int64(id))]]
            if let bytes = try? cancel.data() { outbound.send(Frame(channel: 0, kind: .data, payload: bytes)) }
        }
    }

    static func requestBytes(id: Int, method: String, params: Data) -> Data {
        var w = JSONWriter(pretty: false)
        w.writeString(method)
        var out = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":".utf8)
        out.append(contentsOf: w.bytes)
        out.append(contentsOf: Array(",\"params\":".utf8))
        out.append(params)
        out.append(UInt8(ascii: "}"))
        return out
    }

    // MARK: Calls

    /// Calls `method` with JSON params; returns the `result`.
    /// Throws `CoreError` for a JSON-RPC error, `ConnectionError` when the connection fails.
    public func call(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        try await request(method, params: params.data(), opener: nil).result
    }

    /// Calls `method` with `Encodable` params and decodes the result.
    public func call<P: Encodable, R: Decodable>(_ method: String, _ params: P, as type: R.Type = R.self) async throws -> R {
        let result = try await request(method, params: Self.encode(params), opener: nil).result
        return try Self.decode(type, result, method: method)
    }

    static func encode<P: Encodable>(_ params: P) throws -> Data {
        if let value = params as? JSONValue { return try value.data() }
        return try JSONEncoder().encode(params)
    }

    static func decode<R: Decodable>(_ type: R.Type, _ result: JSONValue, method: String) throws -> R {
        do { return try result.decode(type) } catch {
            throw ConnectionError.decoding(method: method, message: "\(error)")
        }
    }

    // MARK: Channels

    /// Subscribes to events (`events.subscribe`): the snapshot plus a stream of
    /// notifications on the subscription's channel. Subscribe before reading
    /// documents.
    public func subscribe(_ params: SubscribeParams = SubscribeParams()) async throws -> EventSubscription {
        let outbound = outbound
        let reply = try await request("events.subscribe", params: Self.encode(params), opener: { result in
            guard let channel = result["channel"]?.uint64.flatMap({ UInt32(exactly: $0) }) else {
                throw ConnectionError.decoding(method: "events.subscribe", message: "no channel in the reply")
            }
            return EventSink(channel: channel, outbound: outbound)
        })
        guard let sink = reply.sink as? EventSink else {
            throw ConnectionError.decoding(method: "events.subscribe", message: "no channel in the reply")
        }
        let terminals = try Self.decode([Terminal].self, reply.result["terminals"] ?? .array([]), method: "events.subscribe")
        return EventSubscription(channel: sink.channel, seq: reply.result["seq"]?.uint64 ?? 0,
                                 terminals: terminals, sink: sink)
    }

    /// Attaches to a terminal (`terminal.attach`) on a new channel.
    public func attach(_ params: AttachParams) async throws -> AttachStream {
        let outbound = outbound
        let coreAutomatic = supports("automatic_input")
        let observe = params.observe
        let reply = try await request("terminal.attach", params: Self.encode(params), opener: { result in
            guard let channel = result["channel"]?.uint64.flatMap({ UInt32(exactly: $0) }) else {
                throw ConnectionError.decoding(method: "terminal.attach", message: "no channel in the reply")
            }
            let terminal = try (result["terminal"] ?? .null).decode(Terminal.self)
            return AttachStream(
                channel: channel, terminal: terminal,
                automaticInput: coreAutomatic && result["automatic_input"]?.bool == true,
                resizeNotifications: result["resize_notifications"]?.bool == true,
                observe: observe, outbound: outbound)
        })
        guard let stream = reply.sink as? AttachStream else {
            throw ConnectionError.decoding(method: "terminal.attach", message: "no channel in the reply")
        }
        return stream
    }
}

/// Splits the inbound bytes: the first line is the plain-mode `hello` reply,
/// everything after it is frames.
struct InboundParser {
    enum Item {
        case line(Data)
        case frame(Frame)
    }

    private var lineDone = false
    private var line = Data()
    private var decoder = FrameDecoder()

    mutating func push(_ chunk: Data) throws -> [Item] {
        if lineDone { return try decoder.push(chunk).map(Item.frame) }
        guard let nl = chunk.firstIndex(of: 0x0A) else {
            line.append(chunk)
            guard line.count <= Frame.maxPayload else { throw FrameError(description: "handshake line too long") }
            return []
        }
        line.append(chunk[chunk.startIndex..<nl])
        lineDone = true
        let first = Item.line(line)
        line = Data()
        return [first] + (try decoder.push(Data(chunk[(nl + 1)...]))).map(Item.frame)
    }
}
