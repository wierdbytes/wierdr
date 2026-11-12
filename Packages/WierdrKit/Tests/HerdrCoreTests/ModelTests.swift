import Foundation
import Testing
@testable import HerdrCore

@Suite struct ModelTests {
    /// A record as the live core (0.1.20) sends it.
    static let liveRecord = #"""
    {"address":"t12","argv":["/bin/zsh","-l"],"cols":120,"created_ms":1793438459102,"cwd":"/Users/mentor/dev","die_with_parent":false,"exit_code":null,"finished_ms":null,"foreground":{"argv":["pi","",""],"cwd":"/Users/mentor/dev","name":"node","pid":45625},"identity":"ghostty","keep":true,"labels":{"agent.app":"pi","herdr.space":"sp75","herdr.tab":"tb1b"},"name":null,"notify":true,"parent":null,"pid":1090,"reason":null,"reported":true,"rm":false,"rows":39,"screen":"exact","signal":null,"state":"live","status":{"app":"pi","msg":"Перезагрузка","state":"done"},"status_ms":1794323853896,"template":null,"title":"Перезагрузка","turn":13,"records":{"job":{"state":"working","progress":40}}}
    """#

    @Test func decodesLiveRecord() throws {
        let t = try JSONValue(parsing: Self.liveRecord).decode(Terminal.self)
        #expect(t.address == "t12" && t.machine == nil && t.localAddress == "t12")
        #expect(t.foreground == Foreground(pid: 45625, name: "node", argv: ["pi", "", ""], cwd: "/Users/mentor/dev"))
        #expect(t.status?.state == "done" && t.status?.app == "pi")
        #expect(t.labels["herdr.space"] == "sp75")
        #expect(t.keep && t.isLive && t.turn == 13 && t.cols == 120 && t.rows == 39)
        #expect(t.records?["job"]?["progress"] == .int(40))
        #expect(t.exitCode == nil && t.parent == nil)
    }

    @Test func toleratesMinimalAndOddRecords() throws {
        let t = try JSONValue(parsing: #"{"address":"lf/t1","cols":"wide","status":"weird","future_field":[1]}"#).decode(Terminal.self)
        #expect(t.address == "lf/t1" && t.machine == "lf" && t.localAddress == "t1")
        #expect(t.cols == 0 && t.status == nil && t.labels.isEmpty && t.state == "live")
        #expect(throws: DecodingError.self) { try JSONValue(parsing: #"{"cols":1}"#).decode(Terminal.self) }
    }

    @Test func terminalEncodesAndDecodesBack() throws {
        let t = try JSONValue(parsing: Self.liveRecord).decode(Terminal.self)
        let back = try JSONDecoder().decode(Terminal.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }

    @Test func displayEncodesAllMembers() throws {
        let d = Display(fg: "#ffffff", cell: .init(width: 8, height: 16))
        let v = try JSONValue(encoding: d)
        #expect(v == ["fg": "#ffffff", "bg": .null, "cursor": .null, "cell": [8, 16]])
        #expect(try v.decode(Display.self) == d)
    }

    @Test func paramsUseWireNames() throws {
        let p = try JSONValue(encoding: AttachParams(terminal: "t1", cols: 80, rows: 24, observe: true, resizeNotifications: true))
        #expect(p["resize_notifications"] == true && p["observe"] == true && p["display"]?["fg"] == .null)
        let r = try JSONValue(encoding: RunParams(argv: ["sh"], size: .init(cols: 10, rows: 5), noParent: true))
        #expect(r["no_parent"] == true && r["size"]?["cols"] == 10 && r["line"] == nil)
        let s = try JSONValue(encoding: SubscribeParams(childrenOf: "t1"))
        #expect(s == ["children_of": "t1"])
        let e = try JSONValue(encoding: ExecParams(argv: ["cat"], input: Data("hi".utf8)))
        #expect(e["input"] == "aGk=")
    }

    @Test func parsesEvents() throws {
        func event(_ text: String) throws -> CoreEvent {
            try #require(CoreEvent.parse(JSONValue(parsing: text)))
        }
        let created = try event(#"{"jsonrpc":"2.0","method":"event","params":{"seq":5,"type":"created","terminal":"t9","data":\#(Self.liveRecord)}}"#)
        guard case .created(let t) = created.kind else { Issue.record("not created"); return }
        #expect(created.seq == 5 && created.terminal == "t9" && t.address == "t12")

        let status = try event(#"{"method":"event","params":{"seq":6,"type":"status","terminal":"t9","data":{"status":null,"records":{},"reported":true}}}"#)
        guard case .status(nil, let records, true) = status.kind else { Issue.record("not status"); return }
        #expect(records == .object([:]))

        let doc = try event(#"{"method":"event","params":{"seq":7,"type":"doc","machine":"lf","data":{"name":"herdr-app","version":3}}}"#)
        guard case .doc("herdr-app", 3) = doc.kind else { Issue.record("not doc"); return }
        #expect(doc.machine == "lf" && doc.terminal == nil)

        let fg = try event(#"{"method":"event","params":{"seq":8,"type":"foreground","terminal":"t9","data":null}}"#)
        guard case .foreground(nil) = fg.kind else { Issue.record("not foreground"); return }

        let hb = try event(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":42}}"#)
        guard case .heartbeat = hb.kind else { Issue.record("not heartbeat"); return }
        #expect(hb.seq == 42)

        let missed = try event(#"{"method":"missed","params":{"seq":57,"terminals":[\#(Self.liveRecord)]}}"#)
        guard case .missed(let ts) = missed.kind else { Issue.record("not missed"); return }
        #expect(ts.count == 1)

        let future = try event(#"{"method":"event","params":{"seq":9,"type":"teleported","terminal":"t9","data":{"to":"mars"}}}"#)
        guard case .unknown("teleported", let data) = future.kind else { Issue.record("not unknown"); return }
        #expect(data["to"] == "mars")

        let broken = try event(#"{"method":"event","params":{"seq":10,"type":"size","terminal":"t9","data":{"cols":"x"}}}"#)
        guard case .unknown("size", _) = broken.kind else { Issue.record("not unknown"); return }
    }

    @Test func appliesEvents() throws {
        var t = try JSONValue(parsing: Self.liveRecord).decode(Terminal.self)
        t.apply(.title("new"))
        t.apply(.size(cols: 10, rows: 5))
        t.apply(.labels(["a": "b"], record: nil))
        t.apply(.status(status: nil, records: nil, reported: true))
        t.apply(.finished(TerminalEnd(reason: "exited", exitCode: 0, signal: nil, finishedMs: 9)))
        #expect(t.title == "new" && t.cols == 10 && t.labels == ["a": "b"] && t.status == nil)
        #expect(t.isFinished && t.reason == "exited" && t.exitCode == 0 && t.foreground == nil && t.finishedMs == 9)
    }

    @Test func aStatusChangeMovesStatusMs() throws {
        var t = try JSONValue(parsing: Self.liveRecord).decode(Terminal.self)
        t.statusMs = 1000
        let working = TerminalStatus(state: "working", msg: "a")
        t.apply(.status(status: working, records: nil, reported: true))
        let changed = try #require(t.statusMs)
        #expect(changed > 1000)
        // The same state with another message is no change.
        t.apply(.status(status: TerminalStatus(state: "working", msg: "b"), records: nil, reported: true))
        #expect(t.statusMs == changed)
    }

    @Test func coreErrorFromJSON() throws {
        let e = CoreError(json: try JSONValue(parsing: #"{"code":-32000,"message":"no terminal \"t999\"","data":{"hint":"see `hc ls --all`","kind":"not_found"}}"#))
        #expect(e.code == -32000 && e.kind == "not_found" && e.hint == "see `hc ls --all`" && e.isNotFound)
        #expect(e.message == #"no terminal "t999""#)
        let conflict = DocConflict(name: "x", expectedVersion: 99, error: CoreError(code: -32000, message: #"document "x" is at version 3, not 99"#, kind: "conflict"))
        #expect(conflict.currentVersion == 3)
    }
}
