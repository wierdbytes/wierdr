import Foundation
import Testing
@testable import HerdrCore

@Suite(.timeLimit(.minutes(1))) struct ConnectionTests {
    @Test func handshakeIsPlainThenFramed() async throws {
        let core = MockCore()
        let connection = CoreConnection(transport: core.transport)
        async let started = connection.start()
        let hello = try await core.handshake()
        #expect(hello["method"] == "hello")
        #expect(hello["params"]?["framed"] == true && hello["params"]?["generation"] == 1)
        #expect(hello["params"]?["features"]?.array?.contains("automatic_input") == true)
        let result = try await started
        #expect(result.core.name == "mock" && connection.state.isOpen && connection.supports("resize_notifications"))

        // After the handshake, calls are DATA frames on channel 0.
        async let list = connection.call("terminal.list", params: [:])
        let frame = try await core.nextFrame()
        #expect(frame.channel == 0 && frame.kind == .data)
        let request = try JSONValue(data: frame.payload)
        core.reply(request["id"] ?? .null, result: ["terminals": [], "hidden_finished": 0])
        #expect(try await list["hidden_finished"] == 0)
    }

    @Test func handshakeAndFirstFrameInOneChunk() async throws {
        let core = MockCore()
        let connection = CoreConnection(transport: core.transport)
        async let started = connection.start()
        let hello = try await core.nextRequest()
        var bytes = try (["jsonrpc": "2.0", "id": hello["id"] ?? .null, "result": MockCore.helloResult] as JSONValue).data()
        bytes.append(0x0A)
        bytes.append(Frame(channel: 0, kind: .data, payload: Data(#"{"jsonrpc":"2.0","id":999,"result":{}}"#.utf8)).encoded())
        core.transport.feed(bytes)
        #expect(try await started.version == "0.0.0")
    }

    @Test func refusedHandshakeClosesTheConnection() async throws {
        let core = MockCore()
        let connection = CoreConnection(transport: core.transport)
        let started = Task { try await connection.start() }
        let hello = try await core.nextRequest()
        var line = try (["jsonrpc": "2.0", "id": hello["id"] ?? .null,
                         "error": ["code": -32000, "message": "protocol generation 1 not supported",
                                   "data": ["kind": "unsupported_generation"]]] as JSONValue).data()
        line.append(0x0A)
        core.transport.feed(line)
        await #expect(throws: CoreError.self) { try await started.value }
        #expect(connection.state.isClosed)
    }

    @Test func concurrentCallsResolveById() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        let results = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for i in 0..<20 {
                group.addTask { (i, try await connection.call("echo", params: ["i": .int(Int64(i))])["i"]?.int ?? -1) }
            }
            // Answer in reverse order of arrival.
            var requests: [JSONValue] = []
            for _ in 0..<20 { requests.append(try await core.nextRequest()) }
            #expect(Set(requests.compactMap { $0["id"]?.int }).count == 20)
            for r in requests.reversed() { core.reply(r["id"] ?? .null, result: ["i": r["params"]?["i"] ?? .null]) }
            var out: [(Int, Int)] = []
            for try await pair in group { out.append(pair) }
            return out
        }
        #expect(results.count == 20)
        for (sent, got) in results { #expect(sent == got) }
    }

    @Test func rpcErrorsMapToCoreError() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        async let get = connection.getTerminal("t999")
        let request = try await core.nextRequest()
        #expect(request["method"] == "terminal.get" && request["params"]?["terminal"] == "t999")
        core.replyError(request["id"] ?? .null, code: -32000, message: "no terminal \"t999\"", kind: "not_found", hint: "see `hc ls --all`")
        do {
            _ = try await get
            Issue.record("expected an error")
        } catch let error as CoreError {
            #expect(error.code == -32000 && error.kind == "not_found" && error.hint == "see `hc ls --all`")
        }
    }

    @Test func docConflictIsDistinct() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        async let set = connection.setDoc("wierdr-test", value: ["z": 1, "a": 2], version: 99)
        let request = try await core.nextRequest()
        // The value goes out with its key order intact.
        #expect(request["params"]?["value"]?.object?.keys == ["z", "a"])
        core.replyError(request["id"] ?? .null, code: -32000, message: #"document "wierdr-test" is at version 4, not 99"#,
                        kind: "conflict", hint: "read doc.get and retry with its version")
        do {
            _ = try await set
            Issue.record("expected a conflict")
        } catch let conflict as DocConflict {
            #expect(conflict.currentVersion == 4 && conflict.expectedVersion == 99)
        }
    }

    @Test func connectionLossFailsPendingCalls() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        let states = connection.states()
        async let pending = connection.call("terminal.wait", params: [:])
        _ = try await core.nextRequest()
        core.transport.drop()
        do {
            _ = try await pending
            Issue.record("expected a failure")
        } catch let error as ConnectionError {
            guard case .disconnected = error else { Issue.record("wrong error \(error)"); return }
        }
        var seen: [ConnectionState] = []
        for await s in states { seen.append(s) }
        #expect(seen.first?.isOpen == true && seen.last?.isClosed == true)
        await #expect(throws: ConnectionError.self) { try await connection.call("x", params: [:]) }
        guard case .disconnected = await connection.waitUntilClosed() else { Issue.record("not disconnected"); return }
    }

    @Test func closeFailsPendingCallsWithClosed() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        let pending = Task { try await connection.call("terminal.wait", params: [:]) }
        _ = try await core.nextRequest()
        await connection.close()
        await #expect(throws: ConnectionError.closed) { try await pending.value }
        #expect(core.transport.isClosed)
    }

    @Test func callsBeforeStartAreRejected() async throws {
        let connection = CoreConnection(transport: MockTransport())
        await #expect(throws: ConnectionError.notStarted) { try await connection.call("x", params: [:]) }
    }

    @Test func cancelledCallSendsCancelRequest() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        let task = Task { try await connection.call("machine.exec", params: [:]) }
        let request = try await core.nextRequest()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancel = try await core.nextRequest()
        #expect(cancel["method"] == "$/cancelRequest" && cancel["params"]?["id"] == request["id"])
    }

    @Test func subscriptionGetsEventsIncludingOnesBeforeItsReply() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        async let subscription = connection.subscribe()
        let request = try await core.nextRequest()
        #expect(request["method"] == "events.subscribe")
        // Event channels start unpaused: an event may beat the reply.
        let early = Data(#"{"jsonrpc":"2.0","method":"event","params":{"seq":11,"type":"title","terminal":"t1","data":{"title":"a"}}}"#.utf8) + Data([0x0A])
        core.send(Frame(channel: 5, kind: .data, payload: early))
        core.reply(request["id"] ?? .null, result: ["channel": 5, "seq": 10, "terminals": [terminalJSON("t1")]])
        let sub = try await subscription
        #expect(sub.seq == 10 && sub.terminals.map(\.address) == ["t1"] && sub.channel == 5)

        // A line split across frames, then two lines in one frame.
        let line2 = #"{"jsonrpc":"2.0","method":"event","params":{"seq":12,"type":"size","terminal":"t1","data":{"cols":10,"rows":5}}}"#
        let both = #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":12}}"# + "\n" + #"{"jsonrpc":"2.0","method":"event","params":{"seq":13,"type":"brand_new","data":{}}}"# + "\n"
        let bytes = Array(line2.utf8)
        core.send(Frame(channel: 5, kind: .data, payload: Data(bytes[..<20])))
        core.send(Frame(channel: 5, kind: .data, payload: Data(bytes[20...]) + Data([0x0A])))
        core.send(Frame(channel: 5, kind: .data, payload: Data(both.utf8)))
        core.send(Frame(channel: 5, kind: .close))

        var kinds: [String] = []
        for await e in sub.events {
            switch e.kind {
            case .title(let t): kinds.append("title:\(t)")
            case .size(let c, let r): kinds.append("size:\(c)x\(r)")
            case .heartbeat: kinds.append("heartbeat:\(e.seq)")
            case .unknown(let type, _): kinds.append("unknown:\(type)")
            default: kinds.append("other")
            }
        }
        #expect(kinds == ["title:a", "size:10x5", "heartbeat:12", "unknown:brand_new"])
    }

    @Test func subscriptionCreditsWhatItParsed() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        async let subscription = connection.subscribe()
        let request = try await core.nextRequest()
        core.reply(request["id"] ?? .null, result: ["channel": 3, "seq": 0, "terminals": []])
        let sub = try await subscription
        let line = Data(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":1}}"#.utf8) + Data([0x0A])
        var sent = 0
        while sent < 40_000 {
            core.send(Frame(channel: 3, kind: .data, payload: line))
            sent += line.count
        }
        var credited = 0
        while credited < 32 * 1024 {
            let f = try await core.nextFrame()
            if f.channel == 3, let n = f.creditBytes { credited += Int(n) }
        }
        #expect(credited <= sent)
        sub.cancel()
        let close = try await core.nextFrame()
        #expect(close.channel == 3 && close.kind == .close)
    }

    @Test func attachStreamFlow() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        async let attached = connection.attach(AttachParams(terminal: "t1", cols: 80, rows: 24))
        let request = try await core.nextRequest()
        #expect(request["params"]?["cols"] == 80 && request["params"]?["observe"] == false)
        core.reply(request["id"] ?? .null, result: ["channel": 2, "terminal": terminalJSON("t1"),
                                                    "automatic_input": true, "resize_notifications": false])
        let stream = try await attached
        #expect(stream.channel == 2 && stream.automaticInput && !stream.resizeNotifications && stream.terminal.address == "t1")

        core.send(Frame(channel: 2, kind: .data, payload: Data("hello".utf8)))
        core.send(.resize(2, cols: 100, rows: 30))
        core.send(Frame(channel: 2, kind: .data, payload: Data("world".utf8)))
        var it = stream.output.makeAsyncIterator()
        let e1 = await it.next()
        #expect(e1 == .data(Data("hello".utf8)))
        let e2 = await it.next()
        #expect(e2 == .resize(cols: 100, rows: 30))
        let e3 = await it.next()
        #expect(e3 == .data(Data("world".utf8)))

        stream.send(Data("ls\r".utf8))
        stream.sendAutomatic(Data("\u{1b}[?1;2c".utf8))
        stream.resize(cols: 90, rows: 20)
        stream.focus(true)
        stream.facts(Display(bg: "#000000"))
        var f = try await core.nextFrame()
        #expect(f == Frame(channel: 2, kind: .data, payload: Data("ls\r".utf8)))
        f = try await core.nextFrame()
        #expect(f.kind == .automaticInput && f.channel == 2)
        f = try await core.nextFrame()
        #expect(f.resizeSize! == (90, 20))
        f = try await core.nextFrame()
        #expect(f.kind == .focus && f.payload == Data([1]))
        f = try await core.nextFrame()
        let facts = try JSONValue(data: f.payload)
        #expect(f.kind == .facts && facts["bg"] == "#000000")

        // Credit: small acknowledgements are batched until 16 KiB.
        for _ in 0..<15 { stream.consumed(1024) }  // 15 KiB: nothing yet
        stream.consumed(1024)  // 16 KiB: one CREDIT
        stream.consumed(10)
        stream.send(Data("x".utf8))  // a marker: CREDIT must come before it, exactly once
        f = try await core.nextFrame()
        #expect(f.channel == 2 && f.creditBytes == 16 * 1024)
        f = try await core.nextFrame()
        #expect(f.kind == .data && f.payload == Data("x".utf8))

        stream.close()
        f = try await core.nextFrame()
        #expect(f == Frame(channel: 2, kind: .close))
        core.send(Frame(channel: 2, kind: .close))
        let e4 = await it.next()
        #expect(e4 == .closed(reason: nil), "\(String(describing: e4))")
        let e5 = await it.next()
        #expect(e5 == nil)
        stream.send(Data("ignored".utf8))  // no-op after close
    }

    @Test func attachWithoutAutomaticInputFallsBackToData() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        async let attached = connection.attach(AttachParams(terminal: "t1", cols: 80, rows: 24))
        let request = try await core.nextRequest()
        core.reply(request["id"] ?? .null, result: ["channel": 4, "terminal": terminalJSON("t1"),
                                                    "automatic_input": false, "resize_notifications": false])
        let stream = try await attached
        stream.sendAutomatic(Data("r".utf8))
        let f = try await core.nextFrame()
        #expect(f.kind == .data && f.channel == 4)
    }

    @Test func attachEndsWithCoreReasonAndOnDisconnect() async throws {
        let core = MockCore()
        let connection = try await core.connect()
        func attach(_ channel: Int64) async throws -> AttachStream {
            async let attached = connection.attach(AttachParams(terminal: "t1", cols: 80, rows: 24))
            let request = try await core.nextRequest()
            core.reply(request["id"] ?? .null, result: ["channel": .int(channel), "terminal": terminalJSON("t1"),
                                                        "automatic_input": true, "resize_notifications": false])
            return try await attached
        }
        let a = try await attach(2)
        let b = try await attach(3)
        core.send(Frame(channel: 2, kind: .close, payload: Data(#"{"exit_code":0,"finished_ms":1,"reason":"exited","signal":null}"#.utf8)))
        var last: AttachEvent?
        for await e in a.output { last = e }
        guard case .closed(let reason) = last else { Issue.record("no close"); return }
        #expect(reason?["reason"] == "exited" && TerminalEnd(reason ?? .null).exitCode == 0)

        core.transport.drop()
        last = nil
        for await e in b.output { last = e }
        guard case .closed(let why) = last else { Issue.record("no close"); return }
        #expect(why?["reason"] == "disconnected")
    }

    @Test func creditBatcher() {
        var b = CreditBatcher(threshold: 100)
        #expect(b.add(0) == nil)
        #expect(b.add(60) == nil)
        #expect(b.add(60) == 120)
        #expect(b.pending == 0)
        #expect(b.add(99) == nil && b.pending == 99)
    }
}
