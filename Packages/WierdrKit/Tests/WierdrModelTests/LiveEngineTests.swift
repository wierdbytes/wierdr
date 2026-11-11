#if os(macOS)
import Foundation
import HerdrCore
import Testing
@testable import WierdrModel

/// The engine against the real local core. Run with `WIERDR_LIVE=1`.
///
/// Safety: the user's desktop and agents run on this core. The `herdr-app`
/// document is only read (with `allowWrites: false`). The write path uses the
/// scratch document `wierdr-test-layout` and the label prefix `wierdrtest`, so
/// the desktop never adopts these terminals; only terminals carrying
/// `wierdrtest.*` labels are ever killed or removed.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIERDR_LIVE"] == "1"), .serialized, .timeLimit(.minutes(2)))
struct LiveEngineTests {
    static let scratch = "wierdr-test-layout"
    static let prefix = "wierdrtest"

    func connect() async throws -> CoreConnection {
        let connection = CoreConnection(transport: try ProcessTransport())
        try await connection.start()
        return connection
    }

    func start(_ connection: CoreConnection, _ options: EngineOptions) async throws -> (Workspace, WorkspaceEngine) {
        let ws = Workspace()
        let engine = WorkspaceEngine(workspace: ws, options: options)
        engine.log = { print("[engine] \($0)") }
        Task { try? await engine.run(on: connection) }
        try await eventually(20) { ws.phase == .live }
        return (ws, engine)
    }

