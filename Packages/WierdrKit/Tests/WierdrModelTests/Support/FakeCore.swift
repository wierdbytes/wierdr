import Foundation
import Synchronization
@testable import HerdrCore

/// A small in-memory herdr-core: documents with CAS versions, terminals,
/// machines, files and an event subscription. Serves one connection.
final class FakeCore: @unchecked Sendable {
    struct Doc { var value: JSONValue; var version: UInt64 }

    struct State {
        var docs: [String: Doc] = [:]
        var terminals: [String: JSONValue] = [:]
        var order: [String] = []
        var machines: [JSONValue] = []
        var files: [String: String] = [:]
        var calls: [(method: String, params: JSONValue)] = []
        var seq: UInt64 = 10
        var next = 100
        var channel: UInt32?
        /// Runs before a `doc.set` is checked (another writer racing us), one per call.
        var beforeSet: [(inout State, String) -> Void] = []
        var installed = "herdr-has:claude\nherdr-has:pi\n\nherdr-check-complete\n"
    }

    let mock = MockCore()
    let state = Mutex(State())

    static func key(_ name: String, _ machine: String?) -> String { "\(name)|\(machine ?? "")" }

    func setDoc(_ name: String, on machine: String? = nil, _ value: JSONValue, version: UInt64 = 1) {
        state.withLock { $0.docs[Self.key(name, machine)] = Doc(value: value, version: version) }
    }

    func doc(_ name: String, on machine: String? = nil) -> Doc? {
        state.withLock { $0.docs[Self.key(name, machine)] }
    }

    func addTerminal(_ t: JSONValue) {
        state.withLock { s in
            let a = t["address"]!.string!
            s.terminals[a] = t
            s.order.append(a)
        }
    }

    func calls(_ method: String) -> [JSONValue] {
        state.withLock { $0.calls.filter { $0.method == method }.map(\.params) }
    }

    /// Serves requests until the connection ends.
    func start() async throws -> CoreConnection {
        let connection = try await mock.connect()
        Task { [self] in
            while let req = try? await mock.nextRequest() { handle(req) }
        }
        return connection
    }

    func close() { mock.transport.drop() }

    // MARK: Requests

