#if os(macOS)
import Foundation
import Testing
@testable import HerdrCore

/// Against the real local core (`hc connect`). Run with `WIERDR_LIVE=1 swift test`.
///
/// Safety: the user's live agents run on this core. These tests only read
/// existing state, and only start/attach/kill/remove terminals they created
/// themselves (labelled `wierdr.test=1`). Documents: `herdr-app` is read only;
/// writes go to the scratch doc `wierdr-test`, deleted (set to null) after.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIERDR_LIVE"] == "1"), .serialized, .timeLimit(.minutes(2)))
struct LiveTests {
    static let scratchLabels = ["wierdr.test": "1"]

    func connect() async throws -> CoreConnection {
        let connection = CoreConnection(transport: try ProcessTransport())
        try await connection.start()
        return connection
    }

    /// Runs a scratch terminal, hands it to `body`, then kills and removes it no matter what.
    func withScratchTerminal(_ connection: CoreConnection, _ script: String,
                             _ body: (Terminal) async throws -> Void) async throws {
        let run = try await connection.runTerminal(RunParams(
            argv: ["/bin/sh", "-c", script], labels: Self.scratchLabels, size: .init(cols: 60, rows: 12), noParent: true))
        let terminal = run.terminal
        #expect(terminal.labels["wierdr.test"] == "1")
        var failure: Error?
        do { try await body(terminal) } catch { failure = error }
        await cleanUp(connection, terminal.address)
        if let failure { throw failure }
    }

    func cleanUp(_ connection: CoreConnection, _ address: String) async {
        // Only ever our own scratch terminal.
        guard let t = try? await connection.getTerminal(address), t.labels["wierdr.test"] == "1" else { return }
        _ = try? await connection.killTerminal(address)
        for _ in 0..<20 {
            if (try? await connection.removeTerminal(address)) != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func hello() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let hello = try #require(connection.hello)
        #expect(hello.framed && hello.generation == 1 && !hello.core.name.isEmpty)
        #expect(hello.methods.contains("terminal.attach"))
        let status = try await connection.serverStatus()
        #expect(status.core == hello.core && status.version == hello.version)
    }

    @Test func listDecodesEveryTerminal() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let raw = try await connection.call("terminal.list", params: ["all": true])
        let list = try await connection.listTerminals(all: true)
        #expect(list.terminals.count == raw["terminals"]?.array?.count)
        // Every record decodes on its own as well (strictness check, not just leniency).
        for record in raw["terminals"]?.array ?? [] {
            let t = try record.decode(Terminal.self)
            #expect(t.address == record["address"]?.string)
            #expect(t.labels.count == record["labels"]?.object?.count ?? 0)
            #expect((t.foreground == nil) == (record["foreground"] == nil || record["foreground"] == .null))
        }
        let machines = try await connection.listMachines()
        #expect(machines.count == list.machines.count)
        _ = try await connection.listTemplates()
    }

