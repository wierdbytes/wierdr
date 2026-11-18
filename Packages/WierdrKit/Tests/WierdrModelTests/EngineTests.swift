import Foundation
import HerdrCore
import Testing
@testable import WierdrModel

/// The engine against an in-memory core (`FakeCore`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct EngineTests {
    static let lfMachine: JSONValue = ["name": "lf", "host": "de-1", "id": "m1", "target": "x@lf", "state": "connected",
                                       "temporary": false, "version": "0.1.14", "via": false, "session": .null]
    static let tmpMachine: JSONValue = ["name": "tmp", "host": "h", "id": "m2", "target": "x@tmp", "state": "connected",
                                        "temporary": true, "version": "0.1.14", "via": false, "session": .null]

    func makeCore(local: String = Fixture.split) -> FakeCore {
        let core = FakeCore()
        core.setDoc("herdr-app", Fixture.json(local), version: 5)
        core.setDoc("herdr-app", on: "lf", Fixture.json(Fixture.remote), version: 3)
        for a in ["t1", "t2", "t3", "t4"] { core.addTerminal(terminalJSON(a)) }
        var remote = terminalJSON("lf/t1")
        remote["cwd"] = "/home/remote/work"
        core.addTerminal(remote)
        core.state.withLock { s in
            s.machines = [Self.lfMachine, Self.tmpMachine]
            s.files["/home/test/.config/herdr-app/shared.json"] = #"{"layout":"x","space.colors":{"spA":"ansi4","gone":"ansi6"}}"#
        }
        return core
    }

    func start(_ core: FakeCore, _ options: EngineOptions = .init()) async throws -> (Workspace, WorkspaceEngine) {
        let connection = try await core.start()
        let ws = Workspace()
        let engine = WorkspaceEngine(workspace: ws, options: options)
        engine.deadPaneDelay = .milliseconds(50)
        Task { try? await engine.run(on: connection) }
        try await eventually { ws.phase == .live }
        return (ws, engine)
    }

    @Test func buildsTheWorkspace() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        #expect(ws.spaces.map(\.id) == ["spA", "spB", "lf/sp6bc8f7a059117d7f59c9102b833bdb0d"])
        #expect(ws.machines.map(\.name) == [nil, "lf"])  // temporary machines stay out
        #expect(ws.machines.allSatisfy { $0.state == .ready })
        #expect(Set(ws.terminals.keys) == ["t1", "t2", "t3", "t4", "lf/t1"])
        try await eventually { ws.home == "/home/test" && ws.space("lf/sp6bc8f7a059117d7f59c9102b833bdb0d")?.displayName == "work" }
        try await eventually { ws.space("spA")?.color == "#5b8def" }
        let a = try #require(ws.space("spA")), b = try #require(ws.space("spB"))
        #expect(a.displayName == "A" && a.tabs.map(\.displayName) == ["1", "two"])
        #expect(b.displayName == "~" && b.color == "#22a99a")
        #expect(ws.space("lf/sp6bc8f7a059117d7f59c9102b833bdb0d")?.color == "#22a99a")
        #expect(ws.pane(showing: "lf/t1")?.pane.id == "lf/pb85dd291deefc9c91d2e09e614ac4af4")
        try await eventually { ws.launchers[""]?.first { $0.id == "claude" }?.installed == true }
        #expect(ws.launchers[""]?.first { $0.id == "codex" }?.installed == false)
        #expect(ws.launchers[""]?.map(\.id).prefix(3) == ["claude", "codex", "pi"])
        #expect(core.calls("doc.set").isEmpty)
        #expect(core.calls("doc.get").filter { $0["name"] == "herdr-app" }.map { $0["on"]?.string }
            .sorted { ($0 ?? "") < ($1 ?? "") } == [nil, "lf"])
    }

    @Test func limitsFromEveryMachine() async throws {
        typealias F = LimitsFixture
        let core = makeCore()
        core.setDoc("limits", F.doc(["claude.849d2d8c": F.claude(at: 1000, used5h: 37)]), version: 2)
        core.setDoc("limits", on: "lf", F.doc(["claude.849d2d8c": F.claude(at: 2000, used5h: 41, host: "lf"),
                                                "codex.d4800446": F.codex()]), version: 7)
        let (ws, _) = try await start(core)
        try await eventually { ws.limits.map(\.id) == ["claude.849d2d8c", "codex.d4800446"] }
        #expect(ws.limits[0].windows.first?.used == 41 && ws.limits[0].host == "lf")

        // pi writes again: the doc event brings it in.
        core.setDoc("limits", F.doc(["claude.849d2d8c": F.claude(at: 3000, used5h: 50)]), version: 3)
        core.emit("doc", ["name": "limits", "version": 3])
        try await eventually { ws.limits.first?.windows.first?.used == 50 }
        // An event for a version already read reads nothing.
        let reads = { core.calls("doc.get").filter { $0["name"] == "limits" }.count }
        let before = reads()
        core.emit("doc", ["name": "limits", "version": 3])
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads() == before)
        #expect(core.calls("doc.set").isEmpty)
    }

    @Test func limitsCanBeLeftOut() async throws {
        let core = makeCore()
        core.setDoc("limits", LimitsFixture.doc(["codex.d4800446": LimitsFixture.codex()]), version: 2)
        let (ws, _) = try await start(core, EngineOptions(limitsDocument: nil))
        core.emit("doc", ["name": "limits", "version": 3])
        try await Task.sleep(for: .milliseconds(100))
        #expect(ws.limits.isEmpty)
        #expect(core.calls("doc.get").allSatisfy { $0["name"] == "herdr-app" })
    }

    @Test func newTabRunsTheTerminalThenWritesTheDocument() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        let id = try await ws.newTab(in: "spA", after: "tbA", name: "  Build ", launch: .shell)
        #expect(id.hasPrefix("tb") && id.count == 34)
        let run = try #require(core.calls("terminal.run").first)
        #expect(run["argv"] == [])
        #expect(run["labels"] == ["herdr.space": "spA", "herdr.tab": .string(id), "herdr.seen": "0"])
        #expect(run["keep"] == true && run["no_parent"] == true)
        #expect(run["env"] == ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "herdr"])
        #expect(run["cwd"] == "/home/test" && run["on"] == nil)
        let methods = core.state.withLock { $0.calls.map(\.method) }
        #expect(methods.firstIndex(of: "terminal.run")! < methods.firstIndex(of: "doc.set")!)
        let doc = try #require(core.doc("herdr-app"))
        #expect(doc.version == 6)
        let tabs = doc.value.layoutSpaces[0].layoutTabs
        #expect(tabs.map(\.nodeID) == ["tbA", id, "tbB"])
        #expect(tabs[1]["name"] == "Build")
        try await eventually { ws.tab(id)?.panes.first?.terminal != nil }
        let address = try #require(ws.tab(id)?.panes.first?.terminal)
        #expect(ws.terminal(address)?.tabID == id && ws.terminal(address)?.spaceID == "spA")
    }

    @Test func agentLaunchOnARemoteMachine() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        let pi = AgentLauncher(program: ProgramTable.builtIn.resolve(app: "pi", argv: []), run: ["pi"], installed: true)
        let id = try await ws.newSpace(machine: "lf", name: "remote", launch: .agent(pi, task: "hello"))
        #expect(id.hasPrefix("lf/sp"))
        let run = try #require(core.calls("terminal.run").first)
        #expect(run["on"] == "lf" && run["cwd"] == nil)
        #expect(run["argv"]?.array?.compactMap(\.string) == LaunchArgv.agent(["pi"], task: "hello"))
        #expect(run["labels"]?["herdr.space"]?.string == LayoutID.local(id, "lf"))
        let lf = try #require(core.doc("herdr-app", on: "lf"))
        // A new space goes first among its machine's.
        #expect(lf.value.layoutSpaces.first?.nodeID == LayoutID.local(id, "lf"))
        #expect(lf.version == 4 && lf.value.layoutSpaces.first?["name"] == "remote" && lf.value.layoutSpaces.first?["folder"] == "")
        #expect(lf.value.layoutSpaces.first?.layoutTabs.first?["root"]?.terminalAddresses.first?.contains("/") == false)
        #expect(core.doc("herdr-app")?.version == 5)
        try await eventually { ws.space(id)?.name == "remote" }
    }

    @Test func conflictReappliesTheIntent() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        core.state.withLock { s in
            s.beforeSet.append { s, key in  // another screen renames spB first
                var d = s.docs[key]!
                d.value = LayoutEdits.renameSpace(d.value, id: "spB", name: "Theirs")!
                d.version += 1
                s.docs[key] = d
            }
        }
        try await ws.renameSpace("spA", to: "Mine")
        let doc = try #require(core.doc("herdr-app"))
        #expect(doc.value.layoutSpaces.map { $0["name"]?.string } == ["Mine", "Theirs"])
        #expect(core.calls("doc.set").count == 2 && doc.version == 7)
        try await eventually { ws.space("spB")?.name == "Theirs" && ws.space("spA")?.name == "Mine" }
    }

    @Test func adoptedMeanwhileOnlyTheNameIsLeft() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        core.state.withLock { s in
            s.beforeSet.append { s, key in  // the desktop adopts the labeled terminal first (unnamed)
                let address = s.order.last!
                let labels = s.terminals[address]!["labels"]!
                var d = s.docs[key]!
                d.value = LayoutEdits.newSpace(d.value, id: labels["herdr.space"]!.string!, name: "", folder: "/live",
                                               tabID: labels["herdr.tab"]!.string!, paneID: "pDesk", address: address)!
                d.version += 1
                s.docs[key] = d
            }
        }
        let id = try await ws.newSpace(machine: nil, name: "Mine", folder: "/w")
        let doc = try #require(core.doc("herdr-app"))
        let address = core.state.withLock { $0.order.last! }
        #expect(doc.value.layoutSpaces.count == 3)
        // The desktop appended it; ours names it and moves it first.
        #expect(doc.value.layoutSpaces[0]["name"] == "Mine" && doc.value.layoutSpaces[0]["folder"] == "/live")
        #expect(doc.value.layoutSpaces.flatMap { $0.layoutTabs.flatMap { $0["root"]!.terminalAddresses } }.filter { $0 == address }.count == 1)
        #expect(doc.value.layoutSpaces.map(\.nodeID) == [id, "spA", "spB"])
        _ = ws
    }

    @Test func closingKillsTheTreeButSparesKeptSubAgents() async throws {
        let core = makeCore()
        core.addTerminal(terminalJSON("t50", parent: "t3"))
        core.addTerminal(terminalJSON("t51", parent: "mock/t50"))  // the core's own name as prefix
        core.addTerminal(terminalJSON("t52", labels: ["herdr.space": "spX"], parent: "t3"))
        let (ws, _) = try await start(core)
        try await ws.closeTab("tbB")
        let doc = try #require(core.doc("herdr-app"))
        #expect(doc.value.layoutSpaces[0].layoutTabs.map(\.nodeID) == ["tbA"])
        #expect(core.calls("terminal.kill").compactMap { $0["terminal"]?.string } == ["t3", "t50", "t51"])
        // Last pane of the last tab closes the space.
        try await ws.closePane("pV")
        #expect(core.doc("herdr-app")?.value.layoutSpaces.map(\.nodeID) == ["spA"])
        #expect(core.calls("terminal.kill").last?["terminal"] == "t4")
        try await eventually { ws.space("spB") == nil }
    }

    /// Close on a sub-agent's row: it ends, and so do the sub-agents it started, but not a kept one.
    @Test func endingASubAgentKillsItsTreeButSparesKeptOnes() async throws {
        let core = makeCore()
        core.addTerminal(terminalJSON("t50", parent: "t3"))
        core.addTerminal(terminalJSON("t51", parent: "mock/t50"))
        core.addTerminal(terminalJSON("t52", labels: ["herdr.space": "spX"], parent: "t50"))
        let (ws, _) = try await start(core)
        try await ws.endTerminal("t50")
        #expect(core.calls("terminal.kill").compactMap { $0["terminal"]?.string } == ["t50", "t51"])
        #expect(core.doc("herdr-app")?.value.layoutSpaces.count == 2)
        await #expect(throws: WorkspaceError.self) { try await ws.endTerminal("t404") }
    }

    /// Keep: a sub-agent gets a tab right after its parent's (labels first, then
    /// keep, then the document); it still shows under its parent.
    @Test func keepGivesASubAgentATabNextToItsParent() async throws {
        let core = makeCore()
        core.state.withLock { s in s.terminals["t1"]?["status"] = ["state": "working", "app": "pi"] }
        core.addTerminal(terminalJSON("t50", parent: "t1"))
        let (ws, _) = try await start(core)
        try await eventually { ws.terminal("t50") != nil && ws.terminal("t1")?.isAgent == true }
        #expect(ws.sidebarRows(for: ws.space("spA")!).first { $0.terminal?.address == "t1" }?.subtree.map(\.terminal.address) == ["t50"])
        let target = try #require(ws.keepTarget(for: "t50"))
        #expect(target.spaceID == "spA" && target.after == "tbA" && target.parent == "t1")
        let id = try await ws.keepAsTab("t50", in: target.spaceID, after: target.after)
        let label = try #require(core.calls("terminal.label").last)
        #expect(label["terminal"] == "t50" && label["labels"] == ["herdr.space": "spA", "herdr.tab": .string(id)])
        #expect(core.calls("terminal.keep").last?["keep"] == true)
        let methods = core.state.withLock { $0.calls.map(\.method) }
        #expect(methods.lastIndex(of: "terminal.label")! < methods.lastIndex(of: "terminal.keep")!)
        #expect(methods.lastIndex(of: "terminal.keep")! < methods.lastIndex(of: "doc.set")!)
        let doc = try #require(core.doc("herdr-app"))
        #expect(doc.value.layoutSpaces[0].layoutTabs.map(\.nodeID) == ["tbA", id, "tbB"])
        try await eventually { ws.pane(showing: "t50") != nil }
        // Still its parent's: under it, not a row of its own tab.
        let rows = ws.sidebarRows(for: ws.space("spA")!)
        #expect(!rows.contains { $0.terminal?.address == "t50" })
        #expect(rows.first { $0.terminal?.address == "t1" }?.subtree.first?.paneID != nil)
        // Kept already: that tab, nothing written.
        #expect(try await ws.keepAsTab("t50", in: "spA", after: "tbA") == id)
        #expect(core.doc("herdr-app")?.version == doc.version)
    }

    /// Claude Code's records come with its record and with `status` events, and go with them.
    @Test func claudeRecordsFollowStatusEvents() async throws {
        let core = makeCore()
        core.state.withLock { s in
            s.terminals["t1"]?["status"] = ["state": "working", "app": "claude-code"]
            s.terminals["t1"]?["records"] = ["bcq5ektlx": ["app": "claude-code", "state": "working",
                                                          "title": "Sleep for 25 seconds in background"]]
        }
        let (ws, _) = try await start(core)
        try await eventually { ws.terminal("t1")?.records.map(\.id) == ["bcq5ektlx"] }
        let status: JSONValue = ["state": "blocked", "app": "claude-code", "kind": "question", "msg": "Which branch?"]
        core.emit("status", terminal: "t1", ["status": status, "reported": true, "records": ClaudeCodeTests.records])
        try await eventually { ws.terminal("t1")?.records.count == 3 }
        #expect(ws.terminal("t1")?.status == .blocked && ws.terminal("t1")?.message == "Which branch?")
        let row = try #require(ws.sidebarRows(for: ws.space("spA")!).first { $0.terminal?.address == "t1" })
        #expect(row.tree.compactMap(\.record).map(\.record.title) == ["Count to five slowly", "Sleep twenty",
                                                                     "Sleep for 25 seconds in background"])
        #expect(row.kidCounts.agents == 2 && row.kidCounts.shells == 1)
        core.emit("status", terminal: "t1", ["status": ["state": "idle", "app": "claude-code"], "reported": true, "records": .null])
        try await eventually { ws.terminal("t1")?.records.isEmpty == true }
        #expect(ws.sidebarRows(for: ws.space("spA")!).first { $0.terminal?.address == "t1" }?.tree.isEmpty == true)
    }

    @Test func splitRightAndDown() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        let right = try await ws.split(pane: "pW", direction: .right)
        var root = try #require(core.doc("herdr-app")?.value.layoutSpaces[0].layoutTabs[1]["root"])
        #expect(root.nodeChildren?.map(\.nodeID) == ["pW", right])
        #expect(root.nodeChildren?.map { $0["size"] } == [["weight": 0.5], ["weight": 0.5]])
        let down = try await ws.split(pane: right, direction: .down)
        root = try #require(core.doc("herdr-app")?.value.layoutSpaces[0].layoutTabs[1]["root"])
        let col = try #require(root.nodeChildren?[1])
        #expect(col.nodeType == "column" && col["size"] == ["weight": 0.5] && col.nodeID.hasPrefix("s"))
        #expect(col.nodeChildren?.map(\.nodeID) == [right, down])
        // The split's terminal starts in the target's live folder, labeled for its tab.
        let run = try #require(core.calls("terminal.run").last)
        #expect(run["labels"]?["herdr.tab"] == "tbB" && run["cwd"] == "/home/test")
        try await eventually { ws.location(ofPane: down)?.tab.id == "tbB" }
    }

    @Test func moveSpaceStaysOnItsMachine() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        try await ws.moveSpace("spB", before: "spA")
        let doc = try #require(core.doc("herdr-app"))
        #expect(doc.version == 6 && doc.value.layoutSpaces.map(\.nodeID) == ["spB", "spA"])
        #expect(core.doc("herdr-app", on: "lf")?.version == 3)
        try await eventually { ws.spaces.map(\.id) == ["spB", "spA", "lf/sp6bc8f7a059117d7f59c9102b833bdb0d"] }
        // Another machine's spaces aren't in its document: no such move.
        await #expect(throws: WorkspaceError.self) { try await ws.moveSpace("spA", before: "lf/sp6bc8f7a059117d7f59c9102b833bdb0d") }
        await #expect(throws: WorkspaceError.self) { try await ws.moveSpace("spGone", before: nil) }
        #expect(core.calls("doc.set").count == 1)
    }

    @Test func noOpsAreNeverWritten() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        try await ws.renameSpace("spA", to: " A ")
        try await ws.renameTab("tbB", to: "two")
        try await ws.moveTab("tbA", to: 0)
        try await ws.moveSpace("spA", before: "spB")
        try await ws.moveSpace("spB", before: nil)
        #expect(core.calls("doc.set").isEmpty)
        await #expect(throws: WorkspaceError.self) { try await ws.renameTab("tbGone", to: "x") }
    }

    @Test func readOnlyNeverWrites() async throws {
        let core = makeCore()
        core.addTerminal({ var t = terminalJSON("t9"); t["status"] = ["state": "idle"]; t["turn"] = 2; return t }())
        let (ws, _) = try await start(core, EngineOptions(allowWrites: false))
        await #expect(throws: WorkspaceError.self) { try await ws.newSpace(machine: nil) }
        await #expect(throws: WorkspaceError.self) { try await ws.closeSpace("spA") }
        await #expect(throws: WorkspaceError.self) { try await ws.renameTab("tbA", to: "x") }
        ws.markSeen(["t9"])
        ws.setPinned("t9", true)
        core.exit("t2")
        try await Task.sleep(for: .milliseconds(300))
        for m in ["doc.set", "terminal.run", "terminal.kill", "terminal.label", "terminal.keep"] { #expect(core.calls(m).isEmpty, "\(m)") }
    }

    @Test func undecodableLayoutBlocksCommands() async throws {
        let core = makeCore(local: #"{"spaces":[{"id":"sp","name":null,"tabs":[]}]}"#)
        let (ws, _) = try await start(core)
        #expect(ws.machines.first?.state != .ready)
        await #expect(throws: WorkspaceError.self) { try await ws.newSpace(machine: nil) }
        #expect(core.calls("terminal.run").isEmpty && core.calls("doc.set").isEmpty)
        // The remote machine's layout still works.
        #expect(ws.spaces.map(\.machine) == ["lf"])
    }

    @Test func seenIsSharedOncePerTurnAndOnlyRaised() async throws {
        let core = makeCore()
        var agent = terminalJSON("t5", labels: ["herdr.seen": "2"])
        agent["status"] = ["state": "idle", "app": "pi"]
        agent["turn"] = 3
        core.addTerminal(agent)
        let (ws, _) = try await start(core)
        #expect(ws.terminal("t5")?.status == .done)
        ws.markSeen(["t5"])
        try await eventually { ws.terminal("t5")?.status == .idle }
        ws.markSeen(["t5"])
        try await eventually { core.calls("terminal.label").count == 1 }
        #expect(core.calls("terminal.label").first?["labels"] == ["herdr.seen": "3"])
        // Next turn ends: done again, then seen again with the new turn.
        core.emit("status", terminal: "t5", ["status": ["state": "working", "app": "pi"], "reported": true])
        core.emit("turn", terminal: "t5", ["turn": 4, "state": "idle"])
        core.emit("status", terminal: "t5", ["status": ["state": "idle", "app": "pi"], "reported": true])
        try await eventually { ws.terminal("t5")?.status == .done }
        ws.markSeen(["t5"])
        try await eventually { core.calls("terminal.label").count == 2 }
        #expect(core.calls("terminal.label").last?["labels"] == ["herdr.seen": "4"])
        ws.markUnread("t5")
        try await eventually { core.calls("terminal.label").count == 3 && ws.terminal("t5")?.status == .done }
        #expect(core.calls("terminal.label").last?["labels"] == ["herdr.seen": "3"])
        ws.markSeen(["t5"])  // still on screen in the same turn: unread stays
        try await Task.sleep(for: .milliseconds(100))
        #expect(core.calls("terminal.label").count == 3)
        ws.setPinned("t5", true)
        try await eventually { ws.terminal("t5")?.pinned == true && core.calls("terminal.label").count == 4 }
        // The pin's value is when it was made (Unix seconds): the iPhone's list puts the newest on top.
        let pin = try #require(core.calls("terminal.label").last?["labels"]?["herdr.pinned"]?.string)
        #expect(abs((Double(pin) ?? 0) - Date().timeIntervalSince1970) < 60)
        #expect(ws.terminal("t5")?.pinnedAt != nil)
    }

    @Test func unreadClearsWhenLookedAtAgain() async throws {
        let core = makeCore()
        var agent = terminalJSON("t5", labels: ["herdr.seen": "3"])
        agent["status"] = ["state": "idle", "app": "pi"]
        agent["turn"] = 3
        core.addTerminal(agent)
        let (ws, _) = try await start(core)
        #expect(ws.terminal("t5")?.status == .idle)
        func labelWrites(_ n: Int) -> Bool { core.calls("terminal.label").count == n }
        func lastWrite() -> JSONValue? { core.calls("terminal.label").last?["labels"] }

        // Marked unread from the sidebar while another tab is on screen; switching to it clears it.
        ws.markSeen(["t1"])
        ws.markUnread("t5")
        try await eventually { labelWrites(1) && ws.terminal("t5")?.status == .done }
        #expect(lastWrite() == ["herdr.seen": "2"])
        ws.markSeen(["t5"])
        try await eventually { labelWrites(2) && ws.terminal("t5")?.status == .idle }
        #expect(lastWrite() == ["herdr.seen": "3"])

        // Marked unread on screen: it stays until it leaves the screen (here: the app
        // goes to the background) and comes back.
        try await eventually { ws.terminal("t5")?.labels["herdr.seen"] == "3" }
        ws.markUnread("t5")
        try await eventually { labelWrites(3) && ws.terminal("t5")?.status == .done }
        ws.markSeen(["t5"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(labelWrites(3))
        ws.markSeen([])
        ws.markSeen(["t5"])
        try await eventually { labelWrites(4) && ws.terminal("t5")?.status == .idle }

        // Another client marks it unread after our write came back: shown here too.
        try await eventually { ws.terminal("t5")?.labels["herdr.seen"] == "3" }
        ws.markSeen(["t1"])
        core.state.withLock { $0.terminals["t5"]?["labels"] = ["herdr.seen": "2"] }
        core.emit("labels", terminal: "t5", ["labels": ["herdr.seen": "2"]])
        try await eventually { ws.terminal("t5")?.status == .done }

        // "Mark idle" from the sidebar, off screen; again on an idle agent writes nothing.
        ws.markRead("t5")
        try await eventually { labelWrites(5) && ws.terminal("t5")?.status == .idle }
        #expect(lastWrite() == ["herdr.seen": "3"])
        ws.markRead("t5")
        try await Task.sleep(for: .milliseconds(100))
        #expect(labelWrites(5))
    }

    @Test func docEventsReread() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        core.state.withLock { s in
            var d = s.docs[FakeCore.key("herdr-app", "lf")]!
            d.value = LayoutEdits.renameSpace(d.value, id: "sp6bc8f7a059117d7f59c9102b833bdb0d", name: "Box")!
            d.version += 1
            s.docs[FakeCore.key("herdr-app", "lf")] = d
        }
        core.emit("doc", machine: "lf", ["name": "herdr-app", "version": 4])
        try await eventually { ws.space("lf/sp6bc8f7a059117d7f59c9102b833bdb0d")?.displayName == "Box" }
        // Other documents' events are ignored.
        core.emit("doc", ["name": "other", "version": 9])
        #expect(core.calls("doc.get").filter { $0["name"] == "other" }.isEmpty)
    }

    @Test func endedTerminalLosesItsPane() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core)
        core.exit("t2")
        try await eventually { core.doc("herdr-app")?.version == 6 }
        let root = try #require(core.doc("herdr-app")?.value.layoutSpaces[0].layoutTabs[0]["root"])
        #expect(root.nodeChildren?.map(\.nodeID) == ["pX", "pZ"])  // the column collapsed into pZ
        #expect(core.calls("terminal.kill").isEmpty)
        try await eventually { ws.location(ofPane: "pY") == nil }
    }

    @Test func machinesComeAndGo() async throws {
        let core = makeCore()
        let (ws, _) = try await start(core, EngineOptions(machinePollInterval: 0.1))
        core.state.withLock { s in
            var m = Self.lfMachine
            m["state"] = "unreachable"
            m["why"] = "timeout"
            s.machines = [m]
        }
        try await eventually { ws.machines.last?.state == .unavailable("unreachable: timeout") }
        #expect(ws.spaces.contains { $0.machine == "lf" })  // last known layout stays visible
        await #expect(throws: WorkspaceError.self) { try await ws.newSpace(machine: "lf") }
        core.state.withLock { $0.machines = [] }
        try await eventually { ws.machines.count == 1 && !ws.spaces.contains { $0.machine == "lf" } }
    }
}
