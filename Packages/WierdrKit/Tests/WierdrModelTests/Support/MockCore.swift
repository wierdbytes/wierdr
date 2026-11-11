// Copied from HerdrCoreTests/Support/MockCore.swift (test targets cannot share sources).
import Foundation
import Synchronization
@testable import HerdrCore

/// An in-memory transport: the test plays the core.
final class MockTransport: CoreTransport, @unchecked Sendable {
    let inbound: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    let written: AsyncStream<Data>
    private let writtenContinuation: AsyncStream<Data>.Continuation
    private let closedFlag = Mutex(false)

    init() {
        (inbound, inboundContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        (written, writtenContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    var isClosed: Bool { closedFlag.withLock { $0 } }

    func write(_ data: Data) async throws {
        if isClosed { throw ConnectionError.closed }
        writtenContinuation.yield(data)
    }

    func close() async {
        closedFlag.withLock { $0 = true }
        inboundContinuation.finish()
        writtenContinuation.finish()
    }

    /// Core → client bytes.
    func feed(_ data: Data) { inboundContinuation.yield(data) }
    /// The core goes away.
    func drop(_ error: Error? = nil) {
        if let error { inboundContinuation.finish(throwing: error) } else { inboundContinuation.finish() }
    }
}

/// The core side of a `MockTransport`: reads what the client wrote, answers.
final class MockCore: @unchecked Sendable {
    let transport = MockTransport()
    private var iterator: AsyncStream<Data>.AsyncIterator
    private var parser = InboundParser()
    private var queue: [InboundParser.Item] = []

    init() { iterator = transport.written.makeAsyncIterator() }

    /// The next thing the client sent (the hello line, then frames).
    func next() async throws -> InboundParser.Item {
        while queue.isEmpty {
            guard let chunk = await iterator.next() else { throw ConnectionError.closed }
            queue += try parser.push(chunk)
        }
        return queue.removeFirst()
    }

    /// The next frame the client sent.
    func nextFrame() async throws -> Frame {
        switch try await next() {
        case .frame(let f): return f
        case .line(let l): throw ConnectionError.protocolViolation("unexpected line \(String(decoding: l, as: UTF8.self))")
        }
    }

    /// The next JSON-RPC request on channel 0 (skipping other frames).
    func nextRequest() async throws -> JSONValue {
        while true {
            switch try await next() {
            case .line(let l): return try JSONValue(data: l)
            case .frame(let f) where f.channel == 0 && f.kind == .data: return try JSONValue(data: f.payload)
            case .frame: continue
            }
        }
    }

    func send(_ frame: Frame) { transport.feed(frame.encoded()) }

    func reply(_ id: JSONValue, result: JSONValue) {
        let msg: JSONValue = ["jsonrpc": "2.0", "id": id, "result": result]
        send(Frame(channel: 0, kind: .data, payload: (try? msg.data()) ?? Data()))
    }

    func replyError(_ id: JSONValue, code: Int, message: String, kind: String, hint: String) {
        let msg: JSONValue = ["jsonrpc": "2.0", "id": id,
                              "error": ["code": .int(Int64(code)), "message": .string(message),
                                        "data": ["kind": .string(kind), "hint": .string(hint)]]]
        send(Frame(channel: 0, kind: .data, payload: (try? msg.data()) ?? Data()))
    }

    static let helloResult: JSONValue = [
        "core": ["id": "abc", "name": "mock"], "features": ["framed", "attach", "events", "resize_notifications", "automatic_input"],
        "framed": true, "generation": 1, "methods": ["hello"], "version": "0.0.0",
    ]

    /// Answers the plain-mode hello; returns the hello request.
    @discardableResult
    func handshake(_ result: JSONValue = MockCore.helloResult) async throws -> JSONValue {
        let hello = try await nextRequest()
        var line = try (["jsonrpc": "2.0", "id": hello["id"] ?? .null, "result": result] as JSONValue).data()
        line.append(0x0A)
        transport.feed(line)
        return hello
    }

    /// A connection to this mock core, handshaken.
    func connect() async throws -> CoreConnection {
        let connection = CoreConnection(transport: transport)
        async let hello = connection.start()
        try await handshake()
        _ = try await hello
        return connection
    }
}