    /// Kills and removes every terminal labeled `wierdrtest.*`, deletes the scratch document.
    func cleanUp(_ c: CoreConnection) async {
        if let list = try? await c.listTerminals(all: true) {
            for t in list.terminals where t.labels.keys.contains(where: { $0.hasPrefix(Self.prefix + ".") }) {
                if t.isLive { _ = try? await c.killTerminal(t.address) }
                for _ in 0..<30 {
                    if (try? await c.removeTerminal(t.address)) != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        if let d = try? await c.getDoc(Self.scratch), !d.value.isNull {
            _ = try? await c.setDoc(Self.scratch, value: .null, version: d.version)
        }
    }

    @Test func mirrorsTheRealDesktopWithoutWriting() async throws {
        let c = try await connect()
        defer { Task { await c.close() } }
        let before = try await c.getDoc("herdr-app")
        let (ws, _) = try await start(c, EngineOptions(allowWrites: false))
        #expect(!ws.spaces.isEmpty)
        #expect(ws.machines.first?.state == .ready)
        let connected = Set(ws.machines.filter { $0.state == .ready }.map(\.id))
        for space in ws.spaces where connected.contains(space.machine ?? "") {
            for tab in space.tabs {
                #expect(tab.id == tab.root.id && tab.spaceID == space.id)
                for pane in tab.panes {
                    guard let a = pane.terminal else { continue }
                    #expect(ws.terminal(a) != nil, "pane \(pane.id) shows \(a), which the engine does not know")
                    #expect(LayoutID.machine(of: a) == space.machine)
                }
            }
        }
        // Names agree with the desktop's own `where` labels ("<space> / <tab>").
        try await Task.sleep(for: .seconds(3))
        for space in ws.spaces where space.name.isEmpty {
            for tab in space.tabs {
                for pane in tab.panes {
                    guard let t = ws.terminal(pane.terminal), let w = t.labels["where"], let cut = w.range(of: " / ", options: .backwards) else { continue }
                    #expect(String(w[..<cut.lowerBound]) == space.displayName, "\(space.id)")
                }
            }
        }
        let after = try await c.getDoc("herdr-app")
        #expect(after.version == before.version, "the herdr-app document changed during a read-only run")
    }

    @Test func writePathOnAScratchDocument() async throws {
        let c = try await connect()
        defer { Task { await c.close() } }
        await cleanUp(c)
        let (ws, _) = try await start(c, EngineOptions(documentName: Self.scratch, labelPrefix: Self.prefix))
        #expect(ws.spaces.isEmpty)
        var created: Set<String> = []
        var failure: Error?
        do {
            let sp = try await ws.newSpace(machine: nil, name: " wierdr test ", folder: "/tmp")
            try await eventually(10) { ws.space(sp)?.tabs.first?.panes.first?.terminal.flatMap { ws.terminal($0) }?.isLive == true }
            let tab1 = try #require(ws.space(sp)?.tabs.first)
            let p1 = tab1.panes[0].id
            let a1 = try #require(tab1.panes[0].terminal)
            created.insert(a1)
            #expect(ws.space(sp)?.displayName == "wierdr test" && ws.space(sp)?.folder == "/tmp")
            let record = try await c.getTerminal(a1)
            #expect(record.keep && record.labels["\(Self.prefix).space"] == sp && record.labels["herdr.space"] == nil)
            #expect(record.labels["\(Self.prefix).seen"] == "0")

            let tb2 = try await ws.newTab(in: sp, after: tab1.id, name: "second")
            try await eventually { ws.space(sp)?.tabs.map(\.id) == [tab1.id, tb2] && ws.tab(tb2)?.name == "second" }
            if let a = ws.tab(tb2)?.panes.first?.terminal { created.insert(a) }

            let p2 = try await ws.split(pane: p1, direction: .right)
            let p3 = try await ws.split(pane: p2, direction: .down)
            try await eventually { ws.tab(tab1.id)?.panes.map(\.id) == [p1, p2, p3] }
            let root = try #require(ws.tab(tab1.id)?.root)
            guard case .row(let kids) = root.kind, kids.count == 2, case .column(let col) = kids[1].kind else {
                Issue.record("unexpected tree \(root)")
                throw TimeoutError()
            }
            #expect(kids[0].weight == 0.5 && kids[1].weight == 0.5 && col.map(\.id) == [p2, p3])
            for p in ws.tab(tab1.id)!.panes { if let a = p.terminal { created.insert(a) } }
            try await eventually(10) { ws.tab(tab1.id)!.panes.allSatisfy { ws.terminal($0.terminal)?.isLive == true } }

            try await ws.renameSpace(sp, to: "renamed")
            try await ws.renameTab(tb2, to: "two")
            try await eventually { ws.space(sp)?.displayName == "renamed" && ws.tab(tb2)?.displayName == "two" }

            // Someone else writes meanwhile: the next edit conflicts, re-reads and keeps their change.
            let d = try await c.getDoc(Self.scratch)
            var v = d.value
            v["x-test"] = "kept"
            try await c.setDoc(Self.scratch, value: v, version: d.version)
            try await ws.renameTab(tab1.id, to: "one")
            let afterRename = try await c.getDoc(Self.scratch)
            #expect(afterRename.value["x-test"] == "kept")
            #expect(afterRename.value.layoutSpaces.first?.layoutTabs.first?["name"] == "one")

            try await ws.moveTab(tb2, to: 0)
            try await eventually { ws.space(sp)?.tabs.map(\.id) == [tb2, tab1.id] }

            // Close a pane: the column collapses into p2 (which takes its size); p3's terminal ends.
            let a3 = try #require(ws.tab(tab1.id)?.panes.last?.terminal)
            try await ws.closePane(p3)
            try await eventually { ws.tab(tab1.id)?.panes.map(\.id) == [p1, p2] }
            if case .row(let k) = ws.tab(tab1.id)!.root.kind { #expect(k.map(\.weight) == [0.5, 0.5]) }
            let killStart = Date()
            while let t = try? await c.getTerminal(a3), t.isLive, Date().timeIntervalSince(killStart) < 10 {
                try await Task.sleep(for: .milliseconds(100))
            }
            let ended = try? await c.getTerminal(a3)
            #expect(ended == nil || ended?.isFinished == true)

            // Close the space: every terminal in it ends.
            let addresses = ws.space(sp)!.tabs.flatMap { $0.panes.compactMap(\.terminal) }
            try await ws.closeSpace(sp)
            try await eventually { ws.space(sp) == nil }
            for a in addresses {
                let start = Date()
                while let t = try? await c.getTerminal(a), t.isLive, Date().timeIntervalSince(start) < 10 {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let t = try? await c.getTerminal(a)
                #expect(t == nil || t?.isFinished == true, "\(a) still runs")
            }
            #expect(try await c.getDoc(Self.scratch).value.layoutSpaces.isEmpty)
            // None of this ever reached the desktop's document.
            let desktop = try await c.getDoc("herdr-app").value.jsonString()
            for a in created { #expect(!desktop.contains("\"\(a)\"")) }
        } catch {
            failure = error
        }
        await cleanUp(c)
        let left = try await c.listTerminals(all: true).terminals.filter { $0.labels.keys.contains { $0.hasPrefix(Self.prefix + ".") } }
        #expect(left.isEmpty, "scratch terminals survived: \(left.map(\.address))")
        if let failure { throw failure }
    }
}
#endif