    @Test func concurrentCalls() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<25 {
                group.addTask { _ = try await connection.serverStatus() }
                group.addTask { _ = try await connection.listTerminals() }
            }
            try await group.waitForAll()
        }
        do {
            _ = try await connection.getTerminal("t-no-such-terminal")
            Issue.record("expected not_found")
        } catch let error as CoreError {
            #expect(error.kind == "not_found" || error.kind == "invalid_params", "\(error)")
        }
    }

    @Test func herdrAppDocIsReadable() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let doc = try await connection.getDoc("herdr-app")  // READ ONLY
        #expect(doc.value.object != nil && doc.version > 0)
        // Our parse → write is byte-faithful to the core's own serialization of it.
        let raw = try await connection.call("doc.get", params: ["name": "herdr-app"])
        #expect(raw["value"] == doc.value)
    }

    @Test func scratchDocReadWriteConflictDelete() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let name = "wierdr-test"
        let before = try await connection.getDoc(name)
        let value: JSONValue = ["z": 1, "a": ["weight": 0.9999997615814208, "w": 4.0], "big": .uint(UInt64.max), "s": "é😀"]
        let v1 = try await connection.setDoc(name, value: value, version: before.version)
        do {
            #expect(v1 > before.version)
            let read = try await connection.getDoc(name)
            #expect(read.version == v1 && read.value == value)
            // Number kinds survive; the core stores objects with sorted keys (serde_json maps).
            #expect(read.value["a"]?["w"] == .double(4.0) && read.value["big"] == .uint(UInt64.max))
            #expect(read.value.object?.keys == ["a", "big", "s", "z"])
            do {
                try await connection.setDoc(name, value: ["stale": true], version: before.version)
                Issue.record("expected a conflict")
            } catch let conflict as DocConflict {
                #expect(conflict.currentVersion == v1)
            }
        } catch {
            _ = try? await connection.setDoc(name, value: .null, version: v1)
            throw error
        }
        let v2 = try await connection.setDoc(name, value: .null, version: v1)
        #expect(try await connection.getDoc(name) == Document(value: .null, version: v2))
    }

    @Test func execAndFileRead() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let r = try await connection.exec(ExecParams(argv: ["/bin/cat"], input: Data("hi\n".utf8)))
        #expect(r.code == 0 && r.stdoutText == "hi\n")
        let f = try await connection.readFile("/etc/hosts", limit: 1)
        #expect(f.first == 1 && f.last == 1 && f.lines >= 1)
    }

    @Test func attachScratchTerminal() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let script = "echo hello-wierdr; read line; echo got:$line; sleep 30"
        try await withScratchTerminal(connection, script) { terminal in
            let stream = try await connection.attach(AttachParams(terminal: terminal.address, cols: 60, rows: 12))
            #expect(stream.channel != 0 && stream.terminal.address == terminal.address)
            #expect(stream.automaticInput == connection.supports("automatic_input"))
            let output = try await withTimeout(15) {
                var text = ""
                var typed = false
                for await event in stream.output {
                    guard case .data(let bytes) = event else { continue }
                    text += String(decoding: bytes, as: UTF8.self)
                    stream.consumed(bytes.count)
                    if text.contains("hello-wierdr"), !typed {
                        typed = true
                        stream.send(Data("abc\r".utf8))
                    }
                    if text.contains("got:abc") { break }
                }
                return text
            }
            #expect(output.contains("hello-wierdr") && output.contains("got:abc"))
            stream.close()
            let last = try await withTimeout(10) {
                var last: AttachEvent?
                for await event in stream.output { last = event }
                return last
            }
            #expect(last == .closed(reason: nil))
        }
    }

    @Test func observeSeesExitReason() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        try await withScratchTerminal(connection, "echo observed; read x; exit 3") { terminal in
            let viewer = try await connection.attach(AttachParams(terminal: terminal.address, cols: 60, rows: 12))
            let observer = try await connection.attach(AttachParams(
                terminal: terminal.address, cols: 60, rows: 12, observe: true, resizeNotifications: true))
            #expect(observer.observe && observer.resizeNotifications)
            viewer.send(Data("\r".utf8))
            let reason = try await withTimeout(15) {
                var reason: JSONValue?
                for await event in observer.output {
                    switch event {
                    case .data(let b): observer.consumed(b.count)
                    case .resize: break
                    case .closed(let r): reason = r
                    }
                }
                return reason
            }
            #expect(reason?["reason"] == "exited" && reason?["exit_code"] == 3)
            viewer.close()
        }
    }

    @Test func subscriptionSeesScratchLifecycle() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let subscription = try await connection.subscribe(SubscribeParams(labels: Self.scratchLabels))
        #expect(subscription.seq > 0)
        let address = try await withTimeout(20) {
            var address: String?
            var killed = false
            var types: [String] = []
            let run = try await connection.runTerminal(RunParams(
                argv: ["/bin/sh", "-c", "sleep 30"], labels: Self.scratchLabels, noParent: true))
            address = run.terminal.address
            for await event in subscription.events {
                guard event.terminal == run.terminal.address else { continue }
                switch event.kind {
                case .created: types.append("created")
                case .finished(let end):
                    types.append("finished")
                    #expect(end.reason == "killed")
                case .removed:
                    types.append("removed")
                default: continue
                }
                if types == ["created"], !killed {
                    killed = true
                    try await connection.killTerminal(run.terminal.address)
                }
                if types.last == "finished" { try await connection.removeTerminal(run.terminal.address) }
                if types.last == "removed" { break }
            }
            #expect(types == ["created", "finished", "removed"])
            return address
        }
        if let address { await cleanUp(connection, address) }
        subscription.cancel()
        try await withTimeout(10) { for await _ in subscription.events {} }
    }

    @Test func unfilteredSubscriptionGetsHeartbeatOrEvents() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        let subscription = try await connection.subscribe()
        #expect(subscription.seq > 0)
        // Either a live event or the 15 s heartbeat arrives.
        let event: CoreEvent? = try await withTimeout(25) {
            for await e in subscription.events { return e }
            return nil
        }
        #expect(event != nil && event!.seq >= subscription.seq)
    }
}
#endif