    private func handle(_ req: JSONValue) {
        let id = req["id"] ?? .null
        let method = req["method"]?.string ?? ""
        let p = req["params"] ?? .object([:])
        var events: [JSONValue] = []
        let reply: Result<JSONValue, CoreError> = state.withLock { s in
            s.calls.append((method, p))
            func emit(_ type: String, terminal: String? = nil, machine: String? = nil, _ data: JSONValue) {
                s.seq += 1
                var params: JSONValue = ["seq": .int(Int64(s.seq)), "type": .string(type), "data": data]
                if let terminal { params["terminal"] = .string(terminal) }
                if let machine { params["machine"] = .string(machine) }
                events.append(["jsonrpc": "2.0", "method": "event", "params": params])
            }
            func notFound(_ what: String) -> Result<JSONValue, CoreError> {
                .failure(CoreError(code: -32000, message: "no \(what)", kind: "not_found"))
            }
            switch method {
            case "events.subscribe":
                s.channel = 7
                let live = s.order.compactMap { s.terminals[$0] }
                return .success(["channel": 7, "seq": .int(Int64(s.seq)), "terminals": .array(live)])
            case "machine.list":
                return .success(["machines": .array(s.machines)])
            case "doc.get":
                let k = Self.key(p["name"]?.string ?? "", p["on"]?.string)
                let d = s.docs[k] ?? Doc(value: .null, version: 0)
                return .success(["value": d.value, "version": .int(Int64(d.version))])
            case "doc.set":
                let name = p["name"]?.string ?? ""
                let k = Self.key(name, p["on"]?.string)
                if !s.beforeSet.isEmpty { s.beforeSet.removeFirst()(&s, k) }
                let current = s.docs[k] ?? Doc(value: .null, version: 0)
                let wanted = p["version"]?.uint64 ?? 0
                guard wanted == current.version else {
                    return .failure(CoreError(code: -32000, message: "document \"\(name)\" is at version \(current.version), not \(wanted)",
                                              kind: "conflict", hint: "read doc.get and retry with its version"))
                }
                let new = Doc(value: p["value"] ?? .null, version: current.version + 1)
                s.docs[k] = new
                emit("doc", machine: p["on"]?.string, ["name": .string(name), "version": .int(Int64(new.version))])
                return .success(["version": .int(Int64(new.version))])
            case "terminal.run":
                s.next += 1
                let on = p["on"]?.string
                let address = (on.map { "\($0)/" } ?? "") + "t\(s.next)"
                var t = terminalJSON(address)
                t["argv"] = p["argv"] ?? .array([])
                t["cwd"] = p["cwd"] ?? "/home/test"
                t["labels"] = p["labels"] ?? .object([:])
                t["keep"] = p["keep"] ?? false
                s.terminals[address] = t
                s.order.append(address)
                emit("created", terminal: address, t)
                return .success(t)
            case "terminal.kill":
                let a = p["terminal"]?.string ?? ""
                guard var t = s.terminals[a] else { return notFound(a) }
                t["state"] = "finished"
                t["reason"] = "killed"
                s.terminals[a] = t
                emit("finished", terminal: a, ["reason": "killed", "exit_code": .null, "signal": 9])
                return .success(t)
            case "terminal.label":
                let a = p["terminal"]?.string ?? ""
                guard var t = s.terminals[a] else { return notFound(a) }
                var labels = t["labels"]?.object ?? JSONObject()
                for (k, v) in p["labels"]?.object ?? JSONObject() {
                    if v.string == "" { labels[k] = nil } else { labels[k] = v }
                }
                t["labels"] = .object(labels)
                s.terminals[a] = t
                emit("labels", terminal: a, ["labels": .object(labels)])
                return .success(t)
            case "terminal.get":
                let a = p["terminal"]?.string ?? ""
                return s.terminals[a].map { .success($0) } ?? notFound(a)
            case "machine.exec":
                let argv = p["argv"]?.array?.compactMap(\.string) ?? []
                func out(_ code: Int, _ stdout: String, _ stderr: String = "") -> Result<JSONValue, CoreError> {
                    .success(["code": .int(Int64(code)), "stdout": .string(Data(stdout.utf8).base64EncodedString()),
                              "stderr": .string(Data(stderr.utf8).base64EncodedString()), "ms": 1, "timed_out": false,
                              "truncated": false, "signal": .null])
                }
                if argv.contains(where: { $0.contains("herdr-check-complete") }) { return out(0, s.installed) }
                if argv.contains(where: { $0.contains("$HOME") }) { return out(0, p["on"]?.string == nil ? "/home/test" : "/home/remote") }
                if argv.first == "git" { return out(128, "", "fatal: not a git repository") }
                return out(127, "", "unknown")
            case "file.read":
                let path = p["path"]?.string ?? ""
                guard let text = s.files[path] else { return notFound(path) }
                let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
                return .success(["text": .string(text), "first": 1, "last": .int(Int64(n)), "lines": .int(Int64(n))])
            default:
                return .failure(CoreError(code: -32601, message: "unknown method \(method)", kind: "unknown_method"))
            }
        }
        switch reply {
        case .success(let r): mock.reply(id, result: r)
        case .failure(let e): mock.replyError(id, code: e.code, message: e.message, kind: e.kind ?? "", hint: e.hint ?? "")
        }
        for e in events { sendEvent(e) }
    }

    /// An event line on the subscription channel.
    func sendEvent(_ line: JSONValue) {
        guard let channel = state.withLock({ $0.channel }), var data = try? line.data() else { return }
        data.append(0x0A)
        mock.send(Frame(channel: channel, kind: .data, payload: data))
    }

    /// Emits an event as the core would (bumping `seq`).
    func emit(_ type: String, terminal: String? = nil, machine: String? = nil, _ data: JSONValue) {
        let line: JSONValue = state.withLock { s in
            s.seq += 1
            var params: JSONValue = ["seq": .int(Int64(s.seq)), "type": .string(type), "data": data]
            if let terminal { params["terminal"] = .string(terminal) }
            if let machine { params["machine"] = .string(machine) }
            return ["jsonrpc": "2.0", "method": "event", "params": params]
        }
        sendEvent(line)
    }

    /// Ends a terminal on its own (the program exited).
    func exit(_ address: String) {
        state.withLock { s in
            s.terminals[address]?["state"] = "finished"
            s.terminals[address]?["reason"] = "exited"
        }
        emit("finished", terminal: address, ["reason": "exited", "exit_code": 0, "signal": .null])
    }
}

struct TimeoutError: Error {}

/// A minimal live terminal record.
func terminalJSON(_ address: String, labels: [String: String] = [:], parent: String? = nil) -> JSONValue {
    var t: JSONValue = ["address": .string(address), "argv": ["sh"], "cwd": "/home/test", "state": "live",
                        "labels": .object(JSONObject(labels.mapValues(JSONValue.string))),
                        "created_ms": 1, "screen": "exact", "cols": 80, "rows": 24, "turn": 0]
    if let parent { t["parent"] = .string(parent) }
    return t
}

/// Polls `condition` on the main actor until true (fails after `seconds`).
@MainActor
func eventually(_ seconds: Double = 5, _ what: String = "condition", _ condition: () -> Bool) async throws {
    let start = Date()
    while !condition() {
        if Date().timeIntervalSince(start) > seconds { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}
