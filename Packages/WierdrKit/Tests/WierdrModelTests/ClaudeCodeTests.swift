import Foundation
import HerdrCore
import Testing
@testable import WierdrModel

/// Claude Code as Wierdr shows it: its 7501 status (app `claude-code`), the `agent.*`
/// labels its plugin (cc@wierdr) writes, its records (background sub-agents and shells).
@Suite struct ClaudeCodeTests {
    /// The plugin's labels, live values from Claude Code 2.1.327.
    static let labels: [String: String] = [
        "agent.app": "claude-code", "agent.pid": "71234", "agent.provider": "anthropic",
        "agent.model": "Claude Opus 5.5", "agent.model_id": "claude-opus-5-5", "agent.effort": "high",
        "agent.ctx": "84312", "agent.ctx_max": "200000", "agent.cache_until": "1794356000000",
        "agent.cache_ttl": "3600000", "agent.session": "5f0c2a41-7d3e-4b8a-9c61-2e8f4d1a7b30", "agent.subagents": "1",
    ]

    /// `hc get <t> --json` while Claude ran two background sub-agents and a background shell.
    static let records = Fixture.json(#"""
    {"a445e47c8be43ef46": {"app": "claude-code", "state": "working", "title": "Count to five slowly"},
     "a8324c80d4747b666": {"app": "claude-code", "state": "working", "title": "Sleep twenty"},
     "bcq5ektlx": {"app": "claude-code", "state": "working", "title": "Sleep for 25 seconds in background"}}
    """#)

    @Test func labelsThroughAgentMeta() throws {
        let meta = try #require(AgentLabels.meta(labels: Self.labels, foregroundPID: 71234))
        #expect(meta.provider == "anthropic" && meta.providerAsset == "provider.anthropic")
        #expect(meta.model == "Opus 5.5" && meta.effort == "high")
        #expect(meta.ctx == 84_312 && meta.ctxMax == 200_000)
        #expect(meta.cacheUntil == Date(timeIntervalSince1970: 1_794_356_000) && meta.cacheTTL == 3600)
        #expect(meta.session == "5f0c2a41-7d3e-4b8a-9c61-2e8f4d1a7b30" && meta.subagents == 1)
        for effort in ["low", "medium", "xhigh", "max"] {
            var l = Self.labels
            l["agent.effort"] = effort
            #expect(AgentLabels.meta(labels: l, foregroundPID: 71234)?.effort == effort)
        }
        // The pid is Claude's, the terminal's foreground: another program there (Claude quit
        // into the shell) makes them stale.
        #expect(AgentLabels.meta(labels: Self.labels, foregroundPID: 70001) == nil)
        // Through the deriver: the record's foreground decides.
        let deriver = TerminalDeriver(prefix: "herdr")
        let t = Fixture.terminal("t7", fg: ["claude"], fgName: "claude", status: TerminalStatus(state: "working", app: "claude-code"),
                                 labels: Self.labels, pid: 71234)
        let info = deriver.info(t, seenTurn: nil, locallySeen: true)
        #expect(info.program.key == "claude" && info.app == "claude-code" && info.meta?.model == "Opus 5.5")
        var quit = t
        quit.foreground = Foreground(pid: 70001, name: "zsh", argv: ["-zsh"], cwd: "/")
        #expect(deriver.info(quit, seenTurn: nil, locallySeen: true).meta == nil)
    }

    @Test func titleRule() {
        let claude = Program(key: "claude", name: "Claude Code", iconAsset: "program.claude", tint: false, isAgent: true)
        let pi = Program(key: "pi", name: "Pi", iconAsset: "program.pi", isAgent: true)
        func t(_ program: Program, app: String, _ status: AgentStatus, msg: String?, title: String) -> TerminalInfo {
            TerminalInfo(address: "t1", title: title, program: program, status: status,
                         state: status == .blocked ? "blocked" : "working", message: msg, app: app)
        }
        let named = Tab(id: "tb", spaceID: "sp", name: "queue", index: 0, root: PaneNode(id: "tb", kind: .row([])))
        // pi: its message (its session's name) first, as before.
        #expect(AgentText.title(t(pi, app: "pi", .working, msg: "Session", title: "π - wierdr"), tab: nil) == "Session")
        #expect(AgentText.title(t(pi, app: "pi", .idle, msg: nil, title: "π - wierdr"), tab: named) == "queue")
        // Claude working, idle, done: its session's title, not the passing message.
        for s in [AgentStatus.working, .idle, .done] {
            #expect(AgentText.title(t(claude, app: "claude-code", s, msg: "1 shell still running", title: "Ok reply test"),
                                    tab: named) == "Ok reply test")
        }
        // Needs you (blocked, error): the question.
        #expect(AgentText.title(t(claude, app: "claude-code", .blocked, msg: "approve Bash: rm -rf build", title: "Ok reply test"),
                                tab: nil) == "approve Bash: rm -rf build")
        // Blocked without a message: the title.
        #expect(AgentText.title(t(claude, app: "claude-code", .blocked, msg: "", title: "Ok reply test"), tab: nil) == "Ok reply test")
        // No telling title (Claude's own "Claude Code", a path): the message, then the fallbacks.
        #expect(AgentText.title(t(claude, app: "claude-code", .working, msg: "Reading files", title: "Claude Code"), tab: nil) == "Reading files")
        #expect(AgentText.title(t(claude, app: "claude-code", .idle, msg: nil, title: "mentor@mac: ~/dev"), tab: named) == "queue")
        #expect(AgentText.title(t(claude, app: "claude-code", .idle, msg: nil, title: ""), tab: nil) == "Claude Code")
        // Another app keeps the message-first rule, Claude's program or not.
        #expect(AgentText.title(t(claude, app: "claude", .working, msg: "Detail", title: "Ok reply test"), tab: nil) == "Detail")
    }

    @Test func recordsParse() {
        let records = StatusRecords.parse(Self.records)
        #expect(records.map(\.id) == ["a445e47c8be43ef46", "a8324c80d4747b666", "bcq5ektlx"])
        #expect(records.map(\.title) == ["Count to five slowly", "Sleep twenty", "Sleep for 25 seconds in background"])
        #expect(records.map(\.kind) == [.agent, .agent, .shell])
        #expect(records.allSatisfy { $0.status == .working && $0.app == "claude-code" })
        // Blocked with its question; no title: its message, else its id; cleared ones left out.
        let more = StatusRecords.parse(Fixture.json(#"""
        {"a1": {"state": "blocked", "kind": "permission", "msg": "approve Bash: ls", "title": "Look around"},
         "a2": {"state": "error", "msg": "boom"}, "a3": {"state": "working"}, "a4": {"state": ""}, "a5": {"title": "x"},
         "job": {"state": "working", "progress": 40}}
        """#))
        #expect(more.map(\.id) == ["a1", "a2", "a3", "job"])
        #expect(more[0].status == .blocked && more[0].blockedKind == "permission" && more[0].message == "approve Bash: ls")
        #expect(more[0].title == "Look around" && more[1].title == "boom" && more[1].status == .blocked && more[2].title == "a3")
        #expect(more[3].progress == 40 && more[3].kind == .agent)
        #expect(StatusRecords.parse(nil).isEmpty && StatusRecords.parse(.null).isEmpty && StatusRecords.parse(.object([:])).isEmpty)
        // Only Claude's `b` + 8 base-36 ids are shells.
        #expect(TaskRecord.kind(id: "bcq5ektlx", app: "pi") == .agent)
        #expect(TaskRecord.kind(id: "bcq5ektl", app: "claude-code") == .agent)
        #expect(TaskRecord.kind(id: "bCQ5EKTLX", app: "claude-code") == .agent)
        // Through the deriver; an ended terminal reports nothing.
        let deriver = TerminalDeriver(prefix: "herdr")
        var t = Fixture.terminal("t7", fg: ["claude"], status: TerminalStatus(state: "working", app: "claude-code"))
        t.records = Self.records
        #expect(deriver.info(t, seenTurn: nil, locallySeen: true).records.count == 3)
        t.state = "finished"
        #expect(deriver.info(t, seenTurn: nil, locallySeen: true).records.isEmpty)
    }

    /// Records are rows of the tree, each terminal's after its children, by id; they
    /// don't count as agents (status ring, cards, Live Activity) nor in the urgency; the
    /// badges count them: max(`agent.subagents`, sub-agent records) per terminal, shells
    /// with the terminals.
    @MainActor @Test func recordsInTheTree() {
        let now = Date()
        func rec(_ id: String, _ state: String = "working") -> TaskRecord {
            TaskRecord(id: id, app: "claude-code", state: state, title: id)
        }
        var claude = TerminalInfo(address: "c", createdAt: now, status: .idle, state: "idle", app: "claude-code",
                                  statusChangedAt: now.addingTimeInterval(-60),
                                  records: [rec("a8324c80d4747b666", "blocked"), rec("a445e47c8be43ef46"), rec("bcq5ektlx")].sorted { $0.id < $1.id })
        claude.meta = AgentMeta(subagents: 1)
        let terms: [TerminalInfo] = [
            claude,
            // c's sub-agent (hc run), a Claude with a record of its own, and a plain terminal.
            TerminalInfo(address: "k1", createdAt: now.addingTimeInterval(-30), status: .working, state: "working",
                         app: "claude-code", parent: "c", records: [rec("a0000000000000001")]),
            TerminalInfo(address: "k2", createdAt: now.addingTimeInterval(-20), parent: "c"),
        ]
        let pane = PaneNode(id: "pc", kind: .terminal("c"))
        let ws = Workspace()
        ws.spaces = [Space(id: "sp", machine: nil, name: "", displayName: "x", folder: "",
                           tabs: [Tab(id: "tb", spaceID: "sp", name: "", index: 0, root: PaneNode(id: "tb", kind: .row([pane])))])]
        ws.terminals = Dictionary(uniqueKeysWithValues: terms.map { ($0.address, $0) })
        let row = ws.sidebarRows(for: ws.spaces[0])[0]
        #expect(row.tree.map(\.id) == ["kid:k1", "record:k1#a0000000000000001", "kid:k2",
                                       "record:c#a445e47c8be43ef46", "record:c#a8324c80d4747b666", "record:c#bcq5ektlx"])
        #expect(row.tree.map(\.lines) == [[.tee], [.pipe, .elbow], [.tee], [.tee], [.tee], [.elbow]])
        #expect(row.subtree.map(\.terminal.address) == ["k1", "k2"])
        #expect(row.subtree.map(\.lines) == [[.tee], [.tee]])
        // A blocked record doesn't make its agent need you (its own status tells), nor counts.
        #expect(row.urgency == .working)
        #expect(ws.agentCounts(in: "sp") == [.idle: 1, .working: 1])
        #expect([row].countedAgents.map(\.terminal.address) == ["c", "k1"])
        // The badges: k1, and c's in-process max(1, 2) + k1's 1; k2 and c's shell. Alert: c's blocked record.
        let counts = row.kidCounts
        #expect(counts.terminalAgents == 1 && counts.inProcess == 3 && counts.agents == 4)
        #expect(counts.terminals == 1 && counts.shells == 1 && counts.allTerminals == 2 && counts.alert)
        #expect(ws.sidebarRows(for: ws.spaces[0]).tally == SpaceTally(agents: 1, subAgents: 4, terminals: 2))
        // pi saying more than its records: its word.
        ws.terminals["c"]?.meta = AgentMeta(subagents: 5)
        #expect(ws.sidebarRows(for: ws.spaces[0])[0].kidCounts.inProcess == 6)
        // Records gone (`records: null`): the tree is the terminals'.
        ws.terminals["c"]?.records = []
        ws.terminals["k1"]?.records = []
        let bare = ws.sidebarRows(for: ws.spaces[0])[0]
        #expect(bare.tree.map(\.id) == ["kid:k1", "kid:k2"] && bare.tree.map(\.lines) == [[.tee], [.elbow]])
        // An agent with records only still has a tree to fold.
        ws.terminals["k1"]?.isLive = false
        ws.terminals["k2"]?.isLive = false
        ws.terminals["c"]?.records = [rec("bcq5ektlx")]
        let only = ws.sidebarRows(for: ws.spaces[0])[0]
        #expect(only.subtree.isEmpty && only.tree.map(\.lines) == [[.elbow]] && only.kidCounts.agents == 5)
    }

    @MainActor @Test func previewHasAFullClaude() {
        let ws = Workspace.preview()
        let t = ws.terminal("t8a")
        #expect(t?.app == "claude-code" && t?.meta?.model == "Opus 5.5" && t?.meta?.effort == "high")
        #expect(t?.meta?.cacheTTL == 3600 && t?.records.map(\.kind) == [.agent, .shell])
        if let t { #expect(AgentText.title(t, tab: nil) == "Dream jobs on the queue") }
    }
}
